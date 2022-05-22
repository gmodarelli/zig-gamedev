#if !defined(PI)
#define PI 3.1415926
#endif

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

struct PBRInput {
    float3 n;
    float3 v;
    float metallic;
    float roughness;
};

struct LightingResult {
    float3 diffuse;
    float3 specular;
};

LightingResult calculateLighting(Light light, float4 eye_pos, float4 position_vs, float4 normal_vs) {
    float4 V = normalize(eye_pos - position_vs);
    LightingResult result = (LightingResult)0;

    if (light.type == 0) { // Directional Light
        float4 L = normalize(-float4(light.position_vs.xyz, 0));
        float n_dot_l = max(dot(normal_vs, L), 0.0f);
        result.diffuse += light.radiance.rgb * n_dot_l;
        result.specular += 0; // TODO
        result.diffuse = n_dot_l.xxx;
    } else if (light.type == 1) { // Point Light
        float4 L = light.position_vs - position_vs;
        float distance = length(L);
        L /= distance;

        float attenuation = saturate(1.0f - smoothstep(light.radius * 0.75f, light.radius, distance));

        float n_dot_l = max(dot(normal_vs, L), 0.0f);
        result.diffuse += light.radiance.rgb * n_dot_l * attenuation;
        result.specular += 0; // TODO
    } 

    return result;
}

// float3 calculateLighting(PBRInput pbr_input, float3 base_color, float3 position_ws, Light light) {
//     float3 l = light.position_ws.xyz;
//     float attenuation = 1.0;
// 
//     if (light.type == 1) {
//         l = light.position_ws.xyz - position_ws;
//         float distance = length(l);
//         l /= distance;
// 
//         attenuation = 1.0 - smoothstep(light.radius * 0.75f, light.radius, distance);
//     }
// 
//     const float n_dot_v = saturate(dot(pbr_input.n, pbr_input.v));
// 
//     float3 f0 = float3(0.04, 0.04, 0.04);
//     f0 = lerp(f0, base_color, pbr_input.metallic);
// 
//     // Light contribution
//     float3 h = normalize(l + pbr_input.v);
//     float n_dot_l = saturate(dot(pbr_input.n, l));
//     float h_dot_v = saturate(dot(h, pbr_input.v));
// 
//     float3 f = fresnelSchlick(h_dot_v, f0);
//     float nd = distributionGgx(pbr_input.n, h, pbr_input.roughness);
//     float g = geometrySmith(n_dot_l, n_dot_v, (pbr_input.roughness + 1.0) * 0.5);
// 
//     float3 specular = (nd * g * f) / max(4.0 * n_dot_v * n_dot_l, 0.001);
//     float3 kd = (1.0 - f) * (1.0 - pbr_input.metallic);
// 
//     return attenuation.xxx;
//     return (kd * (base_color / PI) + specular * attenuation) * light.radiance.rgb * attenuation * n_dot_l;
// }