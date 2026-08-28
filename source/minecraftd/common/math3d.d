module minecraftd.common.math3d;

import core.stdc.math : sqrtf, sinf, cosf, tanf;

enum float PI = 3.14159265358979323846f;
enum float DEG_TO_RAD = PI / 180.0f;

struct Vec2
{
    float x = 0.0f;
    float y = 0.0f;
}

struct Vec3
{
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;

    Vec3 opBinary(string op)(Vec3 rhs) const
    if (op == "+" || op == "-")
    {
        static if (op == "+") return Vec3(x + rhs.x, y + rhs.y, z + rhs.z);
        else return Vec3(x - rhs.x, y - rhs.y, z - rhs.z);
    }

    Vec3 opBinary(string op)(float scalar) const
    if (op == "*" || op == "/")
    {
        static if (op == "*") return Vec3(x * scalar, y * scalar, z * scalar);
        else return Vec3(x / scalar, y / scalar, z / scalar);
    }

    Vec3 opBinaryRight(string op)(float scalar) const if (op == "*")
    {
        return this * scalar;
    }

    ref Vec3 opOpAssign(string op)(Vec3 rhs)
    if (op == "+" || op == "-")
    {
        static if (op == "+") { x += rhs.x; y += rhs.y; z += rhs.z; }
        else { x -= rhs.x; y -= rhs.y; z -= rhs.z; }
        return this;
    }

    float lengthSquared() const { return x * x + y * y + z * z; }
    float length() const { return sqrtf(lengthSquared()); }
    float horizontalLength() const { return sqrtf(x * x + z * z); }

    Vec3 normalized() const
    {
        const value = length();
        return value > 0.000001f ? this / value : Vec3.init;
    }
}

float dot(Vec3 a, Vec3 b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vec3 cross(Vec3 a, Vec3 b)
{
    return Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    );
}

float clamp(float value, float low, float high)
{
    return value < low ? low : (value > high ? high : value);
}

float lerp(float amount, float from, float to)
{
    return from + (to - from) * amount;
}

struct Mat4
{
    // Row-major storage and row-vector multiplication, matching mul(v, M) in HLSL.
    float[16] m;

    static Mat4 identity()
    {
        Mat4 result;
        result.m[] = 0.0f;
        result.m[0] = result.m[5] = result.m[10] = result.m[15] = 1.0f;
        return result;
    }

    static Mat4 translation(Vec3 value)
    {
        auto result = identity();
        result.m[12] = value.x;
        result.m[13] = value.y;
        result.m[14] = value.z;
        return result;
    }

    static Mat4 scale(Vec3 value)
    {
        Mat4 result;
        result.m[] = 0.0f;
        result.m[0] = value.x;
        result.m[5] = value.y;
        result.m[10] = value.z;
        result.m[15] = 1.0f;
        return result;
    }

    static Mat4 rotationX(float radians)
    {
        auto result = identity();
        const c = cosf(radians);
        const s = sinf(radians);
        result.m[5] = c;
        result.m[6] = s;
        result.m[9] = -s;
        result.m[10] = c;
        return result;
    }

    static Mat4 rotationY(float radians)
    {
        auto result = identity();
        const c = cosf(radians);
        const s = sinf(radians);
        result.m[0] = c;
        result.m[2] = -s;
        result.m[8] = s;
        result.m[10] = c;
        return result;
    }

    static Mat4 rotationZ(float radians)
    {
        auto result = identity();
        const c = cosf(radians);
        const s = sinf(radians);
        result.m[0] = c;
        result.m[1] = s;
        result.m[4] = -s;
        result.m[5] = c;
        return result;
    }

    static Mat4 rotationAxis(Vec3 requestedAxis,float radians)
    {
        const axis=requestedAxis.normalized();
        const c=cosf(radians);
        const s=sinf(radians);
        const t=1.0f-c;
        auto result=identity();
        result.m[0]=t*axis.x*axis.x+c;
        result.m[1]=t*axis.x*axis.y+s*axis.z;
        result.m[2]=t*axis.x*axis.z-s*axis.y;
        result.m[4]=t*axis.x*axis.y-s*axis.z;
        result.m[5]=t*axis.y*axis.y+c;
        result.m[6]=t*axis.y*axis.z+s*axis.x;
        result.m[8]=t*axis.x*axis.z+s*axis.y;
        result.m[9]=t*axis.y*axis.z-s*axis.x;
        result.m[10]=t*axis.z*axis.z+c;
        return result;
    }

    Mat4 opBinary(string op)(const Mat4 rhs) const if (op == "*")
    {
        Mat4 result;
        foreach (row; 0 .. 4)
        {
            foreach (column; 0 .. 4)
            {
                float value = 0.0f;
                foreach (k; 0 .. 4)
                    value += m[row * 4 + k] * rhs.m[k * 4 + column];
                result.m[row * 4 + column] = value;
            }
        }
        return result;
    }

    Vec3 transformPoint(Vec3 point) const
    {
        return Vec3(
            point.x * m[0] + point.y * m[4] + point.z * m[8] + m[12],
            point.x * m[1] + point.y * m[5] + point.z * m[9] + m[13],
            point.x * m[2] + point.y * m[6] + point.z * m[10] + m[14],
        );
    }
}

Mat4 lookToLH(Vec3 eye, Vec3 direction, Vec3 up)
{
    const zAxis = direction.normalized();
    const xAxis = cross(up, zAxis).normalized();
    const yAxis = cross(zAxis, xAxis);

    Mat4 result = Mat4.identity();
    result.m[0] = xAxis.x; result.m[1] = yAxis.x; result.m[2] = zAxis.x;
    result.m[4] = xAxis.y; result.m[5] = yAxis.y; result.m[6] = zAxis.y;
    result.m[8] = xAxis.z; result.m[9] = yAxis.z; result.m[10] = zAxis.z;
    result.m[12] = -dot(xAxis, eye);
    result.m[13] = -dot(yAxis, eye);
    result.m[14] = -dot(zAxis, eye);
    return result;
}

Mat4 perspectiveFovLH(float fovRadians, float aspect, float nearPlane, float farPlane)
{
    Mat4 result;
    result.m[] = 0.0f;
    const yScale = 1.0f / tanf(fovRadians * 0.5f);
    const xScale = yScale / aspect;
    result.m[0] = xScale;
    result.m[5] = yScale;
    result.m[10] = farPlane / (farPlane - nearPlane);
    result.m[11] = 1.0f;
    result.m[14] = -nearPlane * farPlane / (farPlane - nearPlane);
    return result;
}

Vec3 forwardFromYawPitch(float yawDegrees, float pitchDegrees)
{
    const yaw = yawDegrees * DEG_TO_RAD;
    const pitch = pitchDegrees * DEG_TO_RAD;
    const cp = cosf(pitch);
    return Vec3(sinf(yaw) * cp, -sinf(pitch), cosf(yaw) * cp).normalized();
}
