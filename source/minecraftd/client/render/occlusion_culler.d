module minecraftd.client.render.occlusion_culler;

import core.stdc.math : ceilf, floorf;
import minecraftd.common.math3d : Mat4, Vec3, lookToLH, perspectiveFovLH;

/// A guaranteed-solid world-space box used as an opaque occluder.
struct OcclusionBounds
{
    Vec3 minimum;
    Vec3 maximum;
}

private struct ProjectedPoint
{
    float x,y,depth,w;
}

/// Conservative, API-independent hierarchical-depth precursor. It rasterizes
/// only coarse boxes proven to contain opaque blocks, so DirectX 12, Vulkan,
/// and MoltenVK share exactly the same visibility decisions without a GPU
/// readback stall.
final class SoftwareOcclusionCuller
{
    enum int bufferWidth=64;
    enum int bufferHeight=36;
    private float[bufferWidth*bufferHeight] depth;
    private Mat4 viewProjection;

    void beginFrame(Mat4 matrix)
    {
        viewProjection=matrix;
        depth[]=1.0f;
    }

    bool occluded(OcclusionBounds bounds) const
    {
        ProjectedPoint[8] points;
        if(!projectBounds(bounds,points))return false;
        float minX=1,minY=1,maxX=-1,maxY=-1,nearDepth=1;
        foreach(point;points)
        {
            if(point.x<minX)minX=point.x;
            if(point.x>maxX)maxX=point.x;
            if(point.y<minY)minY=point.y;
            if(point.y>maxY)maxY=point.y;
            if(point.depth<nearDepth)nearDepth=point.depth;
        }
        int left=cast(int)floorf((minX*0.5f+0.5f)*bufferWidth);
        int right=cast(int)ceilf((maxX*0.5f+0.5f)*bufferWidth)-1;
        int top=cast(int)floorf((0.5f-minY*0.5f)*bufferHeight);
        int bottom=cast(int)ceilf((0.5f-maxY*0.5f)*bufferHeight)-1;
        // Projection Y grows upward, while the buffer's row grows downward.
        const swapTop=top;top=bottom;bottom=swapTop;
        if(left<0)left=0;if(right>=bufferWidth)right=bufferWidth-1;
        if(top<0)top=0;if(bottom>=bufferHeight)bottom=bufferHeight-1;
        if(left>right||top>bottom)return false;
        // A one-cell guard band deliberately under-culls silhouette edges and
        // small gaps, which is preferable to a single frame of terrain pop-in.
        if(left>0)--left;
        if(right+1<bufferWidth)++right;
        if(top>0)--top;
        if(bottom+1<bufferHeight)++bottom;
        foreach(y;top..bottom+1)foreach(x;left..right+1)
            if(depth[y*bufferWidth+x]>=nearDepth-0.00003f)
                return false;
        return true;
    }

    void addOccluder(OcclusionBounds bounds)
    {
        ProjectedPoint[8] p;
        if(!projectBounds(bounds,p))return;
        rasterizeSilhouette(p);
    }

private:
    bool projectBounds(OcclusionBounds bounds,
        ref ProjectedPoint[8] output) const
    {
        const Vec3[8] corners=[
            Vec3(bounds.minimum.x,bounds.minimum.y,bounds.minimum.z),
            Vec3(bounds.maximum.x,bounds.minimum.y,bounds.minimum.z),
            Vec3(bounds.minimum.x,bounds.maximum.y,bounds.minimum.z),
            Vec3(bounds.maximum.x,bounds.maximum.y,bounds.minimum.z),
            Vec3(bounds.minimum.x,bounds.minimum.y,bounds.maximum.z),
            Vec3(bounds.maximum.x,bounds.minimum.y,bounds.maximum.z),
            Vec3(bounds.minimum.x,bounds.maximum.y,bounds.maximum.z),
            Vec3(bounds.maximum.x,bounds.maximum.y,bounds.maximum.z),
        ];
        foreach(index,point;corners)
        {
            const x=point.x*viewProjection.m[0]
                +point.y*viewProjection.m[4]
                +point.z*viewProjection.m[8]+viewProjection.m[12];
            const y=point.x*viewProjection.m[1]
                +point.y*viewProjection.m[5]
                +point.z*viewProjection.m[9]+viewProjection.m[13];
            const z=point.x*viewProjection.m[2]
                +point.y*viewProjection.m[6]
                +point.z*viewProjection.m[10]+viewProjection.m[14];
            const w=point.x*viewProjection.m[3]
                +point.y*viewProjection.m[7]
                +point.z*viewProjection.m[11]+viewProjection.m[15];
            // Near-plane clipping a box conservatively is more expensive than
            // simply keeping it visible, and near geometry is never worth culling.
            if(w<=0.06f)return false;
            output[index]=ProjectedPoint(x/w,y/w,z/w,w);
        }
        return true;
    }

