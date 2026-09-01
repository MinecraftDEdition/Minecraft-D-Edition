module minecraftd.client.render.player_renderer;

import core.stdc.math : cosf, sinf, sqrtf;
import minecraftd.client.render.mesh : Vertex, Color, appendQuad;
import minecraftd.common.math3d : Vec2, Vec3, Mat4, PI, DEG_TO_RAD,
    clamp, cross, dot;
import minecraftd.game.entity.player : Player;

struct UvRect
{
    float left = 0.0f;
    float top = 0.0f;
    float right = 0.0f;
    float bottom = 0.0f;

    Vec2 uv(float x, float y) const
    {
        return Vec2((left + (right-left)*x) / 64.0f, (top + (bottom-top)*y) / 64.0f);
    }
}

struct BoxUvs
{
    UvRect front;
    UvRect back;
    UvRect left;
    UvRect right;
    UvRect top;
    UvRect bottom;
}

/// Java Edition lets each second skin layer be enabled independently.
struct SkinLayers
{
    bool hat;
    bool jacket;
    bool rightSleeve;
    bool leftSleeve;
    bool rightPants;
    bool leftPants;

    static SkinLayers modern()
    {
        return SkinLayers(true, true, true, true, true, true);
    }

    static SkinLayers classic()
    {
        return SkinLayers(false, false, false, false, false, false);
    }

    static SkinLayers fromBits(ubyte bits)
    {
        return SkinLayers(
            (bits & Player.skinHat) != 0,
            (bits & Player.skinJacket) != 0,
            (bits & Player.skinRightSleeve) != 0,
            (bits & Player.skinLeftSleeve) != 0,
            (bits & Player.skinRightPants) != 0,
            (bits & Player.skinLeftPants) != 0);
    }
}

final class PlayerRenderer
{
    void applyDeathPose(ref Vertex[] geometry, Vec3 position,
        float bodyYawDegrees, float deathTicks) const
    {
        if (deathTicks <= 0.0f)
            return;
        float fall = (deathTicks - 1.0f) / 20.0f * 1.6f;
        if (fall < 0.0f) fall = 0.0f;
        fall = sqrtf(fall);
        if (fall > 1.0f) fall = 1.0f;

        // LivingEntityRenderer reaches 90 degrees with the vanilla sqrt ease.
        // The negative local-Z rotation puts the model on its left side.
        const yaw = bodyYawDegrees * DEG_TO_RAD;
        const transform = Mat4.translation(position * -1.0f)
            * Mat4.rotationY(-yaw)
            * Mat4.rotationZ(-fall * 90.0f * DEG_TO_RAD)
            * Mat4.rotationY(yaw)
            * Mat4.translation(position);
        foreach (ref vertex; geometry)
        {
            const transformed = transform.transformPoint(Vec3(
                vertex.position[0],vertex.position[1],vertex.position[2]));
            vertex.position = [transformed.x,transformed.y,transformed.z];
        }
    }

    Vertex[] buildSpectatorHead(Vec3 position, float bodyYawDegrees,
        float headYawDegrees, float headPitchDegrees)
    {
        Vertex[] result;
        const yaw = bodyYawDegrees * DEG_TO_RAD;
        const center = Vec3(0,1.75f,0);
        const pivot = Vec3(0,1.5f,0);
        const rotation = Vec3(-headPitchDegrees * DEG_TO_RAD,
            headYawDegrees * DEG_TO_RAD,0);
        addPart(result,position,yaw,center,Vec3(.5f,.5f,.5f),pivot,
            rotation,headUvs());
        addPart(result,position,yaw,center,expanded(Vec3(.5f,.5f,.5f),.0625f),
            pivot,rotation,hatUvs());
        foreach (ref vertex; result)
            vertex.color[3] = 0.45f;
        return result;
    }

    Vertex[] buildSteve(Vec3 position, float yawDegrees, float walkPosition, float walkSpeed)
    {
        return buildSteve(position, yawDegrees, 0.0f, 0.0f,
            walkPosition, walkSpeed, SkinLayers.modern());
    }

    Vertex[] buildSteve(Vec3 position, float yawDegrees, float walkPosition,
        float walkSpeed, SkinLayers layers)
    {
        return buildSteve(position, yawDegrees, 0.0f, 0.0f,
            walkPosition, walkSpeed, layers);
    }

    Vertex[] buildSteve(Vec3 position, float bodyYawDegrees,
        float headYawDegrees, float headPitchDegrees, float walkPosition,
        float walkSpeed, SkinLayers layers)
    {
        return buildSteve(position, bodyYawDegrees, headYawDegrees,
            headPitchDegrees, walkPosition, walkSpeed, 0.0f, false, 0.0f,
            layers);
    }

