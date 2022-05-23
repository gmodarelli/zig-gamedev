#define GAMMA 2.2

#include "common.hlsl"
#include "pbr.hlsl"
#include "ACES.hlsl"

#if defined(PSO__Z_PRE_PASS) || defined(PSO__Z_PRE_PASS_ALPHA_TESTED)

#define root_signature \
    "RootFlags(CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED), " \
    "RootConstants(b0, num32BitConstants = 2), " \
    "CBV(b1), " \
    "CBV(b2), " \
    "StaticSampler(s0, filter = FILTER_ANISOTROPIC, maxAnisotropy = 16, visibility = SHADER_VISIBILITY_PIXEL)"

struct DrawRootConst {
    uint vertex_offset;
    uint index_offset;
};

ConstantBuffer<DrawRootConst> cbv_draw_root : register(b0);
ConstantBuffer<FrameConst> cvb_frame_const : register(b1);
ConstantBuffer<DrawConst> cbv_draw_const : register(b2);
SamplerState sam_aniso : register(s0);

[RootSignature(root_signature)]
void vsZPrePass(
    uint vertex_id : SV_VertexID,
    out float4 out_position_clip : SV_Position,
    out float2 out_uv: TEXCOORD0
) {
    StructuredBuffer<float3> srv_position_buffer = ResourceDescriptorHeap[cvb_frame_const.position_buffer_index];
    StructuredBuffer<float2> srv_texcoord_buffer = ResourceDescriptorHeap[cvb_frame_const.texcoord_buffer_index];
    StructuredBuffer<float4x4> srv_transform_buffer = ResourceDescriptorHeap[cvb_frame_const.transform_buffer_index];
    Buffer<uint> srv_index_buffer = ResourceDescriptorHeap[cvb_frame_const.index_buffer_index];

    const uint vertex_index = srv_index_buffer[vertex_id + cbv_draw_root.index_offset] + cbv_draw_root.vertex_offset;
    const float3 position_os = srv_position_buffer[vertex_index];

    const float4x4 world_matrix = srv_transform_buffer[cbv_draw_const.transform_index];
    const float4x4 object_to_clip = mul(world_matrix, cvb_frame_const.view_proj);
    out_position_clip = mul(float4(position_os, 1.0), object_to_clip);
    out_uv = srv_texcoord_buffer[vertex_index];
}

[RootSignature(root_signature)]
void psZPrePass(
    float4 position_window : SV_Position,
    float2 uvs : TEXCOORD0
) {
#if defined(PSO__Z_PRE_PASS_ALPHA_TESTED)
    StructuredBuffer<Material> srv_material_buffer = ResourceDescriptorHeap[cvb_frame_const.material_buffer_index];
    Material material = srv_material_buffer[cbv_draw_const.material_index];

    if (material.base_color_tex_index < 0xffffffff) {
        Texture2D base_color_texture = ResourceDescriptorHeap[material.base_color_tex_index];
        float alpha = base_color_texture.Sample(sam_aniso, uvs).a;
        clip(alpha - material.alpha_cutoff);
    }
#endif
}

#elif defined(PSO__GEOMETRY_PASS) || defined(PSO__GEOMETRY_PASS_ALPHA_TESTED)

#define root_signature \
    "RootFlags(CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED), " \
    "RootConstants(b0, num32BitConstants = 2), " \
    "CBV(b1), " \
    "CBV(b2), " \
    "StaticSampler(s0, filter = FILTER_ANISOTROPIC, maxAnisotropy = 16, visibility = SHADER_VISIBILITY_PIXEL)"

struct DrawRootConst {
    uint vertex_offset;
    uint index_offset;
};

ConstantBuffer<DrawRootConst> cbv_draw_root : register(b0);
ConstantBuffer<FrameConst> cvb_frame_const : register(b1);
ConstantBuffer<DrawConst> cbv_draw_const : register(b2);
SamplerState sam_aniso : register(s0);

