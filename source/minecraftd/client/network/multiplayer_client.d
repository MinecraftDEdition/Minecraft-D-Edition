module minecraftd.client.network.multiplayer_client;

import minecraftd.client.chat.chat_state : ChatMessageKind, ChatState;
import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.client.player.local_player : LocalPlayer;
import minecraftd.common.math3d : Vec3, clamp;
import minecraftd.game.entity.player : Player;
import minecraftd.network.game_protocol : DroppedItemState, GamePacketType,
    CombatEventType, DamageCause, NetworkPlayerState, PacketReader, PacketWriter,
    PlayerActionType,
    PlayerInputCommand,
    encodeInput, framePacket, inputAttack, inputBack, inputCrouch,
    inputForward, inputJump, inputLeft, inputRight, inputSprint,
    gameProtocolVersion;
import minecraftd.world.block : BlockId;
import minecraftd.world.world : World;
import minecraftd.world.world_settings : DimensionId;

struct BlockChangeEvent
{
    int x;
    int y;
    int z;
    BlockId oldBlock;
    BlockId newBlock;
    uint actorPlayerId;
}

struct PickupEvent
{
    uint playerId;
    Vec3 position;
}

struct CriticalHitEvent
{
    uint attackerId;
    uint targetId;
    Vec3 targetPosition;
}

struct ClientDroppedItem
{
    DroppedItemState state;
    Vec3 interpolationStart;
    Vec3 renderPosition;
    float interpolationProgress = 1.0f;

    Vec3 interpolatedPosition() const
    {
        return renderPosition;
    }

    void beginSnapshot(DroppedItemState next)
    {
        interpolationStart = renderPosition;
        state = next;
        interpolationProgress = 0.0f;
    }

    void advance(float frameSeconds)
    {
        interpolationProgress = clamp(interpolationProgress
            + frameSeconds / 0.05f, 0.0f, 1.0f);
        const smooth = interpolationProgress * interpolationProgress
            * (3.0f - 2.0f * interpolationProgress);
        renderPosition = interpolationStart
            + (state.position - interpolationStart) * smooth;
    }
}

final class RemotePlayer : Player
{
    uint networkId;
    string name;
    string accountId;
    string skinVersion;
    string skinModel = "classic";
    bool mining;
    int miningX;
    int miningY;
    int miningZ;
    float miningProgress;

    void pushSnapshot(const NetworkPlayerState state)
    {
        const wasOnGround = onGround;
        if (!state.onGround && state.position.y < position.y)
            fallDistance += position.y - state.position.y;
        else if (state.onGround && !wasOnGround)
        {
            lastLandedFallDistance = fallDistance;
            landingParticlesDue = fallDistance > 3.0f;
            fallDistance = 0.0f;
        }
        networkId = state.id;
        name = state.name;
        accountId = state.accountId;
        skinVersion = state.skinVersion;
        skinModel = state.skinModel;
        previousPosition = position;
        position = state.position;
        velocity = state.velocity;
        previousBodyYaw = bodyYaw;
        bodyYaw = state.bodyYaw;
        yaw = state.yaw;
        pitch = state.pitch;
        previousWalkAnimationPosition = walkAnimationPosition;
        walkAnimationPosition = state.walkPosition;
        previousWalkAnimationSpeed = walkAnimationSpeed;
        walkAnimationSpeed = state.walkSpeed;
        // A swing's 1 -> 0 completion and mining's halfway restart are phase
        // boundaries. Interpolating backward across either boundary makes the
        // remote arm visibly jitter instead of beginning the next smooth arc.
        previousAttackProgress = state.attackProgress < attackProgress
            ? state.attackProgress : attackProgress;
        attackProgress = state.attackProgress;
        crouching = state.crouching;
        sprinting = state.sprinting;
        onGround = state.onGround;
        health = state.health;
        hurtTime = state.hurtTime;
        hurtDirection = state.hurtDirection;
        foodLevel = state.food;
        saturationLevel = state.saturation;
        experienceLevel = cast(int) state.experienceLevel;
        experienceProgress = state.experienceProgress;
        totalExperience = cast(int) state.score;
        deathTime = state.deathTime;
        selectedSlot = state.selectedSlot;
        inventory = state.inventory;
        mining = state.mining;
        miningX = state.miningX;
        miningY = state.miningY;
        miningZ = state.miningZ;
        miningProgress = state.miningProgress;
        gameMode = state.gameMode;
        hardcore = state.hardcore;
        flying = state.flying;
        skinParts = state.skinParts;
        mainHandRight = state.mainHandRight;
        dimension = state.dimension;
        portalProgress = state.portalProgress;
        airSupply=state.airSupply;
        inWater=state.inWater;
        eyeInWater=state.eyeInWater;
        swimming=state.swimming;
    }
}

