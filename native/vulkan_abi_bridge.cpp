#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define VK_USE_PLATFORM_WIN32_KHR
#include <windows.h>
#include <vulkan/vulkan.h>
#define MCD_EXPORT __declspec(dllexport)
#elif defined(__APPLE__)
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>
#define MCD_EXPORT __attribute__((visibility("default")))
#else
#error Minecraft D Edition Vulkan bridge has no surface implementation
#endif

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint32_t MaxTextures = 256;
constexpr uint32_t MaxVertices = 500000;

struct Vertex {
    float position[3];
    float uv[2];
    float color[4];
};

struct Draw {
    uint32_t firstVertex;
    uint32_t vertexCount;
    uint32_t textureIndex;
    uint32_t layer;
    float transform[16];
    float fog[12];
};

struct PushConstants {
    float transform[16];
    float fog[12];
};

struct Texture {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkDescriptorSet set = VK_NULL_HANDLE;
};

void copyError(char* output, uint32_t capacity, const std::string& text) {
    if (!output || capacity == 0) return;
    const size_t count = std::min<size_t>(capacity - 1, text.size());
    std::memcpy(output, text.data(), count);
    output[count] = 0;
}

void require(VkResult result, const char* operation) {
    if (result != VK_SUCCESS)
        throw std::runtime_error(std::string(operation) + " failed (VkResult "
            + std::to_string(static_cast<int>(result)) + ")");
}

std::vector<uint32_t> readSpirv(const char* path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error(std::string("Cannot open SPIR-V shader: ") + path);
    const auto size = input.tellg();
    if (size <= 0 || (size % 4) != 0)
        throw std::runtime_error(std::string("Invalid SPIR-V shader: ") + path);
    std::vector<uint32_t> result(static_cast<size_t>(size) / 4);
    input.seekg(0);
    input.read(reinterpret_cast<char*>(result.data()), size);
    if (!input) throw std::runtime_error(std::string("Cannot read SPIR-V shader: ") + path);
    return result;
}

struct Context {
    void* window = nullptr;
    uint32_t width = 1;
    uint32_t height = 1;
    bool vsync = true;
    bool swapchainDirty = false;

    VkInstance instance = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    uint32_t queueFamily = 0;
    VkQueue queue = VK_NULL_HANDLE;

    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkFormat colorFormat = VK_FORMAT_B8G8R8A8_UNORM;
    VkExtent2D extent{};
    std::vector<VkImage> swapImages;
    std::vector<VkImageView> swapViews;
    std::vector<VkFramebuffer> framebuffers;
    VkRenderPass renderPass = VK_NULL_HANDLE;
    VkRenderPass overlayRenderPass = VK_NULL_HANDLE;
    VkImage depthImage = VK_NULL_HANDLE;
    VkDeviceMemory depthMemory = VK_NULL_HANDLE;
    VkImageView depthView = VK_NULL_HANDLE;

    VkDescriptorSetLayout descriptorLayout = VK_NULL_HANDLE;
    VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
    VkSampler sampler = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
    std::array<VkPipeline, 5> pipelines{};

    VkCommandPool commandPool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkSemaphore imageAvailable = VK_NULL_HANDLE;
    VkSemaphore renderingFinished = VK_NULL_HANDLE;
    VkFence frameFence = VK_NULL_HANDLE;

    VkBuffer vertexBuffer = VK_NULL_HANDLE;
    VkDeviceMemory vertexMemory = VK_NULL_HANDLE;
    void* mappedVertices = nullptr;
    std::vector<Texture> textures;
    uint32_t blurTexture = 0;
    bool blurInitialized = false;

    std::vector<uint32_t> vertexShader;
    std::vector<uint32_t> pixelShader;
    std::vector<uint32_t> blurPixelShader;

    ~Context() { cleanup(); }

    uint32_t memoryType(uint32_t bits, VkMemoryPropertyFlags properties) {
        VkPhysicalDeviceMemoryProperties available{};
        vkGetPhysicalDeviceMemoryProperties(physical, &available);
        for (uint32_t i = 0; i < available.memoryTypeCount; ++i)
            if ((bits & (1u << i)) &&
                (available.memoryTypes[i].propertyFlags & properties) == properties)
                return i;
        throw std::runtime_error("Vulkan could not find a compatible memory type");
    }

