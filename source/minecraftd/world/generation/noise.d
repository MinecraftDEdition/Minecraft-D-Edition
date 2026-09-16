module minecraftd.world.generation.noise;

import std.math : floor;

// Full 64-bit seeds and double coordinates keep distant and negative chunks
// on exactly the same lattice. No mutable RNG or chunk-order dependency.
ulong mix(ulong n) pure nothrow @safe @nogc
{
    n = (n ^ (n >> 30)) * 0xbf58476d1ce4e5b9UL;
    n = (n ^ (n >> 27)) * 0x94d049bb133111ebUL;
    return n ^ (n >> 31);
}

ulong hash(long x, long y, long z, long seed) pure nothrow @safe @nogc
{
    return mix(cast(ulong)seed ^ mix(cast(ulong)x + 0x9e3779b97f4a7c15UL)
        ^ mix(cast(ulong)y + 0x632be59bd9b4e019UL)
        ^ mix(cast(ulong)z + 0x85157af5d66d2e67UL));
}

double lerp(double a, double b, double t) pure nothrow @safe @nogc
{ return a + (b-a)*t; }
double clamp01(double x) pure nothrow @safe @nogc
{ return x<0?0:x>1?1:x; }
double smooth(double lo, double hi, double x) pure nothrow @safe @nogc
{ const t=clamp01((x-lo)/(hi-lo)); return t*t*(3-2*t); }
private double fade(double t) pure nothrow @safe @nogc
{ return t*t*t*(t*(t*6-15)+10); }
private double value(long x, long z, long seed) pure nothrow @safe @nogc
{ return (hash(x,0,z,seed)>>11)*(2.0/9007199254740992.0)-1; }

double noise2(double x, double z, long seed) pure nothrow @safe @nogc
{
    const ix=cast(long)floor(x), iz=cast(long)floor(z);
    const u=fade(x-ix), v=fade(z-iz);
    return lerp(lerp(value(ix,iz,seed),value(ix+1,iz,seed),u),
        lerp(value(ix,iz+1,seed),value(ix+1,iz+1,seed),u),v);
}

double fbm(double x, double z, long seed, int octaves=4) pure nothrow @safe @nogc
{
    double sum=0, total=0, amplitude=1;
    foreach(i;0..octaves)
    {
        sum+=noise2(x,z,seed+i*1013)*amplitude; total+=amplitude;
        x=x*2.03+17.1; z=z*2.03-11.7; amplitude*=.5;
    }
    return sum/total;
}

private double gradient(ulong h, double x, double y, double z) pure nothrow @safe @nogc
{
    const k=h&15, u=k<8?x:y, v=k<4?y:(k==12||k==14?x:z);
    return ((k&1)?-u:u)+((k&2)?-v:v);
}

double noise3(double x, double y, double z, long seed) pure nothrow @safe @nogc
{
    const ix=cast(long)floor(x), iy=cast(long)floor(y), iz=cast(long)floor(z);
    x-=ix; y-=iy; z-=iz;
    const u=fade(x), v=fade(y), w=fade(z);
    double[2] layers;
    foreach(dz;0..2)
    {
        double[2] rows;
        foreach(dy;0..2)
            rows[dy]=lerp(gradient(hash(ix,iy+dy,iz+dz,seed),x,y-dy,z-dz),
                gradient(hash(ix+1,iy+dy,iz+dz,seed),x-1,y-dy,z-dz),u);
        layers[dz]=lerp(rows[0],rows[1],v);
    }
    return lerp(layers[0],layers[1],w);
}
