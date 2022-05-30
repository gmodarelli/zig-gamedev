const std = @import("std");

pub fn getPkg(dependencies: []const std.build.Pkg) std.build.Pkg {
    return .{
        .name = "common",
        .source = .{ .path = thisDir() ++ "/src/common.zig" },
        .dependencies = dependencies,
    };
}

pub fn build(b: *std.build.Builder) void {
    _ = b;
}

pub fn link(exe: *std.build.LibExeObjStep) void {
    const lib = buildLibrary(exe);
    exe.linkLibrary(lib);
    exe.addIncludeDir(thisDir() ++ "/src/c");
    exe.addIncludeDir(thisDir() ++ "/../zgpu/libs/imgui");
    exe.addIncludeDir(thisDir() ++ "/../zmesh/libs/cgltf");
    exe.addIncludeDir(thisDir() ++ "/../zgpu/libs/stb");
}

fn buildLibrary(exe: *std.build.LibExeObjStep) *std.build.LibExeObjStep {
    const lib = exe.builder.addStaticLibrary("common", thisDir() ++ "/src/common.zig");

    lib.setBuildMode(exe.build_mode);
    lib.setTarget(exe.target);
    lib.want_lto = false;
    lib.addIncludeDir(thisDir() ++ "/src/c");

    lib.linkSystemLibrary("c");
    lib.linkSystemLibrary("c++");
    lib.linkSystemLibrary("imm32");

    lib.addIncludeDir(thisDir() ++ "/../zgpu/libs");
    lib.addCSourceFile(thisDir() ++ "/../zgpu/libs/imgui/imgui.cpp", &.{""});
    lib.addCSourceFile(thisDir() ++ "/../zgpu/libs/imgui/imgui_widgets.cpp", &.{""});
    lib.addCSourceFile(thisDir() ++ "/../zgpu/libs/imgui/imgui_tables.cpp", &.{""});
    lib.addCSourceFile(thisDir() ++ "/../zgpu/libs/imgui/imgui_draw.cpp", &.{""});
    lib.addCSourceFile(thisDir() ++ "/../zgpu/libs/imgui/imgui_demo.cpp", &.{""});
    lib.addCSourceFile(thisDir() ++ "/../zgpu/libs/imgui/cimgui.cpp", &.{""});

    lib.addIncludeDir(thisDir() ++ "/../zmesh/libs/cgltf");
    lib.addCSourceFile(thisDir() ++ "/../zmesh/libs/cgltf/cgltf.c", &.{"-std=c99"});

    lib.addIncludeDir(thisDir() ++ "/../zgpu/libs/stb");
    lib.addCSourceFile(thisDir() ++ "/../zgpu/libs/stb/stb_image.c", &.{"-std=c99"});

    return lib;
}

fn thisDir() []const u8 {
    comptime {
        return std.fs.path.dirname(@src().file) orelse ".";
    }
}
