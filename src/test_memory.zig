const CallbackInfo = @import("./bus.zig").Bus.CallbackInfo;

pub const TestMemory = struct {
    callback_info: CallbackInfo,

    pub fn init() TestMemory {
        return .{.callback_info = .{
            .start_address = 0,
            .end_address = 1 << 16 - 1,
            .read_callback = exampleMemRead,
            .write_callback = exampleMemWrite
        }};
    }

    var example_mem = [_]u8{0} ** (1 << 16 - 1);

    fn exampleMemRead(address: u16) u8 {
        return example_mem[address];
    }

    fn exampleMemWrite(address: u16, data: u8) void {
        example_mem[address] = data;
    }
};