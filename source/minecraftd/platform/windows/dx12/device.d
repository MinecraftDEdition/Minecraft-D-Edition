module minecraftd.platform.windows.dx12.device;

version (Windows):

import core.stdc.string : memcpy;
import core.sys.windows.windows;

import directx.d3d12;
import directx.d3d12sdklayers;
import directx.dxgi1_4;

import minecraftd.client.render.mesh : DrawLayer, FrameMesh, MeshHandle, Vertex;
import minecraftd.client.render.texture_manager : ImageData;
import minecraftd.client.render.graphics_device : GraphicsDevice, TextureHandle;
import minecraftd.platform.windows.dx12.command_context : requireSuccess;
import minecraftd.platform.windows.dx12.abi_bridge;
import minecraftd.platform.windows.dx12.descriptor_heap : cpuHandle, gpuHandle;
import minecraftd.platform.windows.dx12.shader : compileWorldShaders;
import minecraftd.platform.windows.dx12.swap_chain : backBufferCount, backBufferFormat, depthBufferFormat;

/// D3D12 renderer with one command allocator and streaming vertex buffer per
/// swap-chain image. CPU frame construction can overlap the GPU's previous
/// frame instead of stalling on a fence after every Present.
final class Dx12Device : GraphicsDevice
{
    private struct StaticMesh
    {
        ID3D12Resource resource;
        ulong gpuAddress;
        uint byteCount;
    }
    private struct RetiredStaticMesh
    {
        ID3D12Resource resource;
        ulong fenceValue;
    }
    // Vanilla's GUI and particle atlases already push this prototype past 64
    // individual SRVs; leave headroom for the upcoming blocks and controller UI.
    enum uint maxTextures = 256;
    // Streamed terrain can legitimately place several hundred thousand
    // visible vertices in one frame. Keep a bounded buffer, but size it for
    // the supported 12-chunk view rather than the old 3x3 prototype map.
    enum uint maxVertices = 2_000_000;
    // directx-d 0.14 predates these Windows 10 DXGI constants.
    enum uint swapChainAllowTearing = 0x800;
    enum uint presentAllowTearing = 0x200;

    private HWND window;
    private uint width;
    private uint height;
    private uint frameIndex;

    private IDXGIFactory4 factory;
    private IDXGISwapChain3 swapChain;
    private ID3D12Device device;
    private ID3D12CommandQueue queue;
    private ID3D12CommandAllocator[backBufferCount] allocators;
    private ID3D12GraphicsCommandList[backBufferCount] commandLists;
    private ID3D12CommandAllocator allocator;
    private ID3D12GraphicsCommandList list;
    private ID3D12RootSignature rootSignature;
    private ID3D12PipelineState pipelineState;
    private ID3D12PipelineState translucentPipelineState;
    private ID3D12PipelineState translucentCulledPipelineState;
    private ID3D12PipelineState skyPipelineState;
    private ID3D12PipelineState entityShadowPipelineState;
    private ID3D12PipelineState viewModelPipelineState;
    private ID3D12PipelineState invertedOverlayPipelineState;
    private ID3D12PipelineState blurPipelineState;
    private ID3D12DescriptorHeap rtvHeap;
    private ID3D12DescriptorHeap dsvHeap;
    private ID3D12DescriptorHeap srvHeap;
    private ID3D12Resource[backBufferCount] renderTargets;
    private ID3D12Resource depthBuffer;
    private ID3D12Resource[backBufferCount] vertexBuffers;
    private ID3D12Resource blurCapture;
    private uint blurTextureIndex;
    private D3D12_VERTEX_BUFFER_VIEW[backBufferCount] vertexViews;
    private ID3D12Resource[] textures;
    private StaticMesh[ulong] staticMeshes;
    private RetiredStaticMesh[] retiredStaticMeshes;
    private ulong nextStaticMeshId = 1;
    private uint nextTexture;

    private ID3D12Fence fence;
    private ulong fenceValue = 1;
    private ulong[backBufferCount] frameFenceValues;
    private HANDLE fenceEvent;
    private uint rtvStride;
    private uint srvStride;
    private D3D12_VIEWPORT viewport;
    private D3D12_RECT scissor;
    private bool vsync = true;
    private bool tearingSupported;
    private uint swapChainFlags;

    this(HWND window, uint width, uint height)
    {
        this.window = window;
        this.width = width;
        this.height = height;
        viewport = D3D12_VIEWPORT(0, 0, cast(float) width, cast(float) height, 0, 1);
        scissor = D3D12_RECT(0, 0, cast(LONG) width, cast(LONG) height);
        createPipeline();
        createAssets();
    }

