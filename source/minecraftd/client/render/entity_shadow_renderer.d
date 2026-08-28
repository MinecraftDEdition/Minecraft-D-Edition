module minecraftd.client.render.entity_shadow_renderer;

import core.stdc.math : floorf;

import minecraftd.client.render.mesh : Color, Vertex, appendQuad;
import minecraftd.common.math3d : Vec2, Vec3, clamp;
import minecraftd.world.block : BlockId;
import minecraftd.world.world : World;

/// Per-renderer shadow parameters, matching Java Edition's entity renderer
/// contract. Most mobs can derive their radius from their collision footprint;
/// renderers with intentionally smaller shadows (such as dropped items) can
/// provide an explicit value.
struct EntityShadowStyle
{
    float radius;
    float strength = 1.0f;

    static EntityShadowStyle fromFootprint(float width, float depth,
        float strength = 1.0f)
    {
        const footprint = width > depth ? width : depth;
        // A 0.6-block player footprint maps to Java's 0.5 shadow radius.
        return EntityShadowStyle(footprint * (5.0f / 6.0f), strength);
    }
}

/// Builds Java-style circular decals over every eligible block top beneath an
/// entity. UVs remain in entity space, so adjacent block pieces join back into
/// one circle while differing surface heights receive independently faded
/// pieces of the same shadow.
final class EntityShadowRenderer
{
    enum float maximumRadius = 32.0f;
    enum float verticalPowerFalloff = 0.5f;
    enum float maximumDistanceSquared = 16.0f * 16.0f;
    enum float surfaceOffset = 1.0f / 64.0f;

    private World world;

    this(World world)
    {
        this.world = world;
    }

    Vertex[] build(Vec3 entityPosition, EntityShadowStyle style,
        Vec3 cameraPosition) const
    {
        Vertex[] output;
        const radius = clamp(style.radius, 0.0f, maximumRadius);
        if (radius <= 0.0f || style.strength <= 0.0f)
            return output;

        const cameraDelta = entityPosition - cameraPosition;
        const distanceSquared = cameraDelta.x * cameraDelta.x
            + cameraDelta.y * cameraDelta.y
            + cameraDelta.z * cameraDelta.z;
        const power = clamp((1.0f - distanceSquared / maximumDistanceSquared)
            * style.strength, 0.0f, 1.0f);
        if (power <= 0.0f)
            return output;

        const minX = cast(int) floorf(entityPosition.x - radius);
        const maxX = cast(int) floorf(entityPosition.x + radius);
        const minZ = cast(int) floorf(entityPosition.z - radius);
        const maxZ = cast(int) floorf(entityPosition.z + radius);
        // Java scans from floor(y - radius) through floor(y), then samples the
        // block below each scan position. This keeps a player's shadow on a
        // one-block-lower ledge and naturally stops it after roughly 1.5 blocks.
        const minSurfaceGridY = cast(int) floorf(entityPosition.y - radius);
        const maxSurfaceGridY = cast(int) floorf(entityPosition.y);

        foreach (x; minX .. maxX + 1)
        foreach (z; minZ .. maxZ + 1)
        foreach (surfaceGridY; minSurfaceGridY .. maxSurfaceGridY + 1)
        {
            const blockY = surfaceGridY - 1;
            if (world.getBlock(x, blockY, z) == BlockId.air)
                continue;

            const surfaceY = blockY + 1.0f;
            const verticalDistance = entityPosition.y - surfaceY;
            const alpha = clamp((power - verticalDistance * verticalPowerFalloff)
                * 0.5f, 0.0f, 1.0f);
            if (alpha <= 0.0f)
                continue;

            const left = x > entityPosition.x - radius
                ? cast(float) x : entityPosition.x - radius;
            const right = x + 1.0f < entityPosition.x + radius
                ? x + 1.0f : entityPosition.x + radius;
            const near = z > entityPosition.z - radius
                ? cast(float) z : entityPosition.z - radius;
            const far = z + 1.0f < entityPosition.z + radius
                ? z + 1.0f : entityPosition.z + radius;
            if (left >= right || near >= far)
                continue;

            const diameter = radius * 2.0f;
            const u0 = (left - (entityPosition.x - radius)) / diameter;
            const u1 = (right - (entityPosition.x - radius)) / diameter;
            const v0 = (near - (entityPosition.z - radius)) / diameter;
            const v1 = (far - (entityPosition.z - radius)) / diameter;
            const y = surfaceY + surfaceOffset;
            const shade = Color(1.0f, 1.0f, 1.0f, alpha);
            appendQuad(output,
                Vec3(left, y, near), Vec3(right, y, near),
                Vec3(right, y, far), Vec3(left, y, far),
                Vec2(u0, v0), Vec2(u1, v0), Vec2(u1, v1), Vec2(u0, v1),
                shade, shade, shade, shade);
        }
        return output;
    }
}

unittest
{
    auto world = new World();
    auto renderer = new EntityShadowRenderer(world);
    const player = EntityShadowStyle.fromFootprint(0.6f, 0.6f);
    assert(player.radius == 0.5f);

    // Ground one full block below the entity is still inside Java's scan.
    const lowerLedge = renderer.build(Vec3(3.5f, 2.0f, 3.5f), player,
        Vec3(3.5f, 2.0f, 3.5f));
    assert(lowerLedge.length != 0);
    foreach (vertex; lowerLedge)
        assert(vertex.position[1] == 1.0f + EntityShadowRenderer.surfaceOffset);

    // Once the lower scan row no longer reaches that surface, the decal ends.
    assert(renderer.build(Vec3(3.5f, 2.6f, 3.5f), player,
        Vec3(3.5f, 2.6f, 3.5f)).length == 0);
    assert(renderer.build(Vec3(3.5f, 1.0f, 3.5f), player,
        Vec3(19.5f, 1.0f, 3.5f)).length == 0);
}
