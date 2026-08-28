module minecraftd.client.audio.sound_manager;

version (Windows):

import std.path : buildPath;
import std.file : exists, readText;
import std.json : JSONType, parseJSON;
import std.utf : toUTF16z;
import minecraftd.game.resources.resource_manager : ResourceManager;
import minecraftd.platform.windows.dx12.abi_bridge : mdAudioCreate,
    mdAudioDestroy, mdAudioMusicPlaying, mdAudioPlayMusicOgg, mdAudioPlayOgg,
    mdAudioPlayOggAt, mdAudioSetListener,
    mdAudioSetMusicPaused, mdAudioSetMusicVolume, mdAudioStopMusic;
import minecraftd.world.block : BlockId, soundType;
import minecraftd.world.world_settings : DimensionId;
import minecraftd.common.math3d : Vec3, DEG_TO_RAD, clamp;

enum MusicContext : ubyte
{
    menu,
    overworld,
    nether,
}

private struct MusicTrack
{
    string path;
    float volume = 1.0f;
    int weight = 1;
}

private struct MusicDefinition
{
    string eventName;
    MusicTrack[] tracks;
    int minimumDelay;
    int maximumDelay;
    bool replaceCurrent;
}

final class SoundManager
{
    private void* engine;
    private string projectRoot;
    private uint randomState = 0xA341316Cu;
    private Vec3 listenerPosition;
    private float listenerYaw;
    private float masterVolume = 1.0f;
    private float soundVolume = 1.0f;
    private float playerVolume = 1.0f;
    private float uiVolume = 1.0f;
    private float musicVolume = 1.0f;
    private bool directionalAudio = true;
    private MusicDefinition menuMusic;
    private MusicDefinition overworldMusic;
    private MusicDefinition netherMusic;
    private string currentMusicEvent;
    private float currentMusicTrackVolume = 1.0f;
    private int nextSongDelay = 100;
    private uint lastMusicMilliseconds;
    private uint musicRemainderMilliseconds;
    private bool musicPaused;

    this(ResourceManager resources)
    {
        projectRoot = resources.root();
        engine = mdAudioCreate();
        menuMusic = loadMusic("music.menu", 20, 600, true);
        overworldMusic = loadMusic("music.game", 12_000, 24_000, false);
        // This game's current Nether is the Nether Wastes-style netherrack
        // dimension, so use the matching vanilla biome event.
        netherMusic = loadMusic("music.nether.nether_wastes", 12_000,
            24_000, false);
    }

    ~this()
    {
        if (engine !is null)
            mdAudioDestroy(engine);
    }

    void playStep(BlockId block,Vec3 position)
    {
        const type = soundType(block);
        const choices = type.family == "grass" ? 6
            : (type.family == "stone" ? 6 : 4);
        const path = type.family == "netherrack"
            ? "block/netherrack/step" ~ randomChoice(6) ~ ".ogg"
            : "step/" ~ type.family ~ randomChoice(choices) ~ ".ogg";
        playAt(path,position,
            type.volume * 0.15f, type.pitch * (0.9f + randomFloat() * 0.2f),
            soundVolume);
    }

    void setListener(Vec3 position, float yaw)
    {
        listenerPosition = position;
        listenerYaw = yaw;
        if (engine !is null)
            mdAudioSetListener(engine, position.x, position.y, position.z, yaw,
                directionalAudio ? 1 : 0);
    }

    void setVolumes(float master, float effects, float players = 1.0f,
        float ui = 1.0f, float music = 1.0f, bool directional = true)
    {
        masterVolume = clamp(master, 0.0f, 1.0f);
        soundVolume = clamp(effects, 0.0f, 1.0f);
        playerVolume = clamp(players,0.0f,1.0f);
        uiVolume = clamp(ui,0.0f,1.0f);
        musicVolume = clamp(music,0.0f,1.0f);
        directionalAudio = directional;
        updateMusicVolume();
    }

    void tickMenuMusic(int frequencySetting)
    {
        tickMusic(MusicContext.menu, frequencySetting, false);
    }

