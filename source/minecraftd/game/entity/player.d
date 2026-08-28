module minecraftd.game.entity.player;

import core.stdc.math : atanf, ceilf, fabsf, sqrtf;
import minecraftd.common.aabb : Aabb;
import minecraftd.common.math3d : Vec3, clamp, lerp;
import minecraftd.game.entity.entity : Entity;
import minecraftd.game.item.inventory : Inventory;
import minecraftd.world.world_settings : DimensionId, GameMode;

class Player : Entity
{
    enum ubyte skinHat = 1 << 0;
    enum ubyte skinJacket = 1 << 1;
    enum ubyte skinRightSleeve = 1 << 2;
    enum ubyte skinLeftSleeve = 1 << 3;
    enum ubyte skinRightPants = 1 << 4;
    enum ubyte skinLeftPants = 1 << 5;
    enum float width = 0.6f;
    enum float standingHeight = 1.8f;
    enum float standingEyeHeight = 1.62f;
    enum float crouchingHeight = 1.5f;
    enum float crouchingEyeHeight = 1.27f;
    enum float swimmingHeight = 0.6f;
    enum float swimmingEyeHeight = 0.4f;
    enum int maximumAirSupply = 300;

    float walkDistance = 0.0f;
    float previousWalkDistance = 0.0f;
    float walkAnimationPosition = 0.0f;
    float previousWalkAnimationPosition = 0.0f;
    float walkAnimationSpeed = 0.0f;
    float previousWalkAnimationSpeed = 0.0f;
    float cameraBob = 0.0f;
    float previousCameraBob = 0.0f;
    float fallCameraPitch = 0.0f;
    float previousFallCameraPitch = 0.0f;
    float attackProgress = 0.0f;
    float previousAttackProgress = 0.0f;
    float smoothedViewYaw = 0.0f;
    float previousSmoothedViewYaw = 0.0f;
    float smoothedViewPitch = 0.0f;
    float previousSmoothedViewPitch = 0.0f;
    float bodyYaw = 0.0f;
    float previousBodyYaw = 0.0f;
    // Client prediction keeps physics authoritative while this short-lived
    // offset makes an occasional reconciliation correction visually smooth.
    Vec3 visualCorrection;
    Vec3 previousVisualCorrection;
    bool attacking;
    bool crouching;
    bool sprinting;
    bool horizontalCollision;
    bool stepSoundDue;
    bool onGround;
    GameMode gameMode = GameMode.survival;
    bool hardcore;
    bool flying;
    ubyte skinParts = 0x3F;
    bool mainHandRight = true;
    DimensionId dimension = DimensionId.overworld;
    float portalProgress;
    bool inWater;
    bool eyeInWater;
    bool swimming;
    int airSupply = maximumAirSupply;
    bool waterEntryDue;
    bool waterExitDue;
    bool swimSoundDue;
    bool drowningDamageDue;

    // Survival state uses Java's half-heart/food scale (20 = ten icons).
    float health = 20.0f;
    float previousDisplayedHealth = 20.0f;
    int foodLevel = 20;
    float saturationLevel = 5.0f;
    float exhaustionLevel = 0.0f;
    int totalExperience;
    int experienceLevel;
    float experienceProgress = 0.0f;
    int foodTickTimer;
    int survivalTicks;
    int selectedSlot;
    Inventory inventory;
    float fallDistance = 0.0f;
    float lastLandedFallDistance = 0.0f;
    bool landingParticlesDue;
    int deathTime;

    // Client-side transition state shared by the camera and HUD.
    float fovModifier = 1.0f;
    float previousFovModifier = 1.0f;
    int hurtTime;
    int maxHurtTime = 10;
    float hurtDirection;
    int damageFlashTicks;
    int hungerJiggleTicks;
    bool hurtSoundDue;
    ubyte fallSoundDue; // 0 none, 1 small, 2 big

