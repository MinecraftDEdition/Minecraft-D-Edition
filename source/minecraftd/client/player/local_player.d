module minecraftd.client.player.local_player;

import core.stdc.math : atan2f, fabsf, floorf, sinf, cosf, sqrtf;
import minecraftd.common.aabb : Aabb;
import minecraftd.common.math3d : Vec3, DEG_TO_RAD, clamp;
import minecraftd.game.entity.player : Player;
import minecraftd.world.world : World;
import minecraftd.world.block : BlockId, fallDamageMultiplier;
import minecraftd.world.world_settings : GameMode;

final class LocalPlayer : Player
{
    enum float walkSpeed = 4.317f;
    enum float sprintSpeed = 5.612f;

    this()
    {
        // Entity position is the center of the feet. The y=0 ground blocks
        // have a top surface at y=1, so this is exactly on the ground.
        position = Vec3(8.0f, 1.0f, 3.0f);
        previousPosition = position;
        yaw = 0.0f;
        bodyYaw = yaw;
        previousBodyYaw = bodyYaw;
        pitch = 20.0f;
        smoothedViewYaw = previousSmoothedViewYaw = yaw;
        smoothedViewPitch = previousSmoothedViewPitch = pitch;
        onGround = true;
    }

    void simulateTick(World world, bool forward, bool back, bool left, bool right,
        bool jumping, bool crouchRequested, bool sprinting,
        bool authoritativeDamage = false)
    {
        beginTick();
        previousVisualCorrection = visualCorrection;
        visualCorrection = visualCorrection * 0.6f;
        if (visualCorrection.lengthSquared() < 0.000001f)
            visualCorrection = Vec3.init;
        const wasOnGround = onGround;
        const wasInWater = inWater;
        stepSoundDue = false;
        waterEntryDue = waterExitDue = swimSoundDue = drowningDamageDue = false;
        previousBodyYaw = bodyYaw;
        previousSmoothedViewYaw = smoothedViewYaw;
        previousSmoothedViewPitch = smoothedViewPitch;
        smoothedViewYaw += Player.wrapDegrees(yaw - smoothedViewYaw) * 0.5f;
        smoothedViewPitch += (pitch - smoothedViewPitch) * 0.5f;

        // A player may always enter the smaller crouching pose, but may only
        // stand when the full 1.8-block box is clear.
        if (crouchRequested)
            crouching = true;
        else if (crouching && world.isUnobstructed(standingBoundingBox()))
            crouching = false;

        float forwardAxis = (forward ? 1.0f : 0.0f) - (back ? 1.0f : 0.0f);
        float strafeAxis = (right ? 1.0f : 0.0f) - (left ? 1.0f : 0.0f);
        const magnitude = sqrtf(forwardAxis * forwardAxis + strafeAxis * strafeAxis);
        if (magnitude > 1.0f)
        {
            forwardAxis /= magnitude;
            strafeAxis /= magnitude;
        }

        const yawRadians = yaw * DEG_TO_RAD;
        const flightActive = gameMode == GameMode.spectator
            || (gameMode == GameMode.creative && flying);
        eyeInWater = world.isPointInWater(eyePosition(1.0f));
        inWater = world.intersectsWater(boundingBox());
        const speed = flightActive ? (sprinting ? 21.84f : 10.92f)
            : (crouching ? walkSpeed * 0.3f
            : (sprinting ? sprintSpeed : walkSpeed));
        // Java survival sprinting requires more than six food points.
        this.sprinting = sprinting && !crouching && magnitude > 0.0f
            && (gameMode == GameMode.creative || gameMode == GameMode.spectator
                || foodLevel > 6);
        swimming = !flightActive && this.sprinting && eyeInWater;
        Vec3 desired = Vec3(
            (sinf(yawRadians) * forwardAxis + cosf(yawRadians) * strafeAxis) * speed,
            0.0f,
            (cosf(yawRadians) * forwardAxis - sinf(yawRadians) * strafeAxis) * speed,
        );

        // Smooth velocity so starts/stops feed naturally into limb and camera animation.
        if(inWater && !flightActive)
        {
            // travelInWater uses 0.02 block/tick input acceleration. This
            // simulation stores blocks/second, hence 0.4 here.
            const input=Vec3(sinf(yawRadians)*forwardAxis+cosf(yawRadians)*strafeAxis,
                0,cosf(yawRadians)*forwardAxis-sinf(yawRadians)*strafeAxis);
            velocity.x+=input.x*0.4f;
            velocity.z+=input.z*0.4f;
            velocity+=world.waterFlowAt(position+Vec3(0,0.4f,0))*0.28f;
        }
        else
        {
            const horizontalControl = flightActive ? 0.35f
                : (onGround ? 0.45f : 0.08f);
            velocity.x += (desired.x - velocity.x) * horizontalControl;
            velocity.z += (desired.z - velocity.z) * horizontalControl;
        }

        // Java's jump impulse is 0.42 blocks/tick. Velocity here is stored in
        // blocks/second, so multiply by the fixed 20 Hz tick rate.
        if (flightActive)
        {
            const vertical = (jumping ? 1.0f : 0.0f)
                - (crouchRequested ? 1.0f : 0.0f);
            velocity.y += (vertical * 7.64f - velocity.y) * 0.35f;
            onGround = false;
            fallDistance = 0.0f;
        }
        else if(inWater)
        {
            if(jumping)velocity.y+=0.8f;
            if(crouchRequested)velocity.y-=0.8f;
            onGround=false;
            fallDistance=0.0f;
        }
        else if (jumping && onGround)
        {
            velocity.y = 8.4f;
            onGround = false;
            addExhaustion(this.sprinting ? 0.2f : 0.05f);
        }

        Vec3 requestedMovement = velocity * 0.05f;
        if (onGround && velocity.y <= 0.0f)
            requestedMovement.y = -0.01f; // support probe; also detects ledges

        // Java's maybeBackOffFromEdge trims voluntary horizontal movement in
        // small increments while sneaking until some part of the player's
        // footprint remains supported. Jumping has already cleared onGround,
        // so crouch-jumps leave the ledge normally.
        if (crouching && onGround)
            requestedMovement = backOffFromEdge(world, boundingBox(),
                requestedMovement);

        const collision = gameMode == GameMode.spectator
            ? typeof(world.collide(boundingBox(), requestedMovement))(
                requestedMovement, false, false, false)
            : world.collide(boundingBox(), requestedMovement);
        position += collision.movement;
        horizontalCollision = collision.hitX || collision.hitZ;

        if (!inWater && !wasOnGround && collision.movement.y < 0.0f)
            fallDistance -= collision.movement.y;

        if (collision.hitX) velocity.x = 0.0f;
        if (collision.hitZ) velocity.z = 0.0f;
        if (collision.hitY) velocity.y = 0.0f;
        onGround = collision.hitY && requestedMovement.y < 0.0f;

        if (onGround && !wasOnGround)
        {
            const ground = world.getBlock(
                cast(int) floorf(position.x),
                cast(int) floorf(position.y - 0.05f),
                cast(int) floorf(position.z));
            lastLandedFallDistance = fallDistance;
            landingParticlesDue = fallDistance > 3.0f;
            const damage = fallDamage(fallDistance, fallDamageMultiplier(ground));
            if (authoritativeDamage && damage > 0)
            {
                takeDamage(cast(float) damage);
                fallSoundDue = damage > 4 ? 2 : 1;
            }
            fallDistance = 0.0f;
        }

        if(inWater && !flightActive)
        {
            const drag=this.sprinting?0.9f:0.8f;
            velocity.x*=drag;
            velocity.z*=drag;
            velocity.y=velocity.y*0.8f-0.1f;
        }
        else if (!onGround && !flightActive)
        {
            // Java gravity is -0.08 blocks/tick followed by 0.98 drag.
            velocity.y = (velocity.y - 1.6f) * 0.98f;
        }

        const dx = position.x - previousPosition.x;
        const dz = position.z - previousPosition.z;
        const horizontalDistance = sqrtf(dx * dx + dz * dz);
        updateAnimationState(horizontalDistance, onGround, velocity.y * 0.05f);
        if (onGround && !inWater
            && floorf(walkDistance) > floorf(previousWalkDistance))
            stepSoundDue = true;
        if(inWater && horizontalDistance>0.01f
            && floorf(walkDistance*4.0f)>floorf(previousWalkDistance*4.0f))
            swimSoundDue=true;
        if (this.sprinting && horizontalDistance > 0.0f)
            addExhaustion(horizontalDistance * 0.1f);

        // Body rotation follows the input pose rather than blindly facing the
        // displacement vector. Backward input mirrors its forward counterpart:
        // S keeps the chest forward and S+A has the same chest direction as W+D.
        if (magnitude > 0.0001f)
        {
            float poseForward = forwardAxis;
            float poseStrafe = strafeAxis;
            if (poseForward < 0.0f)
            {
                poseForward = -poseForward;
                poseStrafe = -poseStrafe;
            }
            const poseX = sinf(yawRadians) * poseForward
                + cosf(yawRadians) * poseStrafe;
            const poseZ = cosf(yawRadians) * poseForward
                - sinf(yawRadians) * poseStrafe;
            const poseYaw = atan2f(poseX, poseZ) / DEG_TO_RAD;
            // Java's body rotation eases toward the movement pose.  Limiting
            // an entire 35 degrees every tick made diagonal changes look like
            // a mechanical snap, especially across the forward/back mirror.
            const turn = Player.wrapDegrees(poseYaw - bodyYaw);
            const movementBlend = clamp(horizontalDistance * 8.0f,0.12f,0.45f);
            bodyYaw += turn * movementBlend;
        }
        else
        {
            constrainHeadToNeck();
        }

        previousAttackProgress = attackProgress;
        if (attacking)
        {
            // Java's normal arm swing lasts six game ticks.
            attackProgress += 1.0f / 6.0f;
            if (attackProgress >= 1.0f)
            {
                // Both endpoints have the neutral pose. Holding 1 for the
                // final tick lets render interpolation reach it smoothly.
                attackProgress = 1.0f;
                attacking = false;
            }
        }
        else
        {
            attackProgress = 0.0f;
            previousAttackProgress = 0.0f;
        }
        inWater=world.intersectsWater(boundingBox());
        eyeInWater=world.isPointInWater(eyePosition(1.0f));
        swimming=!flightActive && this.sprinting && eyeInWater;
        waterEntryDue=!wasInWater&&inWater;
        waterExitDue=wasInWater&&!inWater;
        if(inWater)fallDistance=0.0f;
        if(gameMode==GameMode.creative||gameMode==GameMode.spectator)
            airSupply=Player.maximumAirSupply;
        else if(eyeInWater)
        {
            --airSupply;
            if(airSupply<=-20)
            {
                airSupply=0;
                if(authoritativeDamage)
                {
                    takeDamage(2.0f);
                    drowningDamageDue=true;
                }
            }
        }
        else if(airSupply<Player.maximumAirSupply)
        {
            airSupply+=4;
            if(airSupply>Player.maximumAirSupply)
                airSupply=Player.maximumAirSupply;
        }
        tickSurvival();
    }

