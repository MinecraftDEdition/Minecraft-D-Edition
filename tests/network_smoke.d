module network_smoke;

import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;

import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.network.game_protocol : CombatEventType, DamageCause,
    GamePacketType, PacketReader, PacketWriter, PlayerActionType,
    PlayerInputCommand, encodeInput, inputAttack, inputForward, inputJump;
import minecraftd.server.integrated_game_server : IntegratedGameServer;
import minecraftd.game.item.inventory : ItemId;
import minecraftd.world.block : BlockId;

void main()
{
    enum ushort port = 25567;
    auto server = new IntegratedGameServer(port);
    scope (exit) destroy(server);
    auto first = new GameConnection("Steve", "127.0.0.1", port);
    scope (exit) destroy(first);
    auto second = new GameConnection("Steve", "127.0.0.1", port);
    scope (exit) destroy(second);

    uint firstId;
    uint secondId;
    string firstName;
    string secondName;
    ushort largestPlayerCount;
    uint largestAcknowledged;
    foreach (_; 0 .. 100)
    {
        foreach (packet; first.poll())
        {
            PacketReader reader = PacketReader(packet.payload);
            if (packet.type == GamePacketType.loginAccepted)
            {
                reader.readU16();
                firstId = reader.readU32();
                firstName = reader.readString();
            }
            else if (packet.type == GamePacketType.snapshot)
            {
                reader.readU32();
                const acknowledged = reader.readU32();
                reader.readBool();
                const count = reader.readU16();
                if (count > largestPlayerCount) largestPlayerCount = count;
                if (acknowledged > largestAcknowledged)
                    largestAcknowledged = acknowledged;
            }
        }
        foreach (packet; second.poll())
            if (packet.type == GamePacketType.loginAccepted)
            {
                PacketReader reader = PacketReader(packet.payload);
                reader.readU16();
                secondId = reader.readU32();
                secondName = reader.readString();
            }
        if (firstId != 0 && secondId != 0 && largestPlayerCount >= 2)
            break;
        Thread.sleep(20.msecs);
    }
    writeln("login ids=", firstId, ",", secondId,
        " largest snapshot player count=", largestPlayerCount);
    assert(firstId != 0 && secondId != 0 && firstId != secondId);
    assert((firstName == "Steve" && secondName == "Steve2")
        || (firstName == "Steve2" && secondName == "Steve"));
    assert(largestPlayerCount >= 2);
    assert(server.publish().length != 0);

    foreach (sequence; 1 .. 6)
    {
        first.sendFramed(encodeInput(PlayerInputCommand(sequence,
            sequence == 1 ? inputForward : 0, 0, false, 0.0f, 0.0f)));
        Thread.sleep(55.msecs);
    }
    foreach (_; 0 .. 50)
    {
        foreach (packet; first.poll())
        if (packet.type == GamePacketType.snapshot)
        {
            PacketReader reader = PacketReader(packet.payload);
            reader.readU32();
            const acknowledged = reader.readU32();
            reader.readBool();
            if (acknowledged > largestAcknowledged)
                largestAcknowledged = acknowledged;
        }
        if (largestAcknowledged >= 5) break;
        Thread.sleep(20.msecs);
    }
    assert(largestAcknowledged >= 5);

    first.sendFramed(encodeInput(PlayerInputCommand(6,
        inputAttack, 0, false, 0.0f, 45.0f)));
    bool blockBroken;
    bool itemPickedUp;
    bool dirtReceived;
    float largestMiningProgress = 0.0f;
    uint attackAcknowledged;
    float lastX;
    float lastY;
    float lastZ;
    float lastPitch;
    uint liveSequence = 6;
    foreach (pollIndex; 0 .. 150)
    {
        if (pollIndex != 0 && pollIndex % 3 == 0)
            first.sendFramed(encodeInput(PlayerInputCommand(++liveSequence,
                inputAttack, 0, false, 0.0f, 45.0f)));
        foreach (packet; first.poll())
        {
            PacketReader reader = PacketReader(packet.payload);
            if (packet.type == GamePacketType.blockChange)
            {
                reader.readI32(); reader.readI32(); reader.readI32();
                const oldBlock = cast(BlockId) reader.readU8();
                const newBlock = cast(BlockId) reader.readU8();
                const actorId = reader.readU32();
                if (oldBlock == BlockId.grass && newBlock == BlockId.air
                    && actorId == firstId)
                    blockBroken = true;
            }
            else if (packet.type == GamePacketType.itemPickup)
            {
                if (reader.readU32() == firstId) itemPickedUp = true;
            }
            else if (packet.type == GamePacketType.snapshot)
            {
                reader.readU32();
                const acknowledged = reader.readU32();
                reader.readBool();
                if (acknowledged > attackAcknowledged)
                    attackAcknowledged = acknowledged;
                const count = reader.readU16();
                foreach (_player; 0 .. count)
                {
                    const state = reader.readPlayer();
                    if (state.id != firstId) continue;
                    lastX = state.position.x; lastY = state.position.y;
                    lastZ = state.position.z; lastPitch = state.pitch;
                    if (state.miningProgress > largestMiningProgress)
                        largestMiningProgress = state.miningProgress;
                    foreach (stack; state.inventory.hotbar)
                        if (stack.item == ItemId.dirt && stack.count > 0)
                            dirtReceived = true;
                }
            }
        }
        if (blockBroken && itemPickedUp && dirtReceived) break;
        Thread.sleep(20.msecs);
    }
    writeln("break=", blockBroken, " pickup=", itemPickedUp,
        " dirt=", dirtReceived, " mining=", largestMiningProgress,
        " ack=", attackAcknowledged, " position=", lastX, ",", lastY,
        ",", lastZ, " pitch=", lastPitch);
    assert(blockBroken && itemPickedUp && dirtReceived);

    // Enter a real downward airborne state before attacking. Java criticals use
    // accumulated fall distance rather than merely checking the jump key.
    const combatYaw = firstId < secondId ? 102.0f : -102.0f;
    uint combatSequence = liveSequence + 1;
    first.sendFramed(encodeInput(PlayerInputCommand(combatSequence,
        inputJump, 0, false, combatYaw, 55.0f)));
    Thread.sleep(55.msecs);
    bool descending;
    foreach (_attempt; 0 .. 12)
    {
        first.sendFramed(encodeInput(PlayerInputCommand(++combatSequence,
            0, 0, false, combatYaw, 55.0f)));
        Thread.sleep(55.msecs);
        foreach (packet; first.poll())
        if (packet.type == GamePacketType.snapshot)
        {
            PacketReader reader = PacketReader(packet.payload);
            reader.readU32(); reader.readU32(); reader.readBool();
            const count = reader.readU16();
            foreach (_player; 0 .. count)
            {
                const state = reader.readPlayer();
                if (state.id == firstId && !state.onGround
                    && state.velocity.y < 0.0f)
                    descending = true;
            }
        }
        if (descending) break;
    }
    assert(descending);
    first.sendFramed(encodeInput(PlayerInputCommand(++combatSequence,
        0, 0, false, combatYaw, 55.0f, true)));
    bool playerDamaged;
    bool playerKnockedBack;
    bool hurtStateReplicated;
    bool damageEventReplicated;
    bool criticalEventReceived;
    bool criticalDamageApplied;
    float attackerY;
    bool attackerGrounded;
    foreach (_; 0 .. 100)
    {
        foreach (packet; second.poll())
        if (packet.type == GamePacketType.combatEvent)
        {
            PacketReader reader = PacketReader(packet.payload);
            const type = cast(CombatEventType) reader.readU8();
            reader.readU32();
            const targetId = reader.readU32();
            reader.readVec3();
            criticalEventReceived = reader.valid
                && type == CombatEventType.criticalHit && targetId == secondId;
        }
        else if (packet.type == GamePacketType.snapshot)
        {
            PacketReader reader = PacketReader(packet.payload);
            reader.readU32(); reader.readU32(); reader.readBool();
            const count = reader.readU16();
            foreach (_player; 0 .. count)
            {
                const state = reader.readPlayer();
                if (state.id == firstId)
                {
                    attackerY = state.position.y;
                    attackerGrounded = state.onGround;
                }
                if (state.id != secondId) continue;
                playerDamaged = state.health < 20.0f;
                criticalDamageApplied = state.health <= 18.5f;
                playerKnockedBack = state.velocity.horizontalLength() > 1.0f;
                hurtStateReplicated = state.hurtTime > 0;
                damageEventReplicated = state.damageEventId > 0
                    && state.damageCause == DamageCause.generic;
            }
        }
        if (playerDamaged && playerKnockedBack && hurtStateReplicated
            && damageEventReplicated && criticalEventReceived
            && criticalDamageApplied) break;
        Thread.sleep(20.msecs);
    }
    writeln("critical damage=", playerDamaged, " knockback=",
        playerKnockedBack, " hurt=", hurtStateReplicated, " eventState=",
        damageEventReplicated, " combatEvent=", criticalEventReceived,
        " amount=", criticalDamageApplied, " attackerY=", attackerY,
        " grounded=", attackerGrounded);
    assert(playerDamaged && playerKnockedBack && hurtStateReplicated
        && damageEventReplicated && criticalEventReceived);
    assert(criticalDamageApplied);

    // Release attack, then exercise Java-style discrete Q/drop handling.
    second.send(GamePacketType.disconnect);
    Thread.sleep(100.msecs);
    first.sendFramed(encodeInput(PlayerInputCommand(++combatSequence,
        0, 0, false, 0.0f, 89.0f)));
    PacketWriter dropAction;
    dropAction.putU8(cast(ubyte) PlayerActionType.dropItem);
    dropAction.putU8(0);
    dropAction.putU8(0);
    first.send(GamePacketType.playerAction, dropAction.data);
    bool thrownItemSeen;
    bool dropRemovedFromInventory;
    foreach (_; 0 .. 100)
    {
        foreach (packet; first.poll())
        if (packet.type == GamePacketType.snapshot)
        {
            PacketReader reader = PacketReader(packet.payload);
            reader.readU32(); reader.readU32(); reader.readBool();
            const playerCount = reader.readU16();
            foreach (_player; 0 .. playerCount)
            {
                const state = reader.readPlayer();
                if (state.id != firstId) continue;
                bool hasDirt;
                foreach (stack; state.inventory.hotbar)
                    if (stack.item == ItemId.dirt && stack.count > 0)
                        hasDirt = true;
                if (!hasDirt) dropRemovedFromInventory = true;
            }
            const itemCount = reader.readU16();
            foreach (_item; 0 .. itemCount)
            {
                const item = reader.readDroppedItem();
                if (item.item == ItemId.dirt && item.pickupDelay > 0
                    && item.velocity.lengthSquared() > 0.0f)
                    thrownItemSeen = true;
            }
        }
        if (thrownItemSeen && dropRemovedFromInventory) break;
        Thread.sleep(20.msecs);
    }
    assert(thrownItemSeen && dropRemovedFromInventory);

    server.setPaused(true);
    bool pausedSnapshot;
    foreach (_; 0 .. 30)
    {
        foreach (packet; first.poll())
        if (packet.type == GamePacketType.snapshot)
        {
            PacketReader reader = PacketReader(packet.payload);
            reader.readU32(); reader.readU32();
            if (reader.readBool()) pausedSnapshot = true;
        }
        if (pausedSnapshot) break;
        Thread.sleep(20.msecs);
    }
    assert(pausedSnapshot);
    server.setPaused(false);

    writeln("two-client world, PvP, mining, pickup, and drop smoke test passed");
}