    Vertex[] buildSteve(Vec3 position, float bodyYawDegrees,
        float headYawDegrees, float headPitchDegrees, float walkPosition,
        float walkSpeed, float attackProgress, bool crouching,
        float ageInTicks, SkinLayers layers, bool holdingItem = false,
        bool mainHandRight = true, bool swimming = false,
        bool slimArms = false)
    {
        Vertex[] result;
        const yaw = bodyYawDegrees * DEG_TO_RAD;
        const headYaw = headYawDegrees * DEG_TO_RAD;
        const headPitch = headPitchDegrees * DEG_TO_RAD;
        // Java model space points Y downward. Ours points Y upward, so X/Z
        // rotations must be reflected when porting HumanoidModel's angles.
        float rightArmX = -cosf(walkPosition * 0.6662f + PI) * walkSpeed;
        float leftArmX = -cosf(walkPosition * 0.6662f) * walkSpeed;
        float rightLegX = -cosf(walkPosition * 0.6662f) * 1.4f * walkSpeed;
        float leftLegX = -cosf(walkPosition * 0.6662f + PI) * 1.4f * walkSpeed;
        float rightArmY = 0.0f;
        float leftArmY = 0.0f;
        float rightArmZ = -(cosf(ageInTicks * 0.09f) * 0.05f + 0.05f);
        float leftArmZ = -rightArmZ;
        rightArmX -= sinf(ageInTicks * 0.067f) * 0.05f;
        leftArmX += sinf(ageInTicks * 0.067f) * 0.05f;
        if(swimming)
        {
            const stroke=cosf(ageInTicks*0.25f);
            rightArmX=-PI*0.5f+stroke*0.75f;
            leftArmX=-PI*0.5f+stroke*0.75f;
            rightArmZ=-0.18f;leftArmZ=0.18f;
            rightLegX=cosf(ageInTicks*0.3f)*0.3f;
            leftLegX=-rightLegX;
        }

        // HumanoidModel ArmPose.ITEM: Java's model Y axis points downward, so
        // its -PI/10 carrying pitch becomes +PI/10 in our Y-up model space.
        // Keeping Java's unreflected sign points the hand behind the player.
        if (holdingItem)
        {
            if (mainHandRight)
                rightArmX = rightArmX * 0.5f + PI / 10.0f;
            else
                leftArmX = leftArmX * 0.5f + PI / 10.0f;
        }

        // HumanoidModel.setupAttackAnimation: twist the chest first, move both
        // shoulder joints around it, then drive the main arm through the hit.
        const bodyTwist = sinf(sqrtf(attackProgress) * PI * 2.0f) * 0.2f
            * (mainHandRight ? 1.0f : -1.0f);
        rightArmY += bodyTwist;
        leftArmY += bodyTwist;
        if (attackProgress > 0.0f)
        {
            auto eased = 1.0f - attackProgress;
            eased = 1.0f - eased * eased * eased * eased;
            const hit = sinf(eased * PI);
            const headCompensation = sinf(attackProgress * PI)
                * -(headPitch - 0.7f) * 0.75f;
            if(mainHandRight)
            {
                rightArmX += hit * 1.2f + headCompensation;
                rightArmY += bodyTwist;
                rightArmZ += sinf(attackProgress * PI) * 0.4f;
            }
            else
            {
                leftArmX += hit * 1.2f + headCompensation;
                leftArmY += bodyTwist;
                leftArmZ -= sinf(attackProgress * PI) * 0.4f;
            }
        }

        const crouchBodyX = crouching ? -0.5f : 0.0f;
        if (crouching)
        {
            rightArmX -= 0.4f;
            leftArmX -= 0.4f;
        }

        // ModelPart coordinates are pixels divided by 16. The head pivots at
        // its bottom-center neck joint. Both arm styles pivot at x=+/-5;
        // Java's slim model uses a three-pixel arm and lowers its shoulder by
        // half a pixel compared with the four-pixel classic model.
        const rootOffset = crouching ? Vec3(0,-0.125f,0) : Vec3.init;
        const bodyDrop = crouching ? -3.2f / 16.0f : 0.0f;
        const headDrop = crouching ? -4.2f / 16.0f : 0.0f;
        const armDrop = (crouching ? -3.2f : 0.0f) / 16.0f
            - (slimArms ? 0.5f / 16.0f : 0.0f);
        const legDrop = crouching ? -0.2f / 16.0f : 0.0f;
        const legForward = crouching ? 4.0f / 16.0f : 0.0f;
        const modelPosition = position + rootOffset;

        const bodyCenter = Vec3(0, 1.125f + bodyDrop, 0);
        const bodyPivot = Vec3(0, 1.5f + bodyDrop, 0);
        const headCenter = Vec3(0, 1.75f + headDrop, 0);
        const neckPivot = Vec3(0, 1.5f + headDrop, 0);

        auto rightShoulder = Vec3(-cosf(bodyTwist) * 5.0f / 16.0f,
            1.375f + armDrop, sinf(bodyTwist) * 5.0f / 16.0f);
        auto leftShoulder = Vec3(cosf(bodyTwist) * 5.0f / 16.0f,
            1.375f + armDrop, -sinf(bodyTwist) * 5.0f / 16.0f);
        const armCenterOffset = (slimArms ? 0.5f : 1.0f) / 16.0f;
        const armSize = Vec3((slimArms ? 3.0f : 4.0f) / 16.0f,
            0.75f, 0.25f);
        const rightArmCenter = rightShoulder
            + Vec3(-armCenterOffset, -4.0f / 16.0f, 0);
        const leftArmCenter = leftShoulder
            + Vec3(armCenterOffset, -4.0f / 16.0f, 0);
        const rightLegCenter = Vec3(-0.125f, 0.375f + legDrop, legForward);
        const leftLegCenter = Vec3(0.125f, 0.375f + legDrop, legForward);
        const rightHip = Vec3(-0.11875f, 0.75f + legDrop, legForward);
        const leftHip = Vec3(0.11875f, 0.75f + legDrop, legForward);

        addPart(result, modelPosition, yaw, bodyCenter, Vec3(0.5f,0.75f,0.25f),
            bodyPivot, Vec3(crouchBodyX, bodyTwist, 0), bodyUvs());
        addPart(result, modelPosition, yaw, headCenter, Vec3(0.5f,0.5f,0.5f),
            neckPivot, Vec3(-headPitch, headYaw, 0), headUvs());
        addPart(result, modelPosition, yaw, rightArmCenter, armSize,
            rightShoulder, Vec3(rightArmX, rightArmY, rightArmZ),
            slimArms ? rightSlimArmUvs() : rightArmUvs());
        addPart(result, modelPosition, yaw, leftArmCenter, armSize,
            leftShoulder, Vec3(leftArmX, leftArmY, leftArmZ),
            slimArms ? leftSlimArmUvs() : leftArmUvs());
        addPart(result, modelPosition, yaw, rightLegCenter, Vec3(0.25f,0.75f,0.25f),
            rightHip, Vec3(rightLegX, 0, 0), rightLegUvs());
        addPart(result, modelPosition, yaw, leftLegCenter, Vec3(0.25f,0.75f,0.25f),
            leftHip, Vec3(leftLegX, 0, 0), leftLegUvs());

        // Second-layer cubes are 0.25 skin pixels larger on each side;
        // Java's hat layer uses 0.5 pixels. Transparent texels are clipped by
        // the skin shader, so a modern skin may leave any layer empty.
        if (layers.jacket)
            addPart(result, modelPosition, yaw, bodyCenter,
                expanded(Vec3(0.5f,0.75f,0.25f), 0.03125f), bodyPivot,
                Vec3(crouchBodyX, bodyTwist, 0), jacketUvs());
        if (layers.hat)
            addPart(result, modelPosition, yaw, headCenter,
                expanded(Vec3(0.5f,0.5f,0.5f), 0.0625f), neckPivot,
                Vec3(-headPitch, headYaw, 0), hatUvs());
        if (layers.rightSleeve)
            addPart(result, modelPosition, yaw, rightArmCenter,
                expanded(armSize, 0.03125f), rightShoulder,
                Vec3(rightArmX, rightArmY, rightArmZ),
                slimArms ? rightSlimSleeveUvs() : rightSleeveUvs());
        if (layers.leftSleeve)
            addPart(result, modelPosition, yaw, leftArmCenter,
                expanded(armSize, 0.03125f), leftShoulder,
                Vec3(leftArmX, leftArmY, leftArmZ),
                slimArms ? leftSlimSleeveUvs() : leftSleeveUvs());
        if (layers.rightPants)
            addPart(result, modelPosition, yaw, rightLegCenter,
                expanded(Vec3(0.25f,0.75f,0.25f), 0.03125f), rightHip,
                Vec3(rightLegX, 0, 0), rightPantsUvs());
        if (layers.leftPants)
            addPart(result, modelPosition, yaw, leftLegCenter,
                expanded(Vec3(0.25f,0.75f,0.25f), 0.03125f), leftHip,
                Vec3(leftLegX, 0, 0), leftPantsUvs());
        if(swimming)
        {
            const pivot=position+Vec3(0,0.6f,0);
            const transform=Mat4.translation(pivot*-1.0f)
                *Mat4.rotationX((-90.0f-headPitchDegrees)*DEG_TO_RAD)
                *Mat4.translation(pivot);
            foreach(ref vertex;result)
            {
                const transformed=transform.transformPoint(Vec3(vertex.position[0],
                    vertex.position[1],vertex.position[2]));
                vertex.position=[transformed.x,transformed.y,transformed.z];
            }
            relightDirectional(result);
        }
        return result;
    }

