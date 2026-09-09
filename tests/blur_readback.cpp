// Test-only translation unit. Production links the bridge without this hook.
#define MCD_BLUR_SMOKE 1
#include "../native/vulkan_abi_bridge.cpp"

extern "C" int mdVkReadBlur(void* value, uint8_t* pixels, uint32_t capacity,
    uint32_t* width, uint32_t* height) {
    auto& context = *static_cast<Context*>(value);
    *width = context.blurExtent.width;
    *height = context.blurExtent.height;
    const VkDeviceSize bytes = VkDeviceSize(*width) * *height * 4;
    if (!pixels) return 1;
    if (capacity < bytes) return 0;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    require(vkDeviceWaitIdle(context.device), "Wait blur readback");
    context.createBuffer(bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        buffer, memory);
    context.beginCommands();
    VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    barrier.image = context.textures[1].image;
    barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    barrier.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(context.command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    VkBufferImageCopy copy{};
    copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    copy.imageExtent = {*width, *height, 1};
    vkCmdCopyImageToBuffer(context.command, barrier.image,
        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
    std::swap(barrier.oldLayout, barrier.newLayout);
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(context.command, VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    context.submitAndWait();
    void* mapped = nullptr;
    require(vkMapMemory(context.device, memory, 0, bytes, 0, &mapped), "Map blur readback");
    std::memcpy(pixels, mapped, static_cast<size_t>(bytes));
    vkUnmapMemory(context.device, memory);
    // Normalize Vulkan's preferred BGRA swap format for the shared checks.
    if (context.colorFormat == VK_FORMAT_B8G8R8A8_UNORM)
        for (size_t i = 0; i < bytes; i += 4) std::swap(pixels[i], pixels[i + 2]);
    vkDestroyBuffer(context.device, buffer, nullptr);
    vkFreeMemory(context.device, memory, nullptr);
    return 1;
}
