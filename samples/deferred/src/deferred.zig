const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const zwin32 = @import("zwin32");
const dxgi = zwin32.dxgi;
const w32 = zwin32.base;
const d3d12 = zwin32.d3d12;
const hrPanic = zwin32.hrPanic;
const hrPanicOnFail = zwin32.hrPanicOnFail;
const zd3d12 = @import("zd3d12");
const common = @import("common");
const c = common.c;
const vm = common.vectormath;
const GuiRenderer = common.GuiRenderer;
const zpix = @import("zpix");
const zmesh = @import("zmesh");

const Vec3 = vm.Vec3;
const Vec4 = vm.Vec4;
const Mat4 = vm.Mat4;

pub export const D3D12SDKVersion: u32 = 4;
pub export const D3D12SDKPath: [*:0]const u8 = ".\\d3d12\\";

const content_dir = @import("build_options").content_dir;

const window_name = "zig-gamedev: deferred";
const window_width = 1920;
const window_height = 1080;
const num_lights: u32 = 2000;

const FrameConst = struct {
    view: Mat4,
    proj: Mat4,
    view_proj: Mat4,
    inv_view: Mat4,
    inv_proj: Mat4,
    camera_position: Vec4,
    position_buffer_index: u32,
    normal_buffer_index: u32,
    texcoord_buffer_index: u32,
    tangent_buffer_index: u32,
    index_buffer_index: u32,
    material_buffer_index: u32,
    transform_buffer_index: u32,
};

const DispatchParams = struct {
    num_thread_groups: [3]u32,
    _padding0: u32,
    num_threads: [3]u32,
    _padding1: u32,

    pub const block_size: u32 = 16;

    pub fn init(viewport_width: u32, viewport_height: u32) DispatchParams {
        const f_block_size: f32 = @intToFloat(f32, block_size);
        const f_width: f32 = @intToFloat(f32, viewport_width);
        const f_height: f32 = @intToFloat(f32, viewport_height);

        const num_thread_groups = [3]u32{
            @floatToInt(u32, @ceil(f_width / f_block_size)),
            @floatToInt(u32, @ceil(f_height / f_block_size)),
            1,
        };
        const num_threads = [3]u32{
            num_thread_groups[0] * block_size,
            num_thread_groups[1] * block_size,
            1
        };

        return DispatchParams {
            .num_thread_groups = num_thread_groups,
            ._padding0 = 0,
            .num_threads = num_threads,
            ._padding1 = 0,
        };
    }
};

// TODO: These indices can be sent then as Root Constant
const DrawConst = struct {
    material_index: u32,
    transform_index: u32,
};

const Mesh = struct {
    index_offset: u32,
    vertex_offset: u32,
    num_indices: u32,
    num_vertices: u32,
    material_index: u32,
    transform_index: u32,
};

const Transform = struct {
    world_matrix: Mat4,
};

const Material = struct {
    base_color: Vec3,
    roughness: f32,

    metallic: f32,
    base_color_tex_index: u32,
    metallic_roughness_tex_index: u32,
    normal_tex_index: u32,

    // TODO: alpha_cutoff is the only info we need on the GPU
    // The rest are only used for draw calls sorting.
    alpha_cutoff: f32,
    double_sided: bool,
    alpha_mode: u8,
    _padding0: u16,
    _padding1: [2]u32,
};

const Light = struct {
    position_ws: [4]f32,        // world space position for point lights, direction for directional lights
    position_vs: [4]f32,        // view space position for point lights, direction for directional lights
    radiance: [4]f32,           // xyz: radiance. w: intensity
    radius: f32,                // only used for point lights
    light_type: u32,            // 0: directional, 1: point
    enabled: bool,
    _padding: f32,
};

const Texture = struct {
    resource: zd3d12.ResourceHandle,
    persistent_descriptor: zd3d12.PersistentDescriptor,
};

const Buffer = struct {
    resource: zd3d12.ResourceHandle,
    srv: d3d12.CPU_DESCRIPTOR_HANDLE,
    uav: d3d12.CPU_DESCRIPTOR_HANDLE,
};

const PersistentResource = struct {
    resource: zd3d12.ResourceHandle,
    persistent_descriptor: zd3d12.PersistentDescriptor,
};

const RenderTarget = struct {
    resource: zd3d12.ResourceHandle,
    rtv: d3d12.CPU_DESCRIPTOR_HANDLE,
    srv: d3d12.CPU_DESCRIPTOR_HANDLE,
    uav: d3d12.CPU_DESCRIPTOR_HANDLE,
};

