#include "common.hlsl"

// From: https://www.3dgep.com/forward-plus/
// =========================================
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
    screen_space[0] = float4(input.dispatch_thread_id.xy * BLOCK_SIZE, 1.0f, 1.0f);
    // Top right
    screen_space[1] = float4(float2(input.dispatch_thread_id.x + 1, input.dispatch_thread_id.y) * BLOCK_SIZE, 1.0f, 1.0f);
    // Bottom left
    screen_space[2] = float4(float2(input.dispatch_thread_id.x, input.dispatch_thread_id.y + 1) * BLOCK_SIZE, 1.0f, 1.0f);
    // Bottom right
    screen_space[3] = float4(float2(input.dispatch_thread_id.x + 1, input.dispatch_thread_id.y + 1) * BLOCK_SIZE, 1.0f, 1.0f);

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

#elif defined(PSO__COMPUTE_CLEAR_BUFFERS)

#define root_signature \
    "RootConstants(b0, num32BitConstants = 2), " \
    "CBV(b1), " \
    "CBV(b2), " \
    "DescriptorTable(UAV(u0, numDescriptors = 3))"

ConstantBuffer<DrawRootConst> cbv_root_const : register(b0);
ConstantBuffer<FrameConst> cvb_frame_const : register(b1);
ConstantBuffer<DispatchParams> dispatch_params : register(b2);

RWStructuredBuffer<uint> light_index_counter : register(u0);
RWStructuredBuffer<uint> light_index_list : register(u1);
RWTexture2D<uint2> light_grid : register(u2);

[RootSignature(root_signature)]
[numthreads(1, 1, 1)]
void csClearBuffers(ComputeShaderInput input)
{
    light_index_counter[0] = 0;

    for (uint i = 0; i < NUM_LIGHTS; i++) {
        light_index_list[i] = 0;
    }

    for (uint x = 0; x < dispatch_params.num_thread_groups.x; x++) {
        for (uint y = 0; y < dispatch_params.num_thread_groups.y; y++) {
            light_grid[uint2(x, y)] = uint2(0, 0);
        }
    }
}

#elif defined(PSO__COMPUTE_LIGHT_CULLING)

#define root_signature \
    "RootConstants(b0, num32BitConstants = 2), " \
    "CBV(b1), " \
    "CBV(b2), " \
    "DescriptorTable(SRV(t0, numDescriptors = 3), UAV(u0, numDescriptors = 3))"

ConstantBuffer<DrawRootConst> cbv_root_const : register(b0);
ConstantBuffer<FrameConst> cvb_frame_const : register(b1);
ConstantBuffer<DispatchParams> dispatch_params : register(b2);

Texture2D<float4> depth_texture : register(t0);
StructuredBuffer<Frustum> frustums : register(t1);
StructuredBuffer<Light> lights : register(t2);
RWStructuredBuffer<uint> light_index_counter : register(u0);
RWStructuredBuffer<uint> light_index_list : register(u1);
RWTexture2D<uint2> light_grid : register(u2);


// Shared by a thread group
groupshared uint u_min_depth;
groupshared uint u_max_depth;
groupshared Frustum group_frustum;

groupshared uint light_count;
groupshared uint light_index_start_offset;
groupshared uint light_list[MAX_LIGHT_PER_TILE];

void append_light(uint light_index) {
    uint index; // Index into the visible lights array.
    InterlockedAdd(light_count, 1, index);
    if (index < MAX_LIGHT_PER_TILE) {
        light_list[index] = light_index;
    }
}

[RootSignature(root_signature)]
[numthreads(BLOCK_SIZE, BLOCK_SIZE, 1)]
void csLightCulling(ComputeShaderInput input)
{
    // Calculate min and max depth in threadgroup (tile)
    int2 tex_coord = input.dispatch_thread_id.xy;
    float fdepth = depth_texture.Load(int3(tex_coord, 0)).r;

    // We can only perform atomic operations on int and uint, so we
    // reinterpred depth as uint
    uint udepth = asuint(fdepth);

    // Avoid contention by other threads in the group.
    if (input.group_index == 0) {
        u_min_depth = 0xffffffff;
        u_max_depth = 0;
        light_count = 0;
        group_frustum = frustums[input.group_id.x + (input.group_id.y * dispatch_params.num_thread_groups.x)];
    }

    GroupMemoryBarrierWithGroupSync();

    InterlockedMin(u_min_depth, udepth);
    InterlockedMax(u_max_depth, udepth);

    GroupMemoryBarrierWithGroupSync();

    float f_min_depth = asfloat(u_min_depth);
    float f_max_depth = asfloat(u_max_depth);

    // Convert depth values to view space.
    float2 screen = float2(cbv_root_const.screen_width, cbv_root_const.screen_height);
    float min_depth_vs = screenToView(cvb_frame_const.inv_proj, screen, float4(0, 0, f_min_depth, 1)).z;
    float max_depth_vs = screenToView(cvb_frame_const.inv_proj, screen, float4(0, 0, f_max_depth, 1)).z;
    float near_clip_vs = screenToView(cvb_frame_const.inv_proj, screen, float4(0, 0, 0, 1)).z;

    // Clipping plane for minimum depth value
    Plane min_plane = { float3(0, 0, 1), min_depth_vs };

    // Cull lights
    // Each thread in a group will cull 1 light until all lights have been culled.
    for (uint i = input.group_index; i < NUM_LIGHTS; i += BLOCK_SIZE * BLOCK_SIZE) {
        if (lights[i].enabled) {
            Light light = lights[i];
            switch (light.type) {
                case 0: // Directional
                    append_light(i);
                    break;
                case 1: // Point
                {
                    float3 position_vs = mul(cvb_frame_const.view, light.position_ws).xyz;
                    Sphere sphere = { position_vs, light.radius };
                    if (sphereInsideFrustum(sphere, group_frustum, near_clip_vs, max_depth_vs)) {
                        if (!sphereInsidePlane(sphere, min_plane)) {
                            append_light(i);
                        }
                    }
                }
                break;
            }
        }
    }

    // Wait until all threads in the group have caught up.
    GroupMemoryBarrierWithGroupSync();

    // Update global memroy with visible light buffer.
    // First update the light grid (only thread 0 in group needs to do this)
    if (input.group_index == 0) {
        InterlockedAdd(light_index_counter[0], light_count, light_index_start_offset);
        light_grid[input.group_id.xy] = uint2(light_index_start_offset, light_count);
    }

    GroupMemoryBarrierWithGroupSync();

    for (i = input.group_index; i < light_count; i += BLOCK_SIZE * BLOCK_SIZE) {
        light_index_list[light_index_start_offset + i] = light_list[i];
    }
}

#endif