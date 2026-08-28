module minecraftd.client.render.camera;

import core.stdc.math : sinf, cosf, fabsf, powf;
import minecraftd.common.math3d : Vec3, Mat4, PI, DEG_TO_RAD, lookToLH, perspectiveFovLH, forwardFromYawPitch;
import minecraftd.game.entity.player : Player;

struct Camera
{
    enum float baseFovDegrees = 70.0f;

    Vec3 position;
    float yaw = 0.0f;
    float pitch = 0.0f;
    float fovDegrees = baseFovDegrees;

    Mat4 viewMatrix(const Player player, float partialTick, bool viewBobbing = true) const
    {
        auto view = lookToLH(position, forwardFromYawPitch(yaw, pitch), Vec3(0, 1, 0));
        return view * effectsMatrix(player, partialTick, viewBobbing);
    }

    Mat4 effectsMatrix(const Player player, float partialTick,
        bool viewBobbing = true) const
    {
        // Once dead, freeze out hurt and walking bob.  Layering their decaying
        // oscillations over the death roll was the visible camera jitter.
        if (player.health <= 0.0f)
            return deathMatrix(player,partialTick);
        return deathMatrix(player, partialTick) * hurtMatrix(player, partialTick)
            * (viewBobbing ? bobMatrix(player, partialTick) : Mat4.identity());
    }

    Mat4 deathMatrix(const Player player, float partialTick) const
    {
        if (player.health > 0.0f)
            return Mat4.identity();
        float duration = player.interpolatedDeathTime(partialTick);
        if (duration > 20.0f) duration = 20.0f;
        // GameRenderer.bobHurt: 40 - 8000 / (deathTime + 200).
        const degrees = 40.0f - 8000.0f / (duration + 200.0f);
        return Mat4.rotationZ(degrees * DEG_TO_RAD);
    }

    float deathFov(const Player player, float partialTick) const
    {
        if (player.health > 0.0f)
            return fovDegrees;
        float duration = player.interpolatedDeathTime(partialTick);
        if (duration > 20.0f) duration = 20.0f;
        return fovDegrees / ((1.0f - 500.0f / (duration + 500.0f))
            * 2.0f + 1.0f);
    }

    Mat4 hurtMatrix(const Player player, float partialTick) const
    {
        float remaining = cast(float) player.hurtTime - partialTick;
        if (remaining < 0.0f || player.maxHurtTime <= 0)
            return Mat4.identity();
        float amount = remaining / cast(float) player.maxHurtTime;
        amount = sinf(powf(amount, 4.0f) * PI);
        const direction = player.hurtDirection * DEG_TO_RAD;
        return Mat4.rotationY(-direction)
            * Mat4.rotationZ(-amount * 14.0f * DEG_TO_RAD)
            * Mat4.rotationY(direction);
    }

    Mat4 bobMatrix(const Player player, float partialTick) const
    {
        // Modern GameRenderer keeps this transform active in the air while
        // Player.bob eases toward zero. Disabling it outright causes a snap.
        const walk = player.interpolatedWalkDistance(partialTick);
        const bob = player.interpolatedBob(partialTick);
        const phase = walk * PI;
        const translation = Mat4.translation(Vec3(
            sinf(phase) * bob * 0.5f,
            -fabsf(cosf(phase) * bob),
            0.0f,
        ));
        const roll = Mat4.rotationZ(sinf(phase) * bob * 3.0f * DEG_TO_RAD);
        const nod = Mat4.rotationX(fabsf(cosf(phase - 0.2f) * bob) * 5.0f * DEG_TO_RAD);
        // The final X rotation restores the velocity-driven fall response
        // used by legacy Java's setupViewBobbing for both camera and hand.
        const fall = Mat4.rotationX(
            player.interpolatedFallCameraPitch(partialTick) * DEG_TO_RAD);
        return translation * roll * nod * fall;
    }

    Mat4 projectionMatrix(float aspect) const
    {
        return perspectiveFovLH(fovDegrees * DEG_TO_RAD, aspect, 0.05f, 512.0f);
    }

    /// Held items use their own fixed projection, matching Java Edition's
    /// separate hand render pass instead of inheriting the sprinting FOV.
    Mat4 viewModelProjectionMatrix(float aspect) const
    {
        return perspectiveFovLH(baseFovDegrees * DEG_TO_RAD,
            aspect, 0.05f, 512.0f);
    }
}
