module app;

import core.thread : Thread;
import core.time : msecs;
import std.file : write;
import std.path : buildPath;

import minecraftd.client.game_client : GameClient;
import minecraftd.client.network.eos_service : EosService, EosStatus;
import minecraftd.platform.dialog : showFatalError;
import minecraftd.platform.paths : platformPaths;

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
                write("eos-smoke-test.log",
                    "EOS Connect login succeeded; P2P is ready.\n");
                return 0;
            }
            write("eos-smoke-test.log", eos.error ~ "\n");
            return 1;
        }
        auto client = new GameClient();
        scope (exit) destroy(client);
        int localTestIndex;
        string rendererOverride;
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
            enum rendererPrefix = "--renderer=";
            if (argument.startsWith(rendererPrefix))
            {
                const requested = argument[rendererPrefix.length .. $];
                if (requested == "dx12" || requested == "vulkan")
                    rendererOverride = requested.idup;
            }
        }
        client.run(localTestIndex, rendererOverride);
        return 0;
    }
    catch (Throwable failure)
    {
        const message = failure.toString();
        // Keep a persistent diagnostic for failures launched outside a console.
        const paths = platformPaths();
        write(buildPath(paths.userData, "last-error.log"), message);
        showFatalError("Minecraft D Edition", message);
        return 1;
    }
}
