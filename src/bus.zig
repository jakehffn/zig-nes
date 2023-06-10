pub const Bus = struct {
    pub const CallbackInfo = struct {
        start_address: u16,
        end_address: u16,
        write_callback: WriteCallback,
        read_callback: ReadCallback
    };

    read_callback: [1 << 16 - 1]?ReadCallback,
    write_callback: [1 << 16 - 1]?WriteCallback,

    pub const BusError = error {
        UndefinedRead,
        UndefinedWrite
    };

    pub const ReadCallback = *const fn (address: u16) u8;
    pub const WriteCallback = *const fn (address: u16, value: u8) void;

    pub fn init() Bus {
        return .{
            .read_callback = [_]?ReadCallback{null} ** (1 << 16 - 1),
            .write_callback = [_]?WriteCallback{null} ** (1 << 16 - 1)
        };
    }

    pub fn read_byte(self: Bus, address: u16) !u8 {
        if (self.read_callback[address]) |callback| {
            return callback(address); 
        } else {
            return BusError.UndefinedRead;
        }
    }

    pub fn write_byte(self: Bus, address: u16, data: u8) !void {
        if (self.write_callback[address]) |callback| {
            callback(address, data);
        } else {
            return BusError.UndefinedWrite;
        }
    }

    pub fn set_callbacks(self: *Bus, callback_info: CallbackInfo) void {
        @memset(self.read_callback[callback_info.start_address..callback_info.end_address], callback_info.read_callback);
        @memset(self.write_callback[callback_info.start_address..callback_info.end_address], callback_info.write_callback);
    }
};