    Vertex[] buildFirstPersonArm(bool renderSleeve = true,
        bool slimArms = false)
    {
        Vertex[] result;
        // Classic is [-3,-2,-2] + [4,12,4]; slim is
        // [-2,-2,-2] + [3,12,4]. ModelPart divides by 16.
        const centerX = (slimArms ? -0.5f : -1.0f) / 16.0f;
        const size = Vec3((slimArms ? 3.0f : 4.0f) / 16.0f,
            0.75f, 0.25f);
        addRawBox(result, Vec3(centerX,0.25f,0), size,
            slimArms ? rightSlimArmUvs() : rightArmUvs(),
            Mat4.identity(), true);
        if (renderSleeve)
            addRawBox(result, Vec3(centerX,0.25f,0),
                expanded(size, 0.03125f), slimArms
                    ? rightSlimSleeveUvs() : rightSleeveUvs(),
                Mat4.identity(), true);
        return result;
    }

    /// The lightmap is sampled per entity in Java. Keep it separate from the
    /// normal-based face shade so a limb retains its directional contrast as
    /// it moves between sunlight, caves, and future block-light sources.
    void applyWorldLight(ref Vertex[] geometry, float amount) const
    {
        amount=clamp(amount,0.0f,1.0f);
        foreach(ref vertex;geometry)
        {
            vertex.color[0]*=amount;
            vertex.color[1]*=amount;
            vertex.color[2]*=amount;
        }
    }