[RootSignature(root_signature)]
void vsGeometryPass(
    uint vertex_id : SV_VertexID,
    out float4 out_position_clip : SV_Position,
    out float2 out_uv : TEXCOORD0,
    out float3 out_normal : NORMAL,
    out float4 out_tangent : TANGENT
) {
    StructuredBuffer<float3> srv_position_buffer = ResourceDescriptorHeap[cvb_frame_const.position_buffer_index];
    StructuredBuffer<float3> srv_normal_buffer = ResourceDescriptorHeap[cvb_frame_const.normal_buffer_index];
    StructuredBuffer<float4> srv_tangent_buffer = ResourceDescriptorHeap[cvb_frame_const.tangent_buffer_index];
    StructuredBuffer<float2> srv_texcoord_buffer = ResourceDescriptorHeap[cvb_frame_const.texcoord_buffer_index];
    StructuredBuffer<float4x4> srv_transform_buffer = ResourceDescriptorHeap[cvb_frame_const.transform_buffer_index];
    Buffer<uint> srv_index_buffer = ResourceDescriptorHeap[cvb_frame_const.index_buffer_index];

    const uint vertex_index = srv_index_buffer[vertex_id + cbv_draw_root.index_offset] + cbv_draw_root.vertex_offset;
    const float3 position_os = srv_position_buffer[vertex_index];

    const float4x4 world_matrix = srv_transform_buffer[cbv_draw_const.transform_index];
    const float4x4 object_to_clip = mul(world_matrix, cvb_frame_const.view_proj);
    out_position_clip = mul(float4(position_os, 1.0), object_to_clip);
    
    out_uv = srv_texcoord_buffer[vertex_index];
    out_normal = srv_normal_buffer[vertex_index];
    out_tangent = srv_tangent_buffer[vertex_index];
}

[RootSignature(root_signature)]
void psGeometryPass(
    float4 position_window : SV_Position,
    float2 uvs : TEXCOORD0,
    float3 normal : NORMAL,
    float4 tangent : TANGENT,
    out float4 gbuffer0 : SV_Target0,
    out float4 gbuffer1 : SV_Target1,
    out float4 gbuffer2 : SV_Target2
) {
    StructuredBuffer<Material> srv_material_buffer = ResourceDescriptorHeap[cvb_frame_const.material_buffer_index];
    StructuredBuffer<float4x4> srv_transform_buffer = ResourceDescriptorHeap[cvb_frame_const.transform_buffer_index];
    Material material = srv_material_buffer[cbv_draw_const.material_index];

    float3 albedo = material.base_color;
    if (material.base_color_tex_index < 0xffffffff) {
        Texture2D base_color_texture = ResourceDescriptorHeap[material.base_color_tex_index];
        float4 base_color = base_color_texture.Sample(sam_aniso, uvs);
        base_color.rgb = sRGBToLinear(base_color.rgb);

#if defined(PSO__GEOMETRY_PASS_ALPHA_TESTED)
        clip(base_color.a - material.alpha_cutoff);
#endif
        // NOTE: I'm assuming colours stored in GLTF 2.0 are in linear space
        albedo *= base_color.rgb;
    }
    gbuffer0 = float4(albedo, 1.0);

    float3 n = float3(0.0, 1.0, 0.0);
    if (material.normal_tex_index < 0xffffffff) {
        Texture2D normal_texture = ResourceDescriptorHeap[material.normal_tex_index];
        n = normalize(normal_texture.Sample(sam_aniso, uvs).rgb * 2.0 - 1.0);
    }

    normal = normalize(normal);
    tangent.xyz = normalize(tangent.xyz);
    const float3 bitangent = normalize(cross(normal, tangent.xyz)) * tangent.w;

    const float3x3 world_matrix = (float3x3)srv_transform_buffer[cbv_draw_const.transform_index];

    n = mul(n, float3x3(tangent.xyz, bitangent, normal));
    n = normalize(mul(n, world_matrix));
    gbuffer1 = float4(n * 0.5 + 0.5, 1.0);

    float metallic = 0.0;
    float roughness = 0.5;
    if (material.metallic_roughness_tex_index < 0xffffffff) {
        Texture2D metallic_roughness_texture = ResourceDescriptorHeap[material.metallic_roughness_tex_index];
        const float2 mr = metallic_roughness_texture.Sample(sam_aniso, uvs).bg;
        metallic = mr.r;
        roughness = mr.g;
    }
    gbuffer2 = float4(metallic, roughness, 0.0, 1.0);
}