/// Client-side replication state: predicted local input history, authoritative
/// reconciliation, interpolated remote players, items, and world events.
final class MultiplayerClient
{
    private GameConnection connection;
    private World world;
    private LocalPlayer localPlayer;
    private PlayerInputCommand[] pendingInputs;
    private RemotePlayer[uint] remoteById;
    private BlockChangeEvent[] blockEvents;
    private PickupEvent[] pickupEvents;
    private CriticalHitEvent[] criticalHitEvents;
    private ClientDroppedItem[uint] droppedItemById;
    private uint localDamageEventId;
    private bool dimensionTravelPending;

    uint localPlayerId;
    string playerName = "Steve";
    bool loginComplete;
    uint serverTick;
    bool serverPaused;
    string localDeathMessage;
    string disconnectReason;

    this(GameConnection connection, World world, LocalPlayer localPlayer)
    {
        this.connection = connection;
        this.world = world;
        this.localPlayer = localPlayer;
    }

    ~this()
    {
        if (connection !is null) destroy(connection);
        foreach (remote; remoteById) destroy(remote);
    }

    bool connected() const
    {
        return connection !is null && connection.connected();
    }

    void replaceConnection(GameConnection replacement)
    {
        if (connection !is null)
            destroy(connection);
        connection = replacement;
        loginComplete = false;
        disconnectReason = "";
        localPlayerId = 0;
        pendingInputs.length = 0;
        localDamageEventId = 0;
        droppedItemById.clear();
        foreach (remote; remoteById) destroy(remote);
        remoteById.clear();
    }

    void sendPredictedInput(PlayerInputCommand input)
    {
        if (!connected() || !loginComplete)
            return;
        pendingInputs ~= input;
        connection.sendFramed(encodeInput(input));
    }

    void sendChat(string message)
    {
        if (!connected() || !loginComplete)
            return;
        PacketWriter writer;
        writer.putString(message);
        connection.send(GamePacketType.chatSubmit, writer.data);
    }

    void sendProfileUpdate(string skinVersion,string skinModel)
    {
        if(!connected()||!loginComplete)return;
        PacketWriter writer;
        writer.putString(skinVersion);
        writer.putString(skinModel=="slim"?"slim":"classic");
        connection.send(GamePacketType.profileUpdate,writer.data);
    }

    void requestDrop(ubyte selectedSlot, bool wholeStack = false)
    {
        if (!connected() || !loginComplete)
            return;
        PacketWriter writer;
        writer.putU8(cast(ubyte)(wholeStack
            ? PlayerActionType.dropStack : PlayerActionType.dropItem));
        writer.putU8(selectedSlot);
        writer.putU8(0);
        connection.send(GamePacketType.playerAction, writer.data);
    }

    void requestInventoryAction(PlayerActionType action, ubyte target = 0,
        ubyte auxiliary = 0)
    {
        if (!connected() || !loginComplete) return;
        PacketWriter writer;
        writer.putU8(cast(ubyte)action);
        writer.putU8(target);
        writer.putU8(auxiliary);
        connection.send(GamePacketType.playerAction,writer.data);
    }

    void requestRespawn()
    {
        if (!connected() || !loginComplete)
            return;
        PacketWriter writer;
        writer.putU8(cast(ubyte) PlayerActionType.respawn);
        writer.putU8(0);
        writer.putU8(0);
        connection.send(GamePacketType.playerAction, writer.data);
    }

    void requestDisconnect()
    {
        if (connected()) connection.send(GamePacketType.disconnect);
    }

