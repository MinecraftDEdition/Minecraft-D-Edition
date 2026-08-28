module minecraftd.game.entity.entity;

import minecraftd.common.math3d : Vec3;

class Entity
{
    Vec3 position = Vec3(0, 0, 0);
    Vec3 previousPosition = Vec3(0, 0, 0);
    Vec3 velocity = Vec3(0, 0, 0);
    float yaw = 0.0f;
    float pitch = 0.0f;

    void beginTick()
    {
        previousPosition = position;
    }
}
