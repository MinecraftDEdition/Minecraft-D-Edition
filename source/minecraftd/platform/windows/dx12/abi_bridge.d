module minecraftd.platform.windows.dx12.abi_bridge;

import core.stdc.config : c_ulong;
import core.sys.windows.windows : SIZE_T;
import directx.d3d12 : D3D12_SHADER_RESOURCE_VIEW_DESC;

extern (C):
void* mdAudioCreate();
void mdAudioDestroy(void* handle);
int mdAudioPlayOgg(void* handle, const(wchar)* path, float volume, float pitch,
    float pan,int spatial);
int mdAudioPlayOggAt(void* handle, const(wchar)* path, float volume, float pitch,
    float x, float y, float z, float attenuationDistance);
void mdAudioSetListener(void* handle, float x, float y, float z, float yaw,
    int directionalAudio);
int mdAudioPlayMusicOgg(void* handle, const(wchar)* path, float volume);
int mdAudioMusicPlaying(void* handle);
void mdAudioStopMusic(void* handle);
void mdAudioSetMusicVolume(void* handle, float volume);
void mdAudioSetMusicPaused(void* handle, int paused);
void* mdCreateRootSignature(void* device);
SIZE_T mdGetCPUDescriptorHandleStart(void* heap);
ulong mdGetGPUDescriptorHandleStart(void* heap);
void* mdCreateGraphicsPipeline(void* device, void* rootSignature,
    const(void)* vertexShader, SIZE_T vertexShaderSize,
    const(void)* pixelShader, SIZE_T pixelShaderSize,
    uint renderTargetFormat, uint depthFormat, int depthEnabled,
    int depthWriteEnabled, int blendMode, int cullBackFaces);
int mdUploadBuffer(void* resource, const(void)* data, SIZE_T size);
void mdCreateRenderTargetView(void* device, void* resource, SIZE_T handle);
void mdCreateDepthStencilView(void* device, void* resource, SIZE_T handle);
void mdCreateShaderResourceView(void* device, void* resource,
    const(D3D12_SHADER_RESOURCE_VIEW_DESC)* description, SIZE_T handle);
void mdClearRenderTargetView(void* list, SIZE_T handle, const(float)* color);
void mdClearDepthStencilView(void* list, SIZE_T handle);
void mdSetRootDescriptorTable(void* list, uint rootIndex, ulong handle);
void mdTransition(void* list, void* resource, uint before, uint after);
void mdSetRenderTargets(void* list, SIZE_T rtv, SIZE_T dsv);
void mdPrepareDraw(void* list, void* rootSignature, void* descriptorHeap,
    float width, float height, ulong vertexAddress, uint stride, uint size);
void mdBindVertexBuffer(void* list, ulong vertexAddress, uint stride, uint size);
void mdDraw(void* list, const(float)* transform, const(float)* fog,
    ulong textureHandle,
    uint vertexCount, uint firstVertex);