    bool shouldAutoJump(World world, bool forward, bool back, bool left,
        bool right) const
    {
        if (!onGround || crouching || flying
            || gameMode == GameMode.spectator)
            return false;
        float forwardAxis=(forward?1.0f:0.0f)-(back?1.0f:0.0f);
        float strafeAxis=(right?1.0f:0.0f)-(left?1.0f:0.0f);
        const magnitude=sqrtf(forwardAxis*forwardAxis+strafeAxis*strafeAxis);
        if(magnitude<0.0001f)return false;
        forwardAxis/=magnitude; strafeAxis/=magnitude;
        const yawRadians=yaw*DEG_TO_RAD;
        const probe=Vec3(
            (sinf(yawRadians)*forwardAxis+cosf(yawRadians)*strafeAxis)*0.35f,
            0,
            (cosf(yawRadians)*forwardAxis-sinf(yawRadians)*strafeAxis)*0.35f);
        const blocked=world.collide(boundingBox(),probe);
        if(!blocked.hitX&&!blocked.hitZ)return false;
        // A one-block step is eligible only when the player's raised body and
        // its short forward path are both clear.
        const raised=boundingBox().moved(Vec3(0,1.001f,0));
        if(!world.isUnobstructed(raised))return false;
        const above=world.collide(raised,probe);
        return !above.hitX&&!above.hitZ;
    }

