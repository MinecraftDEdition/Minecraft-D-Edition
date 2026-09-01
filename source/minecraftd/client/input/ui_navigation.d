module minecraftd.client.input.ui_navigation;

import std.algorithm : min;
import std.math : abs;

import minecraftd.platform.input : GamepadButton, GamepadState, Point;

alias UiHitTest = int delegate(int x, int y);

enum UiDirection : ubyte
{
    none,
    up,
    down,
    left,
    right,
}

private struct TargetBounds
{
    int id;
    int minX;
    int minY;
    int maxX;
    int maxY;

    Point center() const
    {
        Point result;
        result.x = (minX + maxX) / 2;
        result.y = (minY + maxY) / 2;
        return result;
    }
}

/// Controller UI focus which is deliberately independent from the OS mouse.
/// Renderers continue receiving a point for their existing hover/highlight
/// paths, but the point jumps between widget centers and never warps a cursor.
struct UiNavigation
{
    private bool controllerMode;
    private bool mouseInitialized;
    private Point previousMouse;
    private ulong screenToken = ulong.max;
    private TargetBounds[] targets;
    private int focusedIndex = -1;
    private UiDirection heldDirection;
    private uint nextRepeatAt;

    bool usingController() const { return controllerMode; }

    void observe(Point mouse, GamepadState gamepad, bool observeMouse = true)
    {
        bool mouseMoved;
        if (!mouseInitialized)
        {
            previousMouse = mouse;
            mouseInitialized = true;
        }
        else if (observeMouse)
            mouseMoved = mouse.x != previousMouse.x || mouse.y != previousMouse.y;
        previousMouse = mouse;

        const controllerUsed = gamepad.pressedButtons != 0
            || gamepad.leftTriggerPressed || gamepad.rightTriggerPressed
            || gamepad.hasStickActivity(0.32f);
        if (mouseMoved)
            controllerMode = false;
        if (controllerUsed)
            controllerMode = true;
    }

    void prepare(ulong token, int noneValue, UiHitTest hitTest,
        int width, int height)
    {
        if (!controllerMode)
            return;
        if (screenToken == token && targets.length)
            return;
        screenToken = token;
        targets = discoverTargets(noneValue, hitTest, width, height);
        focusedIndex = nearestToCenter(targets, width, height);
        heldDirection = UiDirection.none;
        nextRepeatAt = 0;
    }

    UiDirection takeDirection(GamepadState gamepad, uint nowMilliseconds)
    {
        if (!controllerMode)
            return UiDirection.none;
        UiDirection direction;
        if (gamepad.down(GamepadButton.dpadUp)) direction = UiDirection.up;
        else if (gamepad.down(GamepadButton.dpadDown)) direction = UiDirection.down;
        else if (gamepad.down(GamepadButton.dpadLeft)) direction = UiDirection.left;
        else if (gamepad.down(GamepadButton.dpadRight)) direction = UiDirection.right;
        else if (abs(gamepad.leftY) >= abs(gamepad.leftX)
            && gamepad.leftY > 0.55f) direction = UiDirection.up;
        else if (abs(gamepad.leftY) >= abs(gamepad.leftX)
            && gamepad.leftY < -0.55f) direction = UiDirection.down;
        else if (gamepad.leftX < -0.55f) direction = UiDirection.left;
        else if (gamepad.leftX > 0.55f) direction = UiDirection.right;

        if (direction == UiDirection.none)
        {
            heldDirection = UiDirection.none;
            nextRepeatAt = 0;
            return direction;
        }
        if (direction != heldDirection)
        {
            heldDirection = direction;
            nextRepeatAt = nowMilliseconds + 360;
            return direction;
        }
        if (nowMilliseconds >= nextRepeatAt)
        {
            nextRepeatAt = nowMilliseconds + 115;
            return direction;
        }
        return UiDirection.none;
    }

    void move(UiDirection direction)
    {
        if (direction == UiDirection.none || focusedIndex < 0
            || focusedIndex >= targets.length)
            return;
        const origin = targets[focusedIndex].center;
        int best = -1;
        float bestScore = float.max;
        foreach (index, target; targets)
        {
            if (cast(int)index == focusedIndex)
                continue;
            const candidate = target.center;
            const dx = cast(float)(candidate.x - origin.x);
            const dy = cast(float)(candidate.y - origin.y);
            float primary;
            float secondary;
            final switch (direction)
            {
                case UiDirection.up:
                    if (dy >= -2) continue;
                    primary = -dy; secondary = abs(dx); break;
                case UiDirection.down:
                    if (dy <= 2) continue;
                    primary = dy; secondary = abs(dx); break;
                case UiDirection.left:
                    if (dx >= -2) continue;
                    primary = -dx; secondary = abs(dy); break;
                case UiDirection.right:
                    if (dx <= 2) continue;
                    primary = dx; secondary = abs(dy); break;
                case UiDirection.none:
                    return;
            }
            const score = primary + secondary * 2.5f;
            if (score < bestScore)
            {
                bestScore = score;
                best = cast(int)index;
            }
        }
        if (best >= 0)
            focusedIndex = best;
    }

    Point cursor(Point mouse) const
    {
        if (!controllerMode || focusedIndex < 0 || focusedIndex >= targets.length)
            return mouse;
        return targets[focusedIndex].center;
    }

    int focusedId() const
    {
        return focusedIndex >= 0 && focusedIndex < targets.length
            ? targets[focusedIndex].id : int.min;
    }
}

private TargetBounds[] discoverTargets(int noneValue, UiHitTest hitTest,
    int width, int height)
{
    TargetBounds[int] discovered;
    const sampleStep = min(18, width > 0 && height > 0
        ? (width < height ? width : height) / 70 + 4 : 8);
    for (int y = sampleStep / 2; y < height; y += sampleStep)
    for (int x = sampleStep / 2; x < width; x += sampleStep)
    {
        const id = hitTest(x, y);
        if (id == noneValue)
            continue;
        if (auto existing = id in discovered)
        {
            if (x < existing.minX) existing.minX = x;
            if (y < existing.minY) existing.minY = y;
            if (x > existing.maxX) existing.maxX = x;
            if (y > existing.maxY) existing.maxY = y;
        }
        else
            discovered[id] = TargetBounds(id, x, y, x, y);
    }
    TargetBounds[] result;
    foreach (target; discovered)
        result ~= target;
    return result;
}

private int nearestToCenter(const TargetBounds[] targets, int width, int height)
{
    int result = -1;
    long best = long.max;
    foreach (index, target; targets)
    {
        const center = target.center;
        const dx = center.x - width / 2;
        const dy = center.y - height / 2;
        const distance = cast(long)dx * dx + cast(long)dy * dy;
        if (distance < best)
        {
            best = distance;
            result = cast(int)index;
        }
    }
    return result;
}

unittest
{
    int hit(int x, int y)
    {
        if (x >= 20 && x < 80 && y >= 20 && y < 50) return 1;
        if (x >= 20 && x < 80 && y >= 70 && y < 100) return 2;
        return 0;
    }
    UiNavigation navigation;
    Point mouse;
    GamepadState gamepad;
    gamepad.connected = true;
    gamepad.pressedButtons = cast(ushort)GamepadButton.a;
    navigation.observe(mouse, gamepad);
    navigation.prepare(1, 0, &hit, 100, 100);
    assert(navigation.usingController && navigation.focusedId == 1);
    navigation.move(UiDirection.down);
    assert(navigation.focusedId == 2);
    mouse.x = 5;
    navigation.observe(mouse, GamepadState.init);
    assert(!navigation.usingController);
}