    /// Re-lights a mesh after its first-person pose is known. View models are
    /// authored in camera space and transformed only in the draw call, so the
    /// ordinary player-mesh pass cannot otherwise see their final normals.
    void applyPosedLight(ref Vertex[] geometry, Mat4 pose, float worldLight,
        bool blockCardinalColors = false,
        bool previouslyDirectional = true) const
    {
        worldLight=clamp(worldLight,0.0f,1.0f);
        for(size_t first=0;first+5<geometry.length;first+=6)
        {
            const a=vertexPosition(geometry[first]);
            const b=vertexPosition(geometry[first+1]);
            const c=vertexPosition(geometry[first+2]);
            const localNormal=cross(b-a,c-a).normalized();
            const posedNormal=transformDirection(pose,localNormal).normalized();
            float previous=1.0f;
            if(blockCardinalColors) previous=blockFaceShade(localNormal);
            else if(previouslyDirectional) previous=entityFaceShade(localNormal);
            const ratio=entityFaceShade(posedNormal)*worldLight/previous;
            foreach(ref vertex;geometry[first..first+6])
            {
                vertex.color[0]*=ratio;
                vertex.color[1]*=ratio;
                vertex.color[2]*=ratio;
            }
        }
    }

    Mat4 firstPersonArmTransform(float attackProgress, float aspect,
        float equipProgress = 0.0f) const
    {
        const root = sqrtf(attackProgress);
        const swingX = -0.3f * sinf(root * PI);
        const swingY = 0.4f * sinf(root * PI * 2.0f);
        const swingZ = -0.4f * sinf(attackProgress * PI);
        const yRotation = sinf(root * PI) * 70.0f * DEG_TO_RAD;
        const zRotation = sinf(attackProgress * attackProgress * PI) * -20.0f * DEG_TO_RAD;

        // Exact right-hand operation order from Java 1.21.10's
        // ItemInHandRenderer.renderPlayerArm. PoseStack is column-vector based,
        // so the operations are reversed for our row-vector matrices. The last
        // scale converts Java's camera-forward -Z to DirectX's +Z.
        const partPose = Mat4.rotationZ(0.1f)
            * Mat4.translation(Vec3(-5.0f / 16.0f, 2.0f / 16.0f, 0));
        const armPose = partPose
            * Mat4.translation(Vec3(5.6f, 0, 0))
            * Mat4.rotationY(-135.0f * DEG_TO_RAD)
            * Mat4.rotationX(200.0f * DEG_TO_RAD)
            * Mat4.rotationZ(120.0f * DEG_TO_RAD)
            * Mat4.translation(Vec3(-1.0f, 3.6f, 3.5f))
            * Mat4.rotationZ(zRotation)
            * Mat4.rotationY(yRotation)
            * Mat4.rotationY(45.0f * DEG_TO_RAD)
            * Mat4.translation(Vec3(
                swingX + 0.64000005f,
                swingY - 0.6f - equipProgress * 0.6f,
                swingZ - 0.71999997f,
            ));
        return armPose * Mat4.scale(Vec3(1, 1, -1));
    }

