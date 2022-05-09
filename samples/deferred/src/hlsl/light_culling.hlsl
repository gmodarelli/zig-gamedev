#include "common.hlsl"

// From: https://www.3dgep.com/forward-plus/
// =========================================
struct Light {
    float4 position_ws;     // position for point lights, direction for directional lights
    float4 radiance;        // xyz: radiance. w: intensity
    float radius;           // only used for point lights
    uint type;              // 0: directional, 1: point
    float2 _padding;
};

struct Plane {
    float3 normal;          // Plane normal
    float distance;         // Distance to origin
};

// Four planes of a view frustum (in view space).
// The planes are:
// - Left,
// - Right,
// - Top,
// - Botton.
// The back and/or front planes can be computed from depth values
// in the light culling compute shader.
struct Frustum {
    Plane planes[4];
};

// Compute a plane from 3 noncolinear points that form a triangle.
// This equation assumes a right-handed (counter-clockwise winding order)
// coordinate system to determine the direction of the plane normal.
Plane computePlane(float3 p0, float3 p1, float3 p2) {
    Plane plane;
    float3 v0 = p1 - p0;
    float3 v2 = p2 - p0;

    plane.normal = normalize(cross(v0, v2));

    // Compute the distance to the origin using p0.
    plane.distance = dot(plane.normal, p0);

    return plane;
}

#define BLOCK_SIZE 16

struct ComputeShaderInput {
    uint3 group_id              : SV_GroupID;
    uint3 group_thread_id       : SV_GroupThreadID;
    uint3 dispatch_thread_id    : SV_DispatchThreadID;
    uint  group_index           : SV_GroupIndex;
};

struct DispatchParams {
    uint4 num_thread_groups;
    uint4 num_threads;
};

struct DrawRootConst {
    uint screen_width;
    uint screen_height;
    uint frustums_buffer_index;
};

#if defined(PSO__LIGHTING_COMPUTE_FRUSTUMS)

#define root_signature \
    "RootConstants(b0, num32BitConstants = 3), " \
    "CBV(b1), " \
    "CBV(b2), " \
    "DescriptorTable(UAV(u0))"

ConstantBuffer<DrawRootConst> cbv_root_const : register(b0);
ConstantBuffer<FrameConst> cvb_frame_const : register(b1);
ConstantBuffer<DispatchParams> dispatch_params : register(b2);
RWStructuredBuffer<Frustum> frustums : register(u0);

// This kernels is executed once per grid cell.
// Each thread computes a frustum for a grid cell.
[RootSignature(root_signature)]
[numthreads(BLOCK_SIZE, BLOCK_SIZE, 1)]
void csComputeFrustum(ComputeShaderInput input)
{
    // View space eye position is always at the origin.
    const float3 eye_position = float3(0, 0, 0);

    // Compute the 4 corner points on the far clipping plane to use
    // as the frustum vertices.
    float4 screen_space[4];
    // Top left
    screen_space[0] = float4(input.dispatch_thread_id.xy * BLOCK_SIZE, -1.0f, 1.0f);
    // Top right
    screen_space[1] = float4(float2(input.dispatch_thread_id.x + 1, input.dispatch_thread_id.y) * BLOCK_SIZE, -1.0f, 1.0f);
    // Bottom left
    screen_space[2] = float4(float2(input.dispatch_thread_id.x, input.dispatch_thread_id.y + 1) * BLOCK_SIZE, -1.0f, 1.0f);
    // Bottom right
    screen_space[3] = float4(float2(input.dispatch_thread_id.x + 1, input.dispatch_thread_id.y + 1) * BLOCK_SIZE, -1.0f, 1.0f);

    // Convert screen position to view position
    float3 view_space[4];
    for (int i = 0; i < 4; i++)
    {
        float2 tex_coord = screen_space[i].xy / float2(cbv_root_const.screen_width, cbv_root_const.screen_height);
        float4 clip = float4(float2(tex_coord.x, 1.0f - tex_coord.y) * 2.0f - 1.0f, screen_space[i].z, screen_space[i].w);
        float4 view = mul(clip, cvb_frame_const.inv_proj);
        view /= view.w;
        view_space[i] = view.xyz;
    }

    // Build the frustum planes from the view space points
    Frustum frustum;
    // Left plane
    frustum.planes[0] = computePlane(eye_position, view_space[2], view_space[0]);
    // Right plane
    frustum.planes[1] = computePlane(eye_position, view_space[1], view_space[3]);
    // Top plane
    frustum.planes[2] = computePlane(eye_position, view_space[0], view_space[1]);
    // Bottom plane
    frustum.planes[3] = computePlane(eye_position, view_space[3], view_space[2]);

    // Store the computed frustum in global memory
    if (input.dispatch_thread_id.x < dispatch_params.num_threads.x && input.dispatch_thread_id.y < dispatch_params.num_threads.y)
    {
        uint index = input.dispatch_thread_id.x + (input.dispatch_thread_id.y * dispatch_params.num_threads.x);
        frustums[index] = frustum;
    }
}

#endif