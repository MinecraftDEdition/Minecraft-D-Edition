module creative_mechanics_smoke;

import core.thread : Thread;
import core.time : msecs;
import std.file : mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.uuid : randomUUID;

import minecraftd.client.network.game_connection : GameConnection;
import minecraftd.game.item.inventory : ItemId;
import minecraftd.network.game_protocol : GamePacketType, PacketReader,
    PacketWriter, PlayerActionType, PlayerInputCommand, encodeInput,
    inputAttack;
import minecraftd.server.integrated_game_server : IntegratedGameServer;
import minecraftd.world.block : BlockId;
import minecraftd.world.world_settings : GameMode, WorldSettings, WorldType;

void main()
{
    const directory = buildPath(tempDir(), "mcd-creative-smoke-"
        ~ randomUUID().toString());
    mkdirRecurse(directory);
    scope (exit) rmdirRecurse(directory);
    WorldSettings settings;
    settings.gameMode = GameMode.creative;
    settings.worldType = WorldType.flat;
    auto server = new IntegratedGameServer(settings, directory);
    scope (exit) destroy(server);
    auto client = new GameConnection("Builder", "127.0.0.1", server.port);
    scope (exit) destroy(client);

    uint playerId;
    bool hasOnlyPortalTestTool;
    foreach (_; 0 .. 150)
    {
        foreach (packet; client.poll())
        {
            PacketReader reader = PacketReader(packet.payload);
            if (packet.type == GamePacketType.loginAccepted)
            {
                reader.readU16();
                playerId = reader.readU32();
            }
            else if (packet.type == GamePacketType.snapshot)
            {
                reader.readU32(); reader.readU32(); reader.readBool();
                foreach (_player; 0 .. reader.readU16())
                {
                    const state = reader.readPlayer();
                    if (state.id != playerId) continue;
                    hasOnlyPortalTestTool =
                        state.inventory.hotbar[0].item == ItemId.flintAndSteel
                        && state.inventory.hotbar[0].count == 1;
                    foreach (index, stack; state.inventory.hotbar)
                        if (index != 0 && !stack.empty())
                            hasOnlyPortalTestTool = false;
                    foreach (stack; state.inventory.storage)
                        if (!stack.empty()) hasOnlyPortalTestTool = false;
                }
            }
        }
        if (playerId != 0 && hasOnlyPortalTestTool) break;
        Thread.sleep(20.msecs);
    }
    assert(playerId != 0 && hasOnlyPortalTestTool);

    // Aim at the grass ahead, then obtain it through middle-click's
    // authoritative Pick Block action.
    client.sendFramed(encodeInput(PlayerInputCommand(1, 0, 0, false,
        0.0f, 45.0f)));
    Thread.sleep(80.msecs);
    PacketWriter pick;
    pick.putU8(cast(ubyte) PlayerActionType.pickBlock);
    pick.putU8(0); pick.putU8(0);
    client.send(GamePacketType.playerAction, pick.data);
    bool pickedFullStack;
    foreach (_; 0 .. 100)
    {
        foreach (packet; client.poll())
        if (packet.type == GamePacketType.snapshot)
        {
            PacketReader reader = PacketReader(packet.payload);
            reader.readU32(); reader.readU32(); reader.readBool();
            foreach (_player; 0 .. reader.readU16())
            {
                const state = reader.readPlayer();
                if (state.id == playerId
                    && state.inventory.hotbar[state.selectedSlot].item
                        == ItemId.grassBlock
                    && state.inventory.hotbar[state.selectedSlot].count == 64)
                    pickedFullStack = true;
            }
        }
        if (pickedFullStack) break;
        Thread.sleep(20.msecs);
    }
    assert(pickedFullStack);

    // A fresh click destroys immediately, reports no crack progress, and
    // creates no dropped-item entity in Creative.
    client.sendFramed(encodeInput(PlayerInputCommand(2, inputAttack, 0, false,
        0.0f, 45.0f, true)));
    bool blockBroken;
    bool noCracking;
    bool dropSeen;
    foreach (_; 0 .. 100)
    {
        foreach (packet; client.poll())
        {
            PacketReader reader = PacketReader(packet.payload);
            if (packet.type == GamePacketType.blockChange)
            {
                reader.readI32(); reader.readI32(); reader.readI32();
                const oldBlock = cast(BlockId) reader.readU8();
                const newBlock = cast(BlockId) reader.readU8();
                if (oldBlock != BlockId.air && newBlock == BlockId.air)
                    blockBroken = true;
            }
            else if (packet.type == GamePacketType.snapshot)
            {
                reader.readU32(); reader.readU32(); reader.readBool();
                foreach (_player; 0 .. reader.readU16())
                {
                    const state = reader.readPlayer();
                    if (state.id == playerId)
                        noCracking = !state.mining
                            && state.miningProgress == 0.0f;
                }
                if (reader.readU16() != 0)
                    dropSeen = true;
            }
        }
        if (blockBroken && noCracking) break;
        Thread.sleep(20.msecs);
    }
    assert(blockBroken && noCracking && !dropSeen);

    bool brokeBeforeCooldown;
    foreach (sequence; 3 .. 8)
    {
        client.sendFramed(encodeInput(PlayerInputCommand(sequence,
            inputAttack, 0, false, 0.0f, 45.0f)));
        Thread.sleep(65.msecs);
        foreach (packet; client.poll())
        if (packet.type == GamePacketType.blockChange)
            brokeBeforeCooldown = true;
    }
    assert(!brokeBeforeCooldown);
    client.sendFramed(encodeInput(PlayerInputCommand(8, inputAttack, 0,
        false, 0.0f, 45.0f)));
    bool brokeAfterCooldown;
    foreach (_; 0 .. 50)
    {
        foreach (packet; client.poll())
        if (packet.type == GamePacketType.blockChange)
            brokeAfterCooldown = true;
        if (brokeAfterCooldown) break;
        Thread.sleep(20.msecs);
    }
    assert(brokeAfterCooldown);
    client.sendFramed(encodeInput(PlayerInputCommand(9, inputAttack, 0,
        false, 0.0f, 45.0f, true)));
    bool rapidClickBypassedHoldDelay;
    foreach (_; 0 .. 50)
    {
        foreach (packet; client.poll())
        if (packet.type == GamePacketType.blockChange)
            rapidClickBypassedHoldDelay = true;
        if (rapidClickBypassedHoldDelay) break;
        Thread.sleep(20.msecs);
    }
    assert(rapidClickBypassedHoldDelay);
    writeln("creative inventory, pick block, no cracks/drop, held cooldown, and rapid clicks passed");
}