    void poll(ChatState chat)
    {
        if (connection is null)
            return;
        foreach (packet; connection.poll())
        {
            final switch (packet.type)
            {
                case GamePacketType.loginAccepted:
                    handleLogin(packet.payload);
                    break;
                case GamePacketType.snapshot:
                    handleSnapshot(packet.payload);
                    break;
                case GamePacketType.blockChange:
                    handleBlockChange(packet.payload);
                    break;
                case GamePacketType.chatBroadcast:
                {
                    PacketReader reader = PacketReader(packet.payload);
                    const system = reader.readBool();
                    const message = reader.readString();
                    if (reader.valid) chat.addMessage(message, system
                        ? ChatMessageKind.system : ChatMessageKind.normal);
                    break;
                }
                case GamePacketType.keepAlive:
                    connection.send(GamePacketType.keepAliveReply, packet.payload);
                    break;
                case GamePacketType.itemPickup:
                {
                    PacketReader reader = PacketReader(packet.payload);
                    const id = reader.readU32();
                    const position = reader.readVec3();
                    if (reader.valid) pickupEvents ~= PickupEvent(id, position);
                    break;
                }
                case GamePacketType.combatEvent:
                {
                    PacketReader reader = PacketReader(packet.payload);
                    const eventType = cast(CombatEventType) reader.readU8();
                    const attackerId = reader.readU32();
                    const targetId = reader.readU32();
                    const targetPosition = reader.readVec3();
                    if (reader.valid && eventType == CombatEventType.criticalHit)
                        criticalHitEvents ~= CriticalHitEvent(attackerId,
                            targetId, targetPosition);
                    break;
                }
                case GamePacketType.dimensionChange:
                    handleDimensionChange(packet.payload);
                    break;
                case GamePacketType.disconnect:
                {
                    PacketReader reader = PacketReader(packet.payload);
                    const reason = reader.readString();
                    disconnectReason = reader.valid && reason.length
                        ? reason : "The server closed the connection";
                    loginComplete = false;
                    break;
                }
                case GamePacketType.loginRequest,
                     GamePacketType.playerInput,
                     GamePacketType.playerAction,
                     GamePacketType.chatSubmit,
                     GamePacketType.profileUpdate,
                     GamePacketType.keepAliveReply:
                    break;
            }
        }
    }

    RemotePlayer[] remotePlayers()
    {
        RemotePlayer[] result;
        foreach (remote; remoteById) result ~= remote;
        return result;
    }

    ClientDroppedItem[] droppedItems()
    {
        ClientDroppedItem[] result;
        foreach (item; droppedItemById) result ~= item;
        return result;
    }

    void advanceDroppedItems(float frameSeconds)
    {
        foreach (id, ref item; droppedItemById)
            item.advance(frameSeconds);
    }

    BlockChangeEvent[] consumeBlockEvents()
    {
        auto result = blockEvents.dup;
        blockEvents.length = 0;
        return result;
    }

    PickupEvent[] consumePickupEvents()
    {
        auto result = pickupEvents.dup;
        pickupEvents.length = 0;
        return result;
    }

    CriticalHitEvent[] consumeCriticalHitEvents()
    {
        auto result = criticalHitEvents.dup;
        criticalHitEvents.length = 0;
        return result;
    }

    bool consumeDimensionTravel()
    {
        const result = dimensionTravelPending;
        dimensionTravelPending = false;
        return result;
    }

private:
    void handleLogin(const(ubyte)[] payload)
    {
        PacketReader reader = PacketReader(payload);
        const versionValue = reader.readU16();
        const id = reader.readU32();
        const name = reader.readString();
        const spawn = reader.readVec3();
        const dimension = cast(DimensionId) reader.readU8();
        const width = reader.readU16();
        const height = reader.readU16();
        const depth = reader.readU16();
        foreach (y; 0 .. height)
        foreach (z; 0 .. depth)
        foreach (x; 0 .. width)
        {
            const block = cast(BlockId) reader.readU8();
            if (reader.valid) world.setBlock(x, y, z, block);
        }
        if (!reader.valid || versionValue != gameProtocolVersion)
            return;
        world.dimension = dimension;
        world.markDirty();
        localPlayerId = id;
        playerName = name;
        localPlayer.position = spawn;
        localPlayer.previousPosition = spawn;
        localPlayer.velocity = Vec3.init;
        localPlayer.dimension = dimension;
        localPlayer.portalProgress = 0.0f;
        localPlayer.health = 20.0f;
        localPlayer.previousDisplayedHealth = 20.0f;
        localPlayer.deathTime = 0;
        localPlayer.totalExperience = 0;
        localDeathMessage = "";
        pendingInputs.length = 0;
        loginComplete = true;
    }