    void toggleFlight()
    {
        if (gameMode == GameMode.creative)
        {
            flying = !flying;
            if (!flying) velocity.y = 0.0f;
        }
        else if (gameMode == GameMode.spectator)
            flying = true;
    }

    void look(float deltaX, float deltaY)
    {
        yaw += deltaX * 0.12f;
        pitch = clamp(pitch + deltaY * 0.12f, -89.9f, 89.9f);
        constrainHeadToNeck();
    }

    void attack(bool restart = false)
    {
        // LivingEntity.swing only restarts a running six-tick swing once it has
        // reached its halfway point. Mining calls this every tick, producing
        // Java's rapid repeated arc without pinning the arm to frame zero.
        if (!attacking || (restart && attackProgress >= 0.5f))
        {
            attacking = true;
            attackProgress = 0.0f;
            previousAttackProgress = 0.0f;
        }
    }

private:
    static Vec3 backOffFromEdge(World world, Aabb bounds, Vec3 movement)
    {
        enum float edgeStep = 0.05f;
        enum float supportDepth = 0.6f;
        float x = movement.x;
        float z = movement.z;

        bool supported(float offsetX, float offsetZ)
        {
            const probe = bounds.moved(Vec3(offsetX, 0.0f, offsetZ));
            return world.collide(probe, Vec3(0.0f, -supportDepth, 0.0f)).hitY;
        }
        float towardZero(float value)
        {
            if (fabsf(value) <= edgeStep)
                return 0.0f;
            return value + (value > 0.0f ? -edgeStep : edgeStep);
        }

        while (x != 0.0f && !supported(x, 0.0f))
            x = towardZero(x);
        while (z != 0.0f && !supported(0.0f, z))
            z = towardZero(z);
        while (x != 0.0f && z != 0.0f && !supported(x, z))
        {
            x = towardZero(x);
            z = towardZero(z);
        }
        return Vec3(x, movement.y, z);
    }

