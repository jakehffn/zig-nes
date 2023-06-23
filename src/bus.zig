const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;

pub const Bus = struct {
    pub const BusCallback = struct {
        const Self = @This();

        ptr: *anyopaque,
        address_offset: u16 = 0,

        readCallbackFn: ReadCallback,
        writeCallbackFn: WriteCallback,

        pub const ReadCallback = *const fn (*anyopaque, *Bus, u16) u8;
        pub const WriteCallback = *const fn (*anyopaque, *Bus, u16, u8) void;

        pub fn init(ptr: anytype, comptime read_callback: fn (ptr: @TypeOf(ptr), bus: *Bus, address: u16) u8, comptime write_callback: fn (ptr: @TypeOf(ptr), bus: *Bus, address: u16, data: u8) void) Self {
            const Ptr = @TypeOf(ptr);
            const ptr_info = @typeInfo(Ptr);

            if (ptr_info != .Pointer) @compileError("ptr must be a pointer");
            if (ptr_info.Pointer.size != .One) @compileError("ptr must be a single item pointer");
            if (@typeInfo(ptr_info.Pointer.child) != .Struct) @compileError("ptr must be a pointer to a struct");

            const gen = struct {
                fn readCallback(pointer: *anyopaque, bus: *Bus, address: u16) u8 {
                    const alignment = @typeInfo(Ptr).Pointer.alignment;
                    const self = @ptrCast(Ptr, if (alignment >= 1) @alignCast(alignment, pointer) else pointer);
                    return @call(.always_inline, read_callback, .{self, bus, address});
                }

                fn writeCallback(pointer: *anyopaque, bus: *Bus, address: u16, value: u8) void {
                    const alignment = @typeInfo(Ptr).Pointer.alignment;
                    const self = @ptrCast(Ptr, if (alignment >= 1) @alignCast(alignment, pointer) else pointer);
                    @call(.always_inline, write_callback, .{self, bus, address, value});
                }
            };

            return .{
                .ptr = ptr,
                .readCallbackFn = gen.readCallback,
                .writeCallbackFn = gen.writeCallback
            };
        }

        pub inline fn readCallback(self: Self, bus: *Bus, address: u16) u8 {
            return self.readCallbackFn(self.ptr, bus, address - self.address_offset);
        }

        pub inline fn writeCallback(self: Self, bus: *Bus, address: u16, value: u8) void {
            self.writeCallbackFn(self.ptr, bus, address - self.address_offset, value);
        }
    };

    bus_callback: [1 << 16]?BusCallback = undefined,

    /// All `BusCallback`s are set to `default_callback`
    /// The callbacks can be overwritten later with `bus.setCallbacks()`
    pub fn init(default_callback: ?BusCallback) Bus {
        var bus: Bus = .{};    

        // Initializing with the default statically causes 20+ minute compile times
        // Do this instead
        @memset(bus.bus_callback[0..bus.bus_callback.len], default_callback);

        return bus;
    }

    pub fn read_byte(self: *Bus, address: u16) u8 {
        if (self.bus_callback[address]) |bc| {
            return bc.readCallback(self, address); 
        } else {
            panic("Bus::Undefined read: No bus callbacks at address {X}", .{address});
        }
    }

    pub fn write_byte(self: *Bus, address: u16, value: u8) void {
        if (self.bus_callback[address]) |bc| {
            bc.writeCallback(self, address, value);
        } else {
            panic("Bus::Undefined write: No bus callbacks at address {X}", .{address});
        }
    }

    pub fn set_callbacks(self: *Bus, bus_callback: BusCallback, start_address: u16, end_address: u17) void {
        assert(start_address <= end_address);

        var bc = bus_callback;
        bc.address_offset = start_address;
        @memset(self.bus_callback[start_address..end_address], bc);
    }
};