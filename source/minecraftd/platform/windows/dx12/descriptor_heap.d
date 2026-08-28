module minecraftd.platform.windows.dx12.descriptor_heap;

import directx.d3d12;
import minecraftd.platform.windows.dx12.abi_bridge : mdGetCPUDescriptorHandleStart,
    mdGetGPUDescriptorHandleStart;

D3D12_CPU_DESCRIPTOR_HANDLE offsetCpu(D3D12_CPU_DESCRIPTOR_HANDLE start, uint index, uint increment)
{
    start.ptr += cast(size_t) index * increment;
    return start;
}

D3D12_GPU_DESCRIPTOR_HANDLE offsetGpu(D3D12_GPU_DESCRIPTOR_HANDLE start, uint index, uint increment)
{
    start.ptr += cast(ulong) index * increment;
    return start;
}

D3D12_CPU_DESCRIPTOR_HANDLE cpuHandle(ID3D12DescriptorHeap heap, uint index, uint increment)
{
    D3D12_CPU_DESCRIPTOR_HANDLE result;
    result.ptr = mdGetCPUDescriptorHandleStart(cast(void*) heap) + cast(size_t) index * increment;
    return result;
}

D3D12_GPU_DESCRIPTOR_HANDLE gpuHandle(ID3D12DescriptorHeap heap, uint index, uint increment)
{
    D3D12_GPU_DESCRIPTOR_HANDLE result;
    result.ptr = mdGetGPUDescriptorHandleStart(cast(void*) heap) + cast(ulong) index * increment;
    return result;
}