    /// Vanilla block-model first-person-right-hand transform. The imported
    /// block parent supplies Y=45 degrees and scale=.40; HeldItemRenderer adds
    /// the right-hand base translation and the -0.6 equip dip.
    Mat4 firstPersonBlockTransform(float attackProgress,
        float equipProgress) const
    {
        const root = sqrtf(attackProgress);
        const swingX = -0.4f * sinf(root * PI);
        const swingY = 0.2f * sinf(root * PI * 2.0f);
        const swingZ = -0.2f * sinf(attackProgress * PI);
        const attackYaw=sinf(attackProgress*attackProgress*PI);
        const attackArc=sinf(root*PI);
        return Mat4.translation(Vec3(-0.5f,-0.5f,-0.5f))
            * Mat4.rotationY(45.0f * DEG_TO_RAD)
            * Mat4.scale(Vec3(0.4f,0.4f,0.4f))
            * Mat4.rotationY(-45.0f*DEG_TO_RAD)
            * Mat4.rotationX(-80.0f*attackArc*DEG_TO_RAD)
            * Mat4.rotationZ(-20.0f*attackArc*DEG_TO_RAD)
            * Mat4.rotationY((45.0f-20.0f*attackYaw)*DEG_TO_RAD)
            * Mat4.translation(Vec3(
                swingX + 0.56f,
                swingY - 0.52f - equipProgress * 0.6f,
                -swingZ + 0.72f,
            ));
    }

    /// The item/generated display transform used by flat tools such as flint
    /// and steel. It shares the hand's attack arc, but uses the sprite model's
    /// own -90/25-degree presentation and .68 scale instead of block/item Y=45.
    Mat4 firstPersonGeneratedItemTransform(float attackProgress,
        float equipProgress) const
    {
        const root=sqrtf(attackProgress);
        const swingX=-0.4f*sinf(root*PI);
        const swingY=0.2f*sinf(root*PI*2.0f);
        const swingZ=-0.2f*sinf(attackProgress*PI);
        const attackYaw=sinf(attackProgress*attackProgress*PI);
        const attackArc=sinf(root*PI);
        return Mat4.translation(Vec3(-0.5f,-0.5f,-0.5f))
            *Mat4.rotationY(-90.0f*DEG_TO_RAD)
            *Mat4.rotationZ(25.0f*DEG_TO_RAD)
            *Mat4.scale(Vec3(0.68f,0.68f,0.68f))
            *Mat4.translation(Vec3(1.13f/16.0f,3.2f/16.0f,1.13f/16.0f))
            *Mat4.rotationY(-45.0f*DEG_TO_RAD)
            *Mat4.rotationX(-80.0f*attackArc*DEG_TO_RAD)
            *Mat4.rotationZ(-20.0f*attackArc*DEG_TO_RAD)
            *Mat4.rotationY((45.0f-20.0f*attackYaw)*DEG_TO_RAD)
            *Mat4.translation(Vec3(swingX+0.56f,
                swingY-0.52f-equipProgress*0.6f,-swingZ+0.72f));
    }

    /// Attaches an item to the end of the animated main arm rather than to a
    /// fixed point on the torso. This keeps the grip and held model together
    /// during walking, crouching, and the attack swing.
    Mat4 thirdPersonHeldItemTransform(bool generated,Vec3 position,
        float bodyYawDegrees,bool rightHand,float walkPosition,float walkSpeed,
        float attackProgress,bool crouching,float ageInTicks,
        bool slimArms = false) const
    {
        float armX=rightHand
            ? -cosf(walkPosition*0.6662f+PI)*walkSpeed
            : -cosf(walkPosition*0.6662f)*walkSpeed;
        // Match buildSteve's reflected HumanoidModel ArmPose.ITEM pitch so
        // the held mesh remains attached to the forward-pointing hand.
        armX=armX*0.5f+PI/10.0f;
        float armY=0;
        float armZ=rightHand
            ? -(cosf(ageInTicks*0.09f)*0.05f+0.05f)
            : cosf(ageInTicks*0.09f)*0.05f+0.05f;
        armX += rightHand ? -sinf(ageInTicks*0.067f)*0.05f
            : sinf(ageInTicks*0.067f)*0.05f;
        const bodyTwist=sinf(sqrtf(attackProgress)*PI*2.0f)*0.2f
            *(rightHand?1.0f:-1.0f);
        armY+=bodyTwist;
        if(attackProgress>0)
        {
            auto eased=1.0f-attackProgress;
            eased=1.0f-eased*eased*eased*eased;
            armX+=sinf(eased*PI)*1.2f;
            armY+=bodyTwist;
            armZ+=(rightHand?1.0f:-1.0f)*sinf(attackProgress*PI)*0.4f;
        }
        if(crouching)armX-=0.4f;
        const armDrop=(crouching?-3.2f:0.0f)/16.0f
            -(slimArms?0.5f/16.0f:0.0f);
        const rootOffset=crouching?Vec3(0,-0.125f,0):Vec3.init;
        const shoulder=Vec3(
            (rightHand?-1.0f:1.0f)*cosf(bodyTwist)*5.0f/16.0f,
            1.375f+armDrop,
            (rightHand?1.0f:-1.0f)*sinf(bodyTwist)*5.0f/16.0f);
        const gripOffset=(slimArms?0.5f:1.0f)/16.0f;
        const grip=shoulder+Vec3(rightHand?-gripOffset:gripOffset,
            -10.0f/16.0f,0);
        const center=grip+(generated?Vec3(0,0.13f,0.055f)
            :Vec3(rightHand?-0.055f:0.055f,0.04f,0.075f));
        const itemPose=generated
            ? Mat4.translation(Vec3(-0.5f,-0.5f,-0.5f))
                *Mat4.scale(Vec3(0.42f,0.42f,0.42f))
                *Mat4.translation(center)
            : Mat4.translation(Vec3(-0.5f,-0.5f,-0.5f))
                *Mat4.rotationY((rightHand?35.0f:-35.0f)*DEG_TO_RAD)
                *Mat4.rotationX(-12.0f*DEG_TO_RAD)
                *Mat4.scale(Vec3(0.25f,0.25f,0.25f))
                *Mat4.translation(center);
        const armPose=Mat4.translation(shoulder*-1.0f)
            *Mat4.rotationX(armX)*Mat4.rotationY(armY)*Mat4.rotationZ(armZ)
            *Mat4.translation(shoulder);
        return itemPose*armPose
            *Mat4.rotationY(bodyYawDegrees*DEG_TO_RAD)
            *Mat4.translation(position+rootOffset);
    }

