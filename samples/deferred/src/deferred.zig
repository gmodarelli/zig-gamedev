const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const zwin32 = @import("zwin32");
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

const Vec2 = vm.Vec2;
const Vec3 = vm.Vec3;
const Vec4 = vm.Vec4;
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

const Mesh = struct {
    index_offset: u32,
    vertex_offset: u32,
    num_indices: u32,
    num_vertices: u32,
};

const DeferredSample = struct {
    gctx: zd3d12.GraphicsContext,
    guir: GuiRenderer,
    frame_stats: common.FrameStats,

    // Depth Texture for Z Pre Pass, GBuffer Pass
    depth_texture: zd3d12.ResourceHandle,
    depth_texture_dsv: d3d12.CPU_DESCRIPTOR_HANDLE,
    depth_texture_srv: d3d12.CPU_DESCRIPTOR_HANDLE,

    // PSOs
    z_pre_pass_pso: zd3d12.PipelineHandle,
    debug_view_pso: zd3d12.PipelineHandle,

    // Geometry Data
    position_buffer: zd3d12.ResourceHandle,
    position_buffer_descriptor: zd3d12.PersistentDescriptor,
    index_buffer: zd3d12.ResourceHandle,
    index_buffer_descriptor: zd3d12.PersistentDescriptor,
    meshes: std.ArrayList(Mesh),

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
        gctx.device.CreateShaderResourceView(
            gctx.lookupResource(depth_texture).?,
            &d3d12.SHADER_RESOURCE_VIEW_DESC{
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
            },
            depth_texture_srv
        );

        gctx.beginFrame();

        var guir = GuiRenderer.init(arena_allocator, &gctx, 1, content_dir);

        // Load Sponza
        const geometry = blk: {
            zmesh.init(arena_allocator);
            defer zmesh.deinit();

            var meshes = std.ArrayList(Mesh).init(allocator);

            const data_handle = try zmesh.gltf.parseAndLoadFile(content_dir ++ "Sponza/Sponza.gltf");
            defer zmesh.gltf.freeData(data_handle);

            var indices = std.ArrayList(u32).init(arena_allocator);
            var positions = std.ArrayList([3]f32).init(arena_allocator);

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
                        null,
                        null,
                        null,
                    );

                    meshes.append(.{
                        .index_offset = @intCast(u32, pre_indices_len),
                        .vertex_offset = @intCast(u32, pre_positions_len),
                        .num_indices = @intCast(u32, indices.items.len - pre_indices_len),
                        .num_vertices = @intCast(u32, positions.items.len - pre_positions_len),
                    }) catch unreachable;
                }
            }

            // Create Position Buffer, a persisten view and upload all positions to the GPU
            const position_buffer = gctx.createCommittedResource(
                .DEFAULT,
                d3d12.HEAP_FLAG_NONE,
                &d3d12.RESOURCE_DESC.initBuffer(positions.items.len * @sizeOf([3]f32)),
                d3d12.RESOURCE_STATE_COPY_DEST,
                null,
            ) catch |err| hrPanic(err);
            const position_buffer_descriptor = gctx.allocatePersistentGpuDescriptors(1);
            gctx.device.CreateShaderResourceView(
                gctx.lookupResource(position_buffer).?,
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initStructuredBuffer(
                    0,
                    @intCast(u32, positions.items.len),
                    @sizeOf([3]f32),
                ),
                position_buffer_descriptor.cpu_handle,
            );

            {
                const upload = gctx.allocateUploadBufferRegion([3]f32, @intCast(u32, positions.items.len));
                for (positions.items) |position, i| {
                    upload.cpu_slice[i] = position;
                }
                gctx.cmdlist.CopyBufferRegion(
                    gctx.lookupResource(position_buffer).?,
                    0,
                    upload.buffer,
                    upload.buffer_offset,
                    upload.cpu_slice.len * @sizeOf(@TypeOf(upload.cpu_slice[0])),
                );
                gctx.addTransitionBarrier(position_buffer, d3d12.RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                gctx.flushResourceBarriers();
            }

            // Create Index Buffer, a persistent view and upload all indices to the GPU
            const index_buffer = gctx.createCommittedResource(
                .DEFAULT,
                d3d12.HEAP_FLAG_NONE,
                &d3d12.RESOURCE_DESC.initBuffer(indices.items.len * @sizeOf(u32)),
                d3d12.RESOURCE_STATE_COPY_DEST,
                null,
            ) catch |err| hrPanic(err);
            const index_buffer_descriptor = gctx.allocatePersistentGpuDescriptors(1);
            gctx.device.CreateShaderResourceView(
                gctx.lookupResource(index_buffer).?,
                &d3d12.SHADER_RESOURCE_VIEW_DESC.initTypedBuffer(
                    .R32_UINT,
                    0,
                    @intCast(u32, indices.items.len),
                ),
                index_buffer_descriptor.cpu_handle,
            );

            {
                const upload = gctx.allocateUploadBufferRegion(u32, @intCast(u32, indices.items.len));
                for (indices.items) |index, i| {
                    upload.cpu_slice[i] = index;
                }
                gctx.cmdlist.CopyBufferRegion(
                    gctx.lookupResource(index_buffer).?,
                    0,
                    upload.buffer,
                    upload.buffer_offset,
                    upload.cpu_slice.len * @sizeOf(@TypeOf(upload.cpu_slice[0])),
                );
                gctx.addTransitionBarrier(index_buffer, d3d12.RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                gctx.flushResourceBarriers();
            }

            break :blk .{
                .meshes = meshes,
                .position_buffer = position_buffer,
                .position_buffer_descriptor = position_buffer_descriptor,
                .index_buffer = index_buffer,
                .index_buffer_descriptor = index_buffer_descriptor,
            };
        };

        gctx.endFrame();
        gctx.finishGpuCommands();

        _ = zpix.endCapture();

        return DeferredSample {
            .gctx = gctx,
            .guir = guir,
            .frame_stats = common.FrameStats.init(),

            .depth_texture = depth_texture,
            .depth_texture_dsv = depth_texture_dsv,
            .depth_texture_srv = depth_texture_srv,

            .debug_view_pso = debug_view_pso,
            .z_pre_pass_pso = z_pre_pass_pso,

            .meshes = geometry.meshes,
            .position_buffer = geometry.position_buffer,
            .position_buffer_descriptor = geometry.position_buffer_descriptor,
            .index_buffer = geometry.index_buffer,
            .index_buffer_descriptor = geometry.index_buffer_descriptor,

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
        sample.* = undefined;
    }

    pub fn update(sample: *DeferredSample) void {
        sample.frame_stats.update(sample.gctx.window, window_name);

        common.newImGuiFrame(sample.frame_stats.delta_time);

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
                .position_buffer_index = sample.position_buffer_descriptor.index,
                .index_buffer_index = sample.index_buffer_descriptor.index,
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

        const back_buffer = gctx.getBackBuffer();

        // Debug View
        {
            zpix.beginEvent(gctx.cmdlist, "Debug View");
            defer zpix.endEvent(gctx.cmdlist);

            // Transition the depth buffer from Depth attachment to "Texture" attachment
            gctx.addTransitionBarrier(sample.depth_texture, d3d12.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
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
            gctx.cmdlist.SetGraphicsRootDescriptorTable(0, blk: {
                const table = gctx.copyDescriptorsToGpuHeap(1, sample.depth_texture_srv);
                // TODO: Add other GBuffer textures
                // _ = gctx.copyDescriptorsToGpuHeap(1, gbuffer0_srv);
                break :blk table;
            });
            gctx.cmdlist.DrawInstanced(3, 1, 0, 0);
        }

        sample.guir.draw(gctx);

        gctx.addTransitionBarrier(back_buffer.resource_handle, d3d12.RESOURCE_STATE_PRESENT);
        gctx.flushResourceBarriers();

        gctx.endFrame();
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