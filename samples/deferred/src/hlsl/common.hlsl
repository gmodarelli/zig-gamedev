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

struct FrameConst {
    float4x4 view;
    float4x4 proj;
    float4x4 view_proj;
    float4x4 inv_view;
    float4x4 inv_proj;
    float4 camera_position;
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
