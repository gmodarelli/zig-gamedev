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

const DeferredSample = struct {
    gctx: zd3d12.GraphicsContext,
    guir: GuiRenderer,
    frame_stats: common.FrameStats,

    // Depth Texture for Z Pre Pass, GBuffer Pass
    depth_texture: zd3d12.ResourceHandle,
    depth_texture_dsv: d3d12.CPU_DESCRIPTOR_HANDLE,
    depth_texture_srv: d3d12.CPU_DESCRIPTOR_HANDLE,

    // PSOs
    debug_view_pso: zd3d12.PipelineHandle,

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
        // Debug View PSO
        const debug_view_pso = blk: {
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
        _ = cam_world_to_clip;

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