## Deferred rendering

This sample implements a basic Deferred Renderer.

### Passes

- [ ] Z Pre-Pass
- [ ] Main Light Shadow Pass?
- [ ] GBuffer Pass
- [ ] Lighting Pass?
- [ ] Post-Processing?
- [ ] Final Blit
- [ ] Debug View Pass (Albedo, Normals, Metallic, Roughness)

### Some other, random notes

- We'll go fully bindless using [HLSL SM 6.6 Dynamic Resources](https://microsoft.github.io/DirectX-Specs/d3d/HLSL_ShaderModel6_6.html#dynamic-resource) for textures and buffers
- We will have a single shader for every surface. Might extend this in the future to also support alpha-tested surfaces (like foliage)
- I'm not sure about what solution to implement for the lighting pass, but I'd like to try a compute-based approach. What I know is that it'll only be for a single, directional light and no ambient or indirect illumination will be implemented (I'd like to work on some Global Illumination solution in the future (DDGI, SSGI or RTXGI))
- We're gonna use Sponza as a test scene. At the beginning we will stick to the old Sponza models, but it would be cool to use the [newly released version by Intel](https://www.intel.com/content/www/us/en/developer/topic-technology/graphics-research/samples.html)