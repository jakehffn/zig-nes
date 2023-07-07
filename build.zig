const std = @import("std");
// Version 0.11.0

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ZigNES",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const imgui = b.addStaticLibrary(.{
        .name = "imgui",
        .target = target,
        .optimize = optimize
    });
    imgui.linkLibC();

    imgui.addCSourceFiles( 
        &[_][]const u8{
            "libs/cimgui/cimgui.cpp",
            "libs/cimgui/imgui/imgui.cpp",
            "libs/cimgui/imgui/imgui_demo.cpp",
            "libs/cimgui/imgui/imgui_draw.cpp",
            "libs/cimgui/imgui/imgui_tables.cpp",
            "libs/cimgui/imgui/backends/imgui_impl_sdl2.cpp",
            "libs/cimgui/imgui/backends/imgui_impl_opengl3.cpp",
            "libs/cimgui/imgui/imgui_widgets.cpp",
        },
        &[_][]const u8{"-std=c++17"}
    );

    imgui.addIncludePath("./libs/cimgui/imgui");
    
    const sdl_path = "C:/lib/SDL2-2.26.4/";
    // imgui also needs sdl to compile
    imgui.addIncludePath(sdl_path ++ "include");

    exe.addIncludePath("./libs/cimgui");
    exe.addIncludePath("./libs/cimgui/imgui");
    exe.linkLibrary(imgui);

    exe.addIncludePath(sdl_path ++ "include");
    exe.addLibraryPath(sdl_path ++ "lib/x64");
    b.installBinFile(sdl_path ++ "lib/x64/SDL2.dll", "SDL2.dll");

    exe.linkSystemLibrary("sdl2");
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ZigNES");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "./src/tests.zig"},
        .target = target,
        .optimize = optimize
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}