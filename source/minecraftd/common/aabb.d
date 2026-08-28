module minecraftd.common.aabb;

import minecraftd.common.math3d : Vec3;

/// Axis-aligned entity bounds. Coordinates are block/world units.
struct Aabb
{
    float minX = 0.0f;
    float minY = 0.0f;
    float minZ = 0.0f;
    float maxX = 0.0f;
    float maxY = 0.0f;
    float maxZ = 0.0f;

    Aabb moved(Vec3 amount) const
    {
        return Aabb(
            minX + amount.x, minY + amount.y, minZ + amount.z,
            maxX + amount.x, maxY + amount.y, maxZ + amount.z,
        );
    }

    bool intersects(Aabb other) const
    {
        return maxX > other.minX && minX < other.maxX
            && maxY > other.minY && minY < other.maxY
            && maxZ > other.minZ && minZ < other.maxZ;
    }
}
