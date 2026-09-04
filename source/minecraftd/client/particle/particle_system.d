module minecraftd.client.particle.particle_system;

import core.stdc.math : ceilf, cosf, floorf, logf, sinf, sqrtf;
import minecraftd.client.render.camera : Camera;
import minecraftd.client.render.mesh : Color, Vertex, appendQuad;
import minecraftd.common.aabb : Aabb;
import minecraftd.common.math3d : PI, Vec2, Vec3, cross, forwardFromYawPitch, lerp;
import minecraftd.game.entity.player : Player;
import minecraftd.world.block : BlockId;
import minecraftd.world.world : World;

struct ParticleTextureSet
{
    uint grass;
    uint dirt;
    uint stone;
    uint obsidian;
    uint netherrack;
    uint bedrock;
    uint bricks;
    uint oakPlanks;
    uint sprucePlanks;
    uint birchPlanks;
    uint junglePlanks;
    uint acaciaPlanks;
    uint darkOakPlanks;
    uint mangrovePlanks;
    uint cherryPlanks;
    uint bambooPlanks;
    uint paleOakPlanks;
    uint crimsonPlanks;
    uint warpedPlanks;
    uint cobblestone;
    uint glass;
    uint criticalHit;
    uint[8] poof;
    uint[8] portal;
    uint[4] splash;
    uint bubble;
    uint[5] bubblePop;
    uint[8] smoke;
    uint[BlockId] catalog;
}

private struct TerrainParticle
{
    Vec3 position;
    Vec3 previousPosition;
    Vec3 velocity;
    BlockId block;
    float size;
    float u0;
    float v0;
    int age;
    int lifetime;
    bool onGround;
}

private struct CriticalParticle
{
    Vec3 position;
    Vec3 previousPosition;
    Vec3 velocity;
    float size;
    float brightness;
    int age;
    int lifetime;
}

private struct PoofParticle
{
    Vec3 position;
    Vec3 previousPosition;
    Vec3 velocity;
    float size;
    float brightness;
    int age;
    int lifetime;
}

private struct PortalParticle
{
    Vec3 position;
    Vec3 previousPosition;
    Vec3 startPosition;
    Vec3 velocity;
    float size;
    float originalSize;
    int age;
    int lifetime;
}

private struct WaterParticle
{
    Vec3 position;
    Vec3 previousPosition;
    Vec3 velocity;
    float size;
    int age;
    int lifetime;
    bool splash;
}

private struct SmokeParticle
{
    Vec3 position;
    Vec3 previousPosition;
    Vec3 velocity;
    float size;
    int age;
    int lifetime;
}

/// Java-style terrain particles shared by block destruction and sprint trails.
final class ParticleSystem
{
    private enum size_t maximumParticles = 4096;
    private World world;
    private ParticleTextureSet textures;
    private TerrainParticle[] particles;
    private CriticalParticle[] criticalParticles;
    private PoofParticle[] poofParticles;
    private PortalParticle[] portalParticles;
    private WaterParticle[] waterParticles;
    private SmokeParticle[] smokeParticles;
    private uint randomState = 0x6D2B79F5u;
    private int level;

    this(World world, ParticleTextureSet textures)
    {
        this.world = world;
        this.textures = textures;
    }

    size_t count() const
    {
        return particles.length + criticalParticles.length + poofParticles.length
            + portalParticles.length + waterParticles.length
            + smokeParticles.length;
    }
    void setLevel(int value) { level=value<0?0:(value>2?2:value); }

    void spawnBlockBreak(int blockX, int blockY, int blockZ, BlockId block)
    {
        // ParticleEngine.destroy divides a full cube into a 4x4x4 grid.
        const divisions=level==0?4:(level==1?3:2);
        foreach (x; 0 .. divisions)
        foreach (y; 0 .. divisions)
        foreach (z; 0 .. divisions)
        {
            const fx = (cast(float) x + 0.5f) / divisions;
            const fy = (cast(float) y + 0.5f) / divisions;
            const fz = (cast(float) z + 0.5f) / divisions;
            spawnTerrain(
                Vec3(blockX + fx, blockY + fy, blockZ + fz),
                Vec3(fx - 0.5f, fy - 0.5f, fz - 0.5f), block,
            );
        }
    }

