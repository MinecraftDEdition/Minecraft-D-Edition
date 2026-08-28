#include <windows.h>
#include <d3d12.h>
#include <xaudio2.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#pragma comment(lib, "xaudio2.lib")

#define STB_VORBIS_NO_PUSHDATA_API
#include "stb_vorbis.c"

namespace {
struct DecodedSound {
    std::vector<unsigned char> format;
    std::vector<unsigned char> pcm;
};

struct VoiceCallback final : IXAudio2VoiceCallback {
    std::atomic<bool> finished{false};
    void STDMETHODCALLTYPE OnVoiceProcessingPassStart(UINT32) override {}
    void STDMETHODCALLTYPE OnVoiceProcessingPassEnd() override {}
    void STDMETHODCALLTYPE OnStreamEnd() override { finished = true; }
    void STDMETHODCALLTYPE OnBufferStart(void*) override {}
    void STDMETHODCALLTYPE OnBufferEnd(void*) override { finished = true; }
    void STDMETHODCALLTYPE OnLoopEnd(void*) override {}
    void STDMETHODCALLTYPE OnVoiceError(void*, HRESULT) override { finished = true; }
};

struct ActiveVoice {
    VoiceCallback callback;
    IXAudio2SourceVoice* voice = nullptr;
    UINT32 sourceChannels = 0;
    bool spatial = false;
    float baseVolume = 1.0f;
    float x = 0.0f, y = 0.0f, z = 0.0f;
    float attenuationDistance = 16.0f;
    ~ActiveVoice() { if (voice) voice->DestroyVoice(); }
};

// Music is kept separate from the short-effect cache. Vanilla marks music
// entries as streamed; retaining every decoded song in AudioEngine::sounds
// would otherwise consume hundreds of megabytes as the playlist advances.
struct MusicVoice {
    VoiceCallback callback;
    IXAudio2SourceVoice* voice = nullptr;
    DecodedSound decoded;
    bool paused = false;
    ~MusicVoice() { if (voice) voice->DestroyVoice(); }
};

struct AudioEngine {
    IXAudio2* xaudio = nullptr;
    IXAudio2MasteringVoice* mastering = nullptr;
    std::unordered_map<std::wstring, DecodedSound> sounds;
    std::vector<std::unique_ptr<ActiveVoice>> voices;
    std::unique_ptr<MusicVoice> music;
    std::mutex musicMutex;
    std::vector<std::thread> musicWorkers;
    std::atomic<unsigned long long> musicGeneration{0};
    std::atomic<bool> musicLoading{false};
    std::atomic<float> requestedMusicVolume{1.0f};
    std::atomic<bool> requestedMusicPaused{false};
    float listenerX = 0.0f, listenerY = 0.0f, listenerZ = 0.0f;
    float listenerYaw = 0.0f;
    bool directionalAudio = false;

    ~AudioEngine() {
        ++musicGeneration;
        for (auto& worker : musicWorkers)
            if (worker.joinable()) worker.join();
        {
            std::lock_guard<std::mutex> lock(musicMutex);
            music.reset();
        }
        voices.clear();
        if (mastering) mastering->DestroyVoice();
        if (xaudio) xaudio->Release();
    }
};

bool decodeOgg(const wchar_t* path, DecodedSound& output) {
    FILE* file = nullptr;
    if (_wfopen_s(&file, path, L"rb") != 0 || !file) return false;
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return false; }
    const long byteCount = ftell(file);
    if (byteCount <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return false;
    }
    std::vector<unsigned char> encoded(static_cast<size_t>(byteCount));
    const bool read = fread(encoded.data(), 1, encoded.size(), file) == encoded.size();
    fclose(file);
    if (!read) return false;

    int channels = 0;
    int sampleRate = 0;
    short* samples = nullptr;
    const int samplesPerChannel = stb_vorbis_decode_memory(encoded.data(),
        static_cast<int>(encoded.size()), &channels, &sampleRate, &samples);
    if (samplesPerChannel <= 0 || channels <= 0 || !samples) {
        free(samples);
        return false;
    }

