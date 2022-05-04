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
const Mat4 = vm.Mat4;

pub export const D3D12SDKVersion: u32 = 4;
pub export const D3D12SDKPath: [*:0]const u8 = ".\\d3d12\\";

const content_dir = @import("build_options").content_dir;

const window_name = "zig-gamedev: deferred";
const window_width = 1920;
const window_height = 1080;

const PsoZPrePass_DrawRootConst = struct {
    vertex_offset: u32,
    index_offset: u32,
};

const PsoZPrePass_SceneConst = struct {
    world_to_clip: Mat4,
    position_buffer_index: u32,
    index_buffer_index: u32,
};

const PsoZPrePass_DrawConst = struct {
    object_to_world: Mat4,
};

const PsoGeometry_DrawRootConst = struct {
    vertex_offset: u32,
    index_offset: u32,
};

const PsoGeometryPass_SceneConst = struct {
    world_to_clip: Mat4,
    position_buffer_index: u32,
    normal_buffer_index: u32,
    texcoord_buffer_index: u32,
    tangent_buffer_index: u32,
    index_buffer_index: u32,
    material_buffer_index: u32,
};

const PsoGeometry_DrawConst = struct {
    object_to_world: Mat4,
    material_index: u32,
};

const Mesh = struct {
    index_offset: u32,
    vertex_offset: u32,
    num_indices: u32,
    num_vertices: u32,
    material_index: u32,
};

const Material = struct {
    base_color: Vec3,
    roughness: f32,
    metallic: f32,
    base_color_tex_index: u32,
    metallic_roughness_tex_index: u32,
    normal_tex_index: u32,
};

const Texture = struct {
    resource: zd3d12.ResourceHandle,
    persistent_descriptor: zd3d12.PersistentDescriptor,
};

const PersistentResource = struct {
    resource: zd3d12.ResourceHandle,
    persistent_descriptor: zd3d12.PersistentDescriptor,
};

const RenderTarget = struct {
    resource: zd3d12.ResourceHandle,
    rtv: d3d12.CPU_DESCRIPTOR_HANDLE,
    srv: d3d12.CPU_DESCRIPTOR_HANDLE,
};