    Mat4 firstPersonLookSwayTransform(float pitchDifference,
        float yawDifference) const
    {
        // ItemInHandRenderer applies ten percent of the gap between the live
        // view angles and LocalPlayer's half-step-smoothed xBob/yBob angles.
        return Mat4.rotationY(-yawDifference * 0.1f * DEG_TO_RAD)
            * Mat4.rotationX(-pitchDifference * 0.1f * DEG_TO_RAD);
    }

private:
    void addPart(ref Vertex[] output, Vec3 playerPosition, float yaw,
        Vec3 center, Vec3 size, Vec3 pivot, Vec3 rotation, BoxUvs uvs)
    {
        const transform = Mat4.translation(Vec3(-pivot.x,-pivot.y,-pivot.z))
            * Mat4.rotationX(rotation.x)
            * Mat4.rotationY(rotation.y)
            * Mat4.rotationZ(rotation.z)
            * Mat4.translation(pivot)
            * Mat4.rotationY(yaw)
            * Mat4.translation(playerPosition);
        addRawBox(output, center, size, uvs, transform);
    }

    void addRawBox(ref Vertex[] output, Vec3 center, Vec3 size, BoxUvs uvs,
        Mat4 transform, bool modelYDown = false, bool swapSideUvs = false)
    {
        const min = center - size * 0.5f;
        const max = center + size * 0.5f;
        Vec3 t(Vec3 value) { return transform.transformPoint(value); }
        void face(Vec3 a, Vec3 b, Vec3 c, Vec3 d, UvRect uv,
            bool flipVertical = false)
        {
            const ta=t(a),tb=t(b),tc=t(c),td=t(d);
            const normal=cross(tb-ta,td-ta).normalized();
            const light=entityFaceShade(normal);
            const shade = Color(light, light, light, 1);
            if (flipVertical)
                appendQuad(output, ta,tb,tc,td,
                    uv.uv(1,1),uv.uv(0,1),uv.uv(0,0),uv.uv(1,0),
                    shade,shade,shade,shade);
            else
                appendQuad(output, ta,tb,tc,td,
                    uv.uv(1,0),uv.uv(0,0),uv.uv(0,1),uv.uv(1,1),
                    shade,shade,shade,shade);
        }

        // These are ModelPart.Cube's vertex orders.  A skin's rectangular
        // cross layout depends on these exact rotations and mirrors.
        const v0 = Vec3(min.x,min.y,min.z);
        const v1 = Vec3(max.x,min.y,min.z);
        const v2 = Vec3(max.x,max.y,min.z);
        const v3 = Vec3(min.x,max.y,min.z);
        const v4 = Vec3(min.x,min.y,max.z);
        const v5 = Vec3(max.x,min.y,max.z);
        const v6 = Vec3(max.x,max.y,max.z);
        const v7 = Vec3(min.x,max.y,max.z);
        const reverseSides = !modelYDown;
        face(v1,v0,v3,v2,uvs.front,reverseSides); // north
        face(v4,v5,v6,v7,uvs.back,reverseSides);  // south
        // Skin-side names are from the character's perspective: west/X-min
        // consumes the right strip and east/X-max consumes the left strip.
        const westUvs = swapSideUvs ? uvs.left : uvs.right;
        const eastUvs = swapSideUvs ? uvs.right : uvs.left;
        face(v0,v4,v7,v3,westUvs,reverseSides); // west
        face(v5,v1,v2,v6,eastUvs,reverseSides); // east
        if (modelYDown)
        {
            face(v5,v4,v0,v1,uvs.top);             // shoulder cap
            face(v2,v3,v7,v6,uvs.bottom,true);     // hand cap
        }
        else
        {
            face(v2,v3,v7,v6,uvs.top,true);        // world-space top
            face(v5,v4,v0,v1,uvs.bottom);          // world-space bottom
        }
    }