    WAVEFORMATEX wave{};
    wave.wFormatTag = WAVE_FORMAT_PCM;
    wave.nChannels = static_cast<WORD>(channels);
    wave.nSamplesPerSec = static_cast<DWORD>(sampleRate);
    wave.wBitsPerSample = 16;
    wave.nBlockAlign = static_cast<WORD>(channels * sizeof(short));
    wave.nAvgBytesPerSec = wave.nSamplesPerSec * wave.nBlockAlign;
    output.format.resize(sizeof(wave));
    memcpy(output.format.data(), &wave, sizeof(wave));
    const size_t pcmBytes = static_cast<size_t>(samplesPerChannel)
        * static_cast<size_t>(channels) * sizeof(short);
    output.pcm.assign(reinterpret_cast<unsigned char*>(samples),
        reinterpret_cast<unsigned char*>(samples) + pcmBytes);
    free(samples);
    return true;
}

void collectFinishedVoices(AudioEngine* engine) {
    auto& voices = engine->voices;
    for (auto it = voices.begin(); it != voices.end();) {
        if ((*it)->callback.finished.load()) it = voices.erase(it);
        else ++it;
    }
}

void updateSpatialVoice(AudioEngine* engine, ActiveVoice* active) {
    if (!engine || !active || !active->voice || !active->spatial) return;
    const float dx = active->x - engine->listenerX;
    const float dy = active->y - engine->listenerY;
    const float dz = active->z - engine->listenerZ;
    const float distance = sqrtf(dx * dx + dy * dy + dz * dz);
    const float attenuation = active->attenuationDistance > 0.0f
        ? max(0.0f, 1.0f - distance / active->attenuationDistance) : 1.0f;
    active->voice->SetVolume(active->baseVolume * attenuation);

    XAUDIO2_VOICE_DETAILS masterDetails{};
    engine->mastering->GetVoiceDetails(&masterDetails);
    if (masterDetails.InputChannels < 2 || active->sourceChannels == 0) return;
    const float yaw = engine->listenerYaw * 0.01745329251994329577f;
    const float rightX = cosf(yaw);
    const float rightZ = -sinf(yaw);
    float pan = distance > 0.001f ? (dx * rightX + dz * rightZ) / distance : 0.0f;
    pan = max(-1.0f, min(1.0f, pan));
    if (!engine->directionalAudio) pan *= 0.75f;
    const float left = sqrtf(0.5f * (1.0f - pan));
    const float right = sqrtf(0.5f * (1.0f + pan));
    std::vector<float> matrix(active->sourceChannels * masterDetails.InputChannels, 0.0f);
    const float sourceMix = 1.0f / static_cast<float>(active->sourceChannels);
    for (UINT32 source = 0; source < active->sourceChannels; ++source) {
        matrix[source * masterDetails.InputChannels] = left * sourceMix;
        matrix[source * masterDetails.InputChannels + 1] = right * sourceMix;
    }
    active->voice->SetOutputMatrix(engine->mastering, active->sourceChannels,
        masterDetails.InputChannels, matrix.data());
}
}