    void tickGameMusic(DimensionId dimension, int frequencySetting, bool paused)
    {
        tickMusic(dimension == DimensionId.nether
            ? MusicContext.nether : MusicContext.overworld,
            frequencySetting, paused);
    }

    void playBreak(BlockId block, Vec3 position)
    {
        const type = soundType(block);
        const path = type.family == "netherrack"
            ? "block/netherrack/break" ~ randomChoice(6) ~ ".ogg"
            : "dig/" ~ type.family ~ randomChoice(4) ~ ".ogg";
        playAt(path, position,
            (type.volume + 1.0f) * 0.5f,
            type.pitch * (0.72f + randomFloat() * 0.16f));
    }

    void playPlace(BlockId block,Vec3 position)
    {
        const type = soundType(block);
        const path = type.family == "netherrack"
            ? "block/netherrack/break" ~ randomChoice(6) ~ ".ogg"
            : "dig/" ~ type.family ~ randomChoice(4) ~ ".ogg";
        playAt(path,position,
            (type.volume + 1.0f) * 0.5f, type.pitch * 0.8f, soundVolume);
    }

    void playHit(BlockId block, Vec3 position)
    {
        const type = soundType(block);
        const choices = type.family == "grass" ? 6
            : (type.family == "stone" ? 6 : 4);
        const path = type.family == "netherrack"
            ? "block/netherrack/step" ~ randomChoice(6) ~ ".ogg"
            : "step/" ~ type.family ~ randomChoice(choices) ~ ".ogg";
        playAt(path, position,
            type.volume * 0.25f, type.pitch * 0.5f);
    }

    void playPlayerHurt()
    {
        play("damage/hit" ~ randomChoice(3) ~ ".ogg", 1.0f,
            0.9f + randomFloat() * 0.2f, playerVolume);
    }

    void playFall(bool big)
    {
        play(big ? "damage/fallbig.ogg" : "damage/fallsmall.ogg", 1.0f, 1.0f,
            playerVolume);
    }

    void playPickup(Vec3 position)
    {
        // Vanilla uses random/pop with a triangular high-pitch variation. The
        // modest volume boost keeps the very short source audible after our
        // distance attenuation while preserving its familiar character.
        const pitch = ((randomFloat() - randomFloat()) * 0.7f + 1.0f) * 2.0f;
        playAt("random/pop.ogg", position, 0.35f, pitch, playerVolume);
    }

    void playCriticalHit(Vec3 position)
    {
        // sounds.json: entity.player.attack.crit selects crit1..3 at 0.7
        // volume with the default pitch.
        playAt("entity/player/attack/crit" ~ randomChoice(3) ~ ".ogg",
            position, 0.7f, 1.0f, playerVolume);
    }

    void playUiButton()
    {
        // sounds.json maps ui.button.click to this stereo, non-positional OGG.
        play("random/click_stereo.ogg", 1.0f, 1.0f, uiVolume);
    }

    void playPortalTrigger(Vec3 position)
    {
        playAt("portal/trigger.ogg", position, 0.25f,
            0.8f + randomFloat() * 0.4f, playerVolume);
    }

    void playPortalTravel()
    {
        play("portal/travel.ogg", 0.25f, 0.8f + randomFloat() * 0.4f,
            playerVolume);
    }

    void randomPortalAmbient(Vec3 position)
    {
        // NetherPortalBlock.randomDisplayTick: a one-percent positional
        // ambient chance per portal block, volume 0.5, pitch [0.8, 1.2).
        if (randomFloat() < 0.01f)
            playAt("portal/portal.ogg", position, 0.5f,
                0.8f + randomFloat() * 0.4f, soundVolume, 16.0f);
    }

    void playNetherAmbience()
    {
        play("ambient/nether/nether_wastes/ambience.ogg", 0.35f, 1.0f,
            soundVolume);
    }