    void createBuffer(VkDeviceSize size, VkBufferUsageFlags usage,
        VkMemoryPropertyFlags properties, VkBuffer& buffer, VkDeviceMemory& memory) {
        VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        info.size = size;
        info.usage = usage;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        require(vkCreateBuffer(device, &info, nullptr, &buffer), "vkCreateBuffer");
        VkMemoryRequirements requirements{};
        vkGetBufferMemoryRequirements(device, buffer, &requirements);
        VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits, properties);
        require(vkAllocateMemory(device, &allocation, nullptr, &memory), "vkAllocateMemory");
        require(vkBindBufferMemory(device, buffer, memory, 0), "vkBindBufferMemory");
    }

    void beginCommands() {
        require(vkResetCommandPool(device, commandPool, 0), "vkResetCommandPool");
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        require(vkBeginCommandBuffer(command, &begin), "vkBeginCommandBuffer");
    }

    void submitAndWait() {
        require(vkEndCommandBuffer(command), "vkEndCommandBuffer");
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &command;
        require(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit");
        require(vkQueueWaitIdle(queue), "vkQueueWaitIdle");
    }

    void transition(VkImage image, VkImageLayout before, VkImageLayout after) {
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.oldLayout = before;
        barrier.newLayout = after;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;
        VkPipelineStageFlags sourceStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        VkPipelineStageFlags destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        if (before == VK_IMAGE_LAYOUT_UNDEFINED
            && after == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        } else if (before == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
            && after == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
            sourceStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            destinationStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else if (before == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            && after == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            sourceStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (before == VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
            && after == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) {
            barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            sourceStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (before == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
            && after == VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) {
            barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            sourceStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            destinationStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        } else {
            throw std::runtime_error("Unsupported Vulkan image transition");
        }
        vkCmdPipelineBarrier(command, sourceStage, destinationStage, 0,
            0, nullptr, 0, nullptr, 1, &barrier);
    }

    uint32_t uploadTexture(const uint8_t* rgba, uint32_t textureWidth,
        uint32_t textureHeight) {
        if (!rgba || textureWidth == 0 || textureHeight == 0)
            throw std::runtime_error("Vulkan texture has no pixels");
        if (textures.size() >= MaxTextures)
            throw std::runtime_error("Vulkan texture descriptor pool is full");

        const VkDeviceSize bytes = VkDeviceSize(textureWidth) * textureHeight * 4;
        VkBuffer staging = VK_NULL_HANDLE;
        VkDeviceMemory stagingMemory = VK_NULL_HANDLE;
        createBuffer(bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            staging, stagingMemory);
        void* mapped = nullptr;
        require(vkMapMemory(device, stagingMemory, 0, bytes, 0, &mapped), "vkMapMemory");
        std::memcpy(mapped, rgba, static_cast<size_t>(bytes));
        vkUnmapMemory(device, stagingMemory);

        Texture texture;
        VkImageCreateInfo image{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        image.imageType = VK_IMAGE_TYPE_2D;
        image.format = VK_FORMAT_R8G8B8A8_UNORM;
        image.extent = {textureWidth, textureHeight, 1};
        image.mipLevels = 1;
        image.arrayLayers = 1;
        image.samples = VK_SAMPLE_COUNT_1_BIT;
        image.tiling = VK_IMAGE_TILING_OPTIMAL;
        image.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        require(vkCreateImage(device, &image, nullptr, &texture.image), "vkCreateImage");
        VkMemoryRequirements requirements{};
        vkGetImageMemoryRequirements(device, texture.image, &requirements);
        VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        require(vkAllocateMemory(device, &allocation, nullptr, &texture.memory),
            "vkAllocateMemory(texture)");
        require(vkBindImageMemory(device, texture.image, texture.memory, 0),
            "vkBindImageMemory");

        beginCommands();
        transition(texture.image, VK_IMAGE_LAYOUT_UNDEFINED,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        VkBufferImageCopy copy{};
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = {textureWidth, textureHeight, 1};
        vkCmdCopyBufferToImage(command, staging, texture.image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        transition(texture.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        submitAndWait();
        vkDestroyBuffer(device, staging, nullptr);
        vkFreeMemory(device, stagingMemory, nullptr);

        VkImageViewCreateInfo view{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        view.image = texture.image;
        view.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view.format = image.format;
        view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        view.subresourceRange.levelCount = 1;
        view.subresourceRange.layerCount = 1;
        require(vkCreateImageView(device, &view, nullptr, &texture.view),
            "vkCreateImageView(texture)");

        VkDescriptorSetAllocateInfo setInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        setInfo.descriptorPool = descriptorPool;
        setInfo.descriptorSetCount = 1;
        setInfo.pSetLayouts = &descriptorLayout;
        require(vkAllocateDescriptorSets(device, &setInfo, &texture.set),
            "vkAllocateDescriptorSets");
        VkDescriptorImageInfo imageInfo{};
        imageInfo.imageView = texture.view;
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        VkDescriptorImageInfo samplerInfo{};
        samplerInfo.sampler = sampler;
        std::array<VkWriteDescriptorSet, 2> writes{};
        writes[0] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        writes[0].dstSet = texture.set;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        writes[0].pImageInfo = &imageInfo;
        writes[1] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        writes[1].dstSet = texture.set;
        writes[1].dstBinding = 1;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER;
        writes[1].pImageInfo = &samplerInfo;
        vkUpdateDescriptorSets(device, static_cast<uint32_t>(writes.size()),
            writes.data(), 0, nullptr);
        textures.push_back(texture);
        return static_cast<uint32_t>(textures.size() - 1);
    }

    void createBlurCapture() {
        if (textures.empty()) {
            Texture texture;
            VkDescriptorSetAllocateInfo setInfo{
                VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
            setInfo.descriptorPool = descriptorPool;
            setInfo.descriptorSetCount = 1;
            setInfo.pSetLayouts = &descriptorLayout;
            require(vkAllocateDescriptorSets(device, &setInfo, &texture.set),
                "vkAllocateDescriptorSets(blur)");
            textures.push_back(texture);
            blurTexture = 0;
        }
        Texture& texture = textures[blurTexture];
        VkImageCreateInfo image{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        image.imageType = VK_IMAGE_TYPE_2D;
        image.format = colorFormat;
        image.extent = {extent.width, extent.height, 1};
        image.mipLevels = 1;
        image.arrayLayers = 1;
        image.samples = VK_SAMPLE_COUNT_1_BIT;
        image.tiling = VK_IMAGE_TILING_OPTIMAL;
        image.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        require(vkCreateImage(device, &image, nullptr, &texture.image),
            "vkCreateImage(blur)");
        VkMemoryRequirements requirements{};
        vkGetImageMemoryRequirements(device, texture.image, &requirements);
        VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = memoryType(requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        require(vkAllocateMemory(device, &allocation, nullptr, &texture.memory),
            "vkAllocateMemory(blur)");
        require(vkBindImageMemory(device, texture.image, texture.memory, 0),
            "vkBindImageMemory(blur)");
        VkImageViewCreateInfo view{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        view.image = texture.image;
        view.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view.format = colorFormat;
        view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        view.subresourceRange.levelCount = 1;
        view.subresourceRange.layerCount = 1;
        require(vkCreateImageView(device, &view, nullptr, &texture.view),
            "vkCreateImageView(blur)");
        VkDescriptorImageInfo imageInfo{};
        imageInfo.imageView = texture.view;
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        VkDescriptorImageInfo samplerInfo{};
        samplerInfo.sampler = sampler;
        std::array<VkWriteDescriptorSet, 2> writes{};
        writes[0] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        writes[0].dstSet = texture.set;
        writes[0].dstBinding = 0;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        writes[0].pImageInfo = &imageInfo;
        writes[1] = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        writes[1].dstSet = texture.set;
        writes[1].dstBinding = 1;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER;
        writes[1].pImageInfo = &samplerInfo;
        vkUpdateDescriptorSets(device, static_cast<uint32_t>(writes.size()),
            writes.data(), 0, nullptr);
        blurInitialized = false;
    }

    VkShaderModule shaderModule(const std::vector<uint32_t>& code) {
        VkShaderModuleCreateInfo info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        info.codeSize = code.size() * sizeof(uint32_t);
        info.pCode = code.data();
        VkShaderModule result = VK_NULL_HANDLE;
        require(vkCreateShaderModule(device, &info, nullptr, &result),
            "vkCreateShaderModule");
        return result;
    }

    VkPipeline createPipeline(bool depth, bool depthWrite, bool invertedBlend,
        bool blur = false) {
        const VkShaderModule vertex = shaderModule(vertexShader);
        const VkShaderModule pixel = shaderModule(blur ? blurPixelShader : pixelShader);
        VkPipelineShaderStageCreateInfo stages[2]{};
        stages[0] = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vertex;
        stages[0].pName = "VSMain";
        stages[1] = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = pixel;
        stages[1].pName = blur ? "PSBlur" : "PSMain";

        VkVertexInputBindingDescription binding{0, sizeof(Vertex),
            VK_VERTEX_INPUT_RATE_VERTEX};
        std::array<VkVertexInputAttributeDescription, 3> attributes{{
            {0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0},
            {1, 0, VK_FORMAT_R32G32_SFLOAT, 12},
            {2, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 20},
        }};
        VkPipelineVertexInputStateCreateInfo input{
            VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        input.vertexBindingDescriptionCount = 1;
        input.pVertexBindingDescriptions = &binding;
        input.vertexAttributeDescriptionCount = static_cast<uint32_t>(attributes.size());
        input.pVertexAttributeDescriptions = attributes.data();
        VkPipelineInputAssemblyStateCreateInfo assembly{
            VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
        assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkPipelineViewportStateCreateInfo viewport{
            VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
        viewport.viewportCount = 1;
        viewport.scissorCount = 1;
        VkPipelineRasterizationStateCreateInfo raster{
            VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        raster.polygonMode = VK_POLYGON_MODE_FILL;
        raster.cullMode = VK_CULL_MODE_NONE;
        raster.frontFace = VK_FRONT_FACE_CLOCKWISE;
        raster.lineWidth = 1.0f;
        VkPipelineMultisampleStateCreateInfo multisample{
            VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
        VkPipelineDepthStencilStateCreateInfo depthState{
            VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
        depthState.depthTestEnable = depth ? VK_TRUE : VK_FALSE;
        depthState.depthWriteEnable = depthWrite ? VK_TRUE : VK_FALSE;
        depthState.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
        VkPipelineColorBlendAttachmentState blend{};
        blend.blendEnable = VK_TRUE;
        blend.srcColorBlendFactor = invertedBlend
            ? VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR : VK_BLEND_FACTOR_SRC_ALPHA;
        blend.dstColorBlendFactor = invertedBlend
            ? VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR : VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend.colorBlendOp = VK_BLEND_OP_ADD;
        blend.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        blend.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend.alphaBlendOp = VK_BLEND_OP_ADD;
        blend.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
            VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
        VkPipelineColorBlendStateCreateInfo blendState{
            VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
        blendState.attachmentCount = 1;
        blendState.pAttachments = &blend;
        const VkDynamicState dynamicValues[] = {VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR};
        VkPipelineDynamicStateCreateInfo dynamic{
            VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
        dynamic.dynamicStateCount = 2;
        dynamic.pDynamicStates = dynamicValues;
        VkGraphicsPipelineCreateInfo info{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
        info.stageCount = 2;
        info.pStages = stages;
        info.pVertexInputState = &input;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewport;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pDepthStencilState = &depthState;
        info.pColorBlendState = &blendState;
        info.pDynamicState = &dynamic;
        info.layout = pipelineLayout;
        info.renderPass = renderPass;
        VkPipeline result = VK_NULL_HANDLE;
        const VkResult created = vkCreateGraphicsPipelines(device, VK_NULL_HANDLE,
            1, &info, nullptr, &result);
        vkDestroyShaderModule(device, pixel, nullptr);
        vkDestroyShaderModule(device, vertex, nullptr);
        require(created, "vkCreateGraphicsPipelines");
        return result;
    }

    void destroySwapchain() {
        for (auto pipeline : pipelines)
            if (pipeline) vkDestroyPipeline(device, pipeline, nullptr);
        pipelines.fill(VK_NULL_HANDLE);
        if (!textures.empty()) {
            Texture& blur = textures[blurTexture];
            if (blur.view) vkDestroyImageView(device, blur.view, nullptr);
            if (blur.image) vkDestroyImage(device, blur.image, nullptr);
            if (blur.memory) vkFreeMemory(device, blur.memory, nullptr);
            blur.view = VK_NULL_HANDLE;
            blur.image = VK_NULL_HANDLE;
            blur.memory = VK_NULL_HANDLE;
            blurInitialized = false;
        }
        for (auto framebuffer : framebuffers)
            vkDestroyFramebuffer(device, framebuffer, nullptr);
        framebuffers.clear();
        if (depthView) vkDestroyImageView(device, depthView, nullptr);
        if (depthImage) vkDestroyImage(device, depthImage, nullptr);
        if (depthMemory) vkFreeMemory(device, depthMemory, nullptr);
        depthView = VK_NULL_HANDLE;
        depthImage = VK_NULL_HANDLE;
        depthMemory = VK_NULL_HANDLE;
        if (renderPass) vkDestroyRenderPass(device, renderPass, nullptr);
        renderPass = VK_NULL_HANDLE;
        if (overlayRenderPass)
            vkDestroyRenderPass(device, overlayRenderPass, nullptr);
        overlayRenderPass = VK_NULL_HANDLE;
        for (auto view : swapViews) vkDestroyImageView(device, view, nullptr);
        swapViews.clear();
        swapImages.clear();
        if (swapchain) vkDestroySwapchainKHR(device, swapchain, nullptr);
        swapchain = VK_NULL_HANDLE;
    }

    void createSwapchain() {
        vkDeviceWaitIdle(device);
        destroySwapchain();
        VkSurfaceCapabilitiesKHR capabilities{};
        require(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface,
            &capabilities), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
        uint32_t formatCount = 0;
        require(vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface,
            &formatCount, nullptr), "vkGetPhysicalDeviceSurfaceFormatsKHR");
        std::vector<VkSurfaceFormatKHR> formats(formatCount);
        require(vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface,
            &formatCount, formats.data()), "vkGetPhysicalDeviceSurfaceFormatsKHR");
        if (formats.empty()) throw std::runtime_error("Vulkan surface has no formats");
        if (!(capabilities.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_SRC_BIT))
            throw std::runtime_error(
                "Vulkan swapchain does not support menu-blur capture");
        auto selected = formats[0];
        for (const auto& candidate : formats)
            if (candidate.format == VK_FORMAT_B8G8R8A8_UNORM) selected = candidate;
        colorFormat = selected.format;
        if (capabilities.currentExtent.width != UINT32_MAX)
            extent = capabilities.currentExtent;
        else {
            extent.width = std::clamp(width, capabilities.minImageExtent.width,
                capabilities.maxImageExtent.width);
            extent.height = std::clamp(height, capabilities.minImageExtent.height,
                capabilities.maxImageExtent.height);
        }
        uint32_t presentCount = 0;
        vkGetPhysicalDeviceSurfacePresentModesKHR(physical, surface,
            &presentCount, nullptr);
        std::vector<VkPresentModeKHR> modes(presentCount);
        vkGetPhysicalDeviceSurfacePresentModesKHR(physical, surface,
            &presentCount, modes.data());
        VkPresentModeKHR present = VK_PRESENT_MODE_FIFO_KHR;
        if (!vsync) {
            for (auto mode : modes)
                if (mode == VK_PRESENT_MODE_MAILBOX_KHR) present = mode;
            if (present == VK_PRESENT_MODE_FIFO_KHR)
                for (auto mode : modes)
                    if (mode == VK_PRESENT_MODE_IMMEDIATE_KHR) present = mode;
        }
        uint32_t imageCount = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount && imageCount > capabilities.maxImageCount)
            imageCount = capabilities.maxImageCount;
        VkSwapchainCreateInfoKHR info{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
        info.surface = surface;
        info.minImageCount = imageCount;
        info.imageFormat = selected.format;
        info.imageColorSpace = selected.colorSpace;
        info.imageExtent = extent;
        info.imageArrayLayers = 1;
        info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
            | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        info.preTransform = capabilities.currentTransform;
        info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        info.presentMode = present;
        info.clipped = VK_TRUE;
        require(vkCreateSwapchainKHR(device, &info, nullptr, &swapchain),
            "vkCreateSwapchainKHR");
        vkGetSwapchainImagesKHR(device, swapchain, &imageCount, nullptr);
        swapImages.resize(imageCount);
        vkGetSwapchainImagesKHR(device, swapchain, &imageCount, swapImages.data());
        for (auto imageHandle : swapImages) {
            VkImageViewCreateInfo view{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
            view.image = imageHandle;
            view.viewType = VK_IMAGE_VIEW_TYPE_2D;
            view.format = colorFormat;
            view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            view.subresourceRange.levelCount = 1;
            view.subresourceRange.layerCount = 1;
            VkImageView created = VK_NULL_HANDLE;
            require(vkCreateImageView(device, &view, nullptr, &created),
                "vkCreateImageView(swapchain)");
            swapViews.push_back(created);
        }

        VkAttachmentDescription attachments[2]{};
        attachments[0].format = colorFormat;
        attachments[0].samples = VK_SAMPLE_COUNT_1_BIT;
        attachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        attachments[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[0].finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        attachments[1].format = VK_FORMAT_D32_SFLOAT;
        attachments[1].samples = VK_SAMPLE_COUNT_1_BIT;
        attachments[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[1].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        VkAttachmentReference colorReference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkAttachmentReference depthReference{1,
            VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
        VkSubpassDescription subpass{};
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &colorReference;
        subpass.pDepthStencilAttachment = &depthReference;
        VkSubpassDependency dependency{};
        dependency.srcSubpass = VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
            VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dependency.dstStageMask = dependency.srcStageMask;
        dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        VkRenderPassCreateInfo render{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
        render.attachmentCount = 2;
        render.pAttachments = attachments;
        render.subpassCount = 1;
        render.pSubpasses = &subpass;
        render.dependencyCount = 1;
        render.pDependencies = &dependency;
        require(vkCreateRenderPass(device, &render, nullptr, &renderPass),
            "vkCreateRenderPass");
        attachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        attachments[0].initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        attachments[1].loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[1].initialLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        dependency.srcStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
        dependency.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        require(vkCreateRenderPass(device, &render, nullptr, &overlayRenderPass),
            "vkCreateRenderPass(overlay)");

        VkImageCreateInfo depth{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        depth.imageType = VK_IMAGE_TYPE_2D;
        depth.format = VK_FORMAT_D32_SFLOAT;
        depth.extent = {extent.width, extent.height, 1};
        depth.mipLevels = 1;
        depth.arrayLayers = 1;
        depth.samples = VK_SAMPLE_COUNT_1_BIT;
        depth.tiling = VK_IMAGE_TILING_OPTIMAL;
        depth.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        require(vkCreateImage(device, &depth, nullptr, &depthImage),
            "vkCreateImage(depth)");
        VkMemoryRequirements depthRequirements{};
        vkGetImageMemoryRequirements(device, depthImage, &depthRequirements);
        VkMemoryAllocateInfo depthAllocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        depthAllocation.allocationSize = depthRequirements.size;
        depthAllocation.memoryTypeIndex = memoryType(depthRequirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        require(vkAllocateMemory(device, &depthAllocation, nullptr, &depthMemory),
            "vkAllocateMemory(depth)");
        require(vkBindImageMemory(device, depthImage, depthMemory, 0),
            "vkBindImageMemory(depth)");
        VkImageViewCreateInfo depthViewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        depthViewInfo.image = depthImage;
        depthViewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
        depthViewInfo.format = VK_FORMAT_D32_SFLOAT;
        depthViewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
        depthViewInfo.subresourceRange.levelCount = 1;
        depthViewInfo.subresourceRange.layerCount = 1;
        require(vkCreateImageView(device, &depthViewInfo, nullptr, &depthView),
            "vkCreateImageView(depth)");
        for (auto colorView : swapViews) {
            VkImageView views[] = {colorView, depthView};
            VkFramebufferCreateInfo framebuffer{
                VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
            framebuffer.renderPass = renderPass;
            framebuffer.attachmentCount = 2;
            framebuffer.pAttachments = views;
            framebuffer.width = extent.width;
            framebuffer.height = extent.height;
            framebuffer.layers = 1;
            VkFramebuffer created = VK_NULL_HANDLE;
            require(vkCreateFramebuffer(device, &framebuffer, nullptr, &created),
                "vkCreateFramebuffer");
            framebuffers.push_back(created);
        }
        createBlurCapture();
        pipelines[0] = createPipeline(true, true, false);
        pipelines[1] = createPipeline(true, false, false);
        pipelines[2] = createPipeline(false, false, false);
        pipelines[3] = createPipeline(false, false, true);
        pipelines[4] = createPipeline(false, false, false, true);
        swapchainDirty = false;
    }

    uint32_t pipelineForLayer(uint32_t layer) const {
        switch (layer) {
            case 0: return 2; // sky
            case 1: return 0; // world
            case 2: return 1; // translucent
            case 3: return 1; // entity shadow
            case 4: return 0; // view model
            case 5: return 4; // captured-scene menu blur
            case 6: return 2; // overlay
            case 7: return 3; // inverted overlay
            default: return 0;
        }
    }

    void render(const Vertex* vertices, uint32_t vertexCount,
        const Draw* draws, uint32_t drawCount, const float* clearColor) {
        if (vertexCount > MaxVertices)
            throw std::runtime_error("Vulkan frame exceeds dynamic vertex capacity");
        require(vkWaitForFences(device, 1, &frameFence, VK_TRUE, UINT64_MAX),
            "vkWaitForFences(frame)");
        require(vkResetFences(device, 1, &frameFence),
            "vkResetFences(frame)");
        if (vertexCount) std::memcpy(mappedVertices, vertices,
            size_t(vertexCount) * sizeof(Vertex));
        if (swapchainDirty) createSwapchain();
        uint32_t imageIndex = 0;
        VkResult acquired = vkAcquireNextImageKHR(device, swapchain, UINT64_MAX,
            imageAvailable, VK_NULL_HANDLE, &imageIndex);
        if (acquired == VK_ERROR_OUT_OF_DATE_KHR) {
            createSwapchain();
            acquired = vkAcquireNextImageKHR(device, swapchain, UINT64_MAX,
                imageAvailable, VK_NULL_HANDLE, &imageIndex);
        }
        if (acquired != VK_SUCCESS && acquired != VK_SUBOPTIMAL_KHR)
            require(acquired, "vkAcquireNextImageKHR");
        beginCommands();
        VkClearValue clears[2]{};
        std::memcpy(clears[0].color.float32, clearColor, sizeof(float) * 4);
        clears[1].depthStencil = {1.0f, 0};
        VkRenderPassBeginInfo begin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
        begin.renderPass = renderPass;
        begin.framebuffer = framebuffers[imageIndex];
        begin.renderArea.extent = extent;
        begin.clearValueCount = 2;
        begin.pClearValues = clears;
        vkCmdBeginRenderPass(command, &begin, VK_SUBPASS_CONTENTS_INLINE);
        VkViewport viewport{0.0f, static_cast<float>(extent.height),
            static_cast<float>(extent.width), -static_cast<float>(extent.height),
            0.0f, 1.0f};
        VkRect2D scissor{{0, 0}, extent};
        vkCmdSetViewport(command, 0, 1, &viewport);
        vkCmdSetScissor(command, 0, 1, &scissor);
        const VkDeviceSize offset = 0;
        vkCmdBindVertexBuffers(command, 0, 1, &vertexBuffer, &offset);
        uint32_t activePipeline = UINT32_MAX;
        uint32_t previousLayer = UINT32_MAX;
        bool overlayPass = false;
        for (uint32_t i = 0; i < drawCount; ++i) {
            const Draw& draw = draws[i];
            if (draw.textureIndex >= textures.size())
                throw std::runtime_error("Vulkan draw references an unknown texture");
            if (draw.layer == 5 && !overlayPass) {
                vkCmdEndRenderPass(command);
                transition(swapImages[imageIndex], VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
                transition(textures[blurTexture].image,
                    blurInitialized ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                        : VK_IMAGE_LAYOUT_UNDEFINED,
                    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
                VkImageCopy copy{};
                copy.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                copy.srcSubresource.layerCount = 1;
                copy.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                copy.dstSubresource.layerCount = 1;
                copy.extent = {extent.width, extent.height, 1};
                vkCmdCopyImage(command, swapImages[imageIndex],
                    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    textures[blurTexture].image,
                    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
                transition(textures[blurTexture].image,
                    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
                transition(swapImages[imageIndex],
                    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
                blurInitialized = true;
                VkRenderPassBeginInfo overlayBegin{
                    VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
                overlayBegin.renderPass = overlayRenderPass;
                overlayBegin.framebuffer = framebuffers[imageIndex];
                overlayBegin.renderArea.extent = extent;
                vkCmdBeginRenderPass(command, &overlayBegin,
                    VK_SUBPASS_CONTENTS_INLINE);
                activePipeline = UINT32_MAX;
                overlayPass = true;
            }
            const uint32_t pipeline = pipelineForLayer(draw.layer);
            if (pipeline != activePipeline) {
                vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS,
                    pipelines[pipeline]);
                activePipeline = pipeline;
            }
            if (draw.layer == 4 && previousLayer != 4) {
                VkClearAttachment attachment{};
                attachment.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
                attachment.clearValue.depthStencil = {1.0f, 0};
                VkClearRect area{{{0, 0}, extent}, 0, 1};
                vkCmdClearAttachments(command, 1, &attachment, 1, &area);
            }
            previousLayer = draw.layer;
            vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS,
                pipelineLayout, 0, 1, &textures[draw.textureIndex].set,
                0, nullptr);
            PushConstants push{};
            std::memcpy(push.transform, draw.transform, sizeof(push.transform));
            std::memcpy(push.fog, draw.fog, sizeof(push.fog));
            vkCmdPushConstants(command, pipelineLayout,
                VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                0, sizeof(push), &push);
            vkCmdDraw(command, draw.vertexCount, 1, draw.firstVertex, 0);
        }
        vkCmdEndRenderPass(command);
        require(vkEndCommandBuffer(command), "vkEndCommandBuffer(frame)");
        const VkPipelineStageFlags waitStage =
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &imageAvailable;
        submit.pWaitDstStageMask = &waitStage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &command;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &renderingFinished;
        require(vkQueueSubmit(queue, 1, &submit, frameFence),
            "vkQueueSubmit(frame)");
        VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &renderingFinished;
        present.swapchainCount = 1;
        present.pSwapchains = &swapchain;
        present.pImageIndices = &imageIndex;
        const VkResult shown = vkQueuePresentKHR(queue, &present);
        if (shown == VK_ERROR_OUT_OF_DATE_KHR || shown == VK_SUBOPTIMAL_KHR)
            swapchainDirty = true;
        else require(shown, "vkQueuePresentKHR");
    }

    void initialize(void* requestedWindow, uint32_t requestedWidth,
        uint32_t requestedHeight, const char* vertexPath, const char* pixelPath,
        const char* blurPixelPath) {
        window = requestedWindow;
        width = std::max(1u, requestedWidth);
        height = std::max(1u, requestedHeight);
        vertexShader = readSpirv(vertexPath);
        pixelShader = readSpirv(pixelPath);
        blurPixelShader = readSpirv(blurPixelPath);
        VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        application.pApplicationName = "Minecraft D Edition";
        application.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
        application.pEngineName = "Minecraft D Edition";
        application.engineVersion = VK_MAKE_VERSION(0, 1, 0);
        application.apiVersion = VK_API_VERSION_1_1;
        std::vector<const char*> extensions;
        bool enumeratePortability = false;
#if defined(_WIN32)
        extensions = {VK_KHR_SURFACE_EXTENSION_NAME,
            VK_KHR_WIN32_SURFACE_EXTENSION_NAME};
#elif defined(__APPLE__)
        uint32_t sdlExtensionCount = 0;
        const char* const* sdlExtensions =
            SDL_Vulkan_GetInstanceExtensions(&sdlExtensionCount);
        if (!sdlExtensions)
            throw std::runtime_error(std::string("SDL Vulkan extensions failed: ")
                + SDL_GetError());
        uint32_t availableInstanceExtensionCount = 0;
        require(vkEnumerateInstanceExtensionProperties(nullptr,
            &availableInstanceExtensionCount, nullptr),
            "vkEnumerateInstanceExtensionProperties(count)");
        std::vector<VkExtensionProperties> availableInstanceExtensions(
            availableInstanceExtensionCount);
        require(vkEnumerateInstanceExtensionProperties(nullptr,
            &availableInstanceExtensionCount,
            availableInstanceExtensions.data()),
            "vkEnumerateInstanceExtensionProperties");
        const auto extensionAvailable = [&availableInstanceExtensions](const char* name) {
            return std::any_of(availableInstanceExtensions.begin(),
                availableInstanceExtensions.end(), [name](const auto& extension) {
                    return std::strcmp(extension.extensionName, name) == 0;
                });
        };
        for (uint32_t index = 0; index < sdlExtensionCount; ++index) {
            if (!extensionAvailable(sdlExtensions[index])) {
                std::string message = "Bundled MoltenVK is missing SDL-required "
                    "instance extension: ";
                message += sdlExtensions[index];
                throw std::runtime_error(message);
            }
            extensions.push_back(sdlExtensions[index]);
        }
        const char* portabilityEnumeration = "VK_KHR_portability_enumeration";
        if (extensionAvailable(portabilityEnumeration)) {
            if (std::find_if(extensions.begin(), extensions.end(),
                    [portabilityEnumeration](const char* value) {
                        return std::strcmp(value, portabilityEnumeration) == 0;
                    }) == extensions.end())
                extensions.push_back(portabilityEnumeration);
            enumeratePortability = true;
        }
#endif
        VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        instanceInfo.pApplicationInfo = &application;
        instanceInfo.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
        instanceInfo.ppEnabledExtensionNames = extensions.data();
#if defined(__APPLE__)
        if (enumeratePortability)
            instanceInfo.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
#endif
        require(vkCreateInstance(&instanceInfo, nullptr, &instance), "vkCreateInstance");
#if defined(_WIN32)
        VkWin32SurfaceCreateInfoKHR surfaceInfo{
            VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
        surfaceInfo.hinstance = GetModuleHandleW(nullptr);
        surfaceInfo.hwnd = static_cast<HWND>(window);
        require(vkCreateWin32SurfaceKHR(instance, &surfaceInfo, nullptr, &surface),
            "vkCreateWin32SurfaceKHR");
#elif defined(__APPLE__)
        if (!SDL_Vulkan_CreateSurface(static_cast<SDL_Window*>(window), instance,
                nullptr, &surface))
            throw std::runtime_error(std::string("SDL Vulkan surface failed: ")
                + SDL_GetError());
#endif
        uint32_t physicalCount = 0;
        require(vkEnumeratePhysicalDevices(instance, &physicalCount, nullptr),
            "vkEnumeratePhysicalDevices");
        std::vector<VkPhysicalDevice> devices(physicalCount);
        require(vkEnumeratePhysicalDevices(instance, &physicalCount, devices.data()),
            "vkEnumeratePhysicalDevices");
        for (auto candidate : devices) {
            uint32_t familyCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount, nullptr);
            std::vector<VkQueueFamilyProperties> families(familyCount);
            vkGetPhysicalDeviceQueueFamilyProperties(candidate, &familyCount,
                families.data());
            for (uint32_t family = 0; family < familyCount; ++family) {
                VkBool32 present = VK_FALSE;
                vkGetPhysicalDeviceSurfaceSupportKHR(candidate, family, surface, &present);
                if ((families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                    physical = candidate;
                    queueFamily = family;
                    break;
                }
            }
            if (physical) break;
        }
        if (!physical) throw std::runtime_error("No Vulkan graphics/present device found");
        VkPhysicalDeviceProperties properties{};
        vkGetPhysicalDeviceProperties(physical, &properties);
        if (properties.limits.maxPushConstantsSize < sizeof(PushConstants))
            throw std::runtime_error("Vulkan device push-constant limit is too small");
        const float priority = 1.0f;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queueInfo.queueFamilyIndex = queueFamily;
        queueInfo.queueCount = 1;
        queueInfo.pQueuePriorities = &priority;
        std::vector<const char*> deviceExtensions = {
            VK_KHR_SWAPCHAIN_EXTENSION_NAME};
#if defined(__APPLE__)
        uint32_t availableExtensionCount = 0;
        require(vkEnumerateDeviceExtensionProperties(physical, nullptr,
            &availableExtensionCount, nullptr),
            "vkEnumerateDeviceExtensionProperties(count)");
        std::vector<VkExtensionProperties> availableExtensions(
            availableExtensionCount);
        require(vkEnumerateDeviceExtensionProperties(physical, nullptr,
            &availableExtensionCount, availableExtensions.data()),
            "vkEnumerateDeviceExtensionProperties");
        for (const auto& extension : availableExtensions)
            if (std::strcmp(extension.extensionName,
                    "VK_KHR_portability_subset") == 0)
                deviceExtensions.push_back("VK_KHR_portability_subset");
#endif
        VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        deviceInfo.queueCreateInfoCount = 1;
        deviceInfo.pQueueCreateInfos = &queueInfo;
        deviceInfo.enabledExtensionCount =
            static_cast<uint32_t>(deviceExtensions.size());
        deviceInfo.ppEnabledExtensionNames = deviceExtensions.data();
        require(vkCreateDevice(physical, &deviceInfo, nullptr, &device),
            "vkCreateDevice");
        vkGetDeviceQueue(device, queueFamily, 0, &queue);
        VkCommandPoolCreateInfo pool{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        pool.queueFamilyIndex = queueFamily;
        require(vkCreateCommandPool(device, &pool, nullptr, &commandPool),
            "vkCreateCommandPool");
        VkCommandBufferAllocateInfo commandInfo{
            VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        commandInfo.commandPool = commandPool;
        commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        commandInfo.commandBufferCount = 1;
        require(vkAllocateCommandBuffers(device, &commandInfo, &command),
            "vkAllocateCommandBuffers");
        VkSemaphoreCreateInfo semaphore{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        require(vkCreateSemaphore(device, &semaphore, nullptr, &imageAvailable),
            "vkCreateSemaphore");
        require(vkCreateSemaphore(device, &semaphore, nullptr, &renderingFinished),
            "vkCreateSemaphore");
        VkFenceCreateInfo fence{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        fence.flags = VK_FENCE_CREATE_SIGNALED_BIT;
        require(vkCreateFence(device, &fence, nullptr, &frameFence),
            "vkCreateFence");

        VkDescriptorSetLayoutBinding bindings[2]{};
        bindings[0].binding = 0;
        bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        bindings[0].descriptorCount = 1;
        bindings[0].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        bindings[1].binding = 1;
        bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER;
        bindings[1].descriptorCount = 1;
        bindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        VkDescriptorSetLayoutCreateInfo layout{
            VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        layout.bindingCount = 2;
        layout.pBindings = bindings;
        require(vkCreateDescriptorSetLayout(device, &layout, nullptr,
            &descriptorLayout), "vkCreateDescriptorSetLayout");
        VkDescriptorPoolSize poolSizes[2]{{VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            MaxTextures}, {VK_DESCRIPTOR_TYPE_SAMPLER, MaxTextures}};
        VkDescriptorPoolCreateInfo descriptorPoolInfo{
            VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        descriptorPoolInfo.maxSets = MaxTextures;
        descriptorPoolInfo.poolSizeCount = 2;
        descriptorPoolInfo.pPoolSizes = poolSizes;
        require(vkCreateDescriptorPool(device, &descriptorPoolInfo, nullptr,
            &descriptorPool), "vkCreateDescriptorPool");
        VkSamplerCreateInfo samplerInfo{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
        samplerInfo.magFilter = VK_FILTER_NEAREST;
        samplerInfo.minFilter = VK_FILTER_NEAREST;
        samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
        samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
        samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
        samplerInfo.maxLod = 0.0f;
        require(vkCreateSampler(device, &samplerInfo, nullptr, &sampler),
            "vkCreateSampler");
        VkPushConstantRange push{};
        push.stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
        push.size = sizeof(PushConstants);
        VkPipelineLayoutCreateInfo pipelineLayoutInfo{
            VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        pipelineLayoutInfo.setLayoutCount = 1;
        pipelineLayoutInfo.pSetLayouts = &descriptorLayout;
        pipelineLayoutInfo.pushConstantRangeCount = 1;
        pipelineLayoutInfo.pPushConstantRanges = &push;
        require(vkCreatePipelineLayout(device, &pipelineLayoutInfo, nullptr,
            &pipelineLayout), "vkCreatePipelineLayout");
        createBuffer(VkDeviceSize(MaxVertices) * sizeof(Vertex),
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            vertexBuffer, vertexMemory);
        require(vkMapMemory(device, vertexMemory, 0, VK_WHOLE_SIZE, 0,
            &mappedVertices), "vkMapMemory(vertex buffer)");
        createSwapchain();
    }

    void cleanup() {
        if (!device) {
            if (surface && instance) vkDestroySurfaceKHR(instance, surface, nullptr);
            if (instance) vkDestroyInstance(instance, nullptr);
            return;
        }
        vkDeviceWaitIdle(device);
        destroySwapchain();
        for (auto& texture : textures) {
            if (texture.view) vkDestroyImageView(device, texture.view, nullptr);
            if (texture.image) vkDestroyImage(device, texture.image, nullptr);
            if (texture.memory) vkFreeMemory(device, texture.memory, nullptr);
        }
        textures.clear();
        if (mappedVertices) vkUnmapMemory(device, vertexMemory);
        if (vertexBuffer) vkDestroyBuffer(device, vertexBuffer, nullptr);
        if (vertexMemory) vkFreeMemory(device, vertexMemory, nullptr);
        if (pipelineLayout) vkDestroyPipelineLayout(device, pipelineLayout, nullptr);
        if (sampler) vkDestroySampler(device, sampler, nullptr);
        if (descriptorPool) vkDestroyDescriptorPool(device, descriptorPool, nullptr);
        if (descriptorLayout) vkDestroyDescriptorSetLayout(device, descriptorLayout, nullptr);
        if (imageAvailable) vkDestroySemaphore(device, imageAvailable, nullptr);
        if (renderingFinished) vkDestroySemaphore(device, renderingFinished, nullptr);
        if (frameFence) vkDestroyFence(device, frameFence, nullptr);
        if (commandPool) vkDestroyCommandPool(device, commandPool, nullptr);
        vkDestroyDevice(device, nullptr);
        device = VK_NULL_HANDLE;
        if (surface) vkDestroySurfaceKHR(instance, surface, nullptr);
        if (instance) vkDestroyInstance(instance, nullptr);
        surface = VK_NULL_HANDLE;
        instance = VK_NULL_HANDLE;
    }
};

} // namespace

extern "C" {

MCD_EXPORT void* mdVkCreate(void* window, uint32_t width,
    uint32_t height, const char* vertexShader, const char* pixelShader,
    const char* blurPixelShader, char* error, uint32_t errorCapacity) {
    try {
        auto* context = new Context();
        try {
            context->initialize(window, width, height,
                vertexShader, pixelShader, blurPixelShader);
            return context;
        } catch (...) {
            delete context;
            throw;
        }
    } catch (const std::exception& failure) {
        copyError(error, errorCapacity, failure.what());
        return nullptr;
    }
}

MCD_EXPORT void mdVkDestroy(void* context) {
    delete static_cast<Context*>(context);
}

MCD_EXPORT int mdVkUploadTexture(void* context, const uint8_t* rgba,
    uint32_t width, uint32_t height, uint32_t* index, char* error,
    uint32_t errorCapacity) {
    try {
        *index = static_cast<Context*>(context)->uploadTexture(rgba, width, height);
        return 1;
    } catch (const std::exception& failure) {
        copyError(error, errorCapacity, failure.what());
        return 0;
    }
}

MCD_EXPORT void mdVkResize(void* context, uint32_t width,
    uint32_t height) {
    auto* value = static_cast<Context*>(context);
    if (!value || width == 0 || height == 0) return;
    value->width = width;
    value->height = height;
    value->swapchainDirty = true;
}

MCD_EXPORT void mdVkSetVsync(void* context, int enabled) {
    auto* value = static_cast<Context*>(context);
    if (!value) return;
    const bool requested = enabled != 0;
    if (value->vsync != requested) {
        value->vsync = requested;
        value->swapchainDirty = true;
    }
}

MCD_EXPORT int mdVkRender(void* context, const Vertex* vertices,
    uint32_t vertexCount, const Draw* draws, uint32_t drawCount,
    const float* clearColor, char* error, uint32_t errorCapacity) {
    try {
        static_cast<Context*>(context)->render(vertices, vertexCount, draws,
            drawCount, clearColor);
        return 1;
    } catch (const std::exception& failure) {
        copyError(error, errorCapacity, failure.what());
        return 0;
    }
}

MCD_EXPORT uint32_t mdVkBlurTexture(void* context) {
    return static_cast<Context*>(context)->blurTexture;
}

}
