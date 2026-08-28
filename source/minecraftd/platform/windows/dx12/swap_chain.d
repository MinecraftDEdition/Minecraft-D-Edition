module minecraftd.platform.windows.dx12.swap_chain;

import directx.dxgiformat : DXGI_FORMAT, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_D24_UNORM_S8_UINT;

enum uint backBufferCount = 2;
enum DXGI_FORMAT backBufferFormat = DXGI_FORMAT_R8G8B8A8_UNORM;
enum DXGI_FORMAT depthBufferFormat = DXGI_FORMAT_D24_UNORM_S8_UINT;