    static float entityFaceShade(Vec3 normal)
    {
        // Minecraft's entity shader combines two directional lights with
        // 0.4 ambient and 0.6 directional power. The primary direction is the
        // same northwest/up vector used to draw D Edition's sun; the second is
        // the soft opposing fill that prevents silhouettes from going black.
        const sun=Vec3(-0.70710678f,0.70710678f,0.0f);
        const fill=Vec3(0.20076436f,0.70267526f,0.68259882f);
        const sunAmount=dot(sun,normal)>0.0f?dot(sun,normal):0.0f;
        const fillAmount=dot(fill,normal)>0.0f?dot(fill,normal):0.0f;
        return clamp((sunAmount+fillAmount)*0.6f+0.4f,0.0f,1.0f);
    }

    static Vec3 vertexPosition(const Vertex vertex)
    {
        return Vec3(vertex.position[0],vertex.position[1],vertex.position[2]);
    }

    static Vec3 transformDirection(Mat4 transform,Vec3 value)
    {
        return Vec3(
            value.x*transform.m[0]+value.y*transform.m[4]
                +value.z*transform.m[8],
            value.x*transform.m[1]+value.y*transform.m[5]
                +value.z*transform.m[9],
            value.x*transform.m[2]+value.y*transform.m[6]
                +value.z*transform.m[10]);
    }

    static float blockFaceShade(Vec3 normal)
    {
        if(normal.y>0.5f)return 1.0f;
        if(normal.y< -0.5f)return 0.5f;
        if(normal.z>0.5f||normal.z< -0.5f)return 0.8f;
        return 0.6f;
    }

    static void relightDirectional(ref Vertex[] geometry)
    {
        // Player cubes are emitted as six vertices per quad. Re-evaluate the
        // normal after whole-body poses such as swimming rotate the finished
        // model, otherwise its old upright lighting would remain painted on.
        for(size_t first=0;first+5<geometry.length;first+=6)
        {
            const a=Vec3(geometry[first].position[0],geometry[first].position[1],
                geometry[first].position[2]);
            const b=Vec3(geometry[first+1].position[0],
                geometry[first+1].position[1],geometry[first+1].position[2]);
            const c=Vec3(geometry[first+2].position[0],
                geometry[first+2].position[1],geometry[first+2].position[2]);
            const amount=entityFaceShade(cross(b-a,c-a).normalized());
            foreach(ref vertex;geometry[first..first+6])
                vertex.color=[amount,amount,amount,vertex.color[3]];
        }
    }

