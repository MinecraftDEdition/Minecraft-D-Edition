# Platform boundary

Code outside this directory should consume platform-neutral window, input,
clock, path, clipboard, dialog, graphics-surface, and audio interfaces. It must
not import Win32, Cocoa, X11, Wayland, DirectX, Metal, Core Audio, or native
window handles directly.

Current Windows implementations remain under `windows/`. Future shared desktop
implementations belong under `desktop/`; macOS- and Linux-only glue belongs
under `macos/` and `linux/` respectively. Shared gameplay and networking must
stay outside all platform folders.

