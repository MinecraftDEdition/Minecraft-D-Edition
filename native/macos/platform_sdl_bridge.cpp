#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>

#include <mach-o/dyld.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr int KeyMouseLeft = 0x01;
constexpr int KeyMouseRight = 0x02;
constexpr int KeyMouseMiddle = 0x04;
constexpr int KeyBackspace = 0x08;
constexpr int KeyTab = 0x09;
constexpr int KeyReturn = 0x0D;
constexpr int KeyShift = 0x10;
constexpr int KeyControl = 0x11;
constexpr int KeyAlt = 0x12;
constexpr int KeyEscape = 0x1B;
constexpr int KeySpace = 0x20;
constexpr int KeyEnd = 0x23;
constexpr int KeyHome = 0x24;
constexpr int KeyLeft = 0x25;
constexpr int KeyUp = 0x26;
constexpr int KeyRight = 0x27;
constexpr int KeyDown = 0x28;
constexpr int KeyDelete = 0x2E;
constexpr int KeyNumpadAdd = 0x6B;
constexpr int KeyF1 = 0x70;
constexpr int KeyRightShift = 0xA1;
constexpr int KeyOemPlus = 0xBB;

struct WindowContext {
    SDL_Window* window = nullptr;
    std::array<bool, 256> down{};
    std::array<bool, 256> pressed{};
    std::array<bool, 256> repeated{};
    std::string text;
    int wheel = 0;
    int resizeWidth = 0;
    int resizeHeight = 0;
    bool running = true;
    bool captured = false;
    bool textInputActive = false;
    std::array<SDL_Cursor*, 4> cursors{};
};

std::string bundledVulkanLibrary() {
    uint32_t capacity = 0;
    _NSGetExecutablePath(nullptr, &capacity);
    if (capacity == 0) return {};
    std::vector<char> executable(capacity + 1, 0);
    if (_NSGetExecutablePath(executable.data(), &capacity) != 0) return {};
    std::string path(executable.data());
    const auto executableSeparator = path.rfind('/');
    if (executableSeparator == std::string::npos) return {};
    path.resize(executableSeparator); // Contents/MacOS
    const auto contentsSeparator = path.rfind('/');
    if (contentsSeparator == std::string::npos) return {};
    path.resize(contentsSeparator); // Contents
    return path + "/Frameworks/libMoltenVK.dylib";
}

void copyError(char* output, uint32_t capacity, const char* text) {
    if (!output || capacity == 0) return;
    if (!text) text = "Unknown SDL error";
    const size_t length = std::min<size_t>(capacity - 1, std::strlen(text));
    std::memcpy(output, text, length);
    output[length] = 0;
}

int keyFromScancode(SDL_Scancode scancode) {
    if (scancode >= SDL_SCANCODE_A && scancode <= SDL_SCANCODE_Z)
        return 'A' + static_cast<int>(scancode - SDL_SCANCODE_A);
    if (scancode >= SDL_SCANCODE_1 && scancode <= SDL_SCANCODE_9)
        return '1' + static_cast<int>(scancode - SDL_SCANCODE_1);
    if (scancode == SDL_SCANCODE_0) return '0';
    if (scancode >= SDL_SCANCODE_F1 && scancode <= SDL_SCANCODE_F12)
        return KeyF1 + static_cast<int>(scancode - SDL_SCANCODE_F1);
    switch (scancode) {
        case SDL_SCANCODE_BACKSPACE: return KeyBackspace;
        case SDL_SCANCODE_TAB: return KeyTab;
        case SDL_SCANCODE_RETURN:
        case SDL_SCANCODE_KP_ENTER: return KeyReturn;
        case SDL_SCANCODE_LSHIFT: return KeyShift;
        case SDL_SCANCODE_RSHIFT: return KeyRightShift;
        case SDL_SCANCODE_LCTRL:
        case SDL_SCANCODE_RCTRL: return KeyControl;
        case SDL_SCANCODE_LALT:
        case SDL_SCANCODE_RALT: return KeyAlt;
        case SDL_SCANCODE_ESCAPE: return KeyEscape;
        case SDL_SCANCODE_SPACE: return KeySpace;
        case SDL_SCANCODE_END: return KeyEnd;
        case SDL_SCANCODE_HOME: return KeyHome;
        case SDL_SCANCODE_LEFT: return KeyLeft;
        case SDL_SCANCODE_UP: return KeyUp;
        case SDL_SCANCODE_RIGHT: return KeyRight;
        case SDL_SCANCODE_DOWN: return KeyDown;
        case SDL_SCANCODE_DELETE: return KeyDelete;
        case SDL_SCANCODE_EQUALS: return KeyOemPlus;
        case SDL_SCANCODE_KP_PLUS: return KeyNumpadAdd;
        default: return -1;
    }
}