    void playWaterEntry(Vec3 position, float speed)
    {
        if(speed>4.0f)
            playAt("liquid/heavy_splash.ogg",position,1.0f,1.0f,playerVolume);
        else
            playAt(randomFloat()<0.5f?"liquid/splash.ogg":"liquid/splash2.ogg",
                position,1.0f,
                0.8f+randomFloat()*0.4f,playerVolume);
        play("ambient/underwater/enter"~randomChoice(3)~".ogg",0.5f,1.0f,
            soundVolume);
    }

    void playWaterExit()
    {
        play("ambient/underwater/exit"~randomChoice(3)~".ogg",0.3f,1.0f,
            soundVolume);
    }

    void playUnderwaterAmbience()
    {
        play("ambient/underwater/underwater_ambience.ogg",0.65f,1.0f,
            soundVolume);
    }

    void randomFlowingWaterAmbient(Vec3 position)
    {
        // WaterFluid.animateTick uses a 1/64 chance for non-source,
        // non-falling water, volume [.75,1] and pitch [.5,1.5].
        if(randomFloat()<1.0f/64.0f)
            playAt("liquid/water.ogg",position,randomFloat()*0.25f+0.75f,
                randomFloat()+0.5f,soundVolume,16.0f);
    }

    void playSwim(Vec3 position)
    {
        // sounds.json selects swim5..18 for players.
        const index=randomInt(5,18);
        import std.conv:to;
        playAt("liquid/swim"~to!string(index)~".ogg",position,1.0f,
            0.8f+randomFloat()*0.4f,playerVolume);
    }

private:
    MusicDefinition loadMusic(string eventName, int minimumDelay,
        int maximumDelay, bool replaceCurrent)
    {
        MusicDefinition result = MusicDefinition(eventName, [], minimumDelay,
            maximumDelay, replaceCurrent);
        const path = buildPath(projectRoot, "assets", "minecraft", "sounds.json");
        if (!exists(path))
            return result;
        try
        {
            const root = parseJSON(readText(path));
            if (root.type != JSONType.object || eventName !in root.object)
                return result;
            const entry = root.object[eventName];
            if (entry.type != JSONType.object || "sounds" !in entry.object)
                return result;
            const sounds = entry.object["sounds"];
            if (sounds.type != JSONType.array)
                return result;
            foreach (sound; sounds.array)
            {
                MusicTrack track;
                if (sound.type == JSONType.string)
                    track.path = sound.str;
                else if (sound.type == JSONType.object && "name" in sound.object)
                {
                    track.path = sound.object["name"].str;
                    if ("volume" in sound.object)
                        track.volume = cast(float) sound.object["volume"].floating;
                    if ("weight" in sound.object)
                        track.weight = cast(int) sound.object["weight"].integer;
                }
                if (track.path.length && track.weight > 0)
                {
                    track.path ~= ".ogg";
                    result.tracks ~= track;
                }
            }
        }
        catch (Exception) {}
        return result;
    }

    void tickMusic(MusicContext context, int frequencySetting, bool paused)
    {
        import core.sys.windows.windows : GetTickCount;
        const now = cast(uint) GetTickCount();
        if (lastMusicMilliseconds == 0)
            lastMusicMilliseconds = now;
        const delta = now - lastMusicMilliseconds;
        lastMusicMilliseconds = now;
        musicRemainderMilliseconds += delta > 1_000 ? 1_000 : delta;
        if (musicPaused != paused)
        {
            musicPaused = paused;
            if (engine !is null)
                mdAudioSetMusicPaused(engine, paused ? 1 : 0);
        }
        while (musicRemainderMilliseconds >= 50)
        {
            musicRemainderMilliseconds -= 50;
            musicStep(context, frequencySetting);
        }
    }

