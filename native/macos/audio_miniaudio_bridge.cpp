#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include "../stb_vorbis.c"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <future>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

struct DecodedSound {
    int channels = 0;
    int sampleRate = 0;
    std::vector<short> samples;

    ma_uint64 frames() const {
        return channels > 0 ? samples.size() / static_cast<size_t>(channels) : 0;
    }
};

std::shared_ptr<DecodedSound> decodeOgg(const char* path) {
    if (!path || !*path) return {};
    int channels = 0;
    int sampleRate = 0;
    short* decoded = nullptr;
    const int frames = stb_vorbis_decode_filename(path, &channels,
        &sampleRate, &decoded);
    if (frames <= 0 || !decoded || channels <= 0 || sampleRate <= 0) {
        if (decoded) free(decoded);
        return {};
    }
    auto result = std::make_shared<DecodedSound>();
    result->channels = channels;
    result->sampleRate = sampleRate;
    result->samples.assign(decoded,
        decoded + static_cast<size_t>(frames) * channels);
    free(decoded);
    return result;
}

struct ActiveSound {
    std::shared_ptr<DecodedSound> decoded;
    ma_audio_buffer buffer{};
    ma_sound sound{};
    bool bufferReady = false;
    bool soundReady = false;

    ~ActiveSound() {
        if (soundReady) ma_sound_uninit(&sound);
        if (bufferReady) ma_audio_buffer_uninit(&buffer);
    }
};

struct AudioEngine {
    ma_engine engine{};
    bool ready = false;
    std::unordered_map<std::string, std::shared_ptr<DecodedSound>> cache;
    std::vector<std::unique_ptr<ActiveSound>> voices;
    std::unique_ptr<ActiveSound> music;
    std::future<std::shared_ptr<DecodedSound>> musicDecode;
    bool musicLoading = false;
    bool musicPaused = false;
    float musicVolume = 1.0f;

    ~AudioEngine() {
        if (musicDecode.valid()) musicDecode.wait();
        music.reset();
        voices.clear();
        if (ready) ma_engine_uninit(&engine);
    }
};

std::unique_ptr<ActiveSound> makeSound(AudioEngine* engine,
    std::shared_ptr<DecodedSound> decoded, bool spatial) {
    if (!engine || !engine->ready || !decoded || decoded->frames() == 0)
        return {};
    auto active = std::make_unique<ActiveSound>();
    active->decoded = std::move(decoded);
    ma_audio_buffer_config config = ma_audio_buffer_config_init(ma_format_s16,
        static_cast<ma_uint32>(active->decoded->channels),
        active->decoded->frames(), active->decoded->samples.data(), nullptr);
    config.sampleRate = static_cast<ma_uint32>(active->decoded->sampleRate);
    if (ma_audio_buffer_init(&config, &active->buffer) != MA_SUCCESS)
        return {};
    active->bufferReady = true;
    const ma_uint32 flags = spatial ? 0 : MA_SOUND_FLAG_NO_SPATIALIZATION;
    if (ma_sound_init_from_data_source(&engine->engine,
            reinterpret_cast<ma_data_source*>(&active->buffer), flags,
            nullptr, &active->sound) != MA_SUCCESS)
        return {};
    active->soundReady = true;
    return active;
}

void collect(AudioEngine* engine) {
    if (!engine) return;
    engine->voices.erase(std::remove_if(engine->voices.begin(),
        engine->voices.end(), [](const std::unique_ptr<ActiveSound>& voice) {
            return !voice || ma_sound_at_end(&voice->sound);
        }), engine->voices.end());
}

void finishMusicLoad(AudioEngine* engine) {
    if (!engine || !engine->musicLoading || !engine->musicDecode.valid()) return;
    if (engine->musicDecode.wait_for(std::chrono::seconds(0))
            != std::future_status::ready)
        return;
    auto decoded = engine->musicDecode.get();
    engine->musicLoading = false;
    engine->music = makeSound(engine, std::move(decoded), false);
    if (!engine->music) return;
    ma_sound_set_volume(&engine->music->sound,
        std::max(0.0f, engine->musicVolume));
    if (!engine->musicPaused) ma_sound_start(&engine->music->sound);
}

std::shared_ptr<DecodedSound> cached(AudioEngine* engine, const char* path) {
    const std::string key(path ? path : "");
    auto found = engine->cache.find(key);
    if (found != engine->cache.end()) return found->second;
    auto decoded = decodeOgg(path);
    if (decoded) engine->cache.emplace(key, decoded);
    return decoded;
}

} // namespace

