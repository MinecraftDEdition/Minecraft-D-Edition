module minecraftd.platform.clock;

import core.thread : Thread;
import core.time : MonoTime, msecs;

version(Windows)
{
    pragma(lib,"winmm");
    private extern(Windows) uint timeBeginPeriod(uint period);
    private extern(Windows) uint timeEndPeriod(uint period);

    shared static this(){timeBeginPeriod(1);}
    shared static ~this(){timeEndPeriod(1);}
}

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

/// Sleeps most of a frame budget, then yields through its short tail. A plain
/// millisecond sleep can overshoot high-refresh deadlines by an entire OS
/// scheduler quantum, making a 260 fps cap behave like a 50-60 fps cap.
void sleepUntilSeconds(double deadline)
{
    for(;;)
    {
        const remaining=deadline-monotonicSeconds();
        if(remaining<=0)return;
        if(remaining>0.002)
        {
            const coarse=cast(uint)((remaining-0.001)*1000.0);
            if(coarse>0)Thread.sleep(coarse.msecs);
            else Thread.yield();
        }
        else Thread.yield();
    }
}