// DMD's current MSVC ABI and the legacy directx-d declarations disagree only
// on a handful of small structs passed by value. Keep those calls isolated here.
extern "C" {
void* mdAudioCreate() {
    auto engine = std::make_unique<AudioEngine>();
    if (FAILED(XAudio2Create(&engine->xaudio, 0, XAUDIO2_DEFAULT_PROCESSOR))) return nullptr;
    if (FAILED(engine->xaudio->CreateMasteringVoice(&engine->mastering))) return nullptr;
    return engine.release();
}
void mdAudioDestroy(void* handle) {
    delete static_cast<AudioEngine*>(handle);
}
int mdAudioPlayOgg(void* handle, const wchar_t* path, float volume, float pitch,
                   float pan, int spatial) {
    auto* engine = static_cast<AudioEngine*>(handle);
    if (!engine || !path) return -1;
    collectFinishedVoices(engine);
    auto found = engine->sounds.find(path);
    if (found == engine->sounds.end()) {
        DecodedSound decoded;
        if (!decodeOgg(path, decoded)) return -2;
        found = engine->sounds.emplace(path, std::move(decoded)).first;
    }
    auto active = std::make_unique<ActiveVoice>();
    auto* format = reinterpret_cast<const WAVEFORMATEX*>(found->second.format.data());
    // Several vanilla sounds (notably entity.item.pickup) legitimately pitch
    // above XAudio2's default 2x cap.
    if (FAILED(engine->xaudio->CreateSourceVoice(&active->voice, format, 0,
            4.0f, &active->callback))) return -3;
    XAUDIO2_BUFFER buffer{};
    buffer.Flags = XAUDIO2_END_OF_STREAM;
    buffer.AudioBytes = static_cast<UINT32>(found->second.pcm.size());
    buffer.pAudioData = found->second.pcm.data();
    if (FAILED(active->voice->SetVolume(volume))) return -4;
    if (FAILED(active->voice->SetFrequencyRatio(pitch))) return -5;
    XAUDIO2_VOICE_DETAILS masterDetails{};
    engine->mastering->GetVoiceDetails(&masterDetails);
    const UINT32 sourceChannels = format->nChannels;
    const UINT32 destinationChannels = masterDetails.InputChannels;
    if (spatial && destinationChannels >= 2) {
        pan = max(-1.0f, min(1.0f, pan));
        const float left = sqrtf(0.5f * (1.0f - pan));
        const float right = sqrtf(0.5f * (1.0f + pan));
        std::vector<float> matrix(sourceChannels * destinationChannels, 0.0f);
        const float sourceMix = 1.0f / static_cast<float>(sourceChannels);
        for (UINT32 source = 0; source < sourceChannels; ++source) {
            matrix[source * destinationChannels] = left * sourceMix;
            matrix[source * destinationChannels + 1] = right * sourceMix;
        }
        if (FAILED(active->voice->SetOutputMatrix(engine->mastering,
                sourceChannels, destinationChannels, matrix.data()))) return -8;
    }
    if (FAILED(active->voice->SubmitSourceBuffer(&buffer))) return -6;
    if (FAILED(active->voice->Start())) return -7;
    engine->voices.push_back(std::move(active));
    return 1;
}
int mdAudioPlayOggAt(void* handle, const wchar_t* path, float volume, float pitch,
                     float x, float y, float z, float attenuationDistance) {
    auto* engine = static_cast<AudioEngine*>(handle);
    if (!engine || !path) return -1;
    collectFinishedVoices(engine);
    auto found = engine->sounds.find(path);
    if (found == engine->sounds.end()) {
        DecodedSound decoded;
        if (!decodeOgg(path, decoded)) return -2;
        found = engine->sounds.emplace(path, std::move(decoded)).first;
    }
    auto active = std::make_unique<ActiveVoice>();
    auto* format = reinterpret_cast<const WAVEFORMATEX*>(found->second.format.data());
    if (FAILED(engine->xaudio->CreateSourceVoice(&active->voice, format, 0,
            4.0f, &active->callback))) return -3;
    active->sourceChannels = format->nChannels;
    active->spatial = true;
    active->baseVolume = volume;
    active->x = x; active->y = y; active->z = z;
    active->attenuationDistance = attenuationDistance;
    XAUDIO2_BUFFER buffer{};
    buffer.Flags = XAUDIO2_END_OF_STREAM;
    buffer.AudioBytes = static_cast<UINT32>(found->second.pcm.size());
    buffer.pAudioData = found->second.pcm.data();
    updateSpatialVoice(engine, active.get());
    if (FAILED(active->voice->SetFrequencyRatio(pitch))) return -5;
    if (FAILED(active->voice->SubmitSourceBuffer(&buffer))) return -6;
    if (FAILED(active->voice->Start())) return -7;
    engine->voices.push_back(std::move(active));
    return 1;
}
void mdAudioSetListener(void* handle, float x, float y, float z, float yaw,
                        int directionalAudio) {
    auto* engine = static_cast<AudioEngine*>(handle);
    if (!engine) return;
    engine->listenerX = x; engine->listenerY = y; engine->listenerZ = z;
    engine->listenerYaw = yaw;
    engine->directionalAudio = directionalAudio != 0;
    collectFinishedVoices(engine);
    for (auto& active : engine->voices) updateSpatialVoice(engine, active.get());
}
int mdAudioPlayMusicOgg(void* handle, const wchar_t* path, float volume) {
    auto* engine = static_cast<AudioEngine*>(handle);
    if (!engine || !path) return -1;
    const auto generation = ++engine->musicGeneration;
    engine->requestedMusicVolume.store(max(0.0f, volume));
    engine->musicLoading.store(true);
    const std::wstring ownedPath(path);
    // OGG decode is CPU-heavy for multi-minute songs. Do it outside the UI
    // and render thread; mdAudioMusicPlaying reports the pending load as active
    // so the scheduler cannot enqueue the same song again.
    engine->musicWorkers.emplace_back([engine, ownedPath, generation]() {
        auto music = std::make_unique<MusicVoice>();
        if (!decodeOgg(ownedPath.c_str(), music->decoded)) {
            if (engine->musicGeneration.load() == generation)
                engine->musicLoading.store(false);
            return;
        }
        auto* format = reinterpret_cast<const WAVEFORMATEX*>(
            music->decoded.format.data());
        if (FAILED(engine->xaudio->CreateSourceVoice(&music->voice, format, 0,
                1.0f, &music->callback))) {
            if (engine->musicGeneration.load() == generation)
                engine->musicLoading.store(false);
            return;
        }
        XAUDIO2_BUFFER buffer{};
        buffer.Flags = XAUDIO2_END_OF_STREAM;
        buffer.AudioBytes = static_cast<UINT32>(music->decoded.pcm.size());
        buffer.pAudioData = music->decoded.pcm.data();
        music->voice->SetVolume(engine->requestedMusicVolume.load());
        if (FAILED(music->voice->SubmitSourceBuffer(&buffer))) {
            if (engine->musicGeneration.load() == generation)
                engine->musicLoading.store(false);
            return;
        }
        const bool paused = engine->requestedMusicPaused.load();
        music->paused = paused;
        if (!paused && FAILED(music->voice->Start())) {
            if (engine->musicGeneration.load() == generation)
                engine->musicLoading.store(false);
            return;
        }
        std::lock_guard<std::mutex> lock(engine->musicMutex);
        if (engine->musicGeneration.load() == generation) {
            engine->music = std::move(music);
            engine->musicLoading.store(false);
        }
    });
    return 1;
}
int mdAudioMusicPlaying(void* handle) {
    auto* engine = static_cast<AudioEngine*>(handle);
    if (!engine) return 0;
    if (engine->musicLoading.load()) return 1;
    std::lock_guard<std::mutex> lock(engine->musicMutex);
    if (!engine->music) return 0;
    if (engine->music->callback.finished.load()) {
        engine->music.reset();
        return 0;
    }
    return 1;
}
void mdAudioStopMusic(void* handle) {
    auto* engine = static_cast<AudioEngine*>(handle);
    if (!engine) return;
    ++engine->musicGeneration;
    engine->musicLoading.store(false);
    std::lock_guard<std::mutex> lock(engine->musicMutex);
    engine->music.reset();
}
void mdAudioSetMusicVolume(void* handle, float volume) {
    auto* engine = static_cast<AudioEngine*>(handle);
    if (!engine) return;
    engine->requestedMusicVolume.store(max(0.0f, volume));
    std::lock_guard<std::mutex> lock(engine->musicMutex);
    if (engine->music && engine->music->voice)
        engine->music->voice->SetVolume(engine->requestedMusicVolume.load());
}
void mdAudioSetMusicPaused(void* handle, int paused) {
    auto* engine = static_cast<AudioEngine*>(handle);
    const bool shouldPause = paused != 0;
    if (!engine) return;
    engine->requestedMusicPaused.store(shouldPause);
    std::lock_guard<std::mutex> lock(engine->musicMutex);
    if (!engine->music || !engine->music->voice) return;
    if (engine->music->paused == shouldPause) return;
    if (shouldPause) engine->music->voice->Stop(0);
    else engine->music->voice->Start(0);
    engine->music->paused = shouldPause;
}
void* mdCreateRootSignature(void* d) {
    D3D12_DESCRIPTOR_RANGE range{};
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    range.NumDescriptors = 1;
    range.BaseShaderRegister = 0;
    D3D12_ROOT_PARAMETER parameters[3]{};
    parameters[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    parameters[0].Constants.ShaderRegister = 0;
    parameters[0].Constants.Num32BitValues = 16;
    parameters[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_VERTEX;
    parameters[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameters[1].DescriptorTable.NumDescriptorRanges = 1;
    parameters[1].DescriptorTable.pDescriptorRanges = &range;
    parameters[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    parameters[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    parameters[2].Constants.ShaderRegister = 1;
    parameters[2].Constants.Num32BitValues = 12;
    parameters[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_STATIC_SAMPLER_DESC sampler{};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_WRAP;
    sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_ROOT_SIGNATURE_DESC desc{};
    desc.NumParameters = _countof(parameters);
    desc.pParameters = parameters;
    desc.NumStaticSamplers = 1;
    desc.pStaticSamplers = &sampler;
    desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ID3DBlob* blob = nullptr;
    ID3DBlob* errors = nullptr;
    if (FAILED(D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors))) {
        if (errors) errors->Release();
        return nullptr;
    }
    ID3D12RootSignature* root = nullptr;
    const HRESULT result = static_cast<ID3D12Device*>(d)->CreateRootSignature(
        0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&root));
    blob->Release();
    if (errors) errors->Release();
    return SUCCEEDED(result) ? root : nullptr;
}
size_t mdGetCPUDescriptorHandleStart(void* heap) {
    return static_cast<ID3D12DescriptorHeap*>(heap)->GetCPUDescriptorHandleForHeapStart().ptr;
}
unsigned long long mdGetGPUDescriptorHandleStart(void* heap) {
    return static_cast<ID3D12DescriptorHeap*>(heap)->GetGPUDescriptorHandleForHeapStart().ptr;
}
void* mdCreateGraphicsPipeline(void* d, void* root, const void* vs, size_t vsSize,
                               const void* ps, size_t psSize, unsigned rtvFormat,
                               unsigned dsvFormat, int depthEnabled,
                               int depthWriteEnabled, int blendMode) {
    D3D12_INPUT_ELEMENT_DESC input[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 12, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 20, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
    };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pso{};
    pso.pRootSignature = static_cast<ID3D12RootSignature*>(root);
    pso.VS = {vs, vsSize};
    pso.PS = {ps, psSize};
    pso.InputLayout = {input, _countof(input)};
    pso.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pso.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pso.RasterizerState.DepthClipEnable = TRUE;
    auto& blend = pso.BlendState.RenderTarget[0];
    blend.BlendEnable = TRUE;
    blend.SrcBlend = blendMode == 1
        ? D3D12_BLEND_INV_DEST_COLOR : D3D12_BLEND_SRC_ALPHA;
    blend.DestBlend = blendMode == 1
        ? D3D12_BLEND_INV_SRC_COLOR : D3D12_BLEND_INV_SRC_ALPHA;
    blend.BlendOp = D3D12_BLEND_OP_ADD;
    blend.SrcBlendAlpha = D3D12_BLEND_ONE;
    blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
    blend.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    blend.LogicOp = D3D12_LOGIC_OP_NOOP;
    blend.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pso.DepthStencilState.DepthEnable = depthEnabled;
    pso.DepthStencilState.DepthWriteMask = depthWriteEnabled
        ? D3D12_DEPTH_WRITE_MASK_ALL : D3D12_DEPTH_WRITE_MASK_ZERO;
    pso.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS_EQUAL;
    pso.SampleMask = UINT_MAX;
    pso.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pso.NumRenderTargets = 1;
    pso.RTVFormats[0] = static_cast<DXGI_FORMAT>(rtvFormat);
    pso.DSVFormat = static_cast<DXGI_FORMAT>(dsvFormat);
    pso.SampleDesc.Count = 1;
    ID3D12PipelineState* state = nullptr;
    if (FAILED(static_cast<ID3D12Device*>(d)->CreateGraphicsPipelineState(&pso, IID_PPV_ARGS(&state))))
        return nullptr;
    return state;
}
int mdUploadBuffer(void* resource, const void* data, size_t size) {
    void* destination = nullptr;
    const D3D12_RANGE noRead{0, 0};
    auto* buffer = static_cast<ID3D12Resource*>(resource);
    if (FAILED(buffer->Map(0, &noRead, &destination))) return 0;
    memcpy(destination, data, size);
    buffer->Unmap(0, nullptr);
    return 1;
}
void mdCreateRenderTargetView(void* d, void* r, size_t h) {
    static_cast<ID3D12Device*>(d)->CreateRenderTargetView(
        static_cast<ID3D12Resource*>(r), nullptr, D3D12_CPU_DESCRIPTOR_HANDLE{h});
}
void mdCreateDepthStencilView(void* d, void* r, size_t h) {
    static_cast<ID3D12Device*>(d)->CreateDepthStencilView(
        static_cast<ID3D12Resource*>(r), nullptr, D3D12_CPU_DESCRIPTOR_HANDLE{h});
}
void mdCreateShaderResourceView(void* d, void* r, const D3D12_SHADER_RESOURCE_VIEW_DESC* desc, size_t h) {
    static_cast<ID3D12Device*>(d)->CreateShaderResourceView(
        static_cast<ID3D12Resource*>(r), desc, D3D12_CPU_DESCRIPTOR_HANDLE{h});
}
void mdClearRenderTargetView(void* l, size_t h, const float* color) {
    static_cast<ID3D12GraphicsCommandList*>(l)->ClearRenderTargetView(
        D3D12_CPU_DESCRIPTOR_HANDLE{h}, color, 0, nullptr);
}
void mdClearDepthStencilView(void* l, size_t h) {
    static_cast<ID3D12GraphicsCommandList*>(l)->ClearDepthStencilView(
        D3D12_CPU_DESCRIPTOR_HANDLE{h}, D3D12_CLEAR_FLAG_DEPTH, 1.0f, 0, 0, nullptr);
}
void mdSetRootDescriptorTable(void* l, unsigned rootIndex, unsigned long long h) {
    static_cast<ID3D12GraphicsCommandList*>(l)->SetGraphicsRootDescriptorTable(
        rootIndex, D3D12_GPU_DESCRIPTOR_HANDLE{h});
}
void mdTransition(void* l, void* resource, unsigned before, unsigned after) {
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = static_cast<ID3D12Resource*>(resource);
    b.Transition.StateBefore = static_cast<D3D12_RESOURCE_STATES>(before);
    b.Transition.StateAfter = static_cast<D3D12_RESOURCE_STATES>(after);
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    static_cast<ID3D12GraphicsCommandList*>(l)->ResourceBarrier(1, &b);
}
void mdSetRenderTargets(void* l, size_t rtv, size_t dsv) {
    const D3D12_CPU_DESCRIPTOR_HANDLE r{rtv};
    const D3D12_CPU_DESCRIPTOR_HANDLE d{dsv};
    static_cast<ID3D12GraphicsCommandList*>(l)->OMSetRenderTargets(1, &r, FALSE, &d);
}
void mdPrepareDraw(void* l, void* root, void* heap, float width, float height,
                   unsigned long long vertexAddress, unsigned stride, unsigned size) {
    auto* list = static_cast<ID3D12GraphicsCommandList*>(l);
    list->SetGraphicsRootSignature(static_cast<ID3D12RootSignature*>(root));
    ID3D12DescriptorHeap* heaps[] = {static_cast<ID3D12DescriptorHeap*>(heap)};
    list->SetDescriptorHeaps(1, heaps);
    const D3D12_VIEWPORT viewport{0, 0, width, height, 0, 1};
    const D3D12_RECT scissor{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
    list->RSSetViewports(1, &viewport);
    list->RSSetScissorRects(1, &scissor);
    list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    const D3D12_VERTEX_BUFFER_VIEW view{vertexAddress, size, stride};
    list->IASetVertexBuffers(0, 1, &view);
}
void mdDraw(void* l, const float* transform, const float* fog,
            unsigned long long texture,
            unsigned count, unsigned first) {
    auto* list = static_cast<ID3D12GraphicsCommandList*>(l);
    list->SetGraphicsRoot32BitConstants(0, 16, transform, 0);
    list->SetGraphicsRootDescriptorTable(1, D3D12_GPU_DESCRIPTOR_HANDLE{texture});
    list->SetGraphicsRoot32BitConstants(2, 12, fog, 0);
    list->DrawInstanced(count, 1, first, 0);
}
}