int keyFromEvent(const SDL_KeyboardEvent& event) {
    const int scancodeKey = keyFromScancode(event.scancode);
    if (scancodeKey >= 0) return scancodeKey;
    // Some Apple keyboards and remapping tools report a logical key while
    // leaving the physical scancode unknown. Keep editing keys functional in
    // that path as well.
    switch (event.key) {
        case SDLK_BACKSPACE: return KeyBackspace;
        case SDLK_DELETE: return KeyDelete;
        case SDLK_RETURN:
        case SDLK_KP_ENTER: return KeyReturn;
        case SDLK_TAB: return KeyTab;
        case SDLK_ESCAPE: return KeyEscape;
        default: return -1;
    }
}

void setKey(WindowContext* context, int key, bool down, bool pressed) {
    if (key < 0 || key >= static_cast<int>(context->down.size())) return;
    context->down[static_cast<size_t>(key)] = down;
    if (pressed) context->pressed[static_cast<size_t>(key)] = true;
    if (key == KeyRightShift) {
        context->down[KeyShift] = down;
        if (pressed) context->pressed[KeyShift] = true;
    }
}

void setMouseButton(WindowContext* context, uint8_t button, bool down) {
    int key = -1;
    if (button == SDL_BUTTON_LEFT) key = KeyMouseLeft;
    else if (button == SDL_BUTTON_RIGHT) key = KeyMouseRight;
    else if (button == SDL_BUTTON_MIDDLE) key = KeyMouseMiddle;
    setKey(context, key, down, down);
}

} // namespace

extern "C" {

void* mcdPlatformCreateWindow(const char* title, int width, int height,
    int localTestIndex, char* error, uint32_t errorCapacity) {
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_AUDIO)) {
        copyError(error, errorCapacity, SDL_GetError());
        return nullptr;
    }
    const auto vulkanLibrary = bundledVulkanLibrary();
    if (vulkanLibrary.empty()
        || !SDL_Vulkan_LoadLibrary(vulkanLibrary.c_str())) {
        copyError(error, errorCapacity, vulkanLibrary.empty()
            ? "Unable to locate bundled MoltenVK" : SDL_GetError());
        SDL_Quit();
        return nullptr;
    }
    auto context = std::make_unique<WindowContext>();
    SDL_WindowFlags flags = static_cast<SDL_WindowFlags>(SDL_WINDOW_VULKAN
        | SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    context->window = SDL_CreateWindow(title && *title ? title
        : "Minecraft: D Edition", width, height, flags);
    if (!context->window) {
        copyError(error, errorCapacity, SDL_GetError());
        SDL_Vulkan_UnloadLibrary();
        SDL_Quit();
        return nullptr;
    }
    if (localTestIndex > 0)
        SDL_SetWindowPosition(context->window, 30 + localTestIndex * 36,
            30 + localTestIndex * 28);
    context->cursors[0] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_DEFAULT);
    context->cursors[1] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_TEXT);
    context->cursors[2] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_POINTER);
    context->cursors[3] = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_EW_RESIZE);
    SDL_RaiseWindow(context->window);
    return context.release();
}