    void handleSnapshot(const(ubyte)[] payload)
    {
        PacketReader reader = PacketReader(payload);
        const tickValue = reader.readU32();
        const acknowledged = reader.readU32();
        const pausedValue = reader.readBool();
        const playerCount = reader.readU16();
        NetworkPlayerState[] states;
        bool[uint] seen;
        foreach (_; 0 .. playerCount)
        {
            auto state = reader.readPlayer();
            states ~= state;
            seen[state.id] = true;
        }
        const itemCount = reader.readU16();
        DroppedItemState[] items;
        foreach (_; 0 .. itemCount)
            items ~= reader.readDroppedItem();
        if (!reader.valid)
            return;

        serverTick = tickValue;
        serverPaused = pausedValue;
        bool[uint] seenItems;
        foreach (item; items)
        {
            seenItems[item.id] = true;
            auto existing = item.id in droppedItemById;
            if (existing is null)
                droppedItemById[item.id] = ClientDroppedItem(item,
                    item.position, item.position, 1.0f);
            else
                existing.beginSnapshot(item);
        }
        uint[] removedItems;
        foreach (id, item; droppedItemById)
            if (id !in seenItems) removedItems ~= id;
        foreach (id; removedItems)
            droppedItemById.remove(id);
        foreach (state; states)
        {
            if (state.id == localPlayerId)
                reconcileLocal(state, acknowledged);
            else
            {
                auto existing = state.id in remoteById;
                if (existing is null)
                {
                    auto remote = new RemotePlayer();
                    remote.position = state.position;
                    remote.previousPosition = state.position;
                    remoteById[state.id] = remote;
                    existing = state.id in remoteById;
                }
                (*existing).pushSnapshot(state);
            }
        }
        uint[] removed;
        foreach (id, remote; remoteById)
            if (id !in seen) removed ~= id;
        foreach (id; removed)
        {
            destroy(remoteById[id]);
            remoteById.remove(id);
        }
    }

