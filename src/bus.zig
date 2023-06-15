const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;

pub const Bus = struct {
    pub const BusCallback = struct {
        const Self = @This();

        ptr: *anyopaque,

        readCallbackFn: ReadCallback,
        writeCallbackFn: WriteCallback,

        pub const ReadCallback = *const fn (*anyopaque, u16) u8;
        pub const WriteCallback = *const fn (*anyopaque, u16, u8) void;

        pub fn init(ptr: anytype, comptime read_callback: fn (ptr: @TypeOf(ptr), address: u16) u8, comptime write_callback: fn (ptr: @TypeOf(ptr), address: u16, data: u8) void) Self {
            const Ptr = @TypeOf(ptr);
            const ptr_info = @typeInfo(Ptr);

            if (ptr_info != .Pointer) @compileError("ptr must be a pointer");
            if (ptr_info.Pointer.size != .One) @compileError("ptr must be a single item pointer");
            if (@typeInfo(ptr_info.Pointer.child) != .Struct) @compileError("ptr must be a pointer to a struct");

            const gen = struct {
                fn readCallback(pointer: *anyopaque, address: u16) u8 {
                    const alignment = @typeInfo(Ptr).Pointer.alignment;
                    const self = @ptrCast(Ptr, @alignCast(alignment, pointer));
                    return @call(.always_inline, read_callback, .{self, address});
                }

                fn writeCallback(pointer: *anyopaque, address: u16, data: u8) void {
                    const alignment = @typeInfo(Ptr).Pointer.alignment;
                    const self = @ptrCast(Ptr, @alignCast(alignment, pointer));
                    @call(.always_inline, write_callback, .{self, address, data});
                }
            };

            return .{
                .ptr = ptr,
                .readCallbackFn = gen.readCallback,
                .writeCallbackFn = gen.writeCallback
            };
        }

        pub inline fn readCallback(self: Self, address: u16) u8 {
            return self.readCallbackFn(self.ptr, address);
        }

        pub inline fn writeCallback(self: Self, address: u16, data: u8) void {
            self.writeCallbackFn(self.ptr, address, data);
        }
    };

    bus_callback: [(1 << 16) - 1]?*BusCallback,

    pub fn init() Bus {
        return .{
            .bus_callback = [_]?*BusCallback{null} ** ((1 << 16) - 1)
        };
    }

    pub fn read_byte(self: Bus, address: u16) u8 {
        if (self.bus_callback[address]) |bc| {
            return bc.readCallback(address); 
        } else {
            panic("Bus::Undefined read: No bus callbacks at address {X}", .{address});
        }
    }

    pub fn write_byte(self: *Bus, address: u16, data: u8) void {
        if (self.bus_callback[address]) |bc| {
            bc.writeCallback(address, data);
        } else {
            panic("Bus::Undefined write: No bus callbacks at address {X}", .{address});
        }
    }

    pub fn set_callbacks(self: *Bus, bus_callback: *BusCallback, start_address: u16, end_address: u16) void {
        assert(start_address <= end_address);
        @memset(self.bus_callback[start_address..end_address], bus_callback);
    }
};