    void spawnSprint(const Player player)
    {
        if(level==2 || (level==1 && randomFloat()<0.5f))return;
        const blockX = cast(int) floorf(player.position.x);
        const blockY = cast(int) floorf(player.position.y - 0.05f);
        const blockZ = cast(int) floorf(player.position.z);
        const block = world.getBlock(blockX, blockY, blockZ);
        if (block == BlockId.air)
            return;
        const position = Vec3(
            player.position.x + (randomFloat() - 0.5f) * Player.width,
            player.position.y + 0.1f,
            player.position.z + (randomFloat() - 0.5f) * Player.width,
        );
        // Entity.spawnSprintParticle feeds inverse per-tick motion * 4 and
        // a vertical velocity of 1.5 into the shared terrain particle.
        const perTick = player.velocity * 0.05f;
        spawnTerrain(position, Vec3(-perTick.x * 4.0f, 1.5f,
            -perTick.z * 4.0f), block);
    }

    void spawnLanding(const Player player, float fallDistance)
    {
        if (fallDistance <= 3.0f)
            return;
        const blockX = cast(int) floorf(player.position.x);
        const blockY = cast(int) floorf(player.position.y - 0.05f);
        const blockZ = cast(int) floorf(player.position.z);
        const block = world.getBlock(blockX, blockY, blockZ);
        if (block == BlockId.air)
            return;
        int count = cast(int) ceilf(fallDistance - 3.0f);
        if (level == 1)
            count = (count + 1) / 2;
        else if (level == 2)
            count = count > 0 ? 1 : 0;
        foreach (_; 0 .. count)
        {
            const angle = randomFloat() * PI * 2.0f;
            const radius = randomFloat() * Player.width * 0.5f;
            const outward = 0.3f + randomFloat() * 0.35f;
            spawnTerrain(Vec3(
                player.position.x + cosf(angle) * radius,
                player.position.y + 0.08f,
                player.position.z + sinf(angle) * radius),
                Vec3(cosf(angle) * outward, 0.35f,
                    sinf(angle) * outward), block);
        }
    }

    void spawnCriticalHit(Vec3 targetPosition,
        float targetHeight = Player.standingHeight)
    {
        // Minecraft's client-level critical effect emits roughly
        // width*height*60 CRIT particles throughout the struck entity.
        const count = cast(int) (Player.width * targetHeight
            * (level==0?60.0f:(level==1?36.0f:18.0f)));
        foreach (_; 0 .. count)
        {
            CriticalParticle particle;
            particle.position = particle.previousPosition = Vec3(
                targetPosition.x + (randomFloat() - 0.5f) * Player.width,
                targetPosition.y + randomFloat() * targetHeight,
                targetPosition.z + (randomFloat() - 0.5f) * Player.width);
            particle.velocity = Vec3(
                (randomFloat() - 0.5f) * 0.08f,
                0.08f + randomFloat() * 0.16f,
                (randomFloat() - 0.5f) * 0.08f);
            particle.size = 0.08f + randomFloat() * 0.06f;
            particle.brightness = 0.6f + randomFloat() * 0.4f;
            particle.lifetime = 6 + cast(int) (randomFloat() * 4.0f);
            criticalParticles ~= particle;
        }
    }

    void spawnPoof(Vec3 feetPosition, float entityHeight = Player.standingHeight)
    {
        // LivingEntity's death event emits twenty POOF particles distributed
        // across the body's bounding box at the 20-tick removal boundary.
        foreach (_; 0 .. 20)
        {
            PoofParticle particle;
            const supplied=Vec3(randomGaussian()*0.02f,
                randomGaussian()*0.02f,randomGaussian()*0.02f);
            particle.position = particle.previousPosition = Vec3(
                feetPosition.x+(randomFloat()*2.0f-1.0f)*Player.width
                    -supplied.x*10.0f,
                feetPosition.y+randomFloat()*entityHeight-supplied.y*10.0f,
                feetPosition.z+(randomFloat()*2.0f-1.0f)*Player.width
                    -supplied.z*10.0f);
            particle.velocity=supplied+Vec3((randomFloat()*2.0f-1.0f)*0.05f,
                (randomFloat()*2.0f-1.0f)*0.05f,
                (randomFloat()*2.0f-1.0f)*0.05f);
            const sizeRandom=randomFloat();
            particle.size=0.1f*(sizeRandom*sizeRandom*6.0f+1.0f);
            particle.brightness=randomFloat()*0.3f+0.7f;
            particle.lifetime=cast(int)(16.0f/(randomFloat()*0.8f+0.2f))+2;
            poofParticles ~= particle;
        }
    }

