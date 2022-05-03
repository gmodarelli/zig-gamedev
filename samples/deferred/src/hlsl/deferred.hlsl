#if defined(PSO__Z_PRE_PASS)

#define root_signature \
    "RootFlags(CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED), " \
    "RootConstants(b0, num32BitConstants = 2), " \
    "CBV(b1), " \
    "CBV(b2)"

struct DrawRootConst {
    uint vertex_offset;
    uint index_offset;
};

struct SceneConst {
    float4x4 world_to_clip;
    uint position_buffer_index;
    uint index_buffer_index;
};

struct DrawConst {
    float4x4 object_to_world;
};

ConstantBuffer<DrawRootConst> cbv_draw_root : register(b0);
ConstantBuffer<SceneConst> cbv_scene_const : register(b1);
ConstantBuffer<DrawConst> cbv_draw_const : register(b2);

[RootSignature(root_signature)]
void vsZPrePass(
    uint vertex_id : SV_VertexID,
    out float4 out_position_clip : SV_Position
) {
    StructuredBuffer<float3> srv_position_buffer = ResourceDescriptorHeap[cbv_scene_const.position_buffer_index];
    Buffer<uint> srv_index_buffer = ResourceDescriptorHeap[cbv_scene_const.index_buffer_index];

    const uint vertex_index = srv_index_buffer[vertex_id + cbv_draw_root.index_offset] + cbv_draw_root.vertex_offset;
    const float3 position_os = srv_position_buffer[vertex_index];

    const float4x4 object_to_clip = mul(cbv_draw_const.object_to_world, cbv_scene_const.world_to_clip);
    out_position_clip = mul(float4(position_os, 1.0), object_to_clip);
}

[RootSignature(root_signature)]
void psZPrePass(
    float4 position_window : SV_Position
) {
}

#elif defined(PSO__DEBUG_VIEW)

// TODO: Add a root constant so we can pass which view we want to debug
// "RootConstants(b0, num32BitConstants = 2)"

#define root_signature \
    "RootFlags(CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED), " \
    "DescriptorTable(SRV(t0, numDescriptors = 1), visibility = SHADER_VISIBILITY_PIXEL), " \
    "StaticSampler(s0, filter = FILTER_ANISOTROPIC, maxAnisotropy = 16, visibility = SHADER_VISIBILITY_PIXEL)"

Texture2D srv_z_texture : register(t0);
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
    // TODO: Sample srv_z_texture
    out_color = float4(uvs.x, uvs.y, 0.0, 1.0);
}

#endif