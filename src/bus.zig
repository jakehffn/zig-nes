const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;

const Allocator = std.mem.Allocator;

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

        /// Convenience function to generate callback function for disallowed reads
        pub fn disallowedRead(comptime Outer: type, comptime panic_msg: []const u8, comptime log_params: bool) fn (ptr: *Outer, bus: *Bus, address: u16) u8 {
            return struct {
                fn func(self: *Outer, bus: *Bus, address: u16) u8 {
                    _ = bus;
                    _ = self;
                    if (log_params) {
                        panic(panic_msg ++ "\n\t{address:${X:0>4}}", .{address});
                    } else {
                        panic(panic_msg, .{});
                    }
                }
            }.func;
        }

        /// Convenience function to generate callback function for disallowed writes
        pub fn disallowedWrite(comptime Outer: type, comptime panic_msg: []const u8, comptime log_params: bool) fn (ptr: *Outer, bus: *Bus, address: u16, data: u8) void {
            return struct {
                fn func(self: *Outer, bus: *Bus, address: u16, value: u8) void {
                    _ = bus;
                    _ = self;
                    if (log_params) {
                        panic(panic_msg ++ "\n\taddress:${X:0>4} = {X:0>2}", .{address, value});
                    } else {
                        panic(panic_msg, .{});
                    }
                }
            }.func;
        }
    };

    bus_callbacks: []?BusCallback,

    /// All `BusCallback`s are set to `default_callback`
    /// The callbacks can be overwritten later with `bus.setCallbacks()`
    pub fn init(allocator: Allocator, address_space_size: usize, default_callback: ?BusCallback) !Bus {
        var bus: Bus = .{
            .bus_callbacks = try allocator.alloc(?BusCallback, address_space_size)
        };    

        // Initializing with the default statically causes 20+ minute compile times
        // Do this instead
        @memset(bus.bus_callbacks[0..bus.bus_callbacks.len], default_callback);

        return bus;
    }

    pub fn deinit(self: *Bus, allocator: Allocator) void {
        allocator.free(self.bus_callbacks);
    }

    pub fn readByte(self: *Bus, address: u16) u8 {
        if (self.bus_callbacks[address]) |bc| {
            return bc.readCallback(self, address); 
        } else {
            panic("Bus::Undefined read: No bus callbacks at address {X}", .{address});
        }
    }

    pub fn writeByte(self: *Bus, address: u16, value: u8) void {
        if (self.bus_callbacks[address]) |bc| {
            bc.writeCallback(self, address, value);
        } else {
            panic("Bus::Undefined write: No bus callbacks at address {X}", .{address});
        }
    }

    pub fn setCallback(self: *Bus, bus_callback: BusCallback, address: u16) void {
        var bc = bus_callback;
        bc.address_offset = address;
        self.bus_callbacks[address] = bc;
    }

    pub fn setCallbacks(self: *Bus, bus_callback: BusCallback, start_address: u16, end_address: u17) void {
        assert(start_address <= end_address);

        var bc = bus_callback;
        bc.address_offset = start_address;
        @memset(self.bus_callbacks[start_address..end_address], bc);
    }
};