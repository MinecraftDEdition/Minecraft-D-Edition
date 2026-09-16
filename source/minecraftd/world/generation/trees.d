module minecraftd.world.generation.trees;

import std.algorithm : min, max;
import std.math : abs;
import minecraftd.world.block : BlockId, isLeaves;
import minecraftd.world.chunk : Chunk, chunkCoordinate;
import minecraftd.world.world_settings : WorldSettings;
import minecraftd.world.generation.noise : hash, fbm;
import minecraftd.world.generation.overworld : columnAt;
import minecraftd.world.generation.biomes;

// Every chunk evaluates the same neighboring anchor cells and writes only its
// own intersection. Trees neither request neighbor chunks nor depend on jobs'
// completion order. Canopy/branch bounds must stay inside the 8-block halo.
void generateTrees(Chunk target,const WorldSettings settings)
{
    const ox=target.chunkX*16,oz=target.chunkZ*16;
    // Cell addresses remain signed, including across world coordinate zero.
    foreach(cz;target.chunkZ*2-1..target.chunkZ*2+3)
    foreach(cx;target.chunkX*2-1..target.chunkX*2+3)
    {
        const random=hash(cx,0,cz,settings.seed+83177);
        const x=cx*8+1+cast(int)((random>>8)%6);
        const z=cz*8+1+cast(int)((random>>16)%6);
        const c=columnAt(x,z,settings);
        const d=definition(c.biome);
        if(c.water||d.tree==Tree.none||random%100>=d.trees)continue;
        if(fbm(x*.014,z*.014,settings.seed+21031,2)>.44)continue;
        int low=c.height,high=c.height;
        foreach(dz;-2..3)foreach(dx;-2..3)
        {
            const ground=columnAt(x+dx,z+dz,settings);
            low=min(low,ground.height); high=max(high,ground.height);
        }
        if(high-low>3)continue;
        const y=c.height+1;
        const tree=d.tree==Tree.oak&&c.biome==Biome.forest&&(random>>24)%5==0?Tree.birch:d.tree;
        const log=cast(BlockId)(cast(int)BlockId.oakLog+cast(int)tree-1);
        const leaves=cast(BlockId)(cast(int)BlockId.oakLeaves+cast(int)tree-1);
        int height=5+cast(int)((random>>32)%3)+(d.tall?5:0);
        if(tree==Tree.spruce)height+=3;
        const wide=tree==Tree.darkOak||tree==Tree.paleOak;
        void put(int px,int py,int pz,BlockId block)
        {
            if(px<ox||px>=ox+16||pz<oz||pz>=oz+16)return;
            const old=target.get(px-ox,py,pz-oz);
            if(old==BlockId.air||(isLeaves(old)&&block==log))
                target.set(px-ox,py,pz-oz,block);
        }
        foreach(dz;0..(wide?2:1))foreach(dx;0..(wide?2:1))
        {
            const ground=columnAt(x+dx,z+dz,settings);
            foreach(py;min(y,ground.height+1)..y+height)put(x+dx,py,z+dz,log);
        }
        void crown(int px,int py,int pz,int radius,int depth)
        {
            foreach(dy;-depth..2)
            {
                const r=dy==1?max(1,radius-2):dy==0?max(1,radius-1):radius;
                foreach(dz;-r..r+1)foreach(dx;-r..r+1)
                {
                    if(dx*dx+dz*dz>r*r+1)continue;
                    if(abs(dx)==r&&abs(dz)==r&&(hash(px+dx,py+dy,pz+dz,settings.seed)&1))continue;
                    put(px+dx,py+dy,pz+dz,leaves);
                }
            }
        }
        if(tree==Tree.spruce)
        {
            foreach(dy;3..height+2)
            {
                const r=dy>=height?1:min(3,1+(height-dy)/3);
                if(dy%3==0&&dy<height-1)continue;
                foreach(dz;-r..r+1)foreach(dx;-r..r+1)
                    if(abs(dx)+abs(dz)<=r+1)put(x+dx,y+dy,z+dz,leaves);
            }
        }
        else if(tree==Tree.acacia||tree==Tree.cherry)
        {
            const direction=(random&1)?1:-1;
            foreach(i;1..4)put(x+i*direction,y+height-3+i/2,z,log);
            crown(x+3*direction,y+height,z,tree==Tree.cherry?3:2,1);
            crown(x-direction,y+height-2,z+1,2,1);
        }
        else
            crown(x,y+height-1,z,wide||tree==Tree.jungle?3:2,wide?3:2);
        if(tree==Tree.mangrove)
            foreach(dz;-1..2)foreach(dx;-1..2)
                if(abs(dx)+abs(dz)==1)
                {
                    const ground=columnAt(x+dx,z+dz,settings);
                    foreach(py;ground.height+1..y+2)put(x+dx,py,z+dz,log);
                }
    }
}
