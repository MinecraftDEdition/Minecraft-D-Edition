module held_item_pose_smoke;
import std.stdio : writeln;
import minecraftd.client.render.player_renderer;
import minecraftd.client.render.mesh;
import minecraftd.common.math3d;

void main()
{
    auto renderer=new PlayerRenderer();
    Vec3 point(Vertex v){return Vec3(v.position[0],v.position[1],v.position[2]);}
    foreach(slim;[false,true])foreach(right;[false,true])foreach(kind;0..4)
    {
        Vec3[3] reference;
        foreach(sample;0..24)
        {
            const age=sample*7.3f,attack=sample%6/6.0f;
            const crouching=sample%3==1,swimming=sample%3==2;
            const yaw=sample*19.0f,pitch=sample*2.0f;
            const position=Vec3(13,65,-24);
            const walk=sample*.57f,speed=sample%4*.15f;
            auto skin=renderer.buildSteve(position,yaw,0,pitch,walk,speed,attack,
                crouching,age,SkinLayers.classic(),true,right,swimming,slim);
            const first=right?72:108;
            const origin=point(skin[first]);
            const u=(point(skin[first+1])-origin).normalized();
            const v=(point(skin[first+2])-point(skin[first+1])).normalized();
            const n=cross(u,v).normalized();
            const transform=renderer.thirdPersonHeldItemTransform(kind!=0,position,yaw,right,
                walk,speed,attack,crouching,age,slim,kind==2,pitch,swimming,kind==3);
            foreach(i,local;[Vec3(.5f,.5f,.5f),Vec3(.8f,.5f,.5f),Vec3(.5f,.8f,.5f)])
            {
                const relative=transform.transformPoint(local)-origin;
                const attached=Vec3(dot(relative,u),dot(relative,v),dot(relative,n));
                if(sample==0)reference[i]=attached;
                else assert((attached-reference[i]).length()<.00005f,
                    "Held item slipped relative to the actual rendered arm");
            }
        }
    }
    destroy(renderer);
    writeln("PASS: rigid arm attachment across idle, walk, attack, crouch and swimming; both hands and arm widths");
}
