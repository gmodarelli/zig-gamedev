const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    var options = Options{
        .build_mode = b.standardReleaseOptions(),
        .target = b.standardTargetOptions(.{}),
    };

    options.ztracy_enable = b.option(bool, "ztracy-enable", "Enable Tracy profiler") orelse false;
    options.zgpu_dawn_from_source = b.option(
        bool,
        "zgpu-dawn-from-source",
        "Build Dawn (WebGPU) from source",
    ) orelse false;

    // TODO: Remove this
    // On macOS you must compile with `-Dzgpu-dawn-from-source=true`
    // (this will be fixed shortly)
    if (@import("builtin").os.tag == .macos) {
        options.zgpu_dawn_from_source = true;
    }

    if (options.zgpu_dawn_from_source) {
        ensureSubmodules(b.allocator) catch |err| @panic(@errorName(err));
    }

    //
    // Cross-platform demos
    //
    installDemo(b, network_test.build(b, options), "network_test");
    installDemo(b, triangle_wgpu.build(b, options), "triangle_wgpu");
    installDemo(b, procedural_mesh_wgpu.build(b, options), "procedural_mesh_wgpu");
    installDemo(b, textured_quad_wgpu.build(b, options), "textured_quad_wgpu");
    installDemo(b, physically_based_rendering_wgpu.build(b, options), "physically_based_rendering_wgpu");
    installDemo(b, bullet_physics_test_wgpu.build(b, options), "bullet_physics_test_wgpu");

    //
    // Windows-only demos
    //
    if (options.target.isWindows()) {
        options.zpix_enable = b.option(bool, "zpix-enable", "Enable PIX GPU events and markers") orelse false;
        options.enable_dx_debug = b.option(
            bool,
            "enable-dx-debug",
            "Enable debug layer for D3D12, D2D1, DirectML and DXGI",
        ) orelse false;
        options.enable_dx_gpu_debug = b.option(
            bool,
            "enable-dx-gpu-debug",
            "Enable GPU-based validation for D3D12",
        ) orelse false;

        installDemo(b, audio_experiments.build(b, options), "audio_experiments");
        installDemo(b, audio_playback_test.build(b, options), "audio_playback_test");
        installDemo(b, bindless.build(b, options), "bindless");
        installDemo(b, bullet_physics_test.build(b, options), "bullet_physics_test");
        installDemo(b, directml_convolution_test.build(b, options), "directml_convolution_test");
        installDemo(b, mesh_shader_test.build(b, options), "mesh_shader_test");
        installDemo(b, physically_based_rendering.build(b, options), "physically_based_rendering");
        installDemo(b, rasterization.build(b, options), "rasterization");
        installDemo(b, simple3d.build(b, options), "simple3d");
        installDemo(b, simple_raytracer.build(b, options), "simple_raytracer");
        installDemo(b, textured_quad.build(b, options), "textured_quad");
        installDemo(b, vector_graphics_test.build(b, options), "vector_graphics_test");
        installDemo(b, triangle.build(b, options), "triangle");
        installDemo(b, minimal.build(b, options), "minimal");
        installDemo(b, procedural_mesh.build(b, options), "procedural_mesh");
        installDemo(b, deferred.build(b, options), "deferred");

        comptime var intro_index: u32 = 0;
        inline while (intro_index < 7) : (intro_index += 1) {
            const name = "intro" ++ comptime std.fmt.comptimePrint("{}", .{intro_index});
            installDemo(b, intro.build(b, options, intro_index), name);
        }
    }

    //
    // Tests
    //
    const zbullet_tests = @import("libs/zbullet/build.zig").buildTests(b, options.build_mode, options.target);
    const zmesh_tests = @import("libs/zmesh/build.zig").buildTests(b, options.build_mode, options.target);
    const zmath_tests = @import("libs/zmath/build.zig").buildTests(b, options.build_mode, options.target);
    const znoise_tests = @import("libs/znoise/build.zig").buildTests(b, options.build_mode, options.target);
    const znetwork_tests = @import("libs/znetwork/build.zig").buildTests(b, options.build_mode, options.target);
    const zpool_tests = @import("libs/zpool/build.zig").buildTests(b, options.build_mode, options.target);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&zbullet_tests.step);
    test_step.dependOn(&zmesh_tests.step);
    test_step.dependOn(&zmath_tests.step);
    test_step.dependOn(&znoise_tests.step);
    test_step.dependOn(&znetwork_tests.step);
    test_step.dependOn(&zpool_tests.step);
}

