module app;

version (Windows):

import core.sys.windows.windows : MessageBoxW, MB_OK, MB_ICONERROR;
import core.thread : Thread;
import core.time : msecs;
import std.stdio : stderr, stdout;
import std.file : write;
import std.utf : toUTF16z;

import minecraftd.client.game_client : GameClient;
import minecraftd.client.network.eos_service : EosService, EosStatus;

int main(string[] arguments)
{
    try
    {
        if (arguments.length > 1 && arguments[1] == "--eos-smoke-test")
        {
            auto eos = new EosService("EOS-Smoke-Test");
            scope (exit) destroy(eos);
            foreach (_; 0 .. 300)
            {
                eos.tick();
                if (eos.status != EosStatus.initializing) break;
                Thread.sleep(50.msecs);
            }
            if (eos.ready)
            {
                stdout.writeln("EOS Connect login succeeded; P2P is ready.");
                return 0;
            }
            stderr.writeln(eos.error);
            return 1;
        }
        auto client = new GameClient();
        scope (exit) destroy(client);
        int localTestIndex;
        import std.conv : ConvException, to;
        import std.string : startsWith;
        foreach (argument; arguments[1 .. $])
        {
            enum prefix = "--local-test-client=";
            if (argument.startsWith(prefix))
            {
                try localTestIndex = to!int(argument[prefix.length .. $]);
                catch (ConvException) localTestIndex = 0;
            }
        }
        client.run(localTestIndex);
        return 0;
    }
    catch (Throwable failure)
    {
        const message = failure.toString();
        stderr.writeln(message);
        // Keep a persistent diagnostic for failures launched outside a console.
        write("last-error.log", message);
        MessageBoxW(null, message.toUTF16z(), "Minecraft D Edition"w.ptr, MB_OK | MB_ICONERROR);
        return 1;
    }
}