    void spawnPortalBlock(int blockX, int blockY, int blockZ, bool axisX)
    {
        foreach (_; 0 .. 4)
        {
            PortalParticle particle;
            particle.position = particle.previousPosition = Vec3(
                blockX + randomFloat(), blockY + randomFloat(),
                blockZ + randomFloat());
            const direction = randomFloat() < 0.5f ? -1.0f : 1.0f;
            if (axisX)
            {
                particle.position.z = blockZ + 0.5f + direction * 0.25f;
                particle.velocity = Vec3((randomFloat()-0.5f)*0.08f,
                    (randomFloat()-0.5f)*0.08f, direction*0.12f);
            }
            else
            {
                particle.position.x = blockX + 0.5f + direction * 0.25f;
                particle.velocity = Vec3(direction*0.12f,
                    (randomFloat()-0.5f)*0.08f,(randomFloat()-0.5f)*0.08f);
            }
            particle.startPosition=particle.position;
            particle.originalSize = 0.05f + randomFloat() * 0.02f;
            particle.size = 0.0f;
            particle.lifetime = 40 + cast(int) (randomFloat() * 20.0f);
            portalParticles ~= particle;
        }
        if (portalParticles.length > maximumParticles)
            portalParticles = portalParticles[$-maximumParticles/2 .. $].dup;
    }

    void spawnWaterEntry(const Player player)
    {
        int count=cast(int)(1.0f+Player.width*20.0f);
        if(level==1)count=(count+1)/2;else if(level==2)count=(count+3)/4;
        foreach(i;0..count)
        {
            WaterParticle particle;
            const angle=randomFloat()*PI*2.0f;
            const radius=randomFloat()*Player.width;
            particle.position=particle.previousPosition=Vec3(
                player.position.x+cosf(angle)*radius,player.position.y+0.1f,
                player.position.z+sinf(angle)*radius);
            particle.splash=(i&1)==0;
            particle.velocity=particle.splash
                ?Vec3(cosf(angle)*0.04f,0.08f+randomFloat()*0.08f,
                    sinf(angle)*0.04f)
                :Vec3((randomFloat()-0.5f)*0.02f,0.035f,
                    (randomFloat()-0.5f)*0.02f);
            particle.size=particle.splash?0.08f:0.045f;
            particle.lifetime=particle.splash?8:20+cast(int)(randomFloat()*12);
            waterParticles~=particle;
        }
    }

    void spawnSwimming(const Player player)
    {
        if(level==2||level==1&&randomFloat()<0.5f)return;
        WaterParticle particle;
        particle.position=particle.previousPosition=Vec3(
            player.position.x+(randomFloat()-0.5f)*Player.width,
            player.position.y+randomFloat()*player.height(),
            player.position.z+(randomFloat()-0.5f)*Player.width);
        particle.velocity=Vec3(-player.velocity.x*0.01f,0.04f,
            -player.velocity.z*0.01f);
        particle.size=0.04f;
        particle.lifetime=20+cast(int)(randomFloat()*12);
        waterParticles~=particle;
    }

    void spawnFireSmoke(int blockX,int blockY,int blockZ)
    {
        if(level==2&&randomFloat()<0.5f)return;
        SmokeParticle particle;
        particle.position=particle.previousPosition=Vec3(
            blockX+0.25f+randomFloat()*0.5f,
            blockY+0.75f+randomFloat()*0.35f,
            blockZ+0.25f+randomFloat()*0.5f);
        particle.velocity=Vec3((randomFloat()-0.5f)*0.008f,
            0.025f+randomFloat()*0.015f,(randomFloat()-0.5f)*0.008f);
        particle.size=0.10f+randomFloat()*0.05f;
        particle.lifetime=30+cast(int)(randomFloat()*20.0f);
        smokeParticles~=particle;
    }

