const std = @import("std");
const GPA = std.heap.GeneralPurposeAllocator;

var gpa = GPA(.{}){};

const glew_path = "..\\..\\..\\..\\..\\..\\..\\lib\\glew-2.2.0-win32\\glew-2.2.0";
const sdl2_path = "..\\..\\..\\..\\..\\..\\..\\lib\\SDL2-devel-2.30.3-VC\\SDL2-2.30.3";

pub fn build(b: *std.Build) void {
    var allocator = gpa.allocator();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ZigNES",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize
    });

    const imgui = b.addStaticLibrary(.{
        .name = "imgui",
        .target = target,
        .optimize = optimize
    });
    imgui.linkLibCpp();

    imgui.addCSourceFiles(.{
        .files = &[_][]const u8{
            "libs/cimgui/cimgui.cpp",
            "libs/cimgui/imgui/imgui.cpp",
            "libs/cimgui/imgui/imgui_demo.cpp",
            "libs/cimgui/imgui/imgui_draw.cpp",
            "libs/cimgui/imgui/imgui_tables.cpp",
            "libs/cimgui/imgui/backends/imgui_impl_sdl2.cpp",
            "libs/cimgui/imgui/backends/imgui_impl_opengl3.cpp",
            "libs/cimgui/imgui/imgui_widgets.cpp",
        },
        .flags = &[_][]const u8{
            "-std=c++17", 
            // "-DCIMGUI_DEFINE_ENUMS_AND_STRUCTS",
            "-DIMGUI_IMPL_API=extern \"C\" __declspec(dllexport)",
            "-DCIMGUI_USE_SDL2",
            "-DCIMGUI_USE_OPENGL3"
        }
    });

    const sdl2_include_path = std.fs.path.join(allocator, &.{sdl2_path, "include"}) catch |err| {
        std.debug.print("{s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(sdl2_include_path);
    const sdl2_lib_path = std.fs.path.join(allocator, &.{sdl2_path, "lib\\x64"}) catch |err| {
        std.debug.print("{s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(sdl2_lib_path);
    const sdl2_dll_path = std.fs.path.join(allocator, &.{sdl2_lib_path, "SDL2.dll"}) catch |err| {
        std.debug.print("{s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(sdl2_dll_path);

    imgui.addIncludePath(b.path("./libs/cimgui/imgui"));
    imgui.addAfterIncludePath(b.path(sdl2_include_path));
    imgui.addLibraryPath(b.path(sdl2_lib_path));
    
    imgui.linkSystemLibrary("opengl32");
    // imgui.linkSystemLibrary2("sdl2", .{
    //     .needed = true,
    //     .preferred_link_mode = .static,
    //     .search_strategy = .paths_first
    // });
    imgui.linkSystemLibrary("sdl2");

    exe.addIncludePath(b.path("./libs/cimgui"));
    exe.addIncludePath(b.path("./libs/cimgui/generator/output"));
    exe.linkLibrary(imgui);

    exe.addIncludePath(b.path(sdl2_include_path));
    exe.addLibraryPath(b.path(sdl2_lib_path));
    b.installBinFile(sdl2_dll_path, "SDL2.dll");

    const glew_include_path = std.fs.path.join(allocator, &.{glew_path, "include"}) catch |err| {
        std.debug.print("{s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(glew_include_path);
    const glew_lib_path = std.fs.path.join(allocator, &.{glew_path, "lib"}) catch |err| {
        std.debug.print("{s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(glew_lib_path);

    exe.addIncludePath(b.path(glew_include_path));
    exe.addLibraryPath(b.path(glew_lib_path));

    exe.linkSystemLibrary("opengl32");
    exe.linkSystemLibrary2("sdl2", .{
        .needed = true,
        .preferred_link_mode = .static,
        .search_strategy = .paths_first
    });
    // exe.linkSystemLibrary("sdl2");
    exe.linkSystemLibrary2("glew32", .{
        .needed = true,
        .preferred_link_mode = .static,
        .search_strategy = .paths_first
    });
    // exe.linkSystemLibrary("glew32");
    exe.linkLibC();
    // Only output debug messages in debug build
    // if (exe. == .Debug) {
    //     exe.subsystem = .Console;
    // } else {
    //     exe.subsystem = .Windows;
    // }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ZigNES");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("./src/tests.zig"),
        .target = target,
        .optimize = optimize
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}