#elif defined(PSO__DEFERRED_COMPUTE_SHADING)

#define root_signature \
    "RootConstants(b0, num32BitConstants = 2), " \
    "CBV(b1), " \
    "DescriptorTable(SRV(t0, numDescriptors = 7), UAV(u0, numDescriptors = 1))"

struct DrawRootConst {
    uint screen_width;
    uint screen_height;
};

ConstantBuffer<DrawRootConst> cbv_root_const : register(b0);
ConstantBuffer<FrameConst> cvb_frame_const : register(b1);

Texture2D<float4> depth_texture : register(t0);
Texture2D<float4> gbuffer0 : register(t1);
Texture2D<float4> gbuffer1 : register(t2);
Texture2D<float4> gbuffer2 : register(t3);
StructuredBuffer<uint> light_index_list : register(t4);
Texture2D<uint2> light_grid : register(t5);
StructuredBuffer<Light> lights : register(t6);
RWTexture2D<float4> output : register(u0);

[RootSignature(root_signature)]
[numthreads(16, 16, 1)]
void csDeferredShading(uint3 dispatch_id : SV_DispatchThreadID) {
    float z = depth_texture.Load(uint3(dispatch_id.xy, 0)).r;
    float4 position_cs = float4(
        (dispatch_id.x / (float)cbv_root_const.screen_width) * 2.0 - 1.0,
        (1.0 - dispatch_id.y / (float)cbv_root_const.screen_height) * 2.0 - 1.0,
        z,
        1.0
    );
    float4 position_vs = mul(position_cs, cvb_frame_const.inv_proj);
    position_vs /= position_vs.w;
    // position_vs.xyz /= position_vs.w;
    // float3 position_ws = mul(cvb_frame_const.inv_view, position_vs).xyz;

    // Extract base color from Gbuffer
    float3 base_color = gbuffer0.Load(uint3(dispatch_id.xy, 0)).rgb;
    // Extract normal from Gbuffer
    float3 n = gbuffer1.Load(uint3(dispatch_id.xy, 0)).xyz * 2.0 - 1.0;
    float4 normal_vs = float4(mul(n, (float3x3)cvb_frame_const.view), 0);
    // Extract metalness and roughness from Gbuffer
    float2 data = gbuffer2.Load(uint3(dispatch_id.xy, 0)).rg;

    float4 eye_pos = float4(0, 0, 0, 1);
    PBRInput pbr_input = (PBRInput)0;
    pbr_input.v = normalize(eye_pos - position_vs);
    pbr_input.n = normal_vs;
    pbr_input.p = position_vs;
    pbr_input.metallic = data.r;
    pbr_input.roughness = data.g;

    // Get the index of the current pixel in the light grid
    uint2 tile_index = uint2(floor(dispatch_id.xy / BLOCK_SIZE));
    // Get the start position and offset of the light in the light index list
    uint start_offset = light_grid[tile_index].x;
    uint light_count = light_grid[tile_index].y;

    float3 lighting = 0.0;

    for (uint i = 0; i < light_count; i++) {
        uint light_index = light_index_list[start_offset + i];
        Light light = lights[light_index];
        lighting += calculateLighting(pbr_input, base_color, light);
    }

    output[dispatch_id.xy] = float4(lighting.rgb, 1.0);
}

#elif defined(PSO__POST_PROCESSING)