    void tick()
    {
        size_t destination;
        foreach (particle; particles)
        {
            particle.previousPosition = particle.position;
            if (particle.age++ >= particle.lifetime)
                continue;
            particle.velocity.y -= 0.04f;
            const bounds = Aabb(
                particle.position.x - 0.1f, particle.position.y,
                particle.position.z - 0.1f,
                particle.position.x + 0.1f, particle.position.y + 0.2f,
                particle.position.z + 0.1f,
            );
            const collision = world.collide(bounds, particle.velocity);
            particle.position += collision.movement;
            if (collision.hitX) particle.velocity.x = 0.0f;
            if (collision.hitY) particle.velocity.y = 0.0f;
            if (collision.hitZ) particle.velocity.z = 0.0f;
            particle.onGround = collision.hitY;
            particle.velocity = particle.velocity * 0.98f;
            if (particle.onGround)
            {
                particle.velocity.x *= 0.7f;
                particle.velocity.z *= 0.7f;
            }
            particles[destination++] = particle;
        }
        particles.length = destination;

        destination = 0;
        foreach (particle; criticalParticles)
        {
            particle.previousPosition = particle.position;
            if (particle.age++ >= particle.lifetime)
                continue;
            particle.position += particle.velocity;
            particle.velocity = particle.velocity * 0.7f;
            criticalParticles[destination++] = particle;
        }
        criticalParticles.length = destination;

        destination = 0;
        foreach (particle; poofParticles)
        {
            particle.previousPosition = particle.position;
            if (particle.age++ >= particle.lifetime)
                continue;
            particle.velocity.y += 0.004f;
            particle.position += particle.velocity;
            particle.velocity = particle.velocity * 0.9f;
            poofParticles[destination++] = particle;
        }
        poofParticles.length = destination;

        destination = 0;
        foreach (particle; portalParticles)
        {
            particle.previousPosition = particle.position;
            if (particle.age++ >= particle.lifetime)
                continue;
            const life=cast(float)particle.age/particle.lifetime;
            const path=1.0f+life-2.0f*life*life;
            particle.position=particle.startPosition+particle.velocity*path
                +Vec3(0,1.0f-life,0);
            const growth=1.0f-(1.0f-life)*(1.0f-life);
            particle.size=particle.originalSize*growth;
            portalParticles[destination++] = particle;
        }
        portalParticles.length = destination;

        destination=0;
        foreach(particle;waterParticles)
        {
            particle.previousPosition=particle.position;
            if(particle.age++>=particle.lifetime)continue;
            particle.position+=particle.velocity;
            if(particle.splash)particle.velocity.y-=0.012f;
            else
            {
                particle.velocity.y+=0.001f;
                if(!world.isPointInWater(particle.position))continue;
            }
            particle.velocity.x*=0.9f;particle.velocity.z*=0.9f;
            waterParticles[destination++]=particle;
        }
        waterParticles.length=destination;

        destination=0;
        foreach(particle;smokeParticles)
        {
            particle.previousPosition=particle.position;
            if(particle.age++>=particle.lifetime)continue;
            particle.position+=particle.velocity;
            particle.velocity.x*=0.96f;
            particle.velocity.z*=0.96f;
            particle.velocity.y+=0.00035f;
            smokeParticles[destination++]=particle;
        }
        smokeParticles.length=destination;
    }