    void musicStep(MusicContext context, int frequencySetting)
    {
        const desired = definition(context);
        bool playing = currentMusicEvent.length != 0 && engine !is null
            && mdAudioMusicPlaying(engine) != 0;
        if (playing && desired.replaceCurrent
            && currentMusicEvent != desired.eventName)
        {
            mdAudioStopMusic(engine);
            playing = false;
            currentMusicEvent = "";
            nextSongDelay = randomInt(0, desired.minimumDelay / 2);
        }
        if (currentMusicEvent.length && !playing)
        {
            currentMusicEvent = "";
            nextSongDelay = minimum(nextSongDelay,
                nextDelay(desired, frequencySetting));
        }
        nextSongDelay = minimum(nextSongDelay, desired.maximumDelay);
        if (!currentMusicEvent.length && --nextSongDelay <= 0)
            startMusic(desired);
    }

    ref const(MusicDefinition) definition(MusicContext context)
    {
        final switch (context)
        {
            case MusicContext.menu: return menuMusic;
            case MusicContext.overworld: return overworldMusic;
            case MusicContext.nether: return netherMusic;
        }
    }

    int nextDelay(const MusicDefinition definition, int frequencySetting)
    {
        if (frequencySetting >= 2)
            return 100;
        const maximumFrequency = frequencySetting == 1 ? 12_000 : 24_000;
        return randomInt(minimum(definition.minimumDelay, maximumFrequency),
            minimum(definition.maximumDelay, maximumFrequency));
    }

    void startMusic(const MusicDefinition definition)
    {
        int totalWeight;
        foreach (track; definition.tracks)
            totalWeight += track.weight;
        if (engine is null || totalWeight <= 0)
        {
            nextSongDelay = 100;
            return;
        }
        int choice = randomInt(1, totalWeight);
        MusicTrack selected;
        foreach (track; definition.tracks)
        {
            choice -= track.weight;
            if (choice <= 0)
            {
                selected = track;
                break;
            }
        }
        const path = buildPath(projectRoot, "assets", "minecraft", "sounds",
            selected.path);
        currentMusicTrackVolume = selected.volume;
        if (mdAudioPlayMusicOgg(engine, path.toUTF16z(), adjustedMusicVolume()) > 0)
        {
            currentMusicEvent = definition.eventName;
            nextSongDelay = int.max;
            if (musicPaused)
                mdAudioSetMusicPaused(engine, 1);
        }
        else
            nextSongDelay = 100;
    }

    void updateMusicVolume()
    {
        if (engine !is null && currentMusicEvent.length)
            mdAudioSetMusicVolume(engine, adjustedMusicVolume());
    }

    float adjustedMusicVolume() const
    {
        return masterVolume * musicVolume * currentMusicTrackVolume;
    }

    int minimum(int left, int right) const
    {
        return left < right ? left : right;
    }

    int randomInt(int lower, int upper)
    {
        if (upper <= lower)
            return lower;
        return lower + cast(int) (randomFloat() * (upper - lower + 1));
    }

    string randomChoice(int count)
    {
        import std.conv : to;
        return to!string(cast(int) (randomFloat() * count) + 1);
    }

    float randomFloat()
    {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return cast(float) (randomState & 0x00FFFFFFu) / 16777216.0f;
    }

    void play(string relativePath, float volume, float pitch,
        float categoryVolume = 1.0f)
    {
        const adjusted = volume * masterVolume * categoryVolume;
        if (engine is null || adjusted <= 0.0001f)
            return;
        const path = buildPath(projectRoot, "assets", "minecraft", "sounds",
            relativePath);
        mdAudioPlayOgg(engine, path.toUTF16z(), adjusted, pitch, 0.0f,0);
    }

    void playAt(string relativePath, Vec3 position, float volume, float pitch,
        float categoryVolume = -1.0f, float attenuationDistance = 16.0f)
    {
        if(categoryVolume<0.0f)categoryVolume=soundVolume;
        if (engine is null || masterVolume <= 0.0001f
            || categoryVolume <= 0.0001f)
            return;
        const path = buildPath(projectRoot, "assets", "minecraft", "sounds",
            relativePath);
        mdAudioPlayOggAt(engine, path.toUTF16z(),
            volume * masterVolume * categoryVolume, pitch,
            position.x, position.y, position.z, attenuationDistance);
    }
}
