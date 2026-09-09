#include "blur_readback.cpp"
#include <iostream>

int main() {
    try {
        if (!SDL_Init(SDL_INIT_VIDEO)) throw std::runtime_error(SDL_GetError());
        SDL_Window* window = SDL_CreateWindow("MCDE blur regression", 640, 384,
            SDL_WINDOW_VULKAN | SDL_WINDOW_HIDDEN);
        if (!window) throw std::runtime_error(SDL_GetError());
        {
            Context context;
            context.initialize(window, 640, 384, "shaders/spirv/world.vert.spv",
                "shaders/spirv/world.frag.spv", "shaders/spirv/world.blur.frag.spv");
            const Vertex quad[] = {
                {{-1,1,0},{0,0},{1,1,1,1}}, {{1,1,0},{1,0},{1,1,1,1}},
                {{1,-1,0},{1,1},{1,1,1,1}}, {{-1,1,0},{0,0},{1,1,1,1}},
                {{1,-1,0},{1,1},{1,1,1,1}}, {{-1,-1,0},{0,1},{1,1,1,1}}
            };
            for (const auto size : {VkExtent2D{640,384}, VkExtent2D{641,385}, VkExtent2D{320,240}}) {
                SDL_SetWindowSize(window, size.width, size.height);
                SDL_PumpEvents();
                context.width = size.width;
                context.height = size.height;
                context.swapchainDirty = true;
                std::vector<uint8_t> source(size.width * size.height * 4, 255);
                for (uint32_t y = 0; y < size.height; ++y)
                    for (uint32_t x = 0; x < size.width; ++x)
                        for (uint32_t c = 0; c < 3; ++c)
                            source[(y * size.width + x) * 4 + c]
                                = x >= size.width / 2 && y >= size.height / 2 ? 255 : 0;
                Draw draws[2]{};
                draws[0].textureIndex = context.uploadTexture(source.data(), size.width, size.height, 1);
                draws[0].layer = 6;
                draws[0].vertexCount = 6;
                for (uint32_t i = 0; i < 4; ++i) draws[0].transform[i * 5] = 1;
                draws[1] = draws[0];
                draws[1].textureIndex = context.blurTexture;
                draws[1].layer = 5;
                const float clear[] = {0,0,0,1};
                for (float sigma : {2.4f,12.0f,24.0f}) {
                    draws[1].fog[7] = sigma;
                    for (uint32_t frame = 0; frame < 3; ++frame)
                        context.render(quad, 6, draws, 2, clear);
                    uint32_t w, h;
                    mdVkReadBlur(&context, nullptr, 0, &w, &h);
                    std::vector<uint8_t> pixels(w * h * 4);
                    if (!mdVkReadBlur(&context, pixels.data(), static_cast<uint32_t>(pixels.size()), &w, &h))
                        throw std::runtime_error("MoltenVK blur readback failed");
                    const auto pixel = [&](uint32_t x, uint32_t y) { return pixels[(y * w + x) * 4]; };
                    if (pixel(0,0) != 0 || pixel(0,h-1) != 0 || pixel(w-1,h-1) < 250
                        || pixel(w/2,h/2) < 40 || pixel(w/2,h/2) > 155
                        || pixel(w/2-1,h/2-1) < 10)
                        throw std::runtime_error("MoltenVK Gaussian blur/edge regression");
                    for (uint32_t x = 1; x < w; ++x)
                        if (pixel(x,h/2)+1 < pixel(x-1,h/2))
                            throw std::runtime_error("MoltenVK horizontal blur regression");
                    for (uint32_t y = 1; y < h; ++y)
                        if (pixel(w/2,y)+1 < pixel(w/2,y-1))
                            throw std::runtime_error("MoltenVK vertical blur regression");
                    std::cout << "MoltenVK blur " << size.width << "x" << size.height
                        << " sigma=" << sigma << " passed\n";
                }
                context.render(quad, 6, draws, 1, clear);
            }
        }
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