const DeferredSample = struct {
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

    // PSOs
    z_pre_pass_pso: zd3d12.PipelineHandle,
    geometry_pass_pso: zd3d12.PipelineHandle,
    debug_view_pso: zd3d12.PipelineHandle,

    // Geometry Data
    position_buffer: PersistentResource,
    normal_buffer: PersistentResource,
    texcoord_buffer: PersistentResource,
    tangent_buffer: PersistentResource,
    index_buffer: PersistentResource,
    material_buffer: PersistentResource,

    meshes: std.ArrayList(Mesh),
    materials: std.ArrayList(Material),
    textures: std.ArrayList(Texture),

    view_mode: i32,

    camera: struct {
        position: Vec3,
        forward: Vec3,
        pitch: f32,
        yaw: f32,
    },
    mouse: struct {
        cursor_prev_x: i32,
        cursor_prev_y: i32,
    },
    light_position: Vec3,

    pub fn init(allocator: std.mem.Allocator) !DeferredSample {
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
        // Z-PrePass
        const z_pre_pass_pso = blk: {
            var pso_desc = d3d12.GRAPHICS_PIPELINE_STATE_DESC.initDefault();
            pso_desc.RTVFormats[0] = .UNKNOWN;
            pso_desc.NumRenderTargets = 0;
            pso_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = 0x0;
            pso_desc.DSVFormat = .D32_FLOAT;
            pso_desc.PrimitiveTopologyType = .TRIANGLE;

            break :blk gctx.createGraphicsShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/z_pre_pass.vs.cso",
                content_dir ++ "shaders/z_pre_pass.ps.cso",
            );
        };

        // Geometry Pass
        const geometry_pass_pso = blk: {
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

            break :blk gctx.createGraphicsShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/geometry_pass.vs.cso",
                content_dir ++ "shaders/geometry_pass.ps.cso",
            );
        };

        // Debug View PSO
        const debug_view_pso = blk: {
            // NOTE: This causes a warning because we're not binding a depth buffer.
            var pso_desc = d3d12.GRAPHICS_PIPELINE_STATE_DESC.initDefault();
            pso_desc.RTVFormats[0] = .R8G8B8A8_UNORM;
            pso_desc.NumRenderTargets = 1;
            pso_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = 0xf;
            pso_desc.PrimitiveTopologyType = .TRIANGLE;

            break :blk gctx.createGraphicsShaderPipeline(
                arena_allocator,
                &pso_desc,
                content_dir ++ "shaders/debug_view.vs.cso",
                content_dir ++ "shaders/debug_view.ps.cso",
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
        const rt0 = createRenderTarget(&gctx, .R10G10B10A2_UNORM, &.{ 0.0, 0.0, 0.0, 1.0 });
        const rt1 = createRenderTarget(&gctx, .R10G10B10A2_UNORM, &.{ 0.0, 1.0, 0.0, 1.0 });
        const rt2 = createRenderTarget(&gctx, .R8G8B8A8_UNORM, &.{ 0.0, 0.5, 0.0, 1.0 });

        gctx.beginFrame();

        var guir = GuiRenderer.init(arena_allocator, &gctx, 1, content_dir);

        // Load Sponza
        const geometry = blk: {
            zmesh.init(arena_allocator);
            defer zmesh.deinit();

            var meshes = std.ArrayList(Mesh).init(allocator);
            var materials = std.ArrayList(Material).init(allocator);
            var textures = std.ArrayList(Texture).init(allocator);

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
                    }) catch unreachable;
                }
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

                    // TODO: Generate mipmaps
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
                    });
                }
            }

            // Create Index Buffer, a persistent view and upload all indices to the GPU
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

            break :blk .{
                .meshes = meshes,
                .materials = materials,
                .textures = textures,
                .position_buffer = position_buffer,
                .normal_buffer = normal_buffer,
                .texcoord_buffer = texcoord_buffer,
                .tangent_buffer = tangent_buffer,
                .index_buffer = index_buffer,
                .material_buffer = material_buffer,
            };
        };

        gctx.endFrame();
        gctx.finishGpuCommands();

        _ = zpix.endCapture();

        return DeferredSample{
            .gctx = gctx,
            .guir = guir,
            .frame_stats = common.FrameStats.init(),

            .depth_texture = depth_texture,
            .depth_texture_dsv = depth_texture_dsv,
            .depth_texture_srv = depth_texture_srv,

            .rt0 = rt0,
            .rt1 = rt1,
            .rt2 = rt2,

            .z_pre_pass_pso = z_pre_pass_pso,
            .geometry_pass_pso = geometry_pass_pso,
            .debug_view_pso = debug_view_pso,

            .meshes = geometry.meshes,
            .materials = geometry.materials,
            .textures = geometry.textures,
            .position_buffer = geometry.position_buffer,
            .normal_buffer = geometry.normal_buffer,
            .texcoord_buffer = geometry.texcoord_buffer,
            .tangent_buffer = geometry.tangent_buffer,
            .index_buffer = geometry.index_buffer,
            .material_buffer = geometry.material_buffer,

            .view_mode = 0,

            .camera = .{
                .position = Vec3.init(0.0, 1.0, 0.0),
                .forward = Vec3.initZero(),
                .pitch = 0.0,
                .yaw = math.pi + 0.25 * math.pi,
            },
            .mouse = .{
                .cursor_prev_x = 0,
                .cursor_prev_y = 0,
            },
            .light_position = Vec3.init(0.0, 5.0, 0.0),
        };
    }

    pub fn deinit(sample: *DeferredSample, allocator: std.mem.Allocator) void {
        sample.gctx.finishGpuCommands();
        sample.guir.deinit(&sample.gctx);
        sample.gctx.deinit(allocator);
        common.deinitWindow(allocator);

        sample.meshes.deinit();
        sample.materials.deinit();
        sample.textures.deinit();
        sample.* = undefined;
    }

    pub fn update(sample: *DeferredSample) void {
        sample.frame_stats.update(sample.gctx.window, window_name);

        common.newImGuiFrame(sample.frame_stats.delta_time);

        _ = c.igBegin("Demo Settings", null, 0);
        _ = c.igRadioButton_IntPtr("Default", &sample.view_mode, 0);
        _ = c.igRadioButton_IntPtr("Depth", &sample.view_mode, 1);
        _ = c.igRadioButton_IntPtr("Albedo", &sample.view_mode, 2);
        _ = c.igRadioButton_IntPtr("World Space Normals", &sample.view_mode, 3);
        _ = c.igRadioButton_IntPtr("Metalness", &sample.view_mode, 4);
        _ = c.igRadioButton_IntPtr("Roughness", &sample.view_mode, 5);
        c.igEnd();
        // Handle camera rotation with mouse.
        {
            var pos: w32.POINT = undefined;
            _ = w32.GetCursorPos(&pos);
            const delta_x = @intToFloat(f32, pos.x) - @intToFloat(f32, sample.mouse.cursor_prev_x);
            const delta_y = @intToFloat(f32, pos.y) - @intToFloat(f32, sample.mouse.cursor_prev_y);
            sample.mouse.cursor_prev_x = pos.x;
            sample.mouse.cursor_prev_y = pos.y;

            if (w32.GetAsyncKeyState(w32.VK_RBUTTON) < 0) {
                sample.camera.pitch += 0.0025 * delta_y;
                sample.camera.yaw += 0.0025 * delta_x;
                sample.camera.pitch = math.min(sample.camera.pitch, 0.48 * math.pi);
                sample.camera.pitch = math.max(sample.camera.pitch, -0.48 * math.pi);
                sample.camera.yaw = vm.modAngle(sample.camera.yaw);
            }
        }

        // Handle camera movement with 'WASDEQ' keys.
        {
            const speed: f32 = 5.0;
            const delta_time = sample.frame_stats.delta_time;
            const transform = Mat4.initRotationX(sample.camera.pitch).mul(Mat4.initRotationY(sample.camera.yaw));
            var forward = Vec3.init(0.0, 0.0, 1.0).transform(transform).normalize();

            sample.camera.forward = forward;
            const right = Vec3.init(0.0, 1.0, 0.0).cross(forward).normalize().scale(speed * delta_time);
            forward = forward.scale(speed * delta_time);

            const up = sample.camera.forward.cross(right).normalize().scale(speed * delta_time);

            if (w32.GetAsyncKeyState('W') < 0) {
                sample.camera.position = sample.camera.position.add(forward);
            } else if (w32.GetAsyncKeyState('S') < 0) {
                sample.camera.position = sample.camera.position.sub(forward);
            }

            if (w32.GetAsyncKeyState('D') < 0) {
                sample.camera.position = sample.camera.position.add(right);
            } else if (w32.GetAsyncKeyState('A') < 0) {
                sample.camera.position = sample.camera.position.sub(right);
            }

            if (w32.GetAsyncKeyState('E') < 0) {
                sample.camera.position = sample.camera.position.add(up);
            } else if (w32.GetAsyncKeyState('Q') < 0) {
                sample.camera.position = sample.camera.position.sub(up);
            }
        }

        sample.light_position.c[0] = @floatCast(f32, 0.5 * @sin(0.25 * sample.frame_stats.time));
    }

    pub fn draw(sample: *DeferredSample) void {
        var gctx = &sample.gctx;
        gctx.beginFrame();

        const cam_world_to_view = vm.Mat4.initLookToLh(
            sample.camera.position,
            sample.camera.forward,
            vm.Vec3.init(0.0, 1.0, 0.0),
        );
        const cam_view_to_clip = vm.Mat4.initPerspectiveFovLh(
            math.pi / 3.0,
            @intToFloat(f32, gctx.viewport_width) / @intToFloat(f32, gctx.viewport_height),
            0.1,
            50.0,
        );
        const cam_world_to_clip = cam_world_to_view.mul(cam_view_to_clip);

        // Z-PrePass
        {
            zpix.beginEvent(gctx.cmdlist, "Z Pre Pass");
            defer zpix.endEvent(gctx.cmdlist);

            gctx.addTransitionBarrier(sample.depth_texture, d3d12.RESOURCE_STATE_DEPTH_WRITE);
            gctx.flushResourceBarriers();

            // Bind and clear the depth buffer
            gctx.cmdlist.OMSetRenderTargets(0, null, w32.TRUE, &sample.depth_texture_dsv);
            // TODO: Switch to Reversed-Z
            gctx.cmdlist.ClearDepthStencilView(sample.depth_texture_dsv, d3d12.CLEAR_FLAG_DEPTH, 1.0, 0, 0, null);

            gctx.cmdlist.IASetPrimitiveTopology(.TRIANGLELIST);

            // Set scene constants
            const scene_const_mem = gctx.allocateUploadMemory(PsoZPrePass_SceneConst, 1);
            scene_const_mem.cpu_slice[0] = .{
                .world_to_clip = cam_world_to_clip.transpose(),
                .position_buffer_index = sample.position_buffer.persistent_descriptor.index,
                .index_buffer_index = sample.index_buffer.persistent_descriptor.index,
            };

            gctx.setCurrentPipeline(sample.z_pre_pass_pso);
            gctx.cmdlist.SetGraphicsRootConstantBufferView(1, scene_const_mem.gpu_base);

            for (sample.meshes.items) |mesh| {
                gctx.cmdlist.SetGraphicsRoot32BitConstants(0, 2, &.{ mesh.vertex_offset, mesh.index_offset }, 0);
                // TODO: Replace this with a storage buffer?
                const draw_const_mem = gctx.allocateUploadMemory(PsoZPrePass_DrawConst, 1);
                draw_const_mem.cpu_slice[0] = .{
                    .object_to_world = Mat4.initScaling(Vec3.init(0.008, 0.008, 0.008)).transpose(),
                };
                gctx.cmdlist.SetGraphicsRootConstantBufferView(2, draw_const_mem.gpu_base);
                gctx.cmdlist.DrawInstanced(mesh.num_indices, 1, 0, 0);
            }
        }

        // Geometry Pass
        {
            zpix.beginEvent(gctx.cmdlist, "Geometry Pass");
            defer zpix.endEvent(gctx.cmdlist);

            // Transition the render targets to render target
            gctx.addTransitionBarrier(sample.rt0.resource, d3d12.RESOURCE_STATE_RENDER_TARGET);
            gctx.addTransitionBarrier(sample.rt1.resource, d3d12.RESOURCE_STATE_RENDER_TARGET);
            gctx.addTransitionBarrier(sample.rt2.resource, d3d12.RESOURCE_STATE_RENDER_TARGET);
            gctx.flushResourceBarriers();

            // Bind GBuffer render targets
            gctx.cmdlist.OMSetRenderTargets(
                3,
                &[_]d3d12.CPU_DESCRIPTOR_HANDLE{ sample.rt0.rtv, sample.rt1.rtv, sample.rt2.rtv },
                w32.FALSE,
                &sample.depth_texture_dsv,
            );
            // Clear render targets
            gctx.cmdlist.ClearRenderTargetView(
                sample.rt0.rtv,
                &[4]f32{ 0.0, 0.0, 0.0, 1.0 },
                0,
                null,
            );
            gctx.cmdlist.ClearRenderTargetView(
                sample.rt1.rtv,
                &[4]f32{ 0.0, 1.0, 0.0, 1.0 },
                0,
                null,
            );
            gctx.cmdlist.ClearRenderTargetView(
                sample.rt2.rtv,
                &[4]f32{ 0.0, 0.5, 0.0, 1.0 },
                0,
                null,
            );

            gctx.cmdlist.IASetPrimitiveTopology(.TRIANGLELIST);

            // Set scene constants
            const scene_const_mem = gctx.allocateUploadMemory(PsoGeometryPass_SceneConst, 1);
            scene_const_mem.cpu_slice[0] = .{
                .world_to_clip = cam_world_to_clip.transpose(),
                .position_buffer_index = sample.position_buffer.persistent_descriptor.index,
                .normal_buffer_index = sample.normal_buffer.persistent_descriptor.index,
                .texcoord_buffer_index = sample.texcoord_buffer.persistent_descriptor.index,
                .tangent_buffer_index = sample.tangent_buffer.persistent_descriptor.index,
                .index_buffer_index = sample.index_buffer.persistent_descriptor.index,
                .material_buffer_index = sample.material_buffer.persistent_descriptor.index,
            };

            gctx.setCurrentPipeline(sample.geometry_pass_pso);
            gctx.cmdlist.SetGraphicsRootConstantBufferView(1, scene_const_mem.gpu_base);

            for (sample.meshes.items) |mesh| {
                gctx.cmdlist.SetGraphicsRoot32BitConstants(0, 2, &.{ mesh.vertex_offset, mesh.index_offset }, 0);
                // TODO: Replace this with a storage buffer?
                const draw_const_mem = gctx.allocateUploadMemory(PsoGeometry_DrawConst, 1);
                draw_const_mem.cpu_slice[0] = .{
                    .object_to_world = Mat4.initScaling(Vec3.init(0.008, 0.008, 0.008)).transpose(),
                    .material_index = mesh.material_index,
                };
                gctx.cmdlist.SetGraphicsRootConstantBufferView(2, draw_const_mem.gpu_base);
                gctx.cmdlist.DrawInstanced(mesh.num_indices, 1, 0, 0);
            }
        }

        const back_buffer = gctx.getBackBuffer();

        // Debug View
        {
            zpix.beginEvent(gctx.cmdlist, "Debug View");
            defer zpix.endEvent(gctx.cmdlist);

            // Transition the depth buffer from Depth attachment to "Texture" attachment
            gctx.addTransitionBarrier(sample.depth_texture, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            // Transition render targets to texurte attachments
            gctx.addTransitionBarrier(sample.rt0.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(sample.rt1.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            gctx.addTransitionBarrier(sample.rt2.resource, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
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

            gctx.setCurrentPipeline(sample.debug_view_pso);
            gctx.cmdlist.SetGraphicsRoot32BitConstants(
                0,
                1,
                &[_]i32{sample.view_mode},
                0,
            );
            gctx.cmdlist.SetGraphicsRootDescriptorTable(1, blk: {
                const table = gctx.copyDescriptorsToGpuHeap(1, sample.depth_texture_srv);
                // TODO: Add other GBuffer textures
                _ = gctx.copyDescriptorsToGpuHeap(1, sample.rt0.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, sample.rt1.srv);
                _ = gctx.copyDescriptorsToGpuHeap(1, sample.rt2.srv);
                break :blk table;
            });
            gctx.cmdlist.DrawInstanced(3, 1, 0, 0);
        }

        sample.guir.draw(gctx);

        gctx.addTransitionBarrier(back_buffer.resource_handle, d3d12.RESOURCE_STATE_PRESENT);
        gctx.flushResourceBarriers();

        gctx.endFrame();
    }

    fn createPersistentResource(
        gctx: *zd3d12.GraphicsContext,
        resource_desc: *d3d12.RESOURCE_DESC,
        srv_desc: *d3d12.SHADER_RESOURCE_VIEW_DESC,
        state_after: d3d12.RESOURCE_STATES,
        comptime T: type,
        data: *std.ArrayList(T),
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

        {
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

        return PersistentResource{
            .resource = resource,
            .persistent_descriptor = persistent_descriptor,
        };
    }

    fn createRenderTarget(
        gctx: *zd3d12.GraphicsContext,
        format: dxgi.FORMAT,
        clear_value: *const [4]f32,
    ) RenderTarget {
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
                desc.Flags = d3d12.RESOURCE_FLAG_ALLOW_RENDER_TARGET;
                break :blk desc;
            },
            d3d12.RESOURCE_STATE_RENDER_TARGET,
            &d3d12.CLEAR_VALUE.initColor(format, clear_value),
        ) catch |err| hrPanic(err);

        const rt_rtv = gctx.allocateCpuDescriptors(.RTV, 1);
        const rt_srv = gctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);

        gctx.device.CreateRenderTargetView(
            gctx.lookupResource(resource).?,
            null,
            rt_rtv,
        );
        gctx.device.CreateShaderResourceView(
            gctx.lookupResource(resource).?,
            null,
            rt_srv,
        );

        return RenderTarget{
            .resource = resource,
            .rtv = rt_rtv,
            .srv = rt_srv,
        };
    }
};

pub fn main() !void {
    common.init();
    defer common.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var sample = try DeferredSample.init(allocator);
    defer sample.deinit(allocator);

    while (common.handleWindowEvents()) {
        sample.update();
        sample.draw();
    }
}
