const std = @import("std");
const GPA = std.heap.GeneralPurposeAllocator;

var gpa = GPA(.{}){};

pub fn build(b: *std.Build) void {
    var allocator = gpa.allocator();

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
    imgui.linkLibCpp();

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
        &[_][]const u8{
            "-std=c++17", 
            // "-DCIMGUI_DEFINE_ENUMS_AND_STRUCTS",
            "-DIMGUI_IMPL_API=extern \"C\" __declspec(dllexport)",
            "-DCIMGUI_USE_SDL2",
            "-DCIMGUI_USE_OPENGL3"
        }
    );

    const sdl2_path = std.process.getEnvVarOwned(allocator, "SDL2_PATH") catch {
        std.debug.print("Build Error: ENV variable 'SDL2_PATH' not found", .{});
        return;
    };
    defer allocator.free(sdl2_path);

    const sdl2_include_path = std.fs.path.join(allocator, &.{sdl2_path, "include"}) catch |err| {
        std.debug.print("{s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(sdl2_include_path);
    const sdl2_lib_path = std.fs.path.join(allocator, &.{sdl2_path, "lib/x64"}) catch |err| {
        std.debug.print("{s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(sdl2_lib_path);
    const sdl2_dll_path = std.fs.path.join(allocator, &.{sdl2_lib_path, "SDL2.dll"}) catch |err| {
        std.debug.print("{s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(sdl2_dll_path);

    imgui.addIncludePath(.{.path="./libs/cimgui/imgui"});
    imgui.addIncludePath(.{.path=sdl2_include_path});
    imgui.addLibraryPath(.{.path=sdl2_lib_path});
    
    imgui.linkSystemLibrary("opengl32");
    imgui.linkSystemLibrary("sdl2");

    exe.addIncludePath(.{.path="./libs/cimgui"});
    exe.addIncludePath(.{.path="./libs/cimgui/generator/output"});
    exe.linkLibrary(imgui);

    exe.addIncludePath(.{.path=sdl2_include_path});
    exe.addLibraryPath(.{.path=sdl2_lib_path});
    b.installBinFile(sdl2_dll_path, "SDL2.dll");

    const glew_path = std.process.getEnvVarOwned(allocator, "GLEW_PATH") catch {
        std.debug.print("Build Error: ENV variable 'GLEW_PATH' not found", .{});
        return;
    };
    defer allocator.free(glew_path);
    
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

    exe.addIncludePath(.{.path=glew_include_path});
    exe.addLibraryPath(.{.path=glew_lib_path});

    exe.linkSystemLibrary("opengl32");
    exe.linkSystemLibrary("sdl2");
    exe.linkSystemLibrary("glew32");
    exe.linkLibC();
    // Only output debug messages in debug build
    if (exe.optimize == .Debug) {
        exe.subsystem = .Console;
    } else {
        exe.subsystem = .Windows;
    }
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