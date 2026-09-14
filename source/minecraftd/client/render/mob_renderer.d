module minecraftd.client.render.mob_renderer;

import minecraftd.client.render.mesh : FrameMesh, Vertex, DrawLayer, FogSettings;
import minecraftd.client.render.player_renderer : PlayerRenderer, SkinLayers;
import minecraftd.common.math3d : Vec3, Mat4;
import minecraftd.game.entity.zombie : ZombieState;

/// Mob models enter the depth-tested world pass, before first-person depth is
/// cleared. Keep this shared across DX12, Vulkan, and future graphics backends.
final class MobRenderer
{
    private PlayerRenderer humanoid;
    this(){humanoid=new PlayerRenderer();}

    Vertex[] buildZombie(const ZombieState zombie,float uvScaleY,float partialTick=0)
    {
        auto geometry=humanoid.buildSteve(zombie.position,zombie.yaw+180,
            0,0,0,0,0,false,zombie.age+partialTick,
            SkinLayers(true,false,false,false,false,false),false,true,false,false,true);
        foreach(ref vertex;geometry)vertex.uv[1]*=uvScaleY;
        humanoid.applyDeathPose(geometry,zombie.position,zombie.yaw+180,zombie.deathTime);
        if(zombie.hurtTime>0||zombie.health<=0)
            foreach(ref vertex;geometry)
            {vertex.color[0]=1;vertex.color[1]*=.25f;vertex.color[2]*=.25f;}
        return geometry;
    }

    void appendWorld(ref FrameMesh frame,const(ZombieState)[] zombies,
        uint texture,float uvScaleY,Mat4 projection,FogSettings fog,
        float partialTick,float delegate(Vec3) lightAt)
    {
        foreach(draw;frame.draws)
            assert(draw.layer!=DrawLayer.viewModel,
                "Mobs must be submitted before first-person depth is cleared");
        foreach(zombie;zombies)
        {
            if(zombie.deathTime>=20)continue;
            auto geometry=buildZombie(zombie,uvScaleY,partialTick);
            humanoid.applyWorldLight(geometry,lightAt(zombie.position+Vec3(0,1,0)));
            frame.append(geometry,texture,projection,DrawLayer.worldDoubleSided,fog);
        }
    }
}

unittest
{
    auto renderer=new MobRenderer();ZombieState z;z.id=1;
    FrameMesh frame;
    renderer.appendWorld(frame,[z],1,1,Mat4.identity(),FogSettings.init,0,
        (Vec3 p)=>1.0f);
    assert(frame.draws.length==1&&frame.draws[0].layer==DrawLayer.worldDoubleSided);
    auto first=renderer.buildZombie(z,1);z.age=30;
    assert(first!=renderer.buildZombie(z,1));
    frame.append(first,1,Mat4.identity(),DrawLayer.viewModel);
    import std.exception : assertThrown;
    import core.exception : AssertError;
    assertThrown!AssertError(renderer.appendWorld(frame,[z],1,1,Mat4.identity(),
        FogSettings.init,0,(Vec3 p)=>1.0f));
}