extern "C" {

void* mdAudioCreate() {
    auto engine = std::make_unique<AudioEngine>();
    ma_engine_config config = ma_engine_config_init();
    config.listenerCount = 1;
    if (ma_engine_init(&config, &engine->engine) != MA_SUCCESS)
        return nullptr;
    engine->ready = true;
    ma_engine_listener_set_world_up(&engine->engine, 0, 0.0f, 1.0f, 0.0f);
    return engine.release();
}

void mdAudioDestroy(void* value) {
    delete static_cast<AudioEngine*>(value);
}

int mdAudioPlayOgg(void* value, const char* path, float volume, float pitch,
    float pan, int) {
    auto* engine = static_cast<AudioEngine*>(value);
    if (!engine || !path) return -1;
    collect(engine);
    auto voice = makeSound(engine, cached(engine, path), false);
    if (!voice) return -2;
    ma_sound_set_volume(&voice->sound, std::max(0.0f, volume));
    ma_sound_set_pitch(&voice->sound, std::max(0.01f, pitch));
    ma_sound_set_pan(&voice->sound, std::clamp(pan, -1.0f, 1.0f));
    if (ma_sound_start(&voice->sound) != MA_SUCCESS) return -3;
    engine->voices.push_back(std::move(voice));
    return 1;
}

int mdAudioPlayOggAt(void* value, const char* path, float volume, float pitch,
    float x, float y, float z, float attenuationDistance) {
    auto* engine = static_cast<AudioEngine*>(value);
    if (!engine || !path) return -1;
    collect(engine);
    auto voice = makeSound(engine, cached(engine, path), true);
    if (!voice) return -2;
    ma_sound_set_volume(&voice->sound, std::max(0.0f, volume));
    ma_sound_set_pitch(&voice->sound, std::max(0.01f, pitch));
    ma_sound_set_position(&voice->sound, x, y, z);
    ma_sound_set_attenuation_model(&voice->sound,
        ma_attenuation_model_inverse);
    ma_sound_set_min_distance(&voice->sound, 1.0f);
    ma_sound_set_max_distance(&voice->sound,
        std::max(1.0f, attenuationDistance));
    ma_sound_set_rolloff(&voice->sound, 1.0f);
    if (ma_sound_start(&voice->sound) != MA_SUCCESS) return -3;
    engine->voices.push_back(std::move(voice));
    return 1;
}

void mdAudioSetListener(void* value, float x, float y, float z, float yaw,
    int directionalAudio) {
    auto* engine = static_cast<AudioEngine*>(value);
    if (!engine) return;
    constexpr float degreesToRadians = 0.01745329251994329577f;
    const float radians = yaw * degreesToRadians;
    ma_engine_listener_set_position(&engine->engine, 0, x, y, z);
    ma_engine_listener_set_direction(&engine->engine, 0,
        -std::sin(radians), 0.0f, std::cos(radians));
    ma_engine_listener_set_cone(&engine->engine, 0,
        directionalAudio ? 6.2831853f : 6.2831853f, 6.2831853f, 1.0f);
}

int mdAudioPlayMusicOgg(void* value, const char* path, float volume) {
    auto* engine = static_cast<AudioEngine*>(value);
    if (!engine || !path || engine->musicLoading) return -1;
    engine->music.reset();
    if (engine->musicDecode.valid()) engine->musicDecode.wait();
    engine->musicVolume = std::max(0.0f, volume);
    engine->musicLoading = true;
    const std::string ownedPath(path);
    engine->musicDecode = std::async(std::launch::async,
        [ownedPath]() { return decodeOgg(ownedPath.c_str()); });
    return 1;
}

int mdAudioMusicPlaying(void* value) {
    auto* engine = static_cast<AudioEngine*>(value);
    if (!engine) return 0;
    finishMusicLoad(engine);
    if (engine->musicLoading) return 1;
    return engine->music && !ma_sound_at_end(&engine->music->sound) ? 1 : 0;
}

void mdAudioStopMusic(void* value) {
    auto* engine = static_cast<AudioEngine*>(value);
    if (!engine) return;
    if (engine->music) ma_sound_stop(&engine->music->sound);
    engine->music.reset();
}

void mdAudioSetMusicVolume(void* value, float volume) {
    auto* engine = static_cast<AudioEngine*>(value);
    if (!engine) return;
    engine->musicVolume = std::max(0.0f, volume);
    finishMusicLoad(engine);
    if (engine->music)
        ma_sound_set_volume(&engine->music->sound, engine->musicVolume);
}

void mdAudioSetMusicPaused(void* value, int paused) {
    auto* engine = static_cast<AudioEngine*>(value);
    if (!engine) return;
    engine->musicPaused = paused != 0;
    finishMusicLoad(engine);
    if (!engine->music) return;
    if (engine->musicPaused) ma_sound_stop(&engine->music->sound);
    else ma_sound_start(&engine->music->sound);
}

} // extern "C"