void mcdPlatformDestroyWindow(void* value) {
    std::unique_ptr<WindowContext> context(static_cast<WindowContext*>(value));
    if (!context) return;
    if (context->window && context->textInputActive)
        SDL_StopTextInput(context->window);
    for (auto* cursor : context->cursors)
        if (cursor) SDL_DestroyCursor(cursor);
    if (context->window) SDL_DestroyWindow(context->window);
    SDL_Vulkan_UnloadLibrary();
    SDL_Quit();
}

void* mcdPlatformRendererWindow(void* value) {
    auto* context = static_cast<WindowContext*>(value);
    return context ? context->window : nullptr;
}

void mcdPlatformPump(void* value) {
    auto* context = static_cast<WindowContext*>(value);
    if (!context) return;
    context->pressed.fill(false);
    context->repeated.fill(false);
    SDL_Event event{};
    while (SDL_PollEvent(&event)) {
        switch (event.type) {
            case SDL_EVENT_QUIT:
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                context->running = false;
                break;
            case SDL_EVENT_KEY_DOWN:
            case SDL_EVENT_KEY_UP: {
                const bool down = event.type == SDL_EVENT_KEY_DOWN;
                const int key = keyFromEvent(event.key);
                setKey(context, key, down, down && !event.key.repeat);
                if (down && event.key.repeat && key >= 0 && key < 256)
                    context->repeated[static_cast<size_t>(key)] = true;
                // SDL text events intentionally omit control characters. Add a
                // semantic fallback so the D input layer can still observe a
                // macOS Delete/Backspace press if a keyboard layout suppresses
                // the normal key-state route.
                if (down && !event.key.repeat && key == KeyBackspace)
                    context->text.push_back('\b');
                break;
            }
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
            case SDL_EVENT_MOUSE_BUTTON_UP:
                setMouseButton(context, event.button.button,
                    event.type == SDL_EVENT_MOUSE_BUTTON_DOWN);
                break;
            case SDL_EVENT_MOUSE_WHEEL:
                context->wheel += static_cast<int>(event.wheel.y);
                break;
            case SDL_EVENT_TEXT_INPUT:
                if (event.text.text) context->text += event.text.text;
                break;
            case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                context->resizeWidth = event.window.data1;
                context->resizeHeight = event.window.data2;
                break;
            case SDL_EVENT_WINDOW_FOCUS_LOST:
                context->down.fill(false);
                break;
            default: break;
        }
    }
}

int mcdPlatformRunning(void* value) {
    auto* context = static_cast<WindowContext*>(value);
    return context && context->running ? 1 : 0;
}

int mcdPlatformConsumeResize(void* value, int* width, int* height) {
    auto* context = static_cast<WindowContext*>(value);
    if (!context || context->resizeWidth <= 0 || context->resizeHeight <= 0)
        return 0;
    if (width) *width = context->resizeWidth;
    if (height) *height = context->resizeHeight;
    context->resizeWidth = context->resizeHeight = 0;
    return 1;
}

int mcdPlatformKeyDown(void* value, int key) {
    auto* context = static_cast<WindowContext*>(value);
    return context && key >= 0 && key < 256 && context->down[key] ? 1 : 0;
}

int mcdPlatformKeyPressed(void* value, int key) {
    auto* context = static_cast<WindowContext*>(value);
    return context && key >= 0 && key < 256 && context->pressed[key] ? 1 : 0;
}

int mcdPlatformKeyRepeated(void* value, int key) {
    auto* context = static_cast<WindowContext*>(value);
    return context && key >= 0 && key < 256 && context->repeated[key] ? 1 : 0;
}

int mcdPlatformFirstPressedKey(void* value) {
    auto* context = static_cast<WindowContext*>(value);
    if (!context) return -1;
    for (size_t index = 0; index < context->pressed.size(); ++index)
        if (context->pressed[index]) return static_cast<int>(index);
    return -1;
}

int mcdPlatformConsumeWheel(void* value) {
    auto* context = static_cast<WindowContext*>(value);
    if (!context) return 0;
    const int result = context->wheel;
    context->wheel = 0;
    return result;
}