    ~this()
    {
        if (queue !is null && fence !is null)
            waitForGpu();
        if (fenceEvent !is null) CloseHandle(fenceEvent);
        foreach_reverse (ref texture; textures) if (texture !is null) texture.Release();
        foreach (id, ref mesh; staticMeshes)
            if (mesh.resource !is null) mesh.resource.Release();
        foreach (ref mesh; retiredStaticMeshes)
            if (mesh.resource !is null) mesh.resource.Release();
        foreach(ref vertexBuffer;vertexBuffers)
            if(vertexBuffer !is null)vertexBuffer.Release();
        if (blurCapture !is null) blurCapture.Release();
        if (depthBuffer !is null) depthBuffer.Release();
        foreach (ref target; renderTargets) if (target !is null) target.Release();
        if (fence !is null) fence.Release();
        foreach(ref commandList;commandLists)
            if(commandList !is null)commandList.Release();
        foreach(ref commandAllocator;allocators)
            if(commandAllocator !is null)commandAllocator.Release();
        if (pipelineState !is null) pipelineState.Release();
        if (translucentPipelineState !is null) translucentPipelineState.Release();
        if (translucentCulledPipelineState !is null)
            translucentCulledPipelineState.Release();
        if (skyPipelineState !is null) skyPipelineState.Release();
        if (entityShadowPipelineState !is null) entityShadowPipelineState.Release();
        if (viewModelPipelineState !is null) viewModelPipelineState.Release();
        if (invertedOverlayPipelineState !is null) invertedOverlayPipelineState.Release();
        if (blurPipelineState !is null) blurPipelineState.Release();
        if (rootSignature !is null) rootSignature.Release();
        if (srvHeap !is null) srvHeap.Release();
        if (dsvHeap !is null) dsvHeap.Release();
        if (rtvHeap !is null) rtvHeap.Release();
        if (queue !is null) queue.Release();
        if (device !is null) device.Release();
        if (swapChain !is null) swapChain.Release();
        if (factory !is null) factory.Release();
    }

