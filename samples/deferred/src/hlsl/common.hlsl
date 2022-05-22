#define BLOCK_SIZE 16
#define NUM_LIGHTS 2000
#define MAX_LIGHT_PER_TILE 2000

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
    uint transform_buffer_index;
};

struct DrawConst {
    uint material_index;
    uint transform_index;
};

struct Light {
    float4 position_ws;     // position for point lights, direction for directional lights
    float4 position_vs;     // position for point lights, direction for directional lights
    float4 radiance;        // xyz: radiance. w: intensity
    float radius;           // only used for point lights
    uint type;              // 0: directional, 1: point
    bool enabled;
    float _padding;
};

struct Sphere {
    float3 center;
    float radius;
};

struct Plane {
    float3 normal;          // Plane normal
    float distance;         // Distance to origin
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

float4 clipToView(float4x4 inv_proj, float4 clip_position) {
    // View space position
    float4 view = mul(inv_proj, clip_position);
    // Perspective projection
    view = view / view.w;

    return view;
}

float4 screenToView(float4x4 inv_proj, float2 screen_dimensions, float4 screen_position) {
    // Convert to normalized texture coordinates
    float2 tex_coords = screen_position.xy / screen_dimensions;
    // Convert to clip space
    float4 clip_position = float4(float2(tex_coords.x, 1.0f - tex_coords.y) * 2.0f - 1.0f, screen_position.z, screen_position.w);

    return clipToView(inv_proj, clip_position);
}

// Check to see if a sphere is fully behind (inside the negative half space of) a plane.
// Source: Real-time collision detection, Christer Ericson (2005)
bool sphereInsidePlane(Sphere sphere, Plane plane) {
    return dot(plane.normal, sphere.center) - plane.distance < -sphere.radius;
}

// Check to see if a light is partially contained within the frustum.
bool sphereInsideFrustum(Sphere sphere, Frustum frustum, float z_near, float z_far) {
    bool result = true;

    // Unrolled based on Wicked Engine implementation
	result = ((sphere.center.z + sphere.radius < z_near || sphere.center.z - sphere.radius > z_far) ? false : result);
	result = ((sphereInsidePlane(sphere, frustum.planes[0])) ? false : result);
	result = ((sphereInsidePlane(sphere, frustum.planes[1])) ? false : result);
	result = ((sphereInsidePlane(sphere, frustum.planes[2])) ? false : result);
	result = ((sphereInsidePlane(sphere, frustum.planes[3])) ? false : result);

	return result;
}

// https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/ToneMapping.hlsl

float3 linearTosRGB(float3 color) {
    float3 x = color * 12.92f;
    float3 y = 1.055f * pow(saturate(color), 1.0f / 2.4f) - 0.055f;

    float3 clr = color;
    clr.r = color.r < 0.0031308f ? x.r : y.r;
    clr.g = color.g < 0.0031308f ? x.g : y.g;
    clr.b = color.b < 0.0031308f ? x.b : y.b;

    return clr;
}

float3 sRGBToLinear(in float3 color) {
    float3 x = color / 12.92f;
    float3 y = pow(max((color + 0.055f) / 1.055f, 0.0f), 2.4f);

    float3 clr = color;
    clr.r = color.r <= 0.04045f ? x.r : y.r;
    clr.g = color.g <= 0.04045f ? x.g : y.g;
    clr.b = color.b <= 0.04045f ? x.b : y.b;

    return clr;
}