#define root_signature \
    "RootConstants(b0, num32BitConstants = 2), " \
    "CBV(b1), " \
    "DescriptorTable(SRV(t0, numDescriptors = 5), UAV(u0, numDescriptors = 1))"

struct DrawRootConst {
    uint screen_width;
    uint screen_height;
};

ConstantBuffer<DrawRootConst> cbv_root_const : register(b0);
ConstantBuffer<FrameConst> cvb_frame_const : register(b1);

Texture2D<float4> depth_texture : register(t0);
Texture2D<float4> gbuffer0 : register(t1);
Texture2D<float4> gbuffer1 : register(t2);
Texture2D<float4> gbuffer2 : register(t3);
Texture2D<float4> hdr : register(t4);
RWTexture2D<float4> output : register(u0);

[RootSignature(root_signature)]
[numthreads(16, 16, 1)]
void csPostProcessing(uint3 dispatch_id : SV_DispatchThreadID) {
}

#elif defined(PSO__FINAL_BLIT)

#define root_signature \
    "RootFlags(CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED), " \
    "RootConstants(b0, num32BitConstants = 3), " \
    "DescriptorTable(SRV(t0, numDescriptors = 5), visibility = SHADER_VISIBILITY_PIXEL), " \
    "StaticSampler(s0, filter = FILTER_ANISOTROPIC, maxAnisotropy = 16, visibility = SHADER_VISIBILITY_PIXEL)"

struct DrawRootConst {
    int view_mode;
    float znear;
    float zfar;
};

ConstantBuffer<DrawRootConst> cbv_draw_root : register(b0);
Texture2D srv_depth_texture : register(t0);
Texture2D srv_gbuffer0 : register(t1);
Texture2D srv_gbuffer1 : register(t2);
Texture2D srv_gbuffer2 : register(t3);
Texture2D srv_hdr : register(t4);
SamplerState sam_aniso : register(s0);

[RootSignature(root_signature)]
void vsDebugView(
    uint vertex_id : SV_VertexID,
    out float4 out_position_clip : SV_Position,
    out float2 uvs: TEXCOORD0
) {
    uvs = float2((vertex_id << 1) & 2, vertex_id & 2);
    out_position_clip = float4(uvs * float2(2, -2) + float2(-1, 1), 0, 1);
}

[RootSignature(root_signature)]
void psDebugView(
    float4 position_window : SV_Position,
    float2 uvs : TEXCOORD0,
    out float4 out_color : SV_Target0
) {
    if (cbv_draw_root.view_mode == 0) {
        float3 hdr_color = srv_hdr.Sample(sam_aniso, uvs).rgb;
        out_color.rgb = linearTosRGB(ACESFitted(hdr_color) * 1.8);
        out_color.a = 1;
    } else if (cbv_draw_root.view_mode == 1) {
        float depth = srv_depth_texture.Sample(sam_aniso, uvs).r;
        float linear_depth = (depth - cbv_draw_root.znear) / (cbv_draw_root.zfar - cbv_draw_root.znear);
        out_color = float4(depth.xxx, 1.0) ;
    } else if (cbv_draw_root.view_mode == 2) {
        float3 albedo = srv_gbuffer0.Sample(sam_aniso, uvs).rgb;
        out_color = float4(albedo, 1.0) ;
    } else if (cbv_draw_root.view_mode == 3) {
        float3 normal_ws = srv_gbuffer1.Sample(sam_aniso, uvs).rgb;
        out_color = float4(normal_ws, 1.0) ;
    } else if (cbv_draw_root.view_mode == 4) {
        float3 metalness = srv_gbuffer2.Sample(sam_aniso, uvs).rrr;
        out_color = float4(metalness, 1.0) ;
    } else if (cbv_draw_root.view_mode == 5) {
        float3 roughness = srv_gbuffer2.Sample(sam_aniso, uvs).ggg;
        out_color = float4(roughness, 1.0) ;
    }
}

#endif