    Vertex[][uint] build(const Camera camera, float partialTick) const
    {
        Vertex[][uint] result;
        const forward = forwardFromYawPitch(camera.yaw, camera.pitch);
        const right = cross(Vec3(0,1,0), forward).normalized();
        const up = cross(forward, right).normalized();
        const shade = Color(0.6f, 0.6f, 0.6f, 1.0f);
        foreach (particle; particles)
        {
            const center = Vec3(
                lerp(partialTick, particle.previousPosition.x, particle.position.x),
                lerp(partialTick, particle.previousPosition.y, particle.position.y),
                lerp(partialTick, particle.previousPosition.z, particle.position.z),
            );
            const horizontal = right * particle.size;
            const vertical = up * particle.size;
            const texture = textureFor(particle.block);
            auto geometry = texture in result;
            if (geometry is null)
            {
                result[texture] = [];
                geometry = texture in result;
            }
            appendQuad(*geometry,
                center-horizontal-vertical, center+horizontal-vertical,
                center+horizontal+vertical, center-horizontal+vertical,
                Vec2(particle.u0, particle.v0 + 0.25f),
                Vec2(particle.u0 + 0.25f, particle.v0 + 0.25f),
                Vec2(particle.u0 + 0.25f, particle.v0),
                Vec2(particle.u0, particle.v0),
                shade, shade, shade, shade,
            );
        }
        foreach (particle; criticalParticles)
        {
            const center = Vec3(
                lerp(partialTick, particle.previousPosition.x, particle.position.x),
                lerp(partialTick, particle.previousPosition.y, particle.position.y),
                lerp(partialTick, particle.previousPosition.z, particle.position.z));
            const horizontal = right * particle.size;
            const vertical = up * particle.size;
            auto geometry = textures.criticalHit in result;
            if (geometry is null)
            {
                result[textures.criticalHit] = [];
                geometry = textures.criticalHit in result;
            }
            const fade = 1.0f - cast(float) particle.age / particle.lifetime;
            const color = Color(particle.brightness, particle.brightness,
                particle.brightness, fade);
            appendQuad(*geometry,
                center-horizontal-vertical, center+horizontal-vertical,
                center+horizontal+vertical, center-horizontal+vertical,
                Vec2(0,1), Vec2(1,1), Vec2(1,0), Vec2(0,0),
                color, color, color, color);
        }
        foreach (particle; poofParticles)
        {
            const center = Vec3(
                lerp(partialTick,particle.previousPosition.x,particle.position.x),
                lerp(partialTick,particle.previousPosition.y,particle.position.y),
                lerp(partialTick,particle.previousPosition.z,particle.position.z));
            const horizontal=right*particle.size;
            const vertical=up*particle.size;
            int frame=particle.age*7/particle.lifetime;
            if(frame<0)frame=0; if(frame>7)frame=7;
            const texture=textures.poof[frame];
            auto geometry=texture in result;
            if(geometry is null)
            {
                result[texture]=[];
                geometry=texture in result;
            }
            const color=Color(particle.brightness,particle.brightness,
                particle.brightness,1);
            appendQuad(*geometry,center-horizontal-vertical,
                center+horizontal-vertical,center+horizontal+vertical,
                center-horizontal+vertical,Vec2(0,1),Vec2(1,1),
                Vec2(1,0),Vec2(0,0),color,color,color,color);
        }
        foreach (particle; portalParticles)
        {
            const center=Vec3(
                lerp(partialTick,particle.previousPosition.x,particle.position.x),
                lerp(partialTick,particle.previousPosition.y,particle.position.y),
                lerp(partialTick,particle.previousPosition.z,particle.position.z));
            const horizontal=right*particle.size;
            const vertical=up*particle.size;
            int frame=particle.age*8/particle.lifetime;
            if(frame<0)frame=0; if(frame>7)frame=7;
            const texture=textures.portal[frame];
            auto geometry=texture in result;
            if(geometry is null)
            {
                result[texture]=[];
                geometry=texture in result;
            }
            const life=cast(float)particle.age/particle.lifetime;
            const brightness=0.65f+0.35f*(1.0f-life);
            const color=Color(0.75f*brightness,0.18f*brightness,
                1.0f*brightness,1.0f);
            appendQuad(*geometry,center-horizontal-vertical,
                center+horizontal-vertical,center+horizontal+vertical,
                center-horizontal+vertical,Vec2(0,1),Vec2(1,1),
                Vec2(1,0),Vec2(0,0),color,color,color,color);
        }
        foreach(particle;waterParticles)
        {
            const center=Vec3(lerp(partialTick,particle.previousPosition.x,particle.position.x),
                lerp(partialTick,particle.previousPosition.y,particle.position.y),
                lerp(partialTick,particle.previousPosition.z,particle.position.z));
            const horizontal=right*particle.size;
            const vertical=up*particle.size;
            uint texture;
            if(particle.splash)
            {
                int frame=particle.age*4/particle.lifetime;
                if(frame>3)frame=3;
                texture=textures.splash[frame];
            }
            else texture=textures.bubble;
            auto geometry=texture in result;
            if(geometry is null){result[texture]=[];geometry=texture in result;}
            const color=Color(1,1,1,0.9f);
            appendQuad(*geometry,center-horizontal-vertical,center+horizontal-vertical,
                center+horizontal+vertical,center-horizontal+vertical,
                Vec2(0,1),Vec2(1,1),Vec2(1,0),Vec2(0,0),
                color,color,color,color);
        }
        foreach(particle;smokeParticles)
        {
            const center=Vec3(
                lerp(partialTick,particle.previousPosition.x,particle.position.x),
                lerp(partialTick,particle.previousPosition.y,particle.position.y),
                lerp(partialTick,particle.previousPosition.z,particle.position.z));
            const growth=1.0f+cast(float)particle.age/particle.lifetime*0.75f;
            const horizontal=right*particle.size*growth;
            const vertical=up*particle.size*growth;
            int frame=particle.age*8/particle.lifetime;
            if(frame<0)frame=0;if(frame>7)frame=7;
            const texture=textures.smoke[frame];
            auto geometry=texture in result;
            if(geometry is null){result[texture]=[];geometry=texture in result;}
            const fade=1.0f-cast(float)particle.age/particle.lifetime;
            const color=Color(0.35f,0.35f,0.35f,fade*0.85f);
            appendQuad(*geometry,center-horizontal-vertical,
                center+horizontal-vertical,center+horizontal+vertical,
                center-horizontal+vertical,Vec2(0,1),Vec2(1,1),Vec2(1,0),
                Vec2(0,0),color,color,color,color);
        }
        return result;
    }

private:
    void spawnTerrain(Vec3 position, Vec3 requestedVelocity, BlockId block)
    {
        if (particles.length >= maximumParticles)
            particles = particles[$-maximumParticles/2 .. $].dup;
        auto velocity = requestedVelocity + Vec3(
            (randomFloat() * 2.0f - 1.0f) * 0.4f,
            (randomFloat() * 2.0f - 1.0f) * 0.4f,
            (randomFloat() * 2.0f - 1.0f) * 0.4f,
        );
        const magnitude = velocity.length();
        const speed = (randomFloat() + randomFloat() + 1.0f) * 0.15f * 0.4f;
        velocity = magnitude > 0.000001f ? velocity / magnitude * speed : Vec3.init;
        velocity.y += 0.1f;
        TerrainParticle particle;
        particle.position = particle.previousPosition = position;
        particle.velocity = velocity;
        particle.block = block;
        particle.size = 0.05f + randomFloat() * 0.05f;
        particle.u0 = randomFloat() * 0.75f;
        particle.v0 = randomFloat() * 0.75f;
        particle.lifetime = cast(int) (4.0f / (randomFloat() * 0.9f + 0.1f));
        particles ~= particle;
    }