uint32_t mcdPlatformConsumeText(void* value, char* output, uint32_t capacity) {
    auto* context = static_cast<WindowContext*>(value);
    if (!context || !output || capacity == 0) return 0;
    const size_t count = std::min<size_t>(capacity - 1, context->text.size());
    std::memcpy(output, context->text.data(), count);
    output[count] = 0;
    context->text.erase(0, count);
    return static_cast<uint32_t>(count);
}

void mcdPlatformClearText(void* value) {
    auto* context = static_cast<WindowContext*>(value);
    if (context) context->text.clear();
}

void mcdPlatformMouseDelta(void* value, int* x, int* y) {
    auto* context = static_cast<WindowContext*>(value);
    float dx = 0.0f, dy = 0.0f;
    if (context && context->captured)
        SDL_GetRelativeMouseState(&dx, &dy);
    if (x) *x = static_cast<int>(dx);
    if (y) *y = static_cast<int>(dy);
}

void mcdPlatformCursorPosition(void* value, int* x, int* y) {
    auto* context = static_cast<WindowContext*>(value);
    float px = 0.0f, py = 0.0f;
    if (context) SDL_GetMouseState(&px, &py);
    float density = context ? SDL_GetWindowPixelDensity(context->window) : 1.0f;
    if (x) *x = static_cast<int>(px * density);
    if (y) *y = static_cast<int>(py * density);
}

void mcdPlatformSetCursor(void* value, int shape) {
    auto* context = static_cast<WindowContext*>(value);
    if (!context || shape < 0 || shape >= 4) return;
    if (context->cursors[shape]) SDL_SetCursor(context->cursors[shape]);
}

void mcdPlatformSetFullscreen(void* value, int enabled) {
    auto* context = static_cast<WindowContext*>(value);
    if (context) SDL_SetWindowFullscreen(context->window, enabled != 0);
}

int mcdPlatformFullscreen(void* value) {
    auto* context = static_cast<WindowContext*>(value);
    return context && (SDL_GetWindowFlags(context->window)
        & SDL_WINDOW_FULLSCREEN) ? 1 : 0;
}

void mcdPlatformSetMouseCapture(void* value, int captured) {
    auto* context = static_cast<WindowContext*>(value);
    if (!context) return;
    context->captured = captured != 0;
    SDL_SetWindowRelativeMouseMode(context->window, context->captured);
    const bool wantsTextInput = !context->captured;
    if (wantsTextInput != context->textInputActive) {
        if (wantsTextInput)
            SDL_StartTextInput(context->window);
        else
            SDL_StopTextInput(context->window);
        context->textInputActive = wantsTextInput;
    }
}

int mcdPlatformSetClipboard(const char* value) {
    return SDL_SetClipboardText(value ? value : "") ? 1 : 0;
}

uint32_t mcdPlatformGetClipboard(char* output, uint32_t capacity) {
    if (!output || capacity == 0) return 0;
    char* value = SDL_GetClipboardText();
    if (!value) return 0;
    const size_t count = std::min<size_t>(capacity - 1, std::strlen(value));
    std::memcpy(output, value, count);
    output[count] = 0;
    SDL_free(value);
    return static_cast<uint32_t>(count);
}

int mcdPlatformShortcutDown(void*) {
    return (SDL_GetModState() & (SDL_KMOD_GUI | SDL_KMOD_CTRL)) != 0 ? 1 : 0;
}

void mcdPlatformWindowSize(void* value, int* width, int* height) {
    auto* context = static_cast<WindowContext*>(value);
    int w = 1, h = 1;
    if (context) SDL_GetWindowSizeInPixels(context->window, &w, &h);
    if (width) *width = w;
    if (height) *height = h;
}

void mcdPlatformShowError(const char* title, const char* message) {
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR,
        title ? title : "Minecraft: D Edition",
        message ? message : "Unknown error", nullptr);
}

} // extern "C"