    void rasterizeSilhouette(const ProjectedPoint[8] projected)
    {
        // A perspective projection of a convex box is convex. Build its
        // eight-point screen-space hull once instead of rasterizing all six
        // faces independently. Using the box's farthest depth for every
        // covered cell is deliberately conservative but dramatically cheaper.
        ProjectedPoint[8] sorted=projected;
        foreach(i;1..sorted.length)
        {
            const value=sorted[i];
            size_t destination=i;
            while(destination>0&&(value.x<sorted[destination-1].x
                ||(value.x==sorted[destination-1].x
                    &&value.y<sorted[destination-1].y)))
            {
                sorted[destination]=sorted[destination-1];
                --destination;
            }
            sorted[destination]=value;
        }
        ProjectedPoint[8] unique;
        size_t uniqueCount;
        float farthestDepth=0.0f;
        foreach(point;sorted)
        {
            if(point.depth>farthestDepth)farthestDepth=point.depth;
            if(uniqueCount&&point.x==unique[uniqueCount-1].x
                &&point.y==unique[uniqueCount-1].y)continue;
            unique[uniqueCount++]=point;
        }
        if(uniqueCount<3)return;
        ProjectedPoint[16] hull;
        size_t hullCount;
        foreach(i;0..uniqueCount)
        {
            while(hullCount>=2&&cross2d(hull[hullCount-2],
                hull[hullCount-1],unique[i])<=0.0f)--hullCount;
            hull[hullCount++]=unique[i];
        }
        const lowerCount=hullCount;
        foreach_reverse(i;0..uniqueCount-1)
        {
            while(hullCount>lowerCount&&cross2d(hull[hullCount-2],
                hull[hullCount-1],unique[i])<=0.0f)--hullCount;
            hull[hullCount++]=unique[i];
        }
        if(hullCount>1)--hullCount;
        if(hullCount<3)return;

        float minX=hull[0].x,maxX=hull[0].x;
        float minY=hull[0].y,maxY=hull[0].y;
        foreach(point;hull[1..hullCount])
        {
            if(point.x<minX)minX=point.x;
            if(point.x>maxX)maxX=point.x;
            if(point.y<minY)minY=point.y;
            if(point.y>maxY)maxY=point.y;
        }
        int left=cast(int)floorf((minX*0.5f+0.5f)*bufferWidth);
        int right=cast(int)ceilf((maxX*0.5f+0.5f)*bufferWidth)-1;
        int top=cast(int)floorf((0.5f-maxY*0.5f)*bufferHeight);
        int bottom=cast(int)ceilf((0.5f-minY*0.5f)*bufferHeight)-1;
        if(left<0)left=0;if(right>=bufferWidth)right=bufferWidth-1;
        if(top<0)top=0;if(bottom>=bufferHeight)bottom=bufferHeight-1;
        if(left>right||top>bottom)return;
        foreach(y;top..bottom+1)foreach(x;left..right+1)
        {
            bool covered=true;
            foreach(corner;0..4)
            {
                const sx=(cast(float)x+(corner==1||corner==2?1:0))
                    /bufferWidth*2.0f-1.0f;
                const sy=1.0f-(cast(float)y+(corner>=2?1:0))
                    /bufferHeight*2.0f;
                if(!insideConvexHull(hull,hullCount,sx,sy))
                {
                    covered=false;
                    break;
                }
            }
            if(!covered)continue;
            const conservativeDepth=farthestDepth+0.00001f;
            auto cell=&depth[y*bufferWidth+x];
            if(conservativeDepth<*cell)*cell=conservativeDepth;
        }
    }

    static float cross2d(ProjectedPoint a,ProjectedPoint b,ProjectedPoint c)
    {
        return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);
    }

    static bool insideConvexHull(ref const ProjectedPoint[16] hull,
        size_t count,float x,float y)
    {
        const point=ProjectedPoint(x,y,0,1);
        foreach(i;0..count)
            if(cross2d(hull[i],hull[(i+1)%count],point)<-0.00001f)
                return false;
        return true;
    }
}

unittest
{
    auto culler=new SoftwareOcclusionCuller();scope(exit)destroy(culler);
    culler.beginFrame(Mat4.identity());
    // Identity projection is sufficient to verify that a nearer solid screen
    // rectangle hides a smaller one while an uncovered box remains admitted.
    culler.addOccluder(OcclusionBounds(Vec3(-0.8f,-0.8f,0.2f),
        Vec3(0.8f,0.8f,0.3f)));
    assert(culler.occluded(OcclusionBounds(Vec3(-0.2f,-0.2f,0.7f),
        Vec3(0.2f,0.2f,0.8f))));
    assert(!culler.occluded(OcclusionBounds(Vec3(0.85f,0.85f,0.7f),
        Vec3(0.95f,0.95f,0.8f))));

    // Also exercise the game's left-handed perspective convention rather
    // than relying only on identity clip space.
    const projection=lookToLH(Vec3(0,0,0),Vec3(0,0,1),Vec3(0,1,0))
        *perspectiveFovLH(1.57079633f,1.0f,0.05f,512.0f);
    culler.beginFrame(projection);
    culler.addOccluder(OcclusionBounds(Vec3(-2,-2,5),Vec3(2,2,6)));
    assert(culler.occluded(OcclusionBounds(Vec3(-0.5f,-0.5f,10),
        Vec3(0.5f,0.5f,11))));
}