const audio_experiments = @import("samples/audio_experiments/build.zig");
const audio_playback_test = @import("samples/audio_playback_test/build.zig");
const bindless = @import("samples/bindless/build.zig");
const bullet_physics_test = @import("samples/bullet_physics_test/build.zig");
const directml_convolution_test = @import("samples/directml_convolution_test/build.zig");
const mesh_shader_test = @import("samples/mesh_shader_test/build.zig");
const physically_based_rendering = @import("samples/physically_based_rendering/build.zig");
const rasterization = @import("samples/rasterization/build.zig");
const simple3d = @import("samples/simple3d/build.zig");
const simple_raytracer = @import("samples/simple_raytracer/build.zig");
const textured_quad = @import("samples/textured_quad/build.zig");
const triangle = @import("samples/triangle/build.zig");
const vector_graphics_test = @import("samples/vector_graphics_test/build.zig");
const intro = @import("samples/intro/build.zig");
const minimal = @import("samples/minimal/build.zig");
const procedural_mesh = @import("samples/procedural_mesh/build.zig");
const network_test = @import("samples/network_test/build.zig");
const triangle_wgpu = @import("samples/triangle_wgpu/build.zig");
const procedural_mesh_wgpu = @import("samples/procedural_mesh_wgpu/build.zig");
const deferred = @import("samples/deferred/build.zig");
const textured_quad_wgpu = @import("samples/textured_quad_wgpu/build.zig");
const physically_based_rendering_wgpu = @import("samples/physically_based_rendering_wgpu/build.zig");
const bullet_physics_test_wgpu = @import("samples/bullet_physics_test_wgpu/build.zig");

pub const Options = struct {
    build_mode: std.builtin.Mode,
    target: std.zig.CrossTarget,

    ztracy_enable: bool = false,
    zpix_enable: bool = false,
    zgpu_dawn_from_source: bool = false,

    enable_dx_debug: bool = false,
    enable_dx_gpu_debug: bool = false,
};

fn installDemo(b: *std.build.Builder, exe: *std.build.LibExeObjStep, comptime name: []const u8) void {
    comptime var desc_name: [256]u8 = undefined;
    comptime _ = std.mem.replace(u8, name, "_", " ", desc_name[0..]);

    const install = b.step(name, "Build '" ++ desc_name ++ "' demo");
    install.dependOn(&b.addInstallArtifact(exe).step);

    const run_step = b.step(name ++ "-run", "Run '" ++ desc_name ++ "' demo");
    const run_cmd = exe.run();
    run_cmd.step.dependOn(install);
    run_step.dependOn(&run_cmd.step);

    b.getInstallStep().dependOn(install);
}

fn ensureSubmodules(allocator: std.mem.Allocator) !void {
    if (std.process.getEnvVarOwned(allocator, "NO_ENSURE_SUBMODULES")) |no_ensure_submodules| {
        if (std.mem.eql(u8, no_ensure_submodules, "true")) return;
    } else |_| {}
    var child = std.ChildProcess.init(&.{ "git", "submodule", "update", "--init", "--recursive" }, allocator);
    child.cwd = thisDir();
    child.stderr = std.io.getStdErr();
    child.stdout = std.io.getStdOut();
    _ = try child.spawnAndWait();
}

fn thisDir() []const u8 {
    comptime {
        return std.fs.path.dirname(@src().file) orelse ".";
    }
}
