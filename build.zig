const std = @import("std");


pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcgltf_lib = b.addLibrary(.{
        .name = "zcgltf",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    zcgltf_lib.root_module.addIncludePath(b.path("libs/cgltf"));
    zcgltf_lib.root_module.addCSourceFile(.{
        .file = b.path("libs/cgltf/cgltf.c"),
        .flags = &.{"-std=c99"},
    });

    const mod = b.addModule("zcgltf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.linkLibrary(zcgltf_lib);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.root_module.linkLibrary(zcgltf_lib);

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
