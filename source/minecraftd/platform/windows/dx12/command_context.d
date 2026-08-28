module minecraftd.platform.windows.dx12.command_context;

import core.sys.windows.windows : HRESULT, FAILED;
import std.format : format;

final class Dx12Exception : Exception
{
    this(string operation, HRESULT result)
    {
        super(format("%s failed (HRESULT 0x%08X)", operation, cast(uint) result));
    }

    this(string message)
    {
        super(message);
    }
}

void requireSuccess(HRESULT result, string operation)
{
    if (FAILED(result))
        throw new Dx12Exception(operation, result);
}
