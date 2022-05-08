#define GAMMA 2.2
#define PI 3.1415926

struct Material {
    float3 base_color;
    float roughness;

    float metallic;
    uint base_color_tex_index;
    uint metallic_roughness_tex_index;
    uint normal_tex_index;

    float alpha_cutoff;
    float3 _padding;
};

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

// TODO: Consider unifying this across all pipelines
struct SceneConst {
    float4x4 world_to_clip;
    uint position_buffer_index;
    uint index_buffer_index;
    uint texcoord_buffer_index;
    uint material_buffer_index;
};

// TODO: Consider unifying this across all pipelines
struct DrawConst {
    float4x4 object_to_world;
    uint material_index;
};

ConstantBuffer<DrawRootConst> cbv_draw_root : register(b0);
ConstantBuffer<SceneConst> cbv_scene_const : register(b1);
ConstantBuffer<DrawConst> cbv_draw_const : register(b2);
SamplerState sam_aniso : register(s0);

[RootSignature(root_signature)]
void vsZPrePass(
    uint vertex_id : SV_VertexID,
    out float4 out_position_clip : SV_Position,
    out float2 out_uv: TEXCOORD0
) {
    StructuredBuffer<float3> srv_position_buffer = ResourceDescriptorHeap[cbv_scene_const.position_buffer_index];
    StructuredBuffer<float2> srv_texcoord_buffer = ResourceDescriptorHeap[cbv_scene_const.texcoord_buffer_index];
    Buffer<uint> srv_index_buffer = ResourceDescriptorHeap[cbv_scene_const.index_buffer_index];

    const uint vertex_index = srv_index_buffer[vertex_id + cbv_draw_root.index_offset] + cbv_draw_root.vertex_offset;
    const float3 position_os = srv_position_buffer[vertex_index];

    const float4x4 object_to_clip = mul(cbv_draw_const.object_to_world, cbv_scene_const.world_to_clip);
    out_position_clip = mul(float4(position_os, 1.0), object_to_clip);
    out_uv = srv_texcoord_buffer[vertex_index];
}