const DeferredstateState = struct {
    gctx: zd3d12.GraphicsContext,
    guir: GuiRenderer,
    frame_stats: common.FrameStats,

    // Depth Texture for Z Pre Pass, GBuffer Pass
    depth_texture: zd3d12.ResourceHandle,
    depth_texture_dsv: d3d12.CPU_DESCRIPTOR_HANDLE,
    depth_texture_srv: d3d12.CPU_DESCRIPTOR_HANDLE,

    // GBuffer Render Targets
    // Layout
    // RT0: R10G10B10A2_UNORM -> Albedo (alpha unused)
    // RT1: R10G10B10A2_UNORM -> Packed World Space Normal (alpha unused)
    // RT2: R8G8B8A8_UNORM    -> Metallic, Roughness (blue and alpha unused)
    rt0: RenderTarget,
    rt1: RenderTarget,
    rt2: RenderTarget,
    // HDR Output Render Target
    rt_hdr: RenderTarget,

    // PSOs
    frustums_grid_pso: zd3d12.PipelineHandle,
    clear_buffers_pso: zd3d12.PipelineHandle,
    update_lights_pso: zd3d12.PipelineHandle,
    light_culling_pso: zd3d12.PipelineHandle,
    z_pre_pass_opaque_pso: zd3d12.PipelineHandle,
    z_pre_pass_alpha_tested_pso: zd3d12.PipelineHandle,
    geometry_pass_opaque_pso: zd3d12.PipelineHandle,
    geometry_pass_alpha_tested_pso: zd3d12.PipelineHandle,
    compute_shading_pso: zd3d12.PipelineHandle,
    final_blit_pso: zd3d12.PipelineHandle,

    // Geometry Data
    position_buffer: PersistentResource,
    normal_buffer: PersistentResource,
    texcoord_buffer: PersistentResource,
    tangent_buffer: PersistentResource,
    index_buffer: PersistentResource,
    material_buffer: PersistentResource,
    transform_buffer: PersistentResource,

    // Lighting Data
    lights: std.ArrayList(Light),
    frustums_buffer: Buffer,
    light_buffer: Buffer,
    light_index_counter_buffer: Buffer,
    light_index_list_buffer: Buffer,
    light_grid_buffer: Buffer,

    meshes: std.ArrayList(Mesh),
    alpha_tested_mesh_indices: std.ArrayList(u32),
    opaque_mesh_indices: std.ArrayList(u32),
    materials: std.ArrayList(Material),
    textures: std.ArrayList(Texture),
    transforms: std.ArrayList(Transform),

    need_to_compute_frustrums: bool,

    camera: struct {
        position: Vec3,
        forward: Vec3,
        pitch: f32,
        yaw: f32,
        znear: f32,
        zfar: f32,
    },
    mouse: struct {
        cursor_prev_x: i32,
        cursor_prev_y: i32,
    },

    view_mode: i32,

    pub fn init(allocator: std.mem.Allocator) !DeferredstateState {
        const window = try common.initWindow(allocator, window_name, window_width, window_height);

        var arena_allocator_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_allocator_state.deinit();
        const arena_allocator = arena_allocator_state.allocator();

        _ = zpix.loadGpuCapturerLibrary();
        _ = zpix.setTargetWindow(window);
        _ = zpix.beginCapture(
            zpix.CAPTURE_GPU,
            &zpix.CaptureParameters{ .gpu_capture_params = .{ .FileName = L("capture.wpix") } },
        );

        var gctx = zd3d12.GraphicsContext.init(allocator, window);

        // Initialize PSOs

        // Generate Frustum Grid pass
        const frustums_grid_pso = blk: {
            var pso_desc = d3d12.COMPUTE_PIPELINE_STATE_DESC.initDefault();

            break :blk gctx.createComputeShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/compute_frustums.cs.cso",
            );
        };

        // Light culling pass
        const clear_buffers_pso = blk: {
            var pso_desc = d3d12.COMPUTE_PIPELINE_STATE_DESC.initDefault();

            break :blk gctx.createComputeShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/clear_buffers.cs.cso",
            );
        };

        const update_lights_pso = blk: {
            var pso_desc = d3d12.COMPUTE_PIPELINE_STATE_DESC.initDefault();

            break :blk gctx.createComputeShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/update_lights.cs.cso",
            );
        };

        const light_culling_pso = blk: {
            var pso_desc = d3d12.COMPUTE_PIPELINE_STATE_DESC.initDefault();

            break :blk gctx.createComputeShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/light_culling.cs.cso",
            );
        };

        // Z-PrePass
        const z_pre_pass_psos = blk: {
            var pso_desc = d3d12.GRAPHICS_PIPELINE_STATE_DESC.initDefault();
            pso_desc.RTVFormats[0] = .UNKNOWN;
            pso_desc.NumRenderTargets = 0;
            pso_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = 0x0;
            pso_desc.DSVFormat = .D32_FLOAT;
            pso_desc.PrimitiveTopologyType = .TRIANGLE;

            const opaque_pso = gctx.createGraphicsShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/z_pre_pass.vs.cso",
                content_dir ++ "shaders/z_pre_pass_opaque.ps.cso",
            );

            pso_desc.RasterizerState.CullMode = .NONE;

            const alpha_tested_pso = gctx.createGraphicsShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/z_pre_pass.vs.cso",
                content_dir ++ "shaders/z_pre_pass_alpha_tested.ps.cso",
            );

            break :blk .{
                .opaque_pso = opaque_pso,
                .alpha_tested_pso = alpha_tested_pso
            };
        };

        // Geometry Pass
        const geometry_pass_psos = blk: {
            var pso_desc = d3d12.GRAPHICS_PIPELINE_STATE_DESC.initDefault();
            pso_desc.NumRenderTargets = 3;
            pso_desc.RTVFormats[0] = .R10G10B10A2_UNORM;
            pso_desc.RTVFormats[1] = .R10G10B10A2_UNORM;
            pso_desc.RTVFormats[2] = .R8G8B8A8_UNORM;
            pso_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = 0xf;
            pso_desc.BlendState.RenderTarget[1].RenderTargetWriteMask = 0xf;
            pso_desc.BlendState.RenderTarget[2].RenderTargetWriteMask = 0xf;
            pso_desc.DSVFormat = .D32_FLOAT;
            pso_desc.DepthStencilState.DepthFunc = .LESS_EQUAL;
            pso_desc.PrimitiveTopologyType = .TRIANGLE;

            const opaque_pso = gctx.createGraphicsShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/geometry_pass.vs.cso",
                content_dir ++ "shaders/geometry_pass_opaque.ps.cso",
            );

            pso_desc.RasterizerState.CullMode = .NONE;

            const alpha_tested_pso = gctx.createGraphicsShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/geometry_pass.vs.cso",
                content_dir ++ "shaders/geometry_pass_alpha_tested.ps.cso",
            );

            break :blk .{
                .opaque_pso = opaque_pso,
                .alpha_tested_pso = alpha_tested_pso
            };
        };

        // Compute Deferred Shading
        const compute_shading_pso = blk: {
            var pso_desc = d3d12.COMPUTE_PIPELINE_STATE_DESC.initDefault();

            break :blk gctx.createComputeShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/deferred_shading.cs.cso",
            );
        };

        // Final Blit PSO
        const final_blit_pso = blk: {
            // NOTE: This causes a warning because we're not binding a depth buffer.
            var pso_desc = d3d12.GRAPHICS_PIPELINE_STATE_DESC.initDefault();
            pso_desc.RTVFormats[0] = .R8G8B8A8_UNORM;
            pso_desc.NumRenderTargets = 1;
            pso_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = 0xf;
            pso_desc.PrimitiveTopologyType = .TRIANGLE;

            break :blk gctx.createGraphicsShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/final_blit.vs.cso",
                content_dir ++ "shaders/final_blit.ps.cso",
            );
        };

        // Create Depth Texture resource and its views
        // TODO: Figure out if there are any benifits in changing the format
        // to D32_TYPELESS
        // TODO: Convert to Reversed-Z buffer
        const depth_texture = gctx.createCommittedResource(
            .DEFAULT,
            d3d12.HEAP_FLAG_NONE,
            &blk: {
                var desc = d3d12.RESOURCE_DESC.initTex2d(.D32_FLOAT, gctx.viewport_width, gctx.viewport_height, 1);
                desc.Flags = d3d12.RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
                break :blk desc;
            },
            d3d12.RESOURCE_STATE_DEPTH_WRITE,
            &d3d12.CLEAR_VALUE.initDepthStencil(.D32_FLOAT, 1.0, 0),
        ) catch |err| hrPanic(err);

        const depth_texture_dsv = gctx.allocateCpuDescriptors(.DSV, 1);
        gctx.device.CreateDepthStencilView(gctx.lookupResource(depth_texture).?, null, depth_texture_dsv);

        const depth_texture_srv = gctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);
        gctx.device.CreateShaderResourceView(gctx.lookupResource(depth_texture).?, &d3d12.SHADER_RESOURCE_VIEW_DESC{
            .Format = .R32_FLOAT,
            .ViewDimension = .TEXTURE2D,
            .Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
            .u = .{
                .Texture2D = .{
                    .MostDetailedMip = 0,
                    .MipLevels = 1,
                    .PlaneSlice = 0,
                    .ResourceMinLODClamp = 0.0,
                },
            },
        }, depth_texture_srv);

        // Create Geometry Pass render targets
        const rt0 = createRenderTarget(&gctx, .R10G10B10A2_UNORM, &[4]f32{ 0.0, 0.0, 0.0, 1.0 }, true, false);
        const rt1 = createRenderTarget(&gctx, .R10G10B10A2_UNORM, &[4]f32{ 0.0, 1.0, 0.0, 1.0 }, true, false);
        const rt2 = createRenderTarget(&gctx, .R8G8B8A8_UNORM, &[4]f32{ 0.0, 0.5, 0.0, 1.0 }, true, false);
        const rt_hdr = createRenderTarget(&gctx, .R16G16B16A16_FLOAT, &[4]f32{ 0.0, 0.0, 0.0, 1.0 }, true, true);

        var mipgen_rgba8 = zd3d12.MipmapGenerator.init(arena_allocator, &gctx, .R8G8B8A8_UNORM, content_dir);

        gctx.beginFrame();

        var guir = GuiRenderer.init(arena_allocator, &gctx, 1, content_dir);

        const lighting_resources = blk: {
            zpix.beginEvent(gctx.cmdlist, "Lighing resources creation");
            defer zpix.endEvent(gctx.cmdlist);

            // Create Frustums Buffer
            const num_frustums: u32 = (gctx.viewport_width / 16) * (gctx.viewport_height / 16);
            const frustums_buffer = createBuffer(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(num_frustums * @sizeOf([16]f32)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(0, num_frustums, @sizeOf([16]f32)),
                &d3d12.UNORDERED_ACCESS_VIEW_DESC.initStructuredBuffer(0, num_frustums, @sizeOf([16]f32), 0),
                d3d12.RESOURCE_STATE_UNORDERED_ACCESS,
                [16]f32,
                null,
            );

            var lights = std.ArrayList(Light).init(allocator);

            // Add a directional light
            // NOTE: Treating position_ws as a direction, hence 0.0 for its w component
            lights.append(.{
                .position_ws = [4]f32{ 0.32139, 0.76604, -0.55667, 0.0 },
                .position_vs = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
                .radiance = [4]f32{ 10.0, 10.0, 10.0, 0.0 },
                .radius = 0.0,
                .light_type = 0,
                .enabled = true,
                ._padding = 42.0,
            }) catch unreachable;

            // Add a point light
            lights.append(.{
                .position_ws = [4]f32{ 0.0, 1.0, 0.0, 1.0 },
                .position_vs = [4]f32{ 0.0, 0.0, 0.0, 1.0 },
                .radiance = [4]f32{ 0.0, 0.0, 10.0, 0.0 },
                .radius = 2.0,
                .light_type = 1,
                .enabled = true,
                ._padding = 42.0,
            }) catch unreachable;

            // Create random lights
            // TODO: Randomly distribute them in a sphere?
            while (lights.items.len < num_lights) {
                lights.append(.{
                    .position_ws = [4]f32{0.0, 0.0, 0.0, 1.0},
                    .position_vs = [4]f32{0.0, 0.0, 0.0, 1.0},
                    .radiance = [4]f32{0.0, 0.0, 0.0, 0.0},
                    .radius = 0.0,
                    .light_type = 0,
                    .enabled = false,
                    ._padding = 42.0,
                }) catch unreachable;
            }

            const light_buffer = createBuffer(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(num_lights * @sizeOf(Light)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(0, num_lights, @sizeOf(Light)),
                &d3d12.UNORDERED_ACCESS_VIEW_DESC.initStructuredBuffer(0, num_lights, @sizeOf(Light), 0),
                d3d12.RESOURCE_STATE_COMMON,
                Light,
                &lights,
            );

            const light_index_counter_buffer = createBuffer(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(@sizeOf(u32)),
                null,
                &d3d12.UNORDERED_ACCESS_VIEW_DESC.initStructuredBuffer(0, 1, @sizeOf(u32), 0),
                d3d12.RESOURCE_STATE_UNORDERED_ACCESS,
                u32,
                null,
            );

            const num_thread_groups = [4]u32{ @floatToInt(u32, @ceil(@intToFloat(f32, gctx.viewport_width) / 16.0)), @floatToInt(u32, @ceil(@intToFloat(f32, gctx.viewport_height) / 16.0)), 0, 0 };
            const average_light_per_tile: u32 = 200;
            const max_light_list_lights: u32 = num_thread_groups[0] * num_thread_groups[1] * average_light_per_tile;

            const light_index_list_buffer = createBuffer(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(max_light_list_lights * @sizeOf(u32)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(0, max_light_list_lights, @sizeOf(u32)),
                &d3d12.UNORDERED_ACCESS_VIEW_DESC.initStructuredBuffer(0, max_light_list_lights, @sizeOf(u32), 0),
                d3d12.RESOURCE_STATE_UNORDERED_ACCESS,
                u32,
                null,
            );

            var srv_desc = std.mem.zeroes(d3d12.SHADER_RESOURCE_VIEW_DESC);
            srv_desc = .{
                .Format = .R32G32_UINT,
                .ViewDimension = .TEXTURE2D,
                .Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
                .u = .{
                    .Texture2D = .{
                        .MostDetailedMip = 0,
                        .MipLevels = 1,
                        .PlaneSlice = 0,
                        .ResourceMinLODClamp = 0.0,
                    },
                },
            };
            var uav_desc = std.mem.zeroes(d3d12.UNORDERED_ACCESS_VIEW_DESC);
            uav_desc = .{
                .Format = .R32G32_UINT,
                .ViewDimension = .TEXTURE2D,
                .u = .{
                    .Texture2D = .{
                        .MipSlice = 0,
                        .PlaneSlice = 0,
                    },
                },
            };
            const light_grid_buffer = createBuffer(
                &gctx,
                &d3d12.RESOURCE_DESC.initTex2d(.R32G32_UINT, num_thread_groups[0], num_thread_groups[1], 1),
                &srv_desc,
                &uav_desc,
                d3d12.RESOURCE_STATE_UNORDERED_ACCESS,
                [2]u32,
                null,
            );

            break :blk .{
                .lights = lights,
                .frustums_buffer = frustums_buffer,
                .light_buffer = light_buffer,
                .light_index_counter_buffer = light_index_counter_buffer,
                .light_index_list_buffer = light_index_list_buffer,
                .light_grid_buffer = light_grid_buffer,
            };
        };

        // Load Sponza
        const geometry = blk: {
            zmesh.init(arena_allocator);
            defer zmesh.deinit();

            var meshes = std.ArrayList(Mesh).init(allocator);
            var materials = std.ArrayList(Material).init(allocator);
            var textures = std.ArrayList(Texture).init(allocator);
            var transforms = std.ArrayList(Transform).init(allocator);

            const data_handle = try zmesh.gltf.parseAndLoadFile(content_dir ++ "Sponza/Sponza.gltf");
            defer zmesh.gltf.freeData(data_handle);

            var indices = std.ArrayList(u32).init(arena_allocator);
            var positions = std.ArrayList([3]f32).init(arena_allocator);
            var normals = std.ArrayList([3]f32).init(arena_allocator);
            var texcoords = std.ArrayList([2]f32).init(arena_allocator);
            var tangents = std.ArrayList([4]f32).init(arena_allocator);

            const num_meshes = zmesh.gltf.getNumMeshes(data_handle);
            var mesh_index: u32 = 0;
            while (mesh_index < num_meshes) : (mesh_index += 1) {
                const num_primitives = zmesh.gltf.getNumMeshPrimitives(data_handle, mesh_index);
                var primitive_index: u32 = 0;
                while (primitive_index < num_primitives) : (primitive_index += 1) {
                    const pre_indices_len = indices.items.len;
                    const pre_positions_len = positions.items.len;

                    zmesh.gltf.appendMeshPrimitive(
                        data_handle,
                        mesh_index,
                        primitive_index,
                        &indices,
                        &positions,
                        &normals,
                        &texcoords,
                        &tangents,
                    );

                    // Find material index
                    const assigned_material_index: u32 = mt_blk: {
                        var material_index: u32 = 0;
                        const data = @ptrCast(
                            *c.cgltf_data,
                            @alignCast(@alignOf(c.cgltf_data), data_handle),
                        );
                        const num_materials = @intCast(u32, data.materials_count);

                        while (material_index < num_materials) : (material_index += 1) {
                            const prim = &data.meshes[mesh_index].primitives[primitive_index];
                            if (prim.material == &data.materials[material_index]) {
                                break :mt_blk material_index;
                            }
                        }

                        break :mt_blk 0xffff_ffff;
                    };

                    std.debug.assert(assigned_material_index != 0xffff_ffff);

                    meshes.append(.{
                        .index_offset = @intCast(u32, pre_indices_len),
                        .vertex_offset = @intCast(u32, pre_positions_len),
                        .num_indices = @intCast(u32, indices.items.len - pre_indices_len),
                        .num_vertices = @intCast(u32, positions.items.len - pre_positions_len),
                        .material_index = assigned_material_index,
                        .transform_index = @intCast(u32, transforms.items.len),
                    }) catch unreachable;

                    transforms.append(.{ .world_matrix = Mat4.initIdentity() }) catch unreachable;
                }
            }

            // NOTE(mziulek): Sponza requires scaling.
            for (positions.items) |position, i| {
                positions.items[i] = [3]f32{ position[0] * 0.008, position[1] * 0.008, position[2] * 0.008 };
            }

            // Create Position Buffer, a persisten view and upload all positions to the GPU
            const position_buffer = createPersistentResource(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(positions.items.len * @sizeOf([3]f32)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(
                    0,
                    @intCast(u32, positions.items.len),
                    @sizeOf([3]f32),
                ),
                d3d12.RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                [3]f32,
                &positions,
            );

            // Create Normal Buffer, a persisten view and upload all normals to the GPU
            const normal_buffer = createPersistentResource(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(normals.items.len * @sizeOf([3]f32)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(
                    0,
                    @intCast(u32, normals.items.len),
                    @sizeOf([3]f32),
                ),
                d3d12.RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                [3]f32,
                &normals,
            );

            // Create Texcoord Buffer, a persisten view and upload all texcoords to the GPU
            const texcoord_buffer = createPersistentResource(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(texcoords.items.len * @sizeOf([2]f32)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(
                    0,
                    @intCast(u32, texcoords.items.len),
                    @sizeOf([2]f32),
                ),
                d3d12.RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                [2]f32,
                &texcoords,
            );

            // Create Tangent Buffer, a persisten view and upload all tangents to the GPU
            const tangent_buffer = createPersistentResource(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(tangents.items.len * @sizeOf([4]f32)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(
                    0,
                    @intCast(u32, tangents.items.len),
                    @sizeOf([4]f32),
                ),
                d3d12.RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                [4]f32,
                &tangents,
            );

            // Create Index Buffer, a persistent view and upload all indices to the GPU
            const index_buffer = createPersistentResource(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(indices.items.len * @sizeOf(u32)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initTypedBuffer(
                    .R32_UINT,
                    0,
                    @intCast(u32, indices.items.len),
                ),
                d3d12.RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                u32,
                &indices,
            );

            // Upload all textures
            var gltf_texture_index_to_gpu_index = std.HashMap(u32, u32, std.hash_map.AutoContext(u32), 80).init(arena_allocator);
            {
                const data = @ptrCast(
                    *c.cgltf_data,
                    @alignCast(@alignOf(c.cgltf_data), data_handle),
                );

                const num_images = @intCast(u32, data.images_count);
                var image_index: u32 = 0;
                textures.ensureTotalCapacity(num_images + 1) catch unreachable;

                while (image_index < num_images) : (image_index += 1) {
                    const image = &data.images[image_index];

                    var buffer: [64]u8 = undefined;
                    const path = std.fmt.bufPrint(
                        buffer[0..],
                        content_dir ++ "Sponza/{s}",
                        .{image.uri},
                    ) catch unreachable;

                    const resource = gctx.createAndUploadTex2dFromFile(path, .{}) catch unreachable;
                    // _ = gctx.lookupResource(resource).?.SetName(L(path));
                    const view = gctx.allocatePersistentGpuDescriptors(1);
                    gctx.device.CreateShaderResourceView(gctx.lookupResource(resource).?, null, view.cpu_handle);

                    mipgen_rgba8.generateMipmaps(&gctx, resource);
                    gctx.addTransitionBarrier(resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
                    const texture = Texture{
                        .resource = resource,
                        .persistent_descriptor = view,
                    };
                    textures.appendAssumeCapacity(texture);
                    gltf_texture_index_to_gpu_index.putNoClobber(image_index, view.index) catch unreachable;
                }
            }
            gctx.flushResourceBarriers();

            // Collect Materials
            {
                const data = @ptrCast(
                    *c.cgltf_data,
                    @alignCast(@alignOf(c.cgltf_data), data_handle),
                );
                const num_materials = @intCast(u32, data.materials_count);
                materials.ensureTotalCapacity(num_materials) catch unreachable;

                var material_index: u32 = 0;
                while (material_index < num_materials) : (material_index += 1) {
                    const gltf_material = &data.materials[material_index];
                    assert(gltf_material.has_pbr_metallic_roughness == 1);

                    const mr = &gltf_material.pbr_metallic_roughness;

                    const alpha_cutoff: f32 = gltf_material.alpha_cutoff;
                    const double_sided: bool = if(gltf_material.double_sided == 1) true else false;
                    const alpha_mode: u8 = switch(gltf_material.alpha_mode) {
                        c.cgltf_alpha_mode_opaque => 0,
                        c.cgltf_alpha_mode_mask => 1,
                        c.cgltf_alpha_mode_blend => 2,
                        else => 0,
                    };

                    const num_images = @intCast(u32, data.images_count);
                    const invalid_image_index = num_images;

                    var base_color_tex_index: u32 = invalid_image_index;
                    var metallic_roughness_tex_index: u32 = invalid_image_index;
                    var normal_tex_index: u32 = invalid_image_index;

                    var image_index: u32 = 0;

                    while (image_index < num_images) : (image_index += 1) {
                        const image = &data.images[image_index];
                        assert(image.uri != null);

                        if (mr.base_color_texture.texture != null and
                            mr.base_color_texture.texture.*.image.*.uri == image.uri)
                        {
                            assert(base_color_tex_index == invalid_image_index);
                            if (gltf_texture_index_to_gpu_index.get(image_index)) |gpu_index| {
                                base_color_tex_index = gpu_index;
                            }
                        }

                        if (mr.metallic_roughness_texture.texture != null and
                            mr.metallic_roughness_texture.texture.*.image.*.uri == image.uri)
                        {
                            assert(metallic_roughness_tex_index == invalid_image_index);
                            if (gltf_texture_index_to_gpu_index.get(image_index)) |gpu_index| {
                                metallic_roughness_tex_index = gpu_index;
                            }
                        }

                        if (gltf_material.normal_texture.texture != null and
                            gltf_material.normal_texture.texture.*.image.*.uri == image.uri)
                        {
                            assert(normal_tex_index == invalid_image_index);
                            if (gltf_texture_index_to_gpu_index.get(image_index)) |gpu_index| {
                                normal_tex_index = gpu_index;
                            }
                        }
                    }

                    assert(base_color_tex_index != invalid_image_index);

                    materials.appendAssumeCapacity(.{
                        .base_color = Vec3.init(mr.base_color_factor[0], mr.base_color_factor[1], mr.base_color_factor[2]),
                        .roughness = mr.roughness_factor,
                        .metallic = mr.metallic_factor,
                        .base_color_tex_index = base_color_tex_index,
                        .metallic_roughness_tex_index = metallic_roughness_tex_index,
                        .normal_tex_index = normal_tex_index,
                        .alpha_cutoff = alpha_cutoff,
                        .double_sided = double_sided,
                        .alpha_mode = alpha_mode,
                        ._padding0 = 0,
                        ._padding1 = [2]u32{ 0, 0 },
                    });
                }
            }

            // Split meshes into AlphaTested and Opaques
            var alpha_tested_mesh_indices = std.ArrayList(u32).init(allocator);
            var opaque_mesh_indices = std.ArrayList(u32).init(allocator);
            {
                var i: u32 = 0;
                while (i < meshes.items.len) : (i += 1) {
                    var material = &materials.items[meshes.items[i].material_index];
                    if (material.double_sided) {
                        alpha_tested_mesh_indices.append(i) catch unreachable;
                    } else {
                        opaque_mesh_indices.append(i) catch unreachable;
                    }
                }
            }

            // Create Material Buffer, a persistent view and upload all indices to the GPU
            const material_buffer = createPersistentResource(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(materials.items.len * @sizeOf(Material)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(
                    0,
                    @intCast(u32, materials.items.len),
                    @sizeOf(Material),
                ),
                d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
                Material,
                &materials,
            );

            // Create Transform Buffer, a persistent view and upload all indices to the GPU
            const transform_buffer = createPersistentResource(
                &gctx,
                &d3d12.RESOURCE_DESC.initBuffer(transforms.items.len * @sizeOf(Transform)),
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(
                    0,
                    @intCast(u32, transforms.items.len),
                    @sizeOf(Transform),
                ),
                d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
                Transform,
                &transforms,
            );

            break :blk .{
                .meshes = meshes,
                .materials = materials,
                .transforms = transforms,
                .textures = textures,
                .alpha_tested_mesh_indices = alpha_tested_mesh_indices,
                .opaque_mesh_indices = opaque_mesh_indices,
                .position_buffer = position_buffer,
                .normal_buffer = normal_buffer,
                .texcoord_buffer = texcoord_buffer,
                .tangent_buffer = tangent_buffer,
                .index_buffer = index_buffer,
                .material_buffer = material_buffer,
                .transform_buffer = transform_buffer,
            };
        };

        gctx.endFrame();
        gctx.finishGpuCommands();

        mipgen_rgba8.deinit(&gctx);
        _ = zpix.endCapture();

        return DeferredstateState{
            .gctx = gctx,
            .guir = guir,
            .frame_stats = common.FrameStats.init(),

            .depth_texture = depth_texture,
            .depth_texture_dsv = depth_texture_dsv,
            .depth_texture_srv = depth_texture_srv,

            .rt0 = rt0,
            .rt1 = rt1,
            .rt2 = rt2,
            .rt_hdr = rt_hdr,

            .frustums_grid_pso = frustums_grid_pso,
            .clear_buffers_pso = clear_buffers_pso,
            .update_lights_pso = update_lights_pso,
            .light_culling_pso = light_culling_pso,
            .z_pre_pass_opaque_pso = z_pre_pass_psos.opaque_pso,
            .z_pre_pass_alpha_tested_pso = z_pre_pass_psos.alpha_tested_pso,
            .geometry_pass_opaque_pso = geometry_pass_psos.opaque_pso,
            .geometry_pass_alpha_tested_pso = geometry_pass_psos.alpha_tested_pso,
            .compute_shading_pso = compute_shading_pso,
            .final_blit_pso = final_blit_pso,

            .meshes = geometry.meshes,
            .materials = geometry.materials,
            .transforms = geometry.transforms,
            .textures = geometry.textures,
            .alpha_tested_mesh_indices = geometry.alpha_tested_mesh_indices,
            .opaque_mesh_indices = geometry.opaque_mesh_indices,
            .position_buffer = geometry.position_buffer,
            .normal_buffer = geometry.normal_buffer,
            .texcoord_buffer = geometry.texcoord_buffer,
            .tangent_buffer = geometry.tangent_buffer,
            .index_buffer = geometry.index_buffer,
            .material_buffer = geometry.material_buffer,
            .transform_buffer = geometry.transform_buffer,

            .need_to_compute_frustrums = true,
            .lights = lighting_resources.lights,
            .frustums_buffer = lighting_resources.frustums_buffer,
            .light_buffer = lighting_resources.light_buffer,
            .light_index_counter_buffer = lighting_resources.light_index_counter_buffer,
            .light_index_list_buffer = lighting_resources.light_index_list_buffer,
            .light_grid_buffer = lighting_resources.light_grid_buffer,

            .view_mode = 0,

            .camera = .{
                .position = Vec3.init(0.0, 1.0, 0.0),
                .forward = Vec3.init(0.0, 0.0, -1.0),
                .pitch = 0.0,
                .yaw = 0.0,
                .znear = 0.1,
                .zfar = 5000.0,
            },
            .mouse = .{
                .cursor_prev_x = 0,
                .cursor_prev_y = 0,
            },
        };
    }

    pub fn deinit(state: *DeferredstateState, allocator: std.mem.Allocator) void {
        state.gctx.finishGpuCommands();
        state.guir.deinit(&state.gctx);
        state.gctx.deinit(allocator);
        common.deinitWindow(allocator);

        state.lights.deinit();

        state.meshes.deinit();
        state.materials.deinit();
        state.transforms.deinit();
        state.textures.deinit();
        state.alpha_tested_mesh_indices.deinit();
        state.opaque_mesh_indices.deinit();
        state.* = undefined;
    }

    pub fn update(state: *DeferredstateState) void {
        state.frame_stats.update(state.gctx.window, window_name);

        common.newImGuiFrame(state.frame_stats.delta_time);

        _ = c.igBegin("Demo Settings", null, 0);

        _ = c.igRadioButton_IntPtr("Lit", &state.view_mode, 0);
        _ = c.igRadioButton_IntPtr("Depth", &state.view_mode, 1);
        _ = c.igRadioButton_IntPtr("Albedo", &state.view_mode, 2);
        _ = c.igRadioButton_IntPtr("World Space Normals", &state.view_mode, 3);
        _ = c.igRadioButton_IntPtr("Metalness", &state.view_mode, 4);
        _ = c.igRadioButton_IntPtr("Roughness", &state.view_mode, 5);
        c.igEnd();
        // Handle camera rotation with mouse.
        {
            var pos: w32.POINT = undefined;
            _ = w32.GetCursorPos(&pos);
            const delta_x = @intToFloat(f32, pos.x) - @intToFloat(f32, state.mouse.cursor_prev_x);
            const delta_y = @intToFloat(f32, pos.y) - @intToFloat(f32, state.mouse.cursor_prev_y);
            state.mouse.cursor_prev_x = pos.x;
            state.mouse.cursor_prev_y = pos.y;

            if (w32.GetAsyncKeyState(w32.VK_RBUTTON) < 0) {
                state.camera.pitch += 0.0025 * delta_y;
                state.camera.yaw += 0.0025 * delta_x;
                state.camera.pitch = math.min(state.camera.pitch, 0.48 * math.pi);
                state.camera.pitch = math.max(state.camera.pitch, -0.48 * math.pi);
                state.camera.yaw = vm.modAngle(state.camera.yaw);
            }
        }

        // Handle camera movement with 'WASDEQ' keys.
        {
            const speed: f32 = 5.0;
            const delta_time = state.frame_stats.delta_time;
            const transform = Mat4.initRotationX(state.camera.pitch).mul(Mat4.initRotationY(state.camera.yaw));
            var forward = Vec3.init(0.0, 0.0, 1.0).transform(transform).normalize();

            state.camera.forward = forward;
            const right = Vec3.init(0.0, 1.0, 0.0).cross(forward).normalize().scale(speed * delta_time);
            forward = forward.scale(speed * delta_time);

            const up = state.camera.forward.cross(right).normalize().scale(speed * delta_time);

            if (w32.GetAsyncKeyState('W') < 0) {
                state.camera.position = state.camera.position.add(forward);
            } else if (w32.GetAsyncKeyState('S') < 0) {
                state.camera.position = state.camera.position.sub(forward);
            }

            if (w32.GetAsyncKeyState('D') < 0) {
                state.camera.position = state.camera.position.add(right);
            } else if (w32.GetAsyncKeyState('A') < 0) {
                state.camera.position = state.camera.position.sub(right);
            }

            if (w32.GetAsyncKeyState('E') < 0) {
                state.camera.position = state.camera.position.add(up);
            } else if (w32.GetAsyncKeyState('Q') < 0) {
                state.camera.position = state.camera.position.sub(up);
            }
        }
    }

    pub fn draw(state: *DeferredstateState) void {
        var gctx = &state.gctx;
        gctx.beginFrame();

        const view_matrix = vm.Mat4.initLookToLh(
            state.camera.position,
            state.camera.forward,
            vm.Vec3.init(0.0, 1.0, 0.0),
        );
        const proj_matrix = vm.Mat4.initPerspectiveFovLh(
            1.0472, // 60 deg
            @intToFloat(f32, gctx.viewport_width) / @intToFloat(f32, gctx.viewport_height),
            state.camera.znear,
            state.camera.zfar,
        );

        var det: f32 = 0;
        const inv_view_matrix = view_matrix.inv(&det);
        const inv_proj_matrix = proj_matrix.inv(&det);
        _ = det;

        const cam_world_to_clip = view_matrix.mul(proj_matrix);

        // Set frame constants
        const frame_const_mem = gctx.allocateUploadMemory(FrameConst, 1);
        frame_const_mem.cpu_slice[0] = .{
            .view = view_matrix.transpose(),
            .proj = proj_matrix.transpose(),
            .view_proj = cam_world_to_clip.transpose(),
            .inv_view = inv_view_matrix.transpose(),
            .inv_proj = inv_proj_matrix.transpose(),
            .camera_position = Vec3.toVec4(state.camera.position),
            .position_buffer_index = state.position_buffer.persistent_descriptor.index,
            .normal_buffer_index = state.normal_buffer.persistent_descriptor.index,
            .texcoord_buffer_index = state.texcoord_buffer.persistent_descriptor.index,
            .tangent_buffer_index = state.tangent_buffer.persistent_descriptor.index,
            .index_buffer_index = state.index_buffer.persistent_descriptor.index,
            .material_buffer_index = state.material_buffer.persistent_descriptor.index,
            .transform_buffer_index = state.transform_buffer.persistent_descriptor.index,
        };

        // Compute Frustum Grid
        const dispatch_params = DispatchParams.init(gctx.viewport_width, gctx.viewport_height);
        const dispatch_params_mem = gctx.allocateUploadMemory(DispatchParams, 1);
        dispatch_params_mem.cpu_slice[0] = dispatch_params;

        if (state.need_to_compute_frustrums) {
            zpix.beginEvent(gctx.cmdlist, "Compute Frustum Grid");
            defer zpix.endEvent(gctx.cmdlist);

            state.need_to_compute_frustrums = false;

            gctx.setCurrentPipeline(state.frustums_grid_pso);
            gctx.cmdlist.SetComputeRoot32BitConstants(
                0,
                2, 
                &.{ gctx.viewport_width, gctx.viewport_height },
                0,
            );
            gctx.cmdlist.SetComputeRootConstantBufferView(1, frame_const_mem.gpu_base);
            gctx.cmdlist.SetComputeRootConstantBufferView(2, dispatch_params_mem.gpu_base);
            gctx.cmdlist.SetComputeRootDescriptorTable(
                3,
                gctx.copyDescriptorsToGpuHeap(1, state.frustums_buffer.uav),
            );
            gctx.cmdlist.Dispatch(dispatch_params.num_thread_groups[0], dispatch_params.num_thread_groups[1], dispatch_params.num_thread_groups[2]);
        }

        // Z-PrePass
        {
            zpix.beginEvent(gctx.cmdlist, "Z Pre Pass");
            defer zpix.endEvent(gctx.cmdlist);

            gctx.addTransitionBarrier(state.depth_texture, d3d12.RESOURCE_STATE_DEPTH_WRITE);
            gctx.flushResourceBarriers();

            // Bind and clear the depth buffer
            gctx.cmdlist.OMSetRenderTargets(0, null, w32.TRUE, &state.depth_texture_dsv);
            // TODO: Switch to Reversed-Z
            gctx.cmdlist.ClearDepthStencilView(state.depth_texture_dsv, d3d12.CLEAR_FLAG_DEPTH, 1.0, 0, 0, null);

            gctx.cmdlist.IASetPrimitiveTopology(.TRIANGLELIST);

            {
                gctx.setCurrentPipeline(state.z_pre_pass_opaque_pso);
                gctx.cmdlist.SetGraphicsRootConstantBufferView(1, frame_const_mem.gpu_base);

                zpix.beginEvent(gctx.cmdlist, "Opaque");
                defer zpix.endEvent(gctx.cmdlist);

                for (state.opaque_mesh_indices.items) |mesh_index| {
                    const mesh = &state.meshes.items[mesh_index];
                    gctx.cmdlist.SetGraphicsRoot32BitConstants(0, 2, &.{ mesh.vertex_offset, mesh.index_offset }, 0);
                    const draw_const_mem = gctx.allocateUploadMemory(DrawConst, 1);
                    draw_const_mem.cpu_slice[0] = .{
                        .material_index = mesh.material_index,
                        .transform_index = mesh.transform_index,
                    };
                    gctx.cmdlist.SetGraphicsRootConstantBufferView(2, draw_const_mem.gpu_base);
                    gctx.cmdlist.DrawInstanced(mesh.num_indices, 1, 0, 0);
                }
            }

            {
                gctx.setCurrentPipeline(state.z_pre_pass_alpha_tested_pso);
                gctx.cmdlist.SetGraphicsRootConstantBufferView(1, frame_const_mem.gpu_base);

                zpix.beginEvent(gctx.cmdlist, "Alpha Tested");
                defer zpix.endEvent(gctx.cmdlist);

                for (state.alpha_tested_mesh_indices.items) |mesh_index| {
                    const mesh = &state.meshes.items[mesh_index];
                    gctx.cmdlist.SetGraphicsRoot32BitConstants(0, 2, &.{ mesh.vertex_offset, mesh.index_offset }, 0);
                    const draw_const_mem = gctx.allocateUploadMemory(DrawConst, 1);
                    draw_const_mem.cpu_slice[0] = .{
                        .material_index = mesh.material_index,
                        .transform_index = mesh.transform_index,
                    };
                    gctx.cmdlist.SetGraphicsRootConstantBufferView(2, draw_const_mem.gpu_base);
                    gctx.cmdlist.DrawInstanced(mesh.num_indices, 1, 0, 0);
                }
            }
        }

        // Light Culling
        {
            zpix.beginEvent(gctx.cmdlist, "Light Culling");
            defer zpix.endEvent(gctx.cmdlist);

            // Clear buffers
            {
                zpix.beginEvent(gctx.cmdlist, "Clear buffers");
                defer zpix.endEvent(gctx.cmdlist);

                gctx.setCurrentPipeline(state.clear_buffers_pso);

                // Root Constants
                gctx.cmdlist.SetComputeRoot32BitConstants(
                    0,
                    2, 
                    &.{ gctx.viewport_width, gctx.viewport_height },
                    0,
                );

                // Frame Constants
                gctx.cmdlist.SetComputeRootConstantBufferView(1, frame_const_mem.gpu_base);

                // Dispatch Params
                gctx.cmdlist.SetComputeRootConstantBufferView(2, dispatch_params_mem.gpu_base);

                gctx.cmdlist.SetComputeRootDescriptorTable(3, blk: {
                    const table = gctx.copyDescriptorsToGpuHeap(1, state.light_index_counter_buffer.uav);
                    _ = gctx.copyDescriptorsToGpuHeap(1, state.light_index_list_buffer.uav);
                    _ = gctx.copyDescriptorsToGpuHeap(1, state.light_grid_buffer.uav);
                    break :blk table;
                });

                gctx.cmdlist.Dispatch(1, 1, 1);
            }

            // Update lights
            {
                zpix.beginEvent(gctx.cmdlist, "Update Lights");
                defer zpix.endEvent(gctx.cmdlist);

                gctx.setCurrentPipeline(state.update_lights_pso);

                // Root Constants
                gctx.cmdlist.SetComputeRoot32BitConstants(
                    0,
                    2, 
                    &.{ gctx.viewport_width, gctx.viewport_height },
                    0,
                );

                // Frame Constants
                gctx.cmdlist.SetComputeRootConstantBufferView(1, frame_const_mem.gpu_base);

                // Dispatch Params
                gctx.cmdlist.SetComputeRootConstantBufferView(2, dispatch_params_mem.gpu_base);

                gctx.cmdlist.SetComputeRootDescriptorTable(3, blk: {
                    const table = gctx.copyDescriptorsToGpuHeap(1, state.light_buffer.uav);
                    break :blk table;
                });

                gctx.addTransitionBarrier(state.light_buffer.resource, d3d12.RESOURCE_STATE_UNORDERED_ACCESS);
                gctx.flushResourceBarriers();

                gctx.cmdlist.Dispatch(1, 1, 1);
            }

            // Transition the depth buffer from Depth attachment to "Texture" attachment
            // TODO: Add more barriers for other buffers
            gctx.addTransitionBarrier(state.depth_texture, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.flushResourceBarriers();

            gctx.setCurrentPipeline(state.light_culling_pso);

            // Root Constants
            gctx.cmdlist.SetComputeRoot32BitConstants(
                0,
                2, 
                &.{ gctx.viewport_width, gctx.viewport_height },
                0,
            );

            // Frame Constants
            gctx.cmdlist.SetComputeRootConstantBufferView(1, frame_const_mem.gpu_base);

            // Dispatch Params
            gctx.cmdlist.SetComputeRootConstantBufferView(2, dispatch_params_mem.gpu_base);

            gctx.cmdlist.SetComputeRootDescriptorTable(3, blk: {
                const table = gctx.copyDescriptorsToGpuHeap(1, state.depth_texture_srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.frustums_buffer.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.light_buffer.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.light_index_counter_buffer.uav);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.light_index_list_buffer.uav);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.light_grid_buffer.uav);
                break :blk table;
            });

            gctx.addTransitionBarrier(state.light_buffer.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.flushResourceBarriers();

            gctx.cmdlist.Dispatch(dispatch_params.num_thread_groups[0], dispatch_params.num_thread_groups[1], dispatch_params.num_thread_groups[2]);
        }

        // Geometry Pass
        {
            zpix.beginEvent(gctx.cmdlist, "Geometry Pass");
            defer zpix.endEvent(gctx.cmdlist);

            gctx.addTransitionBarrier(state.depth_texture, d3d12.RESOURCE_STATE_DEPTH_WRITE);
            // Transition the render targets to render target
            gctx.addTransitionBarrier(state.rt0.resource, d3d12.RESOURCE_STATE_RENDER_TARGET);
            gctx.addTransitionBarrier(state.rt1.resource, d3d12.RESOURCE_STATE_RENDER_TARGET);
            gctx.addTransitionBarrier(state.rt2.resource, d3d12.RESOURCE_STATE_RENDER_TARGET);
            gctx.flushResourceBarriers();

            // Bind GBuffer render targets
            gctx.cmdlist.OMSetRenderTargets(
                3,
                &[_]d3d12.CPU_DESCRIPTOR_HANDLE{ state.rt0.rtv, state.rt1.rtv, state.rt2.rtv },
                w32.FALSE,
                &state.depth_texture_dsv,
            );
            // Clear render targets
            gctx.cmdlist.ClearRenderTargetView(
                state.rt0.rtv,
                &[4]f32{ 0.0, 0.0, 0.0, 1.0 },
                0,
                null,
            );
            gctx.cmdlist.ClearRenderTargetView(
                state.rt1.rtv,
                &[4]f32{ 0.0, 1.0, 0.0, 1.0 },
                0,
                null,
            );
            gctx.cmdlist.ClearRenderTargetView(
                state.rt2.rtv,
                &[4]f32{ 0.0, 0.5, 0.0, 1.0 },
                0,
                null,
            );

            gctx.cmdlist.IASetPrimitiveTopology(.TRIANGLELIST);

            {
                zpix.beginEvent(gctx.cmdlist, "Opaque");
                defer zpix.endEvent(gctx.cmdlist);

                gctx.setCurrentPipeline(state.geometry_pass_opaque_pso);
                gctx.cmdlist.SetGraphicsRootConstantBufferView(1, frame_const_mem.gpu_base);

                for (state.opaque_mesh_indices.items) |mesh_index| {
                    const mesh = &state.meshes.items[mesh_index];

                    gctx.cmdlist.SetGraphicsRoot32BitConstants(0, 2, &.{ mesh.vertex_offset, mesh.index_offset }, 0);
                    const draw_const_mem = gctx.allocateUploadMemory(DrawConst, 1);
                    draw_const_mem.cpu_slice[0] = .{
                        .material_index = mesh.material_index,
                        .transform_index = mesh.transform_index,
                    };
                    gctx.cmdlist.SetGraphicsRootConstantBufferView(2, draw_const_mem.gpu_base);
                    gctx.cmdlist.DrawInstanced(mesh.num_indices, 1, 0, 0);
                }
            }

            {
                zpix.beginEvent(gctx.cmdlist, "Alpha Tested");
                defer zpix.endEvent(gctx.cmdlist);

                gctx.setCurrentPipeline(state.geometry_pass_alpha_tested_pso);
                gctx.cmdlist.SetGraphicsRootConstantBufferView(1, frame_const_mem.gpu_base);

                for (state.alpha_tested_mesh_indices.items) |mesh_index| {
                    const mesh = &state.meshes.items[mesh_index];

                    gctx.cmdlist.SetGraphicsRoot32BitConstants(0, 2, &.{ mesh.vertex_offset, mesh.index_offset }, 0);
                    const draw_const_mem = gctx.allocateUploadMemory(DrawConst, 1);
                    draw_const_mem.cpu_slice[0] = .{
                        .material_index = mesh.material_index,
                        .transform_index = mesh.transform_index,
                    };
                    gctx.cmdlist.SetGraphicsRootConstantBufferView(2, draw_const_mem.gpu_base);
                    gctx.cmdlist.DrawInstanced(mesh.num_indices, 1, 0, 0);
                }
            }
        }

        // Compute Deferred Shading
        {
            zpix.beginEvent(gctx.cmdlist, "Deferred Shading");
            defer zpix.endEvent(gctx.cmdlist);

            // Transition the depth buffer from Depth attachment to "Texture" attachment
            gctx.addTransitionBarrier(state.depth_texture, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            // Transition render targets to texurte attachments
            gctx.addTransitionBarrier(state.rt0.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(state.rt1.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(state.rt2.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(state.light_index_list_buffer.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(state.light_grid_buffer.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.flushResourceBarriers();

            gctx.setCurrentPipeline(state.compute_shading_pso);
            gctx.cmdlist.SetComputeRoot32BitConstants(
                0,
                2, 
                &.{ gctx.viewport_width, gctx.viewport_height },
                0,
            );

            gctx.cmdlist.SetComputeRootConstantBufferView(1, frame_const_mem.gpu_base);
            gctx.cmdlist.SetComputeRootDescriptorTable(2, blk: {
                const table = gctx.copyDescriptorsToGpuHeap(1, state.depth_texture_srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.rt0.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.rt1.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.rt2.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.light_index_list_buffer.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.light_grid_buffer.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.light_buffer.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.rt_hdr.uav);
                break :blk table;
            });

            gctx.cmdlist.Dispatch(dispatch_params.num_thread_groups[0], dispatch_params.num_thread_groups[1], dispatch_params.num_thread_groups[2]);
        }

        const back_buffer = gctx.getBackBuffer();
        // Final Blit
        {
            zpix.beginEvent(gctx.cmdlist, "Final Blit");
            defer zpix.endEvent(gctx.cmdlist);

            // Transition the depth buffer from Depth attachment to "Texture" attachment
            gctx.addTransitionBarrier(state.depth_texture, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            // Transition render targets to texurte attachments
            gctx.addTransitionBarrier(state.rt0.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(state.rt1.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(state.rt2.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(state.rt_hdr.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            // Transition the back buffer to render target
            gctx.addTransitionBarrier(back_buffer.resource_handle, d3d12.RESOURCE_STATE_RENDER_TARGET);
            gctx.flushResourceBarriers();

            gctx.cmdlist.OMSetRenderTargets(
                1,
                &[_]d3d12.CPU_DESCRIPTOR_HANDLE{back_buffer.descriptor_handle},
                w32.TRUE,
                null,
            );
            gctx.cmdlist.ClearRenderTargetView(
                back_buffer.descriptor_handle,
                &[4]f32{ 0.0, 0.0, 0.0, 1.0 },
                0,
                null,
            );

            gctx.setCurrentPipeline(state.final_blit_pso);
            gctx.cmdlist.SetGraphicsRoot32BitConstants(
                0,
                3,
                &.{ state.view_mode, state.camera.znear, state.camera.zfar },
                0,
            );
            gctx.cmdlist.SetGraphicsRootDescriptorTable(1, blk: {
                const table = gctx.copyDescriptorsToGpuHeap(1, state.depth_texture_srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.rt0.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.rt1.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.rt2.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, state.rt_hdr.srv);
                break :blk table;
            });
            gctx.cmdlist.DrawInstanced(3, 1, 0, 0);
        }

        state.guir.draw(gctx);

        gctx.addTransitionBarrier(back_buffer.resource_handle, d3d12.RESOURCE_STATE_PRESENT);
        gctx.flushResourceBarriers();

        gctx.endFrame();
    }

    fn createBuffer(
        gctx: *zd3d12.GraphicsContext,
        resource_desc: *d3d12.RESOURCE_DESC,
        optional_srv_desc: ?*d3d12.SHADER_RESOURCE_VIEW_DESC,
        optional_uav_desc: ?*d3d12.UNORDERED_ACCESS_VIEW_DESC,
        state_after: d3d12.RESOURCE_STATES,
        comptime T: type,
        optional_data: ?*std.ArrayList(T),
    ) Buffer {
        const initial_state: d3d12.RESOURCE_STATES = if (optional_data) |_| d3d12.RESOURCE_STATE_COPY_DEST else state_after;

        if (optional_uav_desc) |_| {
            resource_desc.Flags |= d3d12.RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        }

        const resource = gctx.createCommittedResource(
            .DEFAULT,
            d3d12.HEAP_FLAG_NONE,
            resource_desc,
            initial_state,
            null,
        ) catch |err| hrPanic(err);

        var srv: d3d12.CPU_DESCRIPTOR_HANDLE = undefined;
        if (optional_srv_desc) |srv_desc| {
            srv = gctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);
            gctx.device.CreateShaderResourceView(
                gctx.lookupResource(resource).?,
                srv_desc,
                srv,
            );
        }

        var uav: d3d12.CPU_DESCRIPTOR_HANDLE = undefined;
        if (optional_uav_desc) |uav_desc| {
            uav = gctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);
            gctx.device.CreateUnorderedAccessView(
                gctx.lookupResource(resource).?,
                null,
                uav_desc,
                uav,
            );
        }

        if (optional_data) |data| {
            const upload = gctx.allocateUploadBufferRegion(T, @intCast(u32, data.items.len));
            for (data.items) |element, i| {
                upload.cpu_slice[i] = element;
            }
            gctx.cmdlist.CopyBufferRegion(
                gctx.lookupResource(resource).?,
                0,
                upload.buffer,
                upload.buffer_offset,
                upload.cpu_slice.len * @sizeOf(@TypeOf(upload.cpu_slice[0])),
            );

            gctx.addTransitionBarrier(resource, state_after);
            gctx.flushResourceBarriers();
        }

        return Buffer{
            .resource = resource,
            .srv = srv,
            .uav = uav,
        };
    }

    fn createPersistentResource(
        gctx: *zd3d12.GraphicsContext,
        resource_desc: *d3d12.RESOURCE_DESC,
        srv_desc: *d3d12.SHADER_RESOURCE_VIEW_DESC,
        state_after: d3d12.RESOURCE_STATES,
        comptime T: type,
        optional_data: ?*std.ArrayList(T),
    ) PersistentResource {
        const resource = gctx.createCommittedResource(
            .DEFAULT,
            d3d12.HEAP_FLAG_NONE,
            resource_desc,
            d3d12.RESOURCE_STATE_COPY_DEST,
            null,
        ) catch |err| hrPanic(err);
        const persistent_descriptor = gctx.allocatePersistentGpuDescriptors(1);
        gctx.device.CreateShaderResourceView(
            gctx.lookupResource(resource).?,
            srv_desc,
            persistent_descriptor.cpu_handle,
        );

        if (optional_data) |data| {
            const upload = gctx.allocateUploadBufferRegion(T, @intCast(u32, data.items.len));
            for (data.items) |element, i| {
                upload.cpu_slice[i] = element;
            }
            gctx.cmdlist.CopyBufferRegion(
                gctx.lookupResource(resource).?,
                0,
                upload.buffer,
                upload.buffer_offset,
                upload.cpu_slice.len * @sizeOf(@TypeOf(upload.cpu_slice[0])),
            );
        }

        gctx.addTransitionBarrier(resource, state_after);
        gctx.flushResourceBarriers();

        return PersistentResource{
            .resource = resource,
            .persistent_descriptor = persistent_descriptor,
        };
    }

    fn createRenderTarget(
        gctx: *zd3d12.GraphicsContext,
        format: dxgi.FORMAT,
        clear_value: *const [4]f32,
        create_srv: bool,
        create_uav: bool,
    ) RenderTarget {
        var flags: d3d12.RESOURCE_FLAGS = d3d12.RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        if (create_uav) {
            flags |= d3d12.RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        }

        const resource = gctx.createCommittedResource(
            .DEFAULT,
            d3d12.HEAP_FLAG_NONE,
            &blk: {
                var desc = d3d12.RESOURCE_DESC.initTex2d(
                    format,
                    gctx.viewport_width,
                    gctx.viewport_height,
                    1,
                );
                desc.Flags = flags;
                break :blk desc;
            },
            d3d12.RESOURCE_STATE_RENDER_TARGET,
            &d3d12.CLEAR_VALUE.initColor(format, clear_value),
        ) catch |err| hrPanic(err);

        const rt_rtv = gctx.allocateCpuDescriptors(.RTV, 1);
        gctx.device.CreateRenderTargetView(
            gctx.lookupResource(resource).?,
            null,
            rt_rtv,
        );

        var rt_srv: d3d12.CPU_DESCRIPTOR_HANDLE = undefined;
        if (create_srv) {
            rt_srv = gctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);
            gctx.device.CreateShaderResourceView(
                gctx.lookupResource(resource).?,
                null,
                rt_srv,
            );
        }

        var rt_uav: d3d12.CPU_DESCRIPTOR_HANDLE = undefined;
        if (create_uav) {
            rt_uav = gctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);
            gctx.device.CreateUnorderedAccessView(
                gctx.lookupResource(resource).?,
                null,
                null,
                rt_uav,
            );
        }

        return RenderTarget{
            .resource = resource,
            .rtv = rt_rtv,
            .srv = rt_srv,
            .uav = rt_uav,
        };
    }
};

pub fn main() !void {
    common.init();
    defer common.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var state = try DeferredstateState.init(allocator);
    defer state.deinit(allocator);

    while (common.handleWindowEvents()) {
        state.update();
        state.draw();
    }
}