    float height() const
    {
        return swimming ? swimmingHeight
            : (crouching ? crouchingHeight : standingHeight);
    }

    float eyeHeight() const
    {
        return swimming ? swimmingEyeHeight
            : (crouching ? crouchingEyeHeight : standingEyeHeight);
    }

    Aabb boundingBox() const
    {
        const halfWidth = width * 0.5f;
        return Aabb(
            position.x - halfWidth, position.y, position.z - halfWidth,
            position.x + halfWidth, position.y + height(), position.z + halfWidth,
        );
    }

    Aabb standingBoundingBox() const
    {
        const halfWidth = width * 0.5f;
        return Aabb(
            position.x - halfWidth, position.y, position.z - halfWidth,
            position.x + halfWidth, position.y + standingHeight, position.z + halfWidth,
        );
    }

    void updateAnimationState(float horizontalDistancePerTick, bool grounded,
        float verticalVelocityPerTick)
    {
        previousWalkDistance = walkDistance;
        walkDistance += horizontalDistancePerTick * 0.6f;

        previousWalkAnimationSpeed = walkAnimationSpeed;
        previousWalkAnimationPosition = walkAnimationPosition;
        // LivingEntity advances walk animation from horizontal displacement
        // even while airborne. Keep a mild legacy-style air slowdown without
        // freezing the player's arms and legs during a jump.
        const animationDistance = horizontalDistancePerTick
            * (grounded ? 1.0f : 0.8f);
        const targetWalkSpeed = clamp(animationDistance * 4.0f, 0.0f, 1.0f);
        walkAnimationSpeed += (targetWalkSpeed - walkAnimationSpeed) * 0.4f;
        walkAnimationPosition += walkAnimationSpeed;

        previousCameraBob = cameraBob;
        const targetBob = grounded
            ? clamp(horizontalDistancePerTick, 0.0f, 0.1f)
            : 0.0f;
        cameraBob += (targetBob - cameraBob) * 0.4f;

        previousFallCameraPitch = fallCameraPitch;
        // Legacy Java cameraPitch: atan(-motionY * 0.2) * 15, eased at 0.8.
        // motionY there is blocks/tick rather than our blocks/second value.
        const targetFallPitch = grounded ? 0.0f
            : atanf(-verticalVelocityPerTick * 0.2f) * 15.0f;
        fallCameraPitch += (targetFallPitch - fallCameraPitch) * 0.8f;
    }

    float interpolatedWalkDistance(float partialTick) const
    {
        return -lerp(partialTick, previousWalkDistance, walkDistance);
    }

    float interpolatedBob(float partialTick) const
    {
        return lerp(partialTick, previousCameraBob, cameraBob);
    }

    float interpolatedFallCameraPitch(float partialTick) const
    {
        return lerp(partialTick, previousFallCameraPitch, fallCameraPitch);
    }

    float interpolatedWalkAnimationPosition(float partialTick) const
    {
        return lerp(partialTick, previousWalkAnimationPosition, walkAnimationPosition);
    }

    float interpolatedWalkAnimationSpeed(float partialTick) const
    {
        return lerp(partialTick, previousWalkAnimationSpeed, walkAnimationSpeed);
    }

    float interpolatedAttackProgress(float partialTick) const
    {
        return lerp(partialTick, previousAttackProgress, attackProgress);
    }

    float interpolatedDeathTime(float partialTick) const
    {
        if (deathTime <= 0)
            return 0.0f;
        const previous = deathTime > 0 ? deathTime - 1 : 0;
        return lerp(partialTick, cast(float)previous, cast(float)deathTime);
    }

    float viewYawSway(float partialTick) const
    {
        const smoothed = previousSmoothedViewYaw
            + wrapDegrees(smoothedViewYaw - previousSmoothedViewYaw) * partialTick;
        return wrapDegrees(yaw - smoothed);
    }

    float viewPitchSway(float partialTick) const
    {
        return pitch - lerp(partialTick, previousSmoothedViewPitch, smoothedViewPitch);
    }

