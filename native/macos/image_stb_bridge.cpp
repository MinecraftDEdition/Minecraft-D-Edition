#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "stb_image.h"

#include <algorithm>
#include <cstdint>
#include <cstring>

extern "C" {

int mcdImageLoadPng(const char* path, unsigned char** pixels,
    uint32_t* width, uint32_t* height, char* error, uint32_t errorCapacity) {
    if (!path || !pixels || !width || !height) return 0;
    int decodedWidth = 0;
    int decodedHeight = 0;
    int channels = 0;
    unsigned char* decoded = stbi_load(path, &decodedWidth, &decodedHeight,
        &channels, 4);
    if (!decoded) {
        if (error && errorCapacity) {
            const char* reason = stbi_failure_reason();
            if (!reason) reason = "Unknown PNG decode failure";
            const size_t count = std::min<size_t>(errorCapacity - 1,
                std::strlen(reason));
            std::memcpy(error, reason, count);
            error[count] = 0;
        }
        return 0;
    }
    *pixels = decoded;
    *width = static_cast<uint32_t>(decodedWidth);
    *height = static_cast<uint32_t>(decodedHeight);
    return 1;
}

void mcdImageFree(void* pixels) {
    stbi_image_free(pixels);
}

}

