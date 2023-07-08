const std = @import("std");
const Allocator = std.mem.Allocator;

const MainBus = @import("./cpu/main_bus.zig");
const Cpu = @import("./cpu/cpu.zig").Cpu;

const PpuBus = @import("./ppu/ppu_bus.zig");
const Ppu = @import("./ppu/ppu.zig").Ppu;

const Ram = @import("./bus/ram.zig").Ram;
const MemoryMirror = @import("./bus/memory_mirror.zig").MemoryMirror;
const Rom = @import("./rom/rom.zig");

const ControllerStatus = @import("./bus/controller.zig").Status;

const Self = @This();

const CpuType = Cpu("./log/ZigNES.log");
const PpuType = Ppu("./log/ZigNES_PPU.log");

cpu: CpuType = undefined,
main_bus: MainBus = undefined,

ppu: PpuType = undefined,
ppu_bus: PpuBus = undefined,

rom: ?Rom = null,

pub fn init(self: *Self, allocator: Allocator) !void {
    self.ppu_bus = try PpuBus.init(allocator);
    self.ppu_bus.setCallbacks();

    self.ppu = try PpuType.init(&self.ppu_bus);

    self.main_bus = try MainBus.init(allocator);
    self.main_bus.setCallbacks(&self.ppu);

    self.cpu = try CpuType.init(&self.main_bus);

    self.ppu.setMainBus(&self.main_bus);
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.ppu_bus.deinit(allocator);
    self.ppu.deinit();
    self.main_bus.deinit(allocator);
    self.cpu.deinit();

    if (self.rom) |rom| {
        rom.deinit();
    }
}

pub fn loadRom(self: *Self, rom_path: []const u8, allocator: Allocator) void {

    if (self.rom) |*old_rom| {
        old_rom.deinit();
    }
   
    self.rom = Rom.init(allocator);
    self.rom.?.load(rom_path) catch {
        std.debug.print("ZigNES: Unable to load ROM file", .{});
        return;
    };

    self.main_bus.loadRom(&self.rom.?);
    self.ppu_bus.loadRom(&self.rom.?);

    // Reset vectors only available at this point
    self.cpu.reset();
}

pub fn stepFrame(self: *Self) void {
    // This is about the number of cpu cycles per frame
    for (0..29780) |_| {
        self.cpu.step();
        // In the future, it would be nice to implement a PPU stack
        // Explained in this: https://gist.github.com/adamveld12/d0398717145a2c8dedab
        self.ppu.step();
        self.ppu.step();
        self.ppu.step();
    }
}

pub fn setControllerStatus(self: *Self, controller_status: ControllerStatus) void {
    self.main_bus.controller.status = controller_status;
}

pub fn getScreenPixels(self: *Self) *anyopaque {
    return &self.ppu.screen.data;
}

pub fn resetCpu(self: *Self) void {
    self.cpu.reset();
}