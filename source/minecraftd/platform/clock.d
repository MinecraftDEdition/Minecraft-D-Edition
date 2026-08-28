module minecraftd.platform.clock;

import core.thread : Thread;
import core.time : MonoTime, msecs;

private __gshared MonoTime processClockStart;
private __gshared bool processClockStarted;

private MonoTime startTime()
{
    if (!processClockStarted)
    {
        processClockStart = MonoTime.currTime;
        processClockStarted = true;
    }
    return processClockStart;
}

double monotonicSeconds()
{
    return cast(double) (MonoTime.currTime - startTime()).total!"hnsecs"
        / 10_000_000.0;
}

uint monotonicMilliseconds()
{
    return cast(uint) ((MonoTime.currTime - startTime()).total!"msecs"
        & uint.max);
}

void sleepMilliseconds(uint milliseconds)
{
    if (milliseconds != 0)
        Thread.sleep(milliseconds.msecs);
}