    void reconcileLocal(const NetworkPlayerState state, uint acknowledged)
    {
        const oldHealth = localPlayer.health;
        auto oldInventory = localPlayer.inventory;
        const predictedPosition = localPlayer.position;
        const predictedPreviousPosition = localPlayer.previousPosition;
        const predictedVelocity = localPlayer.velocity;
        const viewYaw = localPlayer.yaw;
        const viewPitch = localPlayer.pitch;
        const selectedSlot = localPlayer.selectedSlot;
        const bodyYaw = localPlayer.bodyYaw;
        const previousBodyYaw = localPlayer.previousBodyYaw;
        const walkDistance = localPlayer.walkDistance;
        const previousWalkDistance = localPlayer.previousWalkDistance;
        const walkPosition = localPlayer.walkAnimationPosition;
        const previousWalkPosition = localPlayer.previousWalkAnimationPosition;
        const walkSpeed = localPlayer.walkAnimationSpeed;
        const previousWalkSpeed = localPlayer.previousWalkAnimationSpeed;
        const cameraBob = localPlayer.cameraBob;
        const previousCameraBob = localPlayer.previousCameraBob;
        const fallPitch = localPlayer.fallCameraPitch;
        const previousFallPitch = localPlayer.previousFallCameraPitch;
        const attackProgress = localPlayer.attackProgress;
        const previousAttackProgress = localPlayer.previousAttackProgress;
        const attacking = localPlayer.attacking;
        const smoothedYaw = localPlayer.smoothedViewYaw;
        const previousSmoothedYaw = localPlayer.previousSmoothedViewYaw;
        const smoothedPitch = localPlayer.smoothedViewPitch;
        const previousSmoothedPitch = localPlayer.previousSmoothedViewPitch;
        const fov = localPlayer.fovModifier;
        const previousFov = localPlayer.previousFovModifier;
        const stepSoundDue = localPlayer.stepSoundDue;
        const visualCorrection = localPlayer.visualCorrection;
        const previousVisualCorrection = localPlayer.previousVisualCorrection;

        PlayerInputCommand[] remaining;
        foreach (input; pendingInputs)
            if (input.sequence > acknowledged)
                remaining ~= input;
        pendingInputs = remaining;

        // Rebuild the physical prediction from the last server-approved state.
        // Camera angles and visual animation phases are restored below: those
        // are client-owned and rewinding them on every snapshot causes jitter.
        localPlayer.position = state.position;
        localPlayer.previousPosition = state.position;
        localPlayer.velocity = state.velocity;
        localPlayer.yaw = viewYaw;
        localPlayer.pitch = viewPitch;
        localPlayer.crouching = state.crouching;
        localPlayer.sprinting = state.sprinting;
        localPlayer.onGround = state.onGround;
        localPlayer.health = state.health;
        localPlayer.foodLevel = state.food;
        localPlayer.saturationLevel = state.saturation;
        localPlayer.experienceLevel = cast(int) state.experienceLevel;
        localPlayer.experienceProgress = state.experienceProgress;
        localPlayer.totalExperience = cast(int) state.score;
        localPlayer.deathTime = state.deathTime;
        localDeathMessage = state.deathMessage;
        localPlayer.inventory = state.inventory;
        localPlayer.gameMode = state.gameMode;
        localPlayer.hardcore = state.hardcore;
        localPlayer.flying = state.flying;
        localPlayer.dimension = state.dimension;
        localPlayer.portalProgress = state.portalProgress;
        localPlayer.airSupply=state.airSupply;
        localPlayer.inWater=state.inWater;
        localPlayer.eyeInWater=state.eyeInWater;
        localPlayer.swimming=state.swimming;
        foreach (slot; 0 .. localPlayer.inventory.hotbar.length)
        {
            const oldStack = oldInventory.hotbar[slot];
            auto stack = &localPlayer.inventory.hotbar[slot];
            if (oldStack.item != stack.item || oldStack.count != stack.count)
                stack.popTicks = 5;
        }
        if (state.damageEventId != localDamageEventId)
        {
            localPlayer.previousDisplayedHealth = oldHealth;
            localPlayer.hurtTime = localPlayer.maxHurtTime;
            localPlayer.hurtDirection = state.hurtDirection;
            localPlayer.damageFlashTicks = 20;
            localPlayer.hungerJiggleTicks = 10;
            localPlayer.hurtSoundDue = true;
            if (state.damageCause == DamageCause.fall)
            {
                const damage = oldHealth - state.health;
                localPlayer.fallSoundDue = damage > 4.0f ? 2 : 1;
            }
            localDamageEventId = state.damageEventId;
        }

        if (localPlayer.health <= 0.0f)
            pendingInputs.length = 0;
        foreach (input; pendingInputs)
        {
            localPlayer.yaw = input.yaw;
            localPlayer.pitch = input.pitch;
            localPlayer.selectedSlot = input.selectedSlot;
            if (input.down(inputAttack))
                localPlayer.attack();
            if (input.flightTogglePressed)
                localPlayer.toggleFlight();
            localPlayer.simulateTick(world,
                input.down(inputForward), input.down(inputBack),
                input.down(inputLeft), input.down(inputRight),
                input.down(inputJump), input.down(inputCrouch),
                input.down(inputSprint));
        }

        const correctedPosition = localPlayer.position;
        const correctedVelocity = localPlayer.velocity;
        const error = correctedPosition - predictedPosition;
        if (error.lengthSquared() < 0.75f * 0.75f)
        {
            // Routine client/server tick-phase differences are not gameplay
            // corrections. Nudging toward those 20 TPS snapshots makes a
            // correctly predicted player visibly stop and start while walking.
            localPlayer.position = predictedPosition;
            localPlayer.previousPosition = predictedPreviousPosition;
            localPlayer.velocity = predictedVelocity;
        }
        else
        {
            // Large errors indicate a real collision/teleport correction. Move
            // physics immediately, but preserve the rendered endpoint and let
            // LocalPlayer decay the difference instead of jumping backward.
            localPlayer.position = correctedPosition;
            localPlayer.previousPosition = correctedPosition;
            localPlayer.velocity = correctedVelocity;
        }

        localPlayer.yaw = viewYaw;
        localPlayer.pitch = viewPitch;
        localPlayer.selectedSlot = selectedSlot;
        localPlayer.bodyYaw = bodyYaw;
        localPlayer.previousBodyYaw = previousBodyYaw;
        localPlayer.walkDistance = walkDistance;
        localPlayer.previousWalkDistance = previousWalkDistance;
        localPlayer.walkAnimationPosition = walkPosition;
        localPlayer.previousWalkAnimationPosition = previousWalkPosition;
        localPlayer.walkAnimationSpeed = walkSpeed;
        localPlayer.previousWalkAnimationSpeed = previousWalkSpeed;
        localPlayer.cameraBob = cameraBob;
        localPlayer.previousCameraBob = previousCameraBob;
        localPlayer.fallCameraPitch = fallPitch;
        localPlayer.previousFallCameraPitch = previousFallPitch;
        localPlayer.attackProgress = attackProgress;
        localPlayer.previousAttackProgress = previousAttackProgress;
        localPlayer.attacking = attacking;
        localPlayer.smoothedViewYaw = smoothedYaw;
        localPlayer.previousSmoothedViewYaw = previousSmoothedYaw;
        localPlayer.smoothedViewPitch = smoothedPitch;
        localPlayer.previousSmoothedViewPitch = previousSmoothedPitch;
        localPlayer.fovModifier = fov;
        localPlayer.previousFovModifier = previousFov;
        localPlayer.stepSoundDue = stepSoundDue;
        if (error.lengthSquared() < 0.75f * 0.75f)
        {
            localPlayer.visualCorrection = visualCorrection;
            localPlayer.previousVisualCorrection = previousVisualCorrection;
        }
        else
        {
            localPlayer.visualCorrection = visualCorrection
                + predictedPosition - correctedPosition;
            localPlayer.previousVisualCorrection = localPlayer.visualCorrection;
        }
    }