    Vec3 eyePosition(float partialTick) const
    {
        return Vec3(
            lerp(partialTick, previousPosition.x, position.x),
            lerp(partialTick, previousPosition.y, position.y) + eyeHeight(),
            lerp(partialTick, previousPosition.z, position.z),
        );
    }

    Vec3 interpolatedEyePosition(float partialTick) const
    {
        return interpolatedPosition(partialTick) + Vec3(0.0f, eyeHeight(), 0.0f);
    }

    Vec3 interpolatedPosition(float partialTick) const
    {
        const correction = previousVisualCorrection
            + (visualCorrection - previousVisualCorrection) * partialTick;
        return Vec3(
            lerp(partialTick, previousPosition.x, position.x),
            lerp(partialTick, previousPosition.y, position.y),
            lerp(partialTick, previousPosition.z, position.z),
        ) + correction;
    }

    float interpolatedBodyYaw(float partialTick) const
    {
        return previousBodyYaw + wrapDegrees(bodyYaw - previousBodyYaw) * partialTick;
    }

    float headYawOffset(float partialTick) const
    {
        const difference = wrapDegrees(yaw - interpolatedBodyYaw(partialTick));
        return clamp(difference, -50.0f, 50.0f);
    }

    void tickSurvival()
    {
        inventory.tick();
        ++survivalTicks;
        previousFovModifier = fovModifier;
        const targetFov = sprinting ? 1.15f : 1.0f;
        fovModifier += (targetFov - fovModifier) * 0.5f;
        fovModifier = clamp(fovModifier, 0.1f, 1.5f);

        if (hurtTime > 0) --hurtTime;
        if (damageFlashTicks > 0) --damageFlashTicks;
        if (hungerJiggleTicks > 0) --hungerJiggleTicks;

        // Dead players remain dead until the server accepts a respawn action.
        // In particular, full hunger must not regenerate them behind the death screen.
        if (health <= 0.0f)
            return;

        if (gameMode == GameMode.creative || gameMode == GameMode.spectator)
        {
            health = 20.0f;
            foodLevel = 20;
            saturationLevel = 5.0f;
            exhaustionLevel = 0.0f;
            foodTickTimer = 0;
            return;
        }

        if (exhaustionLevel > 4.0f)
        {
            exhaustionLevel -= 4.0f;
            if (saturationLevel > 0.0f)
                saturationLevel = clamp(saturationLevel - 1.0f, 0.0f, 20.0f);
            else if (foodLevel > 0)
                --foodLevel;
        }

        if (health < 20.0f && foodLevel >= 20 && saturationLevel > 0.0f)
        {
            if (++foodTickTimer >= 10)
            {
                const amount = saturationLevel < 6.0f ? saturationLevel : 6.0f;
                heal(amount / 6.0f);
                addExhaustion(amount);
                foodTickTimer = 0;
            }
        }
        else if (health < 20.0f && foodLevel >= 18)
        {
            if (++foodTickTimer >= 80)
            {
                heal(1.0f);
                addExhaustion(6.0f);
                foodTickTimer = 0;
            }
        }
        else
            foodTickTimer = 0;
    }

    void addExhaustion(float amount)
    {
        exhaustionLevel = clamp(exhaustionLevel + amount, 0.0f, 40.0f);
    }

    int experienceNeededForNextLevel() const
    {
        if (experienceLevel >= 30)
            return 9 * experienceLevel - 158;
        if (experienceLevel >= 15)
            return 5 * experienceLevel - 38;
        return 2 * experienceLevel + 7;
    }

    /// Adds raw experience points using Java's level-cost curve. Experience is
    /// server-owned; clients receive the resulting level and progress fraction.
    void giveExperience(int amount)
    {
        if (amount <= 0)
            return;
        totalExperience += amount;
        float points = experienceProgress * experienceNeededForNextLevel()
            + cast(float) amount;
        int required = experienceNeededForNextLevel();
        while (points >= required)
        {
            points -= required;
            ++experienceLevel;
            required = experienceNeededForNextLevel();
        }
        experienceProgress = required > 0 ? points / required : 0.0f;
    }