    override TextureHandle uploadTexture(const ImageData image)
    {
        if (nextTexture >= maxTextures)
            throw new Exception("D3D12 texture descriptor heap is full");

        auto defaultHeap = D3D12_HEAP_PROPERTIES(
            D3D12_HEAP_TYPE_DEFAULT, D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            D3D12_MEMORY_POOL_UNKNOWN, 1, 1);
        auto textureDesc = D3D12_RESOURCE_DESC(
            D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, image.width, image.height, 1, 1,
            DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC(1, 0),
            D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_NONE);

        ID3D12Resource texture;
        requireSuccess(device.CreateCommittedResource(
            &defaultHeap, D3D12_HEAP_FLAG_NONE, &textureDesc,
            D3D12_RESOURCE_STATE_COPY_DEST, null, &IID_ID3D12Resource,
            &texture), "Create texture");

        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;
        ulong uploadBytes;
        device.GetCopyableFootprints(&textureDesc, 0, 1, 0, &footprint, null, null, &uploadBytes);
        auto uploadHeap = D3D12_HEAP_PROPERTIES(
            D3D12_HEAP_TYPE_UPLOAD, D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            D3D12_MEMORY_POOL_UNKNOWN, 1, 1);
        auto uploadDesc = D3D12_RESOURCE_DESC(
            D3D12_RESOURCE_DIMENSION_BUFFER, 0, uploadBytes, 1, 1, 1,
            DXGI_FORMAT_UNKNOWN, DXGI_SAMPLE_DESC(1, 0),
            D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE);
        ID3D12Resource upload;
        requireSuccess(device.CreateCommittedResource(
            &uploadHeap, D3D12_HEAP_FLAG_NONE, &uploadDesc,
            D3D12_RESOURCE_STATE_GENERIC_READ, null, &IID_ID3D12Resource,
            &upload), "Create texture upload buffer");
        scope (exit) upload.Release();

        ubyte* mapped;
        auto noRead = D3D12_RANGE(0, 0);
        requireSuccess(upload.Map(0, &noRead, cast(void**) &mapped), "Map texture upload buffer");
        const sourcePitch = image.width * 4;
        foreach (row; 0 .. image.height)
            memcpy(mapped + footprint.Offset + row * footprint.Footprint.RowPitch,
                image.rgba.ptr + row * sourcePitch, sourcePitch);
        upload.Unmap(0, null);

        beginCommands();
        D3D12_TEXTURE_COPY_LOCATION destination;
        destination.pResource = texture;
        destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        destination.SubresourceIndex = 0;
        D3D12_TEXTURE_COPY_LOCATION source;
        source.pResource = upload;
        source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        source.PlacedFootprint = footprint;
        list.CopyTextureRegion(&destination, 0, 0, 0, &source, null);
        transition(texture, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        executeCommands();
        waitForGpu();

        D3D12_SHADER_RESOURCE_VIEW_DESC srv;
        srv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        srv.Texture2D.MostDetailedMip = 0;
        srv.Texture2D.MipLevels = 1;
        srv.Texture2D.PlaneSlice = 0;
        srv.Texture2D.ResourceMinLODClamp = 0;
        auto srvDestination = cpuHandle(srvHeap, nextTexture, srvStride);
        mdCreateShaderResourceView(cast(void*) device, cast(void*) texture, &srv, srvDestination.ptr);
        textures ~= texture;
        return TextureHandle(nextTexture++);
    }

    override MeshHandle uploadStaticMesh(const Vertex[] vertices)
    {
        if (vertices.length == 0)
            return MeshHandle.init;
        if (vertices.length > uint.max || vertices.length * Vertex.sizeof > uint.max)
            throw new Exception("Static D3D12 mesh is too large");
        const byteCount = cast(ulong) vertices.length * Vertex.sizeof;
        auto bufferDesc = D3D12_RESOURCE_DESC(
            D3D12_RESOURCE_DIMENSION_BUFFER, 0, byteCount, 1, 1, 1,
            DXGI_FORMAT_UNKNOWN, DXGI_SAMPLE_DESC(1, 0),
            D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE);
        auto defaultHeap = D3D12_HEAP_PROPERTIES(
            D3D12_HEAP_TYPE_DEFAULT, D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            D3D12_MEMORY_POOL_UNKNOWN, 1, 1);
        ID3D12Resource resident;
        requireSuccess(device.CreateCommittedResource(&defaultHeap,
            D3D12_HEAP_FLAG_NONE, &bufferDesc, D3D12_RESOURCE_STATE_COPY_DEST,
            null, &IID_ID3D12Resource, &resident),
            "Create resident terrain buffer");
        scope(failure) if (resident !is null) resident.Release();

        auto uploadHeap = D3D12_HEAP_PROPERTIES(
            D3D12_HEAP_TYPE_UPLOAD, D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            D3D12_MEMORY_POOL_UNKNOWN, 1, 1);
        ID3D12Resource staging;
        requireSuccess(device.CreateCommittedResource(&uploadHeap,
            D3D12_HEAP_FLAG_NONE, &bufferDesc, D3D12_RESOURCE_STATE_GENERIC_READ,
            null, &IID_ID3D12Resource, &staging),
            "Create resident terrain staging buffer");
        scope(exit) if (staging !is null) staging.Release();
        if (!mdUploadBuffer(cast(void*) staging, vertices.ptr, byteCount))
            throw new Exception("Unable to stage resident terrain mesh");

        beginCommands();
        list.CopyBufferRegion(resident, 0, staging, 0, byteCount);
        transition(resident, D3D12_RESOURCE_STATE_COPY_DEST,
            D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER);
        executeCommands();
        waitForGpu();

        const id = nextStaticMeshId++;
        staticMeshes[id] = StaticMesh(resident, resident.GetGPUVirtualAddress(),
            cast(uint) byteCount);
        return MeshHandle(id, cast(uint) vertices.length);
    }

    override void releaseStaticMesh(MeshHandle handle)
    {
        if (!handle.valid) return;
        auto mesh = handle.id in staticMeshes;
        if (mesh is null) return;
        ulong lastUse;
        foreach(value;frameFenceValues)if(value>lastUse)lastUse=value;
        if(lastUse==0||fence.GetCompletedValue()>=lastUse)
        {
            if(mesh.resource !is null)mesh.resource.Release();
        }
        else retiredStaticMeshes~=RetiredStaticMesh(mesh.resource,lastUse);
        staticMeshes.remove(handle.id);
    }

    override TextureHandle menuBlurTexture() const { return TextureHandle(blurTextureIndex); }

    override void resize(uint resizedWidth, uint resizedHeight)
    {
        if (resizedWidth == 0 || resizedHeight == 0
            || (resizedWidth == width && resizedHeight == height))
            return;
        waitForGpu();
        if (depthBuffer !is null)
        {
            depthBuffer.Release();
            depthBuffer = null;
        }
        if (blurCapture !is null)
        {
            blurCapture.Release();
            blurCapture = null;
        }
        foreach (ref target; renderTargets)
        {
            if (target !is null)
            {
                target.Release();
                target = null;
            }
        }
        requireSuccess(swapChain.ResizeBuffers(backBufferCount,
            resizedWidth,resizedHeight,backBufferFormat,swapChainFlags),
            "Resize swap-chain buffers");
        width = resizedWidth;
        height = resizedHeight;
        viewport.Width = cast(float) width;
        viewport.Height = cast(float) height;
        scissor.right = cast(LONG) width;
        scissor.bottom = cast(LONG) height;
        frameIndex = swapChain.GetCurrentBackBufferIndex();
        createTargets();
        createBlurCapture();
    }

    override void render(const FrameMesh frame)
    {
        const byteCount = frame.vertices.length * Vertex.sizeof;
        if (frame.vertices.length > maxVertices)
            throw new Exception("Frame exceeds dynamic vertex capacity");
        // Waiting occurs only when this particular back buffer is reused. With
        // two swap-chain images this permits one complete CPU/GPU frame of
        // overlap without allowing either upload buffer to be overwritten.
        beginCommands();
        if (byteCount != 0 && !mdUploadBuffer(
            cast(void*)vertexBuffers[frameIndex],
            frame.vertices.ptr, byteCount))
            throw new Exception("Unable to upload dynamic vertex data");
        vertexViews[frameIndex].SizeInBytes = cast(uint) byteCount;

        transition(renderTargets[frameIndex], D3D12_RESOURCE_STATE_PRESENT,
            D3D12_RESOURCE_STATE_RENDER_TARGET);
        auto rtv = cpuHandle(rtvHeap, frameIndex, rtvStride);
        auto dsv = dsvHeap.GetCPUDescriptorHandleForHeapStart();
        mdSetRenderTargets(cast(void*) list, rtv.ptr, dsv.ptr);
        const float[4] skyColor = [frame.clearColor.r, frame.clearColor.g,
            frame.clearColor.b, frame.clearColor.a];
        mdClearRenderTargetView(cast(void*) list, rtv.ptr, skyColor.ptr);
        mdClearDepthStencilView(cast(void*) list, dsv.ptr);
        mdPrepareDraw(cast(void*) list, cast(void*) rootSignature, cast(void*) srvHeap,
            cast(float) width, cast(float) height,
            vertexViews[frameIndex].BufferLocation,
            vertexViews[frameIndex].StrideInBytes,
            vertexViews[frameIndex].SizeInBytes);

        DrawLayer activeLayer = DrawLayer.world;
        ulong activeMeshId;
        foreach (draw; frame.draws)
        {
            if (draw.meshId != activeMeshId)
            {
                activeMeshId = draw.meshId;
                if (activeMeshId == 0)
                    mdBindVertexBuffer(cast(void*) list,
                        vertexViews[frameIndex].BufferLocation,
                        vertexViews[frameIndex].StrideInBytes,
                        vertexViews[frameIndex].SizeInBytes);
                else
                {
                    auto resident = activeMeshId in staticMeshes;
                    if (resident is null)
                        throw new Exception("Draw references a released D3D12 mesh");
                    mdBindVertexBuffer(cast(void*) list, resident.gpuAddress,
                        Vertex.sizeof, resident.byteCount);
                }
            }
            if (draw.layer != activeLayer)
            {
                activeLayer = draw.layer;
                final switch (activeLayer)
                {
                    case DrawLayer.sky: list.SetPipelineState(skyPipelineState); break;
                    case DrawLayer.world: list.SetPipelineState(pipelineState); break;
                    case DrawLayer.translucent:
                        list.SetPipelineState(translucentPipelineState);
                        break;
                    case DrawLayer.translucentCulled:
                        list.SetPipelineState(translucentCulledPipelineState);
                        break;
                    case DrawLayer.worldDoubleSided:
                        list.SetPipelineState(viewModelPipelineState);
                        break;
                    case DrawLayer.entityShadow:
                        list.SetPipelineState(entityShadowPipelineState);
                        break;
                    case DrawLayer.viewModel:
                        // Discard world depth, then give the hand a fresh depth
                        // field so its outside faces still occlude its inside faces.
                        mdClearDepthStencilView(cast(void*) list, dsv.ptr);
                        list.SetPipelineState(viewModelPipelineState);
                        break;
                    case DrawLayer.blurBackdrop:
                        transition(renderTargets[frameIndex],
                            D3D12_RESOURCE_STATE_RENDER_TARGET,
                            D3D12_RESOURCE_STATE_COPY_SOURCE);
                        transition(blurCapture,
                            D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
                            D3D12_RESOURCE_STATE_COPY_DEST);
                        list.CopyResource(blurCapture, renderTargets[frameIndex]);
                        transition(blurCapture, D3D12_RESOURCE_STATE_COPY_DEST,
                            D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
                        transition(renderTargets[frameIndex],
                            D3D12_RESOURCE_STATE_COPY_SOURCE,
                            D3D12_RESOURCE_STATE_RENDER_TARGET);
                        mdSetRenderTargets(cast(void*) list, rtv.ptr, dsv.ptr);
                        list.SetPipelineState(blurPipelineState);
                        break;
                    case DrawLayer.overlay: list.SetPipelineState(skyPipelineState); break;
                    case DrawLayer.invertedOverlay: list.SetPipelineState(invertedOverlayPipelineState); break;
                }
            }
            const textureHandle = gpuHandle(srvHeap, draw.textureIndex, srvStride);
            const fog = draw.fog.constants();
            mdDraw(cast(void*) list, draw.transform.m.ptr, fog.ptr, textureHandle.ptr,
                draw.vertexCount, draw.firstVertex);
        }

        transition(renderTargets[frameIndex], D3D12_RESOURCE_STATE_RENDER_TARGET,
            D3D12_RESOURCE_STATE_PRESENT);
        executeCommands();
        const presentFlags=!vsync&&tearingSupported?presentAllowTearing:0;
        requireSuccess(swapChain.Present(vsync?1:0,presentFlags),
            "Present frame");
        signalFrame(frameIndex);
        frameIndex = swapChain.GetCurrentBackBufferIndex();
    }

    override void setVsync(bool enabled) { vsync = enabled; }

private:
    void createPipeline()
    {
        debug
        {
            ID3D12Debug debugController;
            if (SUCCEEDED(D3D12GetDebugInterface(&IID_ID3D12Debug, cast(void**) &debugController)))
            {
                debugController.EnableDebugLayer();
                debugController.Release();
            }
        }

        requireSuccess(CreateDXGIFactory1(&IID_IDXGIFactory4, cast(void**) &factory), "Create DXGI factory");
        IDXGIAdapter1 adapter = findHardwareAdapter(factory);
        scope (exit) if (adapter !is null) adapter.Release();
        requireSuccess(D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0,
            &IID_ID3D12Device, &device), "Create D3D12 device");

        D3D12_COMMAND_QUEUE_DESC queueDesc;
        queueDesc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        queueDesc.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
        requireSuccess(device.CreateCommandQueue(&queueDesc, &IID_ID3D12CommandQueue,
            &queue), "Create command queue");

        DXGI_SWAP_CHAIN_DESC swapDesc;
        swapDesc.BufferCount = backBufferCount;
        swapDesc.BufferDesc.Width = width;
        swapDesc.BufferDesc.Height = height;
        swapDesc.BufferDesc.Format = backBufferFormat;
        swapDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        swapDesc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        swapDesc.OutputWindow = window;
        swapDesc.SampleDesc.Count = 1;
        swapDesc.Windowed = TRUE;
        IDXGISwapChain baseSwap;
        // Opt into variable-rate presentation on modern Windows. Without the
        // allow-tearing creation and Present flags, borderless/windowed flip
        // chains may remain paced by the desktop's 60 Hz compositor even when
        // the game's VSync option is disabled. Fall back cleanly on older or
        // remote-display adapters that reject the flag.
        swapDesc.Flags=swapChainAllowTearing;
        auto swapResult=factory.CreateSwapChain(queue,&swapDesc,&baseSwap);
        if(FAILED(swapResult))
        {
            swapDesc.Flags=0;
            requireSuccess(factory.CreateSwapChain(queue,&swapDesc,&baseSwap),
                "Create swap chain");
            tearingSupported=false;
            swapChainFlags=0;
        }
        else
        {
            tearingSupported=true;
            swapChainFlags=swapChainAllowTearing;
        }
        // directx-d exposes COM inheritance directly; retain the factory-owned
        // reference rather than performing a second interface write through void**.
        swapChain = cast(IDXGISwapChain3) baseSwap;
        baseSwap = null;
        if (swapChain is null)
            throw new Exception("Query IDXGISwapChain3 failed");
        requireSuccess(factory.MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER),
            "Disable DXGI Alt+Enter");
        frameIndex = swapChain.GetCurrentBackBufferIndex();

        createHeapsAndTargets();
        createRootSignature();
        createPipelineState();
        foreach(index;0..backBufferCount)
        {
            requireSuccess(device.CreateCommandAllocator(
                D3D12_COMMAND_LIST_TYPE_DIRECT,
                &IID_ID3D12CommandAllocator,&allocators[index]),
                "Create frame command allocator");
            requireSuccess(device.CreateCommandList(0,
                D3D12_COMMAND_LIST_TYPE_DIRECT,allocators[index],pipelineState,
                &IID_ID3D12GraphicsCommandList,
                cast(ID3D12CommandList*)&commandLists[index]),
                "Create frame graphics command list");
            requireSuccess(commandLists[index].Close(),
                "Close initial frame command list");
        }
        allocator=allocators[frameIndex];
        list=commandLists[frameIndex];
    }