    uint textureFor(BlockId block) const
    {
        switch (block)
        {
            // Java's grass-block model declares dirt as its particle sprite.
            case BlockId.grass: return textures.dirt;
            case BlockId.dirt: return textures.dirt;
            case BlockId.stone: return textures.stone;
            case BlockId.obsidian: return textures.obsidian;
            case BlockId.netherrack: return textures.netherrack;
            case BlockId.bedrock: return textures.bedrock;
            case BlockId.bricks: return textures.bricks;
            case BlockId.oakPlanks: return textures.oakPlanks;
            case BlockId.sprucePlanks: return textures.sprucePlanks;
            case BlockId.birchPlanks: return textures.birchPlanks;
            case BlockId.junglePlanks: return textures.junglePlanks;
            case BlockId.acaciaPlanks: return textures.acaciaPlanks;
            case BlockId.darkOakPlanks: return textures.darkOakPlanks;
            case BlockId.mangrovePlanks: return textures.mangrovePlanks;
            case BlockId.cherryPlanks: return textures.cherryPlanks;
            case BlockId.bambooPlanks: return textures.bambooPlanks;
            case BlockId.paleOakPlanks: return textures.paleOakPlanks;
            case BlockId.crimsonPlanks: return textures.crimsonPlanks;
            case BlockId.warpedPlanks: return textures.warpedPlanks;
            case BlockId.cobblestone: return textures.cobblestone;
            case BlockId.glass: return textures.glass;
            case BlockId.air, BlockId.netherPortalX, BlockId.netherPortalZ:
                return textures.dirt;
            case BlockId.waterSource, BlockId.waterFlow1, BlockId.waterFlow2,
                 BlockId.waterFlow3, BlockId.waterFlow4, BlockId.waterFlow5,
                 BlockId.waterFlow6, BlockId.waterFlow7, BlockId.waterFalling:
                return textures.dirt;
            case BlockId.fire: return textures.dirt;
            default:
                const found = block in textures.catalog;
                return found is null ? textures.dirt : *found;
        }
    }

    float randomFloat()
    {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return cast(float) (randomState & 0x00FFFFFFu) / 16777216.0f;
    }

    float randomGaussian()
    {
        float first=randomFloat();
        if(first<0.000001f)first=0.000001f;
        return sqrtf(-2.0f*logf(first))*cosf(2.0f*PI*randomFloat());
    }
}