    void constrainHeadToNeck()
    {
        const difference = Player.wrapDegrees(yaw - bodyYaw);
        if (difference > 50.0f)
            bodyYaw += (difference - 50.0f) * 0.35f;
        else if (difference < -50.0f)
            bodyYaw += (difference + 50.0f) * 0.35f;
    }
}

unittest
{
    auto player = new LocalPlayer();
    player.attacking = true;
    player.attackProgress = 0.49f;
    player.attack(true);
    assert(player.attackProgress == 0.49f);
    player.attackProgress = 0.5f;
    player.attack(true);
    assert(player.attackProgress == 0.0f);
}

unittest
{
    // Java: (0 - 0.08) * 0.98 = -0.0784 blocks/tick.  LocalPlayer stores
    // blocks/second, hence the equivalent -1.568 value after one tick.
    const velocityAfterFirstFallTick = (0.0f - 1.6f) * 0.98f;
    assert(velocityAfterFirstFallTick > -1.5681f
        && velocityAfterFirstFallTick < -1.5679f);
}

unittest
{
    auto world = new World();
    scope (exit) destroy(world);

    auto crouchJumper = new LocalPlayer();
    scope (exit) destroy(crouchJumper);
    crouchJumper.simulateTick(world, false, false, false, false,
        true, true, false);
    assert(crouchJumper.crouching && crouchJumper.position.y > 1.0f
        && !crouchJumper.onGround);

    foreach (x; 7 .. 10)
    foreach (z; 4 .. 7)
        world.setBlock(x, 0, z, BlockId.air);
    auto edging = new LocalPlayer();
    scope (exit) destroy(edging);
    foreach (_; 0 .. 80)
        edging.simulateTick(world, true, false, false, false,
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
}

unittest
{
    auto waterWorld=new World();
    scope(exit)destroy(waterWorld);
    foreach(z;18..23)foreach(x;18..23)
    {
        waterWorld.setBlock(x,0,z,BlockId.stone);
        foreach(y;1..5)waterWorld.setBlock(x,y,z,BlockId.waterSource);
    }
    auto swimmer=new LocalPlayer();
    scope(exit)destroy(swimmer);
    swimmer.position=swimmer.previousPosition=Vec3(20.5f,1.0f,20.5f);
    swimmer.onGround=false;
    foreach(_;0..Player.maximumAirSupply)
        swimmer.simulateTick(waterWorld,false,false,false,false,false,false,
            false,true);
    assert(swimmer.eyeInWater&&swimmer.airSupply==0&&swimmer.health==20.0f);
    foreach(_;0..20)
        swimmer.simulateTick(waterWorld,false,false,false,false,false,false,
            false,true);
    assert(swimmer.health==18.0f&&swimmer.airSupply==0
        &&swimmer.drowningDamageDue);
}