    void heal(float amount)
    {
        health = clamp(health + amount, 0.0f, 20.0f);
    }

    void takeDamage(float amount, float direction = 0.0f)
    {
        if (amount <= 0.0f || health <= 0.0f
            || gameMode == GameMode.creative || gameMode == GameMode.spectator)
            return;
        previousDisplayedHealth = health;
        health = clamp(health - amount, 0.0f, 20.0f);
        hurtDirection = direction;
        hurtTime = maxHurtTime;
        damageFlashTicks = 20;
        hungerJiggleTicks = 10;
        hurtSoundDue = true;
        if (health <= 0.0f)
            deathTime = 0;
    }

    void respawnAt(Vec3 spawn, GameMode mode)
    {
        position = previousPosition = spawn;
        velocity = Vec3.init;
        visualCorrection = previousVisualCorrection = Vec3.init;
        health = previousDisplayedHealth = 20.0f;
        foodLevel = 20;
        saturationLevel = 5.0f;
        exhaustionLevel = 0.0f;
        foodTickTimer = 0;
        totalExperience = 0;
        experienceLevel = 0;
        experienceProgress = 0.0f;
        fallDistance = lastLandedFallDistance = 0.0f;
        landingParticlesDue = false;
        deathTime = 0;
        hurtTime = damageFlashTicks = hungerJiggleTicks = 0;
        hurtSoundDue = false;
        fallSoundDue = 0;
        crouching = sprinting = attacking = false;
        inWater=eyeInWater=swimming=false;
        airSupply=maximumAirSupply;
        waterEntryDue=waterExitDue=swimSoundDue=drowningDamageDue=false;
        attackProgress = previousAttackProgress = 0.0f;
        gameMode = mode;
        flying = mode == GameMode.spectator;
        onGround = false;
        inventory = Inventory.init;
    }

    int fallDamage(float distance, float multiplier = 1.0f) const
    {
        return cast(int) ceilf((distance - 3.0f) * multiplier) > 0
            ? cast(int) ceilf((distance - 3.0f) * multiplier) : 0;
    }

    float interpolatedFovModifier(float partialTick) const
    {
        return lerp(partialTick, previousFovModifier, fovModifier);
    }


    static float wrapDegrees(float degrees)
    {
        while (degrees > 180.0f) degrees -= 360.0f;
        while (degrees < -180.0f) degrees += 360.0f;
        return degrees;
    }
}

unittest
{
    auto player = new Player();
    player.cameraBob = 0.1f;
    player.previousCameraBob = 0.1f;
    player.updateAnimationState(0.2f, false, -0.4f);

    // Airborne travel keeps limb phase alive while bob amplitude decays.
    assert(fabsf(player.walkDistance - 0.12f) < 0.0001f);
    assert(player.walkAnimationSpeed > 0.0f);
    assert(fabsf(player.cameraBob - 0.06f) < 0.0001f);
    assert(player.fallCameraPitch > 0.0f);

    const airbornePitch = player.fallCameraPitch;
    player.updateAnimationState(0.0f, true, 0.0f);
    assert(player.cameraBob < 0.06f);
    assert(player.fallCameraPitch < airbornePitch);

    player.sprinting = true;
    player.tickSurvival();
    assert(fabsf(player.fovModifier - 1.075f) < 0.0001f);
    assert(player.fallDamage(3.0f) == 0);
    assert(player.fallDamage(4.0f) == 1);
    player.giveExperience(7);
    assert(player.experienceLevel == 1);
    assert(player.experienceProgress == 0.0f);
    player.giveExperience(5);
    assert(fabsf(player.experienceProgress - 5.0f / 9.0f) < 0.0001f);
}