[RootSignature(root_signature)]
void psZPrePass(
    float4 position_window : SV_Position,
    float2 uvs : TEXCOORD0
) {
#if defined(PSO__Z_PRE_PASS_ALPHA_TESTED)
    StructuredBuffer<Material> srv_material_buffer = ResourceDescriptorHeap[cbv_scene_const.material_buffer_index];
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

struct SceneConst {
    float4x4 world_to_clip;
    uint position_buffer_index;
    uint normal_buffer_index;
    uint texcoord_buffer_index;
    uint tangent_buffer_index;
    uint index_buffer_index;
    uint material_buffer_index;
};

struct DrawConst {
    float4x4 object_to_world;
    uint material_index;
};

ConstantBuffer<DrawRootConst> cbv_draw_root : register(b0);
ConstantBuffer<SceneConst> cbv_scene_const : register(b1);
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
    StructuredBuffer<float3> srv_position_buffer = ResourceDescriptorHeap[cbv_scene_const.position_buffer_index];
    StructuredBuffer<float3> srv_normal_buffer = ResourceDescriptorHeap[cbv_scene_const.normal_buffer_index];
    StructuredBuffer<float4> srv_tangent_buffer = ResourceDescriptorHeap[cbv_scene_const.tangent_buffer_index];
    StructuredBuffer<float2> srv_texcoord_buffer = ResourceDescriptorHeap[cbv_scene_const.texcoord_buffer_index];
    Buffer<uint> srv_index_buffer = ResourceDescriptorHeap[cbv_scene_const.index_buffer_index];

    const uint vertex_index = srv_index_buffer[vertex_id + cbv_draw_root.index_offset] + cbv_draw_root.vertex_offset;
    const float3 position_os = srv_position_buffer[vertex_index];

    const float4x4 object_to_clip = mul(cbv_draw_const.object_to_world, cbv_scene_const.world_to_clip);
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
    StructuredBuffer<Material> srv_material_buffer = ResourceDescriptorHeap[cbv_scene_const.material_buffer_index];
    Material material = srv_material_buffer[cbv_draw_const.material_index];

    float3 albedo = material.base_color;
    if (material.base_color_tex_index < 0xffffffff) {
        Texture2D base_color_texture = ResourceDescriptorHeap[material.base_color_tex_index];
        float4 base_color = base_color_texture.Sample(sam_aniso, uvs);

#if defined(PSO__GEOMETRY_PASS_ALPHA_TESTED)
        clip(base_color.a - material.alpha_cutoff);
#endif
        albedo *= pow(base_color.rgb, GAMMA);
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

    const float3x3 object_to_world = (float3x3)cbv_draw_const.object_to_world;

    n = mul(n, float3x3(tangent.xyz, bitangent, normal));
    n = normalize(mul(n, object_to_world));
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
    "DescriptorTable(SRV(t0, numDescriptors = 4), UAV(u0, numDescriptors = 1))"

struct DrawRootConst {
    uint screen_width;
    uint screen_height;
};

struct Light {
    float4 position_ws;     // position for point lights, direction for directional lights
    float4 radiance;        // xyz: radiance. w: intensity
    float radius;           // only used for point lights
    uint type;              // 0: directional, 1: point
    float2 _padding;
};

struct SceneConst {
    float4x4 inverse_projection;
    float4x4 inverse_view;
    float3 camera_position;
    float padding;
};

ConstantBuffer<DrawRootConst> cbv_root_const : register(b0);
ConstantBuffer<SceneConst> cbv_scene_const : register(b1);

Texture2D<float4> depth_texture : register(t0);
Texture2D<float4> gbuffer0 : register(t1);
Texture2D<float4> gbuffer1 : register(t2);
Texture2D<float4> gbuffer2 : register(t3);
RWTexture2D<float4> output : register(u0);

float3 fresnelSchlick(float cos_theta, float3 f0) {
    return saturate(f0 + (1.0 - f0) * pow(1.0 - cos_theta, 5.0));
}

float distributionGgx(float3 n, float3 h, float roughness) {
    float alpha = roughness * roughness;
    float alpha_sq = alpha * alpha;
    float n_dot_h = dot(n, h);
    float n_dot_h_sq = n_dot_h * n_dot_h;
    float k = n_dot_h_sq * alpha_sq + (1.0 - n_dot_h_sq);
    return alpha_sq / (PI * k * k);
}

float geometrySchlickGgx(float cos_theta, float roughness) {
    float k = (roughness * roughness) * 0.5;
    return cos_theta / (cos_theta * (1.0 - k) + k);
}

// Geometry function returns probability [0.0, 1.0].
float geometrySmith(float n_dot_l, float n_dot_v, float roughness) {
    return saturate(geometrySchlickGgx(n_dot_v, roughness) * geometrySchlickGgx(n_dot_l, roughness));
}

[RootSignature(root_signature)]
[numthreads(16, 16, 1)]
void csDeferredShading(uint3 dispatch_id : SV_DispatchThreadID) {
    float z = depth_texture.Load(uint3(dispatch_id.xy, 0)).r;
    float4 position_cs = float4(
        (dispatch_id.x / cbv_root_const.screen_width) * 2.0 - 1.0,
        (dispatch_id.y / cbv_root_const.screen_height) * 2.0 - 1.0,
        z,
        1.0
    );
    float4 position_vs = mul(position_cs, cbv_scene_const.inverse_projection);
    position_vs /= position_vs.w;
    float3 position_ws = mul(position_vs, cbv_scene_const.inverse_view).xyz;

    // Extract base color from Gbuffer
    float3 base_color = gbuffer0.Load(uint3(dispatch_id.xy, 0)).rgb;
    // Extract normal from Gbuffer
    float3 n = gbuffer1.Load(uint3(dispatch_id.xy, 0)).xyz * 2.0 - 1.0;
    // Extract metalness and roughness from Gbuffer
    float2 data = gbuffer2.Load(uint3(dispatch_id.xy, 0)).rg;
    float metalness = data.r;
    float roughness = data.g;

    const float3 v = normalize(cbv_scene_const.camera_position - position_ws);
    const float n_dot_v = saturate(dot(n, v));

    float3 f0 = float3(0.04, 0.04, 0.04);
    f0 = lerp(f0, base_color, metalness);

    float3 lo = 0.0;

    // Light contribution
    const float3 l_radiance = float3(70.0, 70.0, 50.0);
    const float3 l = float3(0.0, -1.0, 0.0);

    float3 h = normalize(l + v);
    float n_dot_l = saturate(dot(n, l));
    float h_dot_v = saturate(dot(h, v));
    float3 radiance = l_radiance;

    float3 f = fresnelSchlick(h_dot_v, f0);
    float nd = distributionGgx(n, h, roughness);
    float g = geometrySmith(n_dot_l, n_dot_v, (roughness + 1.0) * 0.5);

    float3 specular = (nd * g * f) / max(4.0 * n_dot_v * n_dot_l, 0.001);
    float3 kd = (1.0 - f) * (1.0 - metalness);
    lo += (kd * (base_color / PI) + specular) * radiance * n_dot_l;

    output[dispatch_id.xy] = float4(lo, 1.0);
}

#elif defined(PSO__DEBUG_VIEW)

#define root_signature \
    "RootFlags(CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED), " \
    "RootConstants(b0, num32BitConstants = 3), " \
    "DescriptorTable(SRV(t0, numDescriptors = 4), visibility = SHADER_VISIBILITY_PIXEL), " \
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
        out_color = float4(uvs, 0.0, 1.0);
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