    void handleBlockChange(const(ubyte)[] payload)
    {
        PacketReader reader = PacketReader(payload);
        BlockChangeEvent event;
        event.x = reader.readI32(); event.y = reader.readI32();
        event.z = reader.readI32();
        event.oldBlock = cast(BlockId) reader.readU8();
        event.newBlock = cast(BlockId) reader.readU8();
        event.actorPlayerId = reader.readU32();
        if (!reader.valid) return;
        world.setBlock(event.x, event.y, event.z, event.newBlock);
        if (event.actorPlayerId == localPlayerId
            && event.oldBlock == BlockId.air && event.newBlock != BlockId.air)
            localPlayer.attack(true);
        blockEvents ~= event;
    }

    void handleDimensionChange(const(ubyte)[] payload)
    {
        PacketReader reader = PacketReader(payload);
        const dimension = cast(DimensionId) reader.readU8();
        const position = reader.readVec3();
        const width = reader.readU16();
        const height = reader.readU16();
        const depth = reader.readU16();
        foreach (y; 0 .. height)
        foreach (z; 0 .. depth)
        foreach (x; 0 .. width)
        {
            const block = cast(BlockId) reader.readU8();
            if (reader.valid) world.setBlock(x, y, z, block);
        }
        if (!reader.valid) return;
        world.dimension = dimension;
        world.markDirty();
        localPlayer.dimension = dimension;
        localPlayer.position = position;
        localPlayer.previousPosition = position;
        localPlayer.velocity = Vec3.init;
        localPlayer.visualCorrection = Vec3.init;
        localPlayer.previousVisualCorrection = Vec3.init;
        localPlayer.portalProgress = 1.0f;
        pendingInputs.length = 0;
        droppedItemById.clear();
        foreach (remote; remoteById) destroy(remote);
        remoteById.clear();
        blockEvents.length = 0;
        dimensionTravelPending = true;
    }
}
