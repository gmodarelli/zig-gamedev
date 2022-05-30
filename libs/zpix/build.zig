const std = @import("std");

pub const BuildOptions = struct {
    enable_zpix: bool = false,
};

pub const BuildOptionsStep = struct {
    options: BuildOptions,
    step: *std.build.OptionsStep,

    pub fn init(b: *std.build.Builder, options: BuildOptions) BuildOptionsStep {
        const bos = BuildOptionsStep{
            .options = options,
            .step = b.addOptions(),
        };
        bos.step.addOption(bool, "enable_zpix", bos.options.enable_zpix);
        return bos;
    }

    pub fn getPkg(bos: BuildOptionsStep) std.build.Pkg {
        return bos.step.getPackage("zpix_options");
    }

    fn addTo(bos: BuildOptionsStep, target_step: *std.build.LibExeObjStep) void {
        target_step.addOptions("zpix_options", bos.step);
    }
};

pub fn getPkg(dependencies: []const std.build.Pkg) std.build.Pkg {
    return .{
        .name = "zpix",
        .source = .{ .path = thisDir() ++ "/src/zpix.zig" },
        .dependencies = dependencies,
    };
}

pub fn link(exe: *std.build.LibExeObjStep, bos: BuildOptionsStep) void {
    bos.addTo(exe);
}

fn thisDir() []const u8 {
    comptime {
        return std.fs.path.dirname(@src().file) orelse ".";
    }
}
