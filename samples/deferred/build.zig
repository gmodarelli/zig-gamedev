const std = @import("std");
const zwin32 = @import("../../libs/zwin32/build.zig");
const ztracy = @import("../../libs/ztracy/build.zig");
const zd3d12 = @import("../../libs/zd3d12/build.zig");
const zpix = @import("../../libs/zpix/build.zig");
const zmesh = @import("../../libs/zmesh/build.zig");
const common = @import("../../libs/common/build.zig");

const Options = @import("../../build.zig").Options;
const content_dir = "deferred_content/";

pub fn build(b: *std.build.Builder, options: Options) *std.build.LibExeObjStep {
    const exe_options = b.addOptions();
    exe_options.addOption(bool, "enable_pix", options.enable_pix);
    exe_options.addOption(bool, "enable_dx_debug", options.enable_dx_debug);
    exe_options.addOption(bool, "enable_dx_gpu_debug", options.enable_dx_gpu_debug);
    exe_options.addOption(bool, "enable_tracy", options.enable_tracy);
    exe_options.addOption(bool, "enable_d2d", false);
    exe_options.addOption([]const u8, "content_dir", content_dir);

    const exe = b.addExecutable("deferred", thisDir() ++ "/src/deferred.zig");
    exe.setBuildMode(options.build_mode);
    exe.setTarget(options.target);
    exe.addOptions("build_options", exe_options);

    const dxc_step = buildShaders(b);
    const install_content_step = b.addInstallDirectory(.{
        .source_dir = thisDir() ++ "/" ++ content_dir,
        .install_dir = .{ .custom = "" },
        .install_subdir = "bin/" ++ content_dir,
    });
    install_content_step.step.dependOn(dxc_step);
    exe.step.dependOn(&install_content_step.step);

    // This is needed to export symbols from an .exe file.
    // We export D3D12SDKVersion and D3D12SDKPath symbols which
    // is required by DirectX 12 Agility SDK.
    exe.rdynamic = true;
    exe.want_lto = false;

    const options_pkg = exe_options.getPackage("build_options");
    exe.addPackage(ztracy.getPkg(b, options_pkg));
    exe.addPackage(zd3d12.getPkg(b, options_pkg));
    exe.addPackage(zpix.getPkg(b, options_pkg));
    exe.addPackage(zmesh.pkg);
    exe.addPackage(common.getPkg(b, options_pkg));
    exe.addPackage(zwin32.pkg);

    ztracy.link(exe, options.enable_tracy, .{});
    zd3d12.link(exe);
    zmesh.link(exe);
    common.link(exe);

    return exe;
}

fn buildShaders(b: *std.build.Builder) *std.build.Step {
    const dxc_step = b.step("deferred-dxc", "Build shaders for 'deferred' demo");

    var dxc_command = makeDxcCmd(
        "../../libs/common/src/hlsl/common.hlsl",
        "vsImGui",
        "imgui.vs.cso",
        "vs",
        "PSO__IMGUI",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);
    dxc_command = makeDxcCmd(
        "../../libs/common/src/hlsl/common.hlsl",
        "psImGui",
        "imgui.ps.cso",
        "ps",
        "PSO__IMGUI",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "../../libs/common/src/hlsl/common.hlsl",
        "csGenerateMipmaps",
        "generate_mipmaps.cs.cso",
        "cs",
        "PSO__GENERATE_MIPMAPS",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "vsZPrePass",
        "z_pre_pass.vs.cso",
        "vs",
        "PSO__Z_PRE_PASS",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "psZPrePass",
        "z_pre_pass_opaque.ps.cso",
        "ps",
        "PSO__Z_PRE_PASS",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "psZPrePass",
        "z_pre_pass_alpha_tested.ps.cso",
        "ps",
        "PSO__Z_PRE_PASS_ALPHA_TESTED",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "vsGeometryPass",
        "geometry_pass.vs.cso",
        "vs",
        "PSO__GEOMETRY_PASS",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "psGeometryPass",
        "geometry_pass_opaque.ps.cso",
        "ps",
        "PSO__GEOMETRY_PASS",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "psGeometryPass",
        "geometry_pass_alpha_tested.ps.cso",
        "ps",
        "PSO__GEOMETRY_PASS_ALPHA_TESTED",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "csDeferredShading",
        "deferred_shading.cs.cso",
        "cs",
        "PSO__DEFERRED_COMPUTE_SHADING",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/light_culling.hlsl",
        "csComputeFrustum",
        "compute_frustums.cs.cso",
        "cs",
        "PSO__LIGHTING_COMPUTE_FRUSTUMS",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "vsDebugView",
        "debug_view.vs.cso",
        "vs",
        "PSO__DEBUG_VIEW",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    dxc_command = makeDxcCmd(
        "src/hlsl/deferred.hlsl",
        "psDebugView",
        "debug_view.ps.cso",
        "ps",
        "PSO__DEBUG_VIEW",
    );
    dxc_step.dependOn(&b.addSystemCommand(&dxc_command).step);

    return dxc_step;
}

fn makeDxcCmd(
    comptime input_path: []const u8,
    comptime entry_point: []const u8,
    comptime output_filename: []const u8,
    comptime profile: []const u8,
    comptime define: []const u8,
) [9][]const u8 {
    const shader_ver = "6_6";
    const shader_dir = thisDir() ++ "/" ++ content_dir ++ "shaders/";
    return [9][]const u8{
        thisDir() ++ "/../../libs/zwin32/bin/x64/dxc.exe",
        thisDir() ++ "/" ++ input_path,
        if (entry_point.len == 0) "" else "/E " ++ entry_point,
        "/Fo " ++ shader_dir ++ output_filename,
        "/T " ++ profile ++ "_" ++ shader_ver,
        if (define.len == 0) "" else "/D " ++ define,
        "/WX",
        "/Ges",
        "/O3",
    };
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}