    void createHeapsAndTargets()
    {
        D3D12_DESCRIPTOR_HEAP_DESC heapDesc;
        heapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        heapDesc.NumDescriptors = backBufferCount;
        requireSuccess(device.CreateDescriptorHeap(&heapDesc, &IID_ID3D12DescriptorHeap,
            &rtvHeap), "Create RTV heap");
        rtvStride = device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        heapDesc = D3D12_DESCRIPTOR_HEAP_DESC();
        heapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
        heapDesc.NumDescriptors = 1;
        requireSuccess(device.CreateDescriptorHeap(&heapDesc, &IID_ID3D12DescriptorHeap,
            &dsvHeap), "Create DSV heap");

        heapDesc = D3D12_DESCRIPTOR_HEAP_DESC();
        heapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        heapDesc.NumDescriptors = maxTextures;
        heapDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        requireSuccess(device.CreateDescriptorHeap(&heapDesc, &IID_ID3D12DescriptorHeap,
            &srvHeap), "Create texture heap");
        srvStride = device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);

        createTargets();
    }

    void createTargets()
    {
        auto rtvHandle = cpuHandle(rtvHeap, 0, rtvStride);
        foreach (i; 0 .. backBufferCount)
        {
            requireSuccess(swapChain.GetBuffer(i, &IID_ID3D12Resource,
                cast(void**) &renderTargets[i]), "Acquire swap-chain buffer");
            mdCreateRenderTargetView(cast(void*) device,
                cast(void*) renderTargets[i], rtvHandle.ptr);
            rtvHandle.ptr += rtvStride;
        }

        auto depthHeap = D3D12_HEAP_PROPERTIES(
            D3D12_HEAP_TYPE_DEFAULT, D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            D3D12_MEMORY_POOL_UNKNOWN, 1, 1);
        auto depthDesc = D3D12_RESOURCE_DESC(
            D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, width, height, 1, 1,
            depthBufferFormat, DXGI_SAMPLE_DESC(1, 0), D3D12_TEXTURE_LAYOUT_UNKNOWN,
            D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL);
        D3D12_CLEAR_VALUE clear;
        clear.Format = depthBufferFormat;
        clear.DepthStencil.Depth = 1;
        clear.DepthStencil.Stencil = 0;
        requireSuccess(device.CreateCommittedResource(&depthHeap, D3D12_HEAP_FLAG_NONE,
            &depthDesc, D3D12_RESOURCE_STATE_DEPTH_WRITE, &clear, &IID_ID3D12Resource,
            &depthBuffer), "Create depth buffer");
        const depthHandle = cpuHandle(dsvHeap, 0,
            device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_DSV));
        mdCreateDepthStencilView(cast(void*) device, cast(void*) depthBuffer, depthHandle.ptr);
    }

    void createRootSignature()
    {
        rootSignature = cast(ID3D12RootSignature) mdCreateRootSignature(cast(void*) device);
        if (rootSignature is null)
            throw new Exception("Create root signature failed");
    }

    void createPipelineState()
    {
        auto shaders = compileWorldShaders();
        scope (exit) shaders.release();
        pipelineState = cast(ID3D12PipelineState) mdCreateGraphicsPipeline(
            cast(void*) device, cast(void*) rootSignature,
            shaders.vertex.GetBufferPointer(), shaders.vertex.GetBufferSize(),
            shaders.pixel.GetBufferPointer(), shaders.pixel.GetBufferSize(),
            backBufferFormat, depthBufferFormat, 1, 1, 0, 1);
        if (pipelineState is null)
            throw new Exception("Create graphics pipeline failed");
        translucentPipelineState = cast(ID3D12PipelineState)
            mdCreateGraphicsPipeline(cast(void*) device, cast(void*) rootSignature,
                shaders.vertex.GetBufferPointer(), shaders.vertex.GetBufferSize(),
                shaders.pixel.GetBufferPointer(), shaders.pixel.GetBufferSize(),
                backBufferFormat, depthBufferFormat, 1, 0, 0, 0);
        if (translucentPipelineState is null)
            throw new Exception("Create translucent graphics pipeline failed");
        translucentCulledPipelineState = cast(ID3D12PipelineState)
            mdCreateGraphicsPipeline(cast(void*) device, cast(void*) rootSignature,
                shaders.vertex.GetBufferPointer(), shaders.vertex.GetBufferSize(),
                shaders.pixel.GetBufferPointer(), shaders.pixel.GetBufferSize(),
                backBufferFormat, depthBufferFormat, 1, 0, 0, 1);
        if (translucentCulledPipelineState is null)
            throw new Exception("Create culled translucent graphics pipeline failed");
        skyPipelineState = cast(ID3D12PipelineState) mdCreateGraphicsPipeline(
            cast(void*) device, cast(void*) rootSignature,
            shaders.vertex.GetBufferPointer(), shaders.vertex.GetBufferSize(),
            shaders.pixel.GetBufferPointer(), shaders.pixel.GetBufferSize(),
            backBufferFormat, depthBufferFormat, 0, 0, 0, 0);
        if (skyPipelineState is null)
            throw new Exception("Create sky graphics pipeline failed");
        entityShadowPipelineState = cast(ID3D12PipelineState) mdCreateGraphicsPipeline(
            cast(void*) device, cast(void*) rootSignature,
            shaders.vertex.GetBufferPointer(), shaders.vertex.GetBufferSize(),
            shaders.pixel.GetBufferPointer(), shaders.pixel.GetBufferSize(),
            backBufferFormat, depthBufferFormat, 1, 0, 0, 0);
        if (entityShadowPipelineState is null)
            throw new Exception("Create entity-shadow graphics pipeline failed");
        viewModelPipelineState = cast(ID3D12PipelineState) mdCreateGraphicsPipeline(
            cast(void*) device, cast(void*) rootSignature,
            shaders.vertex.GetBufferPointer(), shaders.vertex.GetBufferSize(),
            shaders.pixel.GetBufferPointer(), shaders.pixel.GetBufferSize(),
            backBufferFormat, depthBufferFormat, 1, 1, 0, 0);
        if (viewModelPipelineState is null)
            throw new Exception("Create view-model graphics pipeline failed");
        invertedOverlayPipelineState = cast(ID3D12PipelineState) mdCreateGraphicsPipeline(
            cast(void*) device, cast(void*) rootSignature,
            shaders.vertex.GetBufferPointer(), shaders.vertex.GetBufferSize(),
            shaders.pixel.GetBufferPointer(), shaders.pixel.GetBufferSize(),
            backBufferFormat, depthBufferFormat, 0, 0, 1, 0);
        if (invertedOverlayPipelineState is null)
            throw new Exception("Create inverted-overlay graphics pipeline failed");
        blurPipelineState = cast(ID3D12PipelineState) mdCreateGraphicsPipeline(
            cast(void*) device, cast(void*) rootSignature,
            shaders.vertex.GetBufferPointer(), shaders.vertex.GetBufferSize(),
            shaders.blurPixel.GetBufferPointer(), shaders.blurPixel.GetBufferSize(),
            backBufferFormat, depthBufferFormat, 0, 0, 0, 0);
        if (blurPipelineState is null)
            throw new Exception("Create menu-blur graphics pipeline failed");
    }

    void createAssets()
    {
        createBlurCapture();
        auto heap = D3D12_HEAP_PROPERTIES(
            D3D12_HEAP_TYPE_UPLOAD, D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            D3D12_MEMORY_POOL_UNKNOWN, 1, 1);
        const bytes = cast(ulong) maxVertices * Vertex.sizeof;
        auto desc = D3D12_RESOURCE_DESC(
            D3D12_RESOURCE_DIMENSION_BUFFER, 0, bytes, 1, 1, 1,
            DXGI_FORMAT_UNKNOWN, DXGI_SAMPLE_DESC(1, 0), D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
            D3D12_RESOURCE_FLAG_NONE);
        foreach(index;0..backBufferCount)
        {
            requireSuccess(device.CreateCommittedResource(&heap,
                D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_GENERIC_READ,
                null,&IID_ID3D12Resource,&vertexBuffers[index]),
                "Create frame vertex buffer");
            vertexViews[index].BufferLocation=
                vertexBuffers[index].GetGPUVirtualAddress();
            vertexViews[index].StrideInBytes=Vertex.sizeof;
            vertexViews[index].SizeInBytes=cast(uint)bytes;
        }

        requireSuccess(device.CreateFence(0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence,
            &fence), "Create GPU fence");
        fenceEvent = CreateEvent(null, FALSE, FALSE, null);
        if (fenceEvent is null)
            throw new Exception("CreateEvent failed for D3D12 fence");
    }

    void createBlurCapture()
    {
        auto heap = D3D12_HEAP_PROPERTIES(
            D3D12_HEAP_TYPE_DEFAULT, D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
            D3D12_MEMORY_POOL_UNKNOWN, 1, 1);
        auto desc = D3D12_RESOURCE_DESC(
            D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, width, height, 1, 1,
            backBufferFormat, DXGI_SAMPLE_DESC(1, 0),
            D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_NONE);
        requireSuccess(device.CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE,
            &desc, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, null,
            &IID_ID3D12Resource, &blurCapture), "Create menu blur capture");

        // Descriptor zero is permanently reserved for the resizeable scene copy.
        if (nextTexture == 0)
        {
            blurTextureIndex = 0;
            nextTexture = 1;
        }
        D3D12_SHADER_RESOURCE_VIEW_DESC srv;
        srv.Format = backBufferFormat;
        srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        srv.Texture2D.MostDetailedMip = 0;
        srv.Texture2D.MipLevels = 1;
        srv.Texture2D.PlaneSlice = 0;
        srv.Texture2D.ResourceMinLODClamp = 0;
        const destination = cpuHandle(srvHeap, blurTextureIndex, srvStride);
        mdCreateShaderResourceView(cast(void*) device, cast(void*) blurCapture,
            &srv, destination.ptr);
    }

    void beginCommands()
    {
        waitForFrame(frameIndex);
        collectRetiredStaticMeshes();
        allocator=allocators[frameIndex];
        list=commandLists[frameIndex];
        requireSuccess(allocator.Reset(), "Reset command allocator");
        requireSuccess(list.Reset(allocator, pipelineState), "Reset command list");
    }

    void executeCommands()
    {
        requireSuccess(list.Close(), "Close command list");
        ID3D12CommandList[1] lists = [cast(ID3D12CommandList) list];
        queue.ExecuteCommandLists(1, lists.ptr);
    }

    void transition(ID3D12Resource resource, D3D12_RESOURCE_STATES before,
        D3D12_RESOURCE_STATES after)
    {
        mdTransition(cast(void*) list, cast(void*) resource, before, after);
    }

    void waitForGpu()
    {
        const value = fenceValue++;
        requireSuccess(queue.Signal(fence, value), "Signal GPU fence");
        if (fence.GetCompletedValue() < value)
        {
            requireSuccess(fence.SetEventOnCompletion(value, fenceEvent), "Arm GPU fence event");
            WaitForSingleObject(fenceEvent, INFINITE);
        }
    }

    void waitForFrame(uint index)
    {
        const value=frameFenceValues[index];
        if(value==0||fence.GetCompletedValue()>=value)return;
        requireSuccess(fence.SetEventOnCompletion(value,fenceEvent),
            "Arm frame fence event");
        WaitForSingleObject(fenceEvent,INFINITE);
    }

    void signalFrame(uint index)
    {
        const value=fenceValue++;
        requireSuccess(queue.Signal(fence,value),"Signal frame fence");
        frameFenceValues[index]=value;
    }

    void collectRetiredStaticMeshes()
    {
        const completed=fence.GetCompletedValue();
        size_t write;
        foreach(index;0..retiredStaticMeshes.length)
        {
            auto mesh=retiredStaticMeshes[index];
            if(mesh.fenceValue<=completed)
            {
                if(mesh.resource !is null)mesh.resource.Release();
            }
            else retiredStaticMeshes[write++]=mesh;
        }
        retiredStaticMeshes.length=write;
    }
}

private IDXGIAdapter1 findHardwareAdapter(IDXGIFactory4 factory)
{
    IDXGIAdapter1 adapter;
    for (uint index = 0; factory.EnumAdapters1(index, &adapter) != DXGI_ERROR_NOT_FOUND; ++index)
    {
        DXGI_ADAPTER_DESC1 desc;
        adapter.GetDesc1(&desc);
        if ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0 &&
            SUCCEEDED(D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0,
                &IID_ID3D12Device, null)))
            return adapter;
        adapter.Release();
        adapter = null;
    }
    return null;
}
