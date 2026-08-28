module collision_test;

import core.stdc.math : fabsf;
import std.stdio : writeln;

import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.client.render.camera : Camera;
import minecraftd.common.aabb : Aabb;
import minecraftd.common.math3d : Vec3, forwardFromYawPitch;
import minecraftd.world.block : BlockId, soundType;
import minecraftd.world.world : World;

private void requireNear(float actual, float expected, string message)
{
    if (fabsf(actual - expected) > 0.0001f)
        throw new Exception(message);
}

void main()
{
    auto world = new World();
    scope (exit) destroy(world);

    // The standing box rests on top of y=0 ground without sinking.
    const grounded = Aabb(7.7f, 1.0f, 2.7f, 8.3f, 2.8f, 3.3f);
    const groundHit = world.collide(grounded, Vec3(0, -0.25f, 0));
    requireNear(groundHit.movement.y, 0.0f, "ground collision moved below y=1");
    assert(groundHit.hitY);

    // The stone platform begins at x=5 and clips a 0.6-wide player exactly.
    const besideWall = Aabb(4.3f, 1.0f, 6.2f, 4.9f, 2.8f, 6.8f);
    const wallHit = world.collide(besideWall, Vec3(0.5f, 0, 0));
    requireNear(wallHit.movement.x, 0.1f, "wall collision did not stop at x=5");
    assert(wallHit.hitX);

    // A held jump must leave the floor, peak, and return to the same feet Y.
    auto player = new LocalPlayer();
    scope (exit) destroy(player);
    player.simulateTick(world, false, false, false, false, true, false, false);
    assert(player.position.y > 1.4f);
    assert(!player.onGround);
    foreach (_; 0 .. 80)
        player.simulateTick(world, false, false, false, false, false, false, false);
    requireNear(player.position.y, 1.0f, "jump did not land on the ground surface");
    assert(player.onGround);

    // Sneaking changes the pose and speed, but it must not suppress a jump.
    auto crouchJumper = new LocalPlayer();
    scope (exit) destroy(crouchJumper);
    crouchJumper.simulateTick(world, false, false, false, false,
        true, true, false);
    assert(crouchJumper.crouching && crouchJumper.position.y > 1.0f
        && !crouchJumper.onGround);

    // Voluntary crouch movement backs away from an unsupported edge while a
    // normal jump can still intentionally leave it.
    auto edgeWorld = new World();
    scope (exit) destroy(edgeWorld);
    foreach (x; 7 .. 10)
    foreach (z; 4 .. 7)
        edgeWorld.setBlock(x, 0, z, BlockId.air);
    auto edging = new LocalPlayer();
    scope (exit) destroy(edging);
    foreach (_; 0 .. 80)
        edging.simulateTick(edgeWorld, true, false, false, false,
            false, true, false);
    assert(edging.onGround && edging.position.y == 1.0f
        && edging.position.z < 4.31f);

    auto landing = new LocalPlayer();
    scope (exit) destroy(landing);
    landing.position = landing.previousPosition = Vec3(8.0f, 6.0f, 3.0f);
    landing.onGround = false;
    foreach (_; 0 .. 100)
    {
        landing.simulateTick(world, false, false, false, false,
            false, false, false);
        if (landing.onGround) break;
    }
    assert(landing.onGround && landing.landingParticlesDue
        && landing.lastLandedFallDistance > 3.0f);

    // Walking straight into the platform must stop with the player's front
    // face at z=6 (center z=5.7 for a 0.6-wide box), even over many ticks.
    foreach (_; 0 .. 100)
        player.simulateTick(world, true, false, false, false, false, false, false);
    requireNear(player.position.z, 5.7f, "sustained movement penetrated the stone wall");

    // The neck may turn freely to 50 degrees; excess yaw rotates the torso.
    auto posed = new LocalPlayer();
    scope (exit) destroy(posed);
    posed.look(300.0f, 0); // 36 degrees
    requireNear(posed.bodyYaw, 0.0f, "torso moved before the neck threshold");
    requireNear(posed.headYawOffset(1.0f), 36.0f, "head did not use its free neck range");
    posed.look(200.0f, 0); // total 60 degrees
    // The current softened body follow closes 35% of the excess per update,
    // avoiding the old robotic ten-degree snap.
    requireNear(posed.bodyYaw, 3.5f, "torso did not ease beyond 50 degrees");
    requireNear(posed.headYawOffset(1.0f), 50.0f,
        "rendered neck exceeded its clamped range");

    // Render-time interpolation must fill the space between 20 Hz attack
    // updates; otherwise the view-model hand visibly jumps six times per hit.
    auto animated = new LocalPlayer();
    scope (exit) destroy(animated);
    animated.attack();
    animated.simulateTick(world, false, false, false, false, false, false, false);
    requireNear(animated.interpolatedAttackProgress(0.5f), 1.0f / 12.0f,
        "attack animation was not interpolated between ticks");

    // Strafing turns the rendered torso toward actual travel rather than
    // leaving it permanently welded to camera yaw.
    auto strafing = new LocalPlayer();
    scope (exit) destroy(strafing);
    strafing.simulateTick(world, false, false, false, true, false, false, false);
    requireNear(strafing.bodyYaw, 40.5f,
        "moving torso did not begin turning toward travel direction");

    // Backward poses mirror their forward counterparts instead of turning the
    // whole remote model around and snapping it back toward the camera.
    auto backward = new LocalPlayer();
    scope (exit) destroy(backward);
    backward.simulateTick(world, false, true, false, false,
        false, false, false);
    requireNear(backward.bodyYaw, 0.0f,
        "plain backward movement rotated the torso away from forward");
    auto backwardDiagonal = new LocalPlayer();
    scope (exit) destroy(backwardDiagonal);
    backwardDiagonal.simulateTick(world, false, true, true, false,
        false, false, false);
    requireNear(backwardDiagonal.bodyYaw, 20.25f,
        "S+A did not mirror the W+D torso pose");

    auto swaying = new LocalPlayer();
    scope (exit) destroy(swaying);
    swaying.look(100.0f, 50.0f); // live view changes immediately
    swaying.simulateTick(world, false, false, false, false, false, false, false);
    assert(swaying.viewYawSway(1.0f) > 0.0f);
    assert(swaying.viewYawSway(1.0f) < 12.0f);
    assert(swaying.viewPitchSway(1.0f) > 0.0f);

    // Airborne travel eases the existing bob instead of snapping the camera
    // transform to identity on the first jump frame.
    posed.onGround = false;
    posed.cameraBob = posed.previousCameraBob = 0.1f;
    Camera camera;
    const airborneBob = camera.bobMatrix(posed, 0.5f);
    bool retainedAirborneBob;
    foreach (index, value; airborneBob.m)
        if (fabsf(value - (index % 5 == 0 ? 1.0f : 0.0f)) > 0.0001f)
            retainedAirborneBob = true;
    assert(retainedAirborneBob);

    // A front-facing third-person camera cannot pass through the platform.
    const clippedCamera = world.clipCamera(Vec3(8,1.5f,3), Vec3(8,1.5f,8));
    requireNear(clippedCamera.z, 5.9f, "third-person camera entered a solid block");

    // First-person interaction reaches the same stone block visible beneath
    // the initial crosshair and never selects air along the ray.
    const selected = world.rayCast(Vec3(8.0f, 2.62f, 3.0f),
        forwardFromYawPitch(0.0f, 20.0f), 5.0f);
    assert(selected.hit && selected.block == BlockId.stone);
    assert(selected.x == 8 && selected.y == 1 && selected.z == 6);

    assert(soundType(BlockId.grass).family == "grass");
    assert(soundType(BlockId.dirt).family == "gravel");
    assert(soundType(BlockId.stone).family == "stone");

    writeln("collision tests passed");
}