    BoxUvs headUvs() const { return BoxUvs(UvRect(8,8,16,16),UvRect(24,8,32,16),UvRect(16,8,24,16),UvRect(0,8,8,16),UvRect(8,0,16,8),UvRect(16,0,24,8)); }
    BoxUvs bodyUvs() const { return BoxUvs(UvRect(20,20,28,32),UvRect(32,20,40,32),UvRect(28,20,32,32),UvRect(16,20,20,32),UvRect(20,16,28,20),UvRect(28,16,36,20)); }
    BoxUvs rightArmUvs() const { return BoxUvs(UvRect(44,20,48,32),UvRect(52,20,56,32),UvRect(48,20,52,32),UvRect(40,20,44,32),UvRect(44,16,48,20),UvRect(48,16,52,20)); }
    BoxUvs leftArmUvs() const { return BoxUvs(UvRect(36,52,40,64),UvRect(44,52,48,64),UvRect(40,52,44,64),UvRect(32,52,36,64),UvRect(36,48,40,52),UvRect(40,48,44,52)); }
    BoxUvs rightSlimArmUvs() const { return BoxUvs(UvRect(44,20,47,32),UvRect(51,20,54,32),UvRect(47,20,51,32),UvRect(40,20,44,32),UvRect(44,16,47,20),UvRect(47,16,50,20)); }
    BoxUvs leftSlimArmUvs() const { return BoxUvs(UvRect(36,52,39,64),UvRect(43,52,46,64),UvRect(39,52,43,64),UvRect(32,52,36,64),UvRect(36,48,39,52),UvRect(39,48,42,52)); }
    BoxUvs rightLegUvs() const { return BoxUvs(UvRect(4,20,8,32),UvRect(12,20,16,32),UvRect(8,20,12,32),UvRect(0,20,4,32),UvRect(4,16,8,20),UvRect(8,16,12,20)); }
    BoxUvs leftLegUvs() const { return BoxUvs(UvRect(20,52,24,64),UvRect(28,52,32,64),UvRect(24,52,28,64),UvRect(16,52,20,64),UvRect(20,48,24,52),UvRect(24,48,28,52)); }
    BoxUvs hatUvs() const { return BoxUvs(UvRect(40,8,48,16),UvRect(56,8,64,16),UvRect(48,8,56,16),UvRect(32,8,40,16),UvRect(40,0,48,8),UvRect(48,0,56,8)); }
    BoxUvs jacketUvs() const { return BoxUvs(UvRect(20,36,28,48),UvRect(32,36,40,48),UvRect(28,36,32,48),UvRect(16,36,20,48),UvRect(20,32,28,36),UvRect(28,32,36,36)); }
    BoxUvs rightSleeveUvs() const { return BoxUvs(UvRect(44,36,48,48),UvRect(52,36,56,48),UvRect(48,36,52,48),UvRect(40,36,44,48),UvRect(44,32,48,36),UvRect(48,32,52,36)); }
    BoxUvs leftSleeveUvs() const { return BoxUvs(UvRect(52,52,56,64),UvRect(60,52,64,64),UvRect(56,52,60,64),UvRect(48,52,52,64),UvRect(52,48,56,52),UvRect(56,48,60,52)); }
    BoxUvs rightSlimSleeveUvs() const { return BoxUvs(UvRect(44,36,47,48),UvRect(51,36,54,48),UvRect(47,36,51,48),UvRect(40,36,44,48),UvRect(44,32,47,36),UvRect(47,32,50,36)); }
    BoxUvs leftSlimSleeveUvs() const { return BoxUvs(UvRect(52,52,55,64),UvRect(59,52,62,64),UvRect(55,52,59,64),UvRect(48,52,52,64),UvRect(52,48,55,52),UvRect(55,48,58,52)); }
    BoxUvs rightPantsUvs() const { return BoxUvs(UvRect(4,36,8,48),UvRect(12,36,16,48),UvRect(8,36,12,48),UvRect(0,36,4,48),UvRect(4,32,8,36),UvRect(8,32,12,36)); }
    BoxUvs leftPantsUvs() const { return BoxUvs(UvRect(4,52,8,64),UvRect(12,52,16,64),UvRect(8,52,12,64),UvRect(0,52,4,64),UvRect(4,48,8,52),UvRect(8,48,12,52)); }

    Vec3 expanded(Vec3 size, float amount) const
    {
        return size + Vec3(amount, amount, amount);
    }
}

unittest
{
    auto renderer = new PlayerRenderer();
    scope (exit) destroy(renderer);
    const classic = renderer.buildFirstPersonArm(false, false);
    const slim = renderer.buildFirstPersonArm(false, true);
    float classicMin = float.max, classicMax = -float.max;
    float slimMin = float.max, slimMax = -float.max;
    foreach (vertex; classic)
    {
        if (vertex.position[0] < classicMin) classicMin = vertex.position[0];
        if (vertex.position[0] > classicMax) classicMax = vertex.position[0];
    }
    foreach (vertex; slim)
    {
        if (vertex.position[0] < slimMin) slimMin = vertex.position[0];
        if (vertex.position[0] > slimMax) slimMax = vertex.position[0];
    }
    assert(classicMax-classicMin == 4.0f/16.0f);
    assert(slimMax-slimMin == 3.0f/16.0f);
    assert(renderer.rightSlimArmUvs().front.right
        - renderer.rightSlimArmUvs().front.left == 3.0f);

    // Rotating the body must rotate its normals through the directional
    // lights; the old hard-coded face values produced identical colors here.
    const facingNorth=renderer.buildSteve(Vec3.init,0.0f,0.0f,0.0f,
        0.0f,0.0f,SkinLayers.init);
    const facingSouth=renderer.buildSteve(Vec3.init,180.0f,0.0f,0.0f,
        0.0f,0.0f,SkinLayers.init);
    assert(facingNorth[0].color[0] != facingSouth[0].color[0]);

    auto posedArm=classic.dup;
    renderer.applyPosedLight(posedArm,Mat4.rotationY(PI*0.5f),1.0f);
    assert(posedArm[0].color[0] != classic[0].color[0]);
    auto darkArm=classic.dup;
    renderer.applyPosedLight(darkArm,Mat4.identity(),0.25f);
    assert(darkArm[0].color[0] < classic[0].color[0]);
}
