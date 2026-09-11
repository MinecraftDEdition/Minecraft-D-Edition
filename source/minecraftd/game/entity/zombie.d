module minecraftd.game.entity.zombie;

import core.stdc.math : floorf;
import minecraftd.common.aabb : Aabb;
import minecraftd.common.math3d : Vec3;
import minecraftd.world.world : World;
import minecraftd.world.block : isOpaque, isWater;
import minecraftd.world.world_settings : DimensionId;
import minecraftd.world.chunk : chunkCoordinate;

enum maximumZombies = 128;
enum ZombieSound : ubyte { ambient, hurt, death }
struct ZombieSoundEvent { ZombieSound sound; Vec3 position; }

/// Stationary first mob. Simulation has no movement, targeting or AI decisions.
struct ZombieState
{
    uint id;
    Vec3 position;
    float yaw = 0;
    DimensionId dimension;
    float health = 20;
    uint age;
    ushort fireTicks;
    ubyte hurtTime;
    ubyte deathTime;
    uint ambientSerial, hurtSerial, deathSerial;
    int ambientTime;
    uint randomState = 1;
    ubyte fireDamageTime;

    Aabb bounds() const
    {
        return Aabb(position.x-.3f,position.y,position.z-.3f,
            position.x+.3f,position.y+1.95f,position.z+.3f);
    }

    bool damage(float amount)
    {
        if(health<=0 || hurtTime>0 || amount<=0)return false;
        health-=amount;
        hurtTime=10;
        ambientTime=-80;
        if(health<=0){health=0;fireTicks=0;++deathSerial;}
        else ++hurtSerial;
        return true;
    }

    uint random()
    {
        if(!randomState)randomState=id+1;
        randomState^=randomState<<13;
        randomState^=randomState>>17;
        randomState^=randomState<<5;
        return randomState;
    }

    void tick(World world, bool daylight)
    {
        ++age;
        if(hurtTime)--hurtTime;
        if(health<=0){if(deathTime<20)++deathTime;return;}
        if(cast(int)(random()%1000)<ambientTime++)
        {ambientTime=-80;++ambientSerial;}
        if(world.intersectsWater(bounds()))
        {fireTicks=0;fireDamageTime=0;return;}
        // Full daylight gives vanilla's 4% ignition chance per tick.
        if(daylight && dimension==DimensionId.overworld
            && random()%1000<40 && seesSky(world,position+Vec3(0,1.74f,0)))
            fireTicks=160;
        if(world.intersectsFire(bounds()))fireTicks=160;
        if(fireTicks)
        {
            --fireTicks;
            if(++fireDamageTime>=20){fireDamageTime=0;damage(1);}
        }
        else fireDamageTime=0;
    }
}

/// No overhead distance cutoff. Glass passes sky light; opaque blocks and
/// water attenuate it. Never generate terrain as a side effect of this query.
bool seesSky(World world, Vec3 eye)
{
    const x=cast(int)floorf(eye.x),z=cast(int)floorf(eye.z);
    if(!world.hasChunk(chunkCoordinate(x),chunkCoordinate(z)))return false;
    for(int y=cast(int)floorf(eye.y);y<=world.maximumBuildY();++y)
    {
        const block=world.getBlock(x,y,z);
        if(isOpaque(block)||isWater(block))return false;
    }
    return true;
}

unittest
{
    import minecraftd.world.block : BlockId;
    auto world=new World();scope(exit)destroy(world);
    ZombieState z;z.id=42;z.position=Vec3(30.5f,40,30.5f);
    const eye=z.position+Vec3(0,1.74f,0);
    assert(seesSky(world,eye));
    world.setBlock(30,world.maximumBuildY(),30,BlockId.stone);
    assert(!seesSky(world,eye));
    foreach(_;0..500)z.tick(world,true);
    assert(z.health==20&&z.fireTicks==0&&z.position==Vec3(30.5f,40,30.5f));
    assert(!seesSky(world,Vec3(10000,40,10000)));
    world.setBlock(30,world.maximumBuildY(),30,BlockId.glass);
    assert(seesSky(world,eye));
    foreach(_;0..200)z.tick(world,true);
    assert(z.health<20);
    world.setBlock(30,40,30,BlockId.waterSource);
    z.tick(world,true);assert(z.fireTicks==0);
    world.setBlock(30,40,30,BlockId.air);
    foreach(_;0..200)z.tick(world,false);
    assert(z.fireTicks==0);
    z.fireTicks=0;z.dimension=DimensionId.nether;
    foreach(_;0..200)z.tick(world,true);
    assert(z.fireTicks==0);
    z.hurtTime=0;assert(z.damage(100));assert(z.deathSerial==1);
    assert(!z.damage(100));
    foreach(_;0..20)z.tick(world,true);
    assert(z.deathTime==20);
}
