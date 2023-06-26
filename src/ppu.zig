const std = @import("std");
const panic = std.debug.panic;

const Bus = @import("./bus.zig").Bus;
const BusCallback = Bus.BusCallback;
const PpuBus = @import("./ppu_bus.zig").PpuBus;
const MainBus = @import("./main_bus.zig").MainBus;

pub const Ppu = struct {
    const Self = @This();

    bus: *Bus,
    main_bus: *Bus,

    // In CPU, mapped to:
    // 0x2000
    controller_register: struct {
        const ControlRegister = @This();

        flags: ControlFlags = .{},

        fn write(ppu: *Ppu, bus: *Bus, address: u16, value: u8) void {
            _ = address;
            _ = bus;
            ppu.controller_register.flags = @bitCast(ControlFlags, value);
        }

        pub fn busCallback(self: *ControlRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "controller_register", self),
                BusCallback.disallowedRead(Self, "Cannot read from PPU controller register", false),
                ControlRegister.write
            );
        }
    } = .{},
    // 0x2001
    mask_register: struct {
        const MaskRegister = @This();

        flags: MaskFlags = .{},

        fn write(ppu: *Ppu, bus: *Bus, address: u16, value: u8) void {
            _ = address;
            _ = bus;
            ppu.mask_register.flags = @bitCast(MaskFlags, value);
        }

        pub fn busCallback(self: *MaskRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "mask_register", self),
                BusCallback.disallowedRead(Self, "Cannot read from PPU mask register", false),
                MaskRegister.write
            );
        }
    } = .{},
    // 0x2002
    status_register: struct {
        const StatusRegister = @This();

        flags: StatusFlags = .{},

        fn read(ppu: *Ppu, bus: *Bus, address: u16) u8 {
            _ = address;
            _ = bus;
            ppu.address_register.high_latch = true;
            return @bitCast(u8, ppu.status_register.flags);
        }

        pub fn busCallback(self: *StatusRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "status_register", self),
                StatusRegister.read,
                BusCallback.disallowedWrite(Self, "Cannot write to PPU status register", false)
            );
        }
    } = .{}, 
    // 0x2003
    oam_address_register: struct {
        const OamAddressRegister = @This();
        // TODO: Address should be set to 9 during each of ticks 257-320 of the pre-render and visible scanlines
        // https://www.nesdev.org/wiki/PPU_registers#OAMADDR
        address: u8 = 0,

        fn write(ppu: *Ppu, bus: *Bus, address: u16, value: u8) void {
            _ = address;
            _ = bus;
            ppu.oam_address_register.address = value;
        }

        pub fn busCallback(self: *OamAddressRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "oam_address_register", self), 
                BusCallback.disallowedRead(Self, "Cannot read from PPU oam address register", false),
                OamAddressRegister.write
            );
        }
    } = .{},
    // 0x2004
    oam_data_register: struct {
        const OamDataRegister = @This();

        // TODO: Implement this function
        fn read(ppu: *Ppu, bus: *Bus, address: u16) u8 {
            _ = address;
            _ = bus;
            _ = ppu;

            return 0;
        }

        // TODO: Implement this function
        fn write(ppu: *Ppu, bus: *Bus, address: u16, value: u8) void {
            _ = value;
            _ = address;
            _ = bus;
            _ = ppu;
        }

        pub fn busCallback(self: *OamDataRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "oam_data_register", self), 
                OamDataRegister.read,
                OamDataRegister.write
            );
        }
    } = .{},
    // 0x2005
    scroll_register: struct {
        const ScrollRegister = @This();

        // TODO: Implement this function
        fn read(ppu: *Ppu, bus: *Bus, address: u16) u8 {
            _ = address;
            _ = bus;
            _ = ppu;

            return 0;
        }

        // TODO: Implement this function
        fn write(ppu: *Ppu, bus: *Bus, address: u16, value: u8) void {
            _ = value;
            _ = address;
            _ = bus;
            _ = ppu;
        }

        pub fn busCallback(self: *ScrollRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "scroll_register", self), 
                ScrollRegister.read,
                ScrollRegister.write
            );
        }
    } = .{},
    // 0x2006
    address_register: struct {
        const AddressRegister = @This();
        
        address: packed union {
            value: u16,
            bytes: packed struct {
                low: u8,
                high: u8
            }
        } = .{
            .value = 0
        },
        high_latch: bool = true,

        fn write(ppu: *Ppu, bus: *Bus, address: u16, value: u8) void {
            _ = bus;
            _ = address;
            if (ppu.address_register.high_latch) {
                ppu.address_register.address.bytes.high = value;
            } else {
                ppu.address_register.address.bytes.low = value;
            } 
            ppu.address_register.high_latch = false;
        }

        fn incrementAddress(ppu: *Ppu) void {
            // Increment row or column based on the controller register increment flag
            ppu.address_register.address.value +%= if (ppu.controller_register.flags.I == 0) 1 else 32;
        }

        pub fn busCallback(self: *AddressRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "address_register", self),
                BusCallback.disallowedRead(Self, "Cannot read from PPU address register", false),
                AddressRegister.write
            );
        }
    } = .{},
    // 0x2007
    data_register: struct {
        const DataRegister = @This();

        read_buffer: u8 = 0,

        fn read(ppu: *Ppu, bus: *Bus, address: u16) u8 {
            // TODO: Read conflict with DPCM samples

            _ = address; 
            // Wrapping back to addressable range
            var wrapped_address = ppu.address_register.address.value & 0x3FFF;
            // When reading palette data, the data is placed immediately on the bus
            //  and the buffer instead is filled with the data from the nametables
            //  as if the mirrors continued to the end of the address range
            //  Explained here: https://www.nesdev.org/wiki/PPU_registers#PPUDATA
            if (wrapped_address >= 0x3F00) {
                ppu.data_register.read_buffer = bus.readByte(wrapped_address - 0x1000);
                return bus.readByte(wrapped_address);
            }
            const last_read_byte = ppu.data_register.read_buffer;
            ppu.data_register.read_buffer = bus.readByte(wrapped_address);
            @TypeOf(ppu.address_register).incrementAddress(ppu);
            return last_read_byte;
        }    

        fn write(ppu: *Ppu, bus: *Bus, address: u16, value: u8) void {
            _ = address;
            // Wrapping back to addressable range
            bus.writeByte(ppu.address_register.address.value & 0x3FFF, value);
            @TypeOf(ppu.address_register).incrementAddress(ppu);
        }

        pub fn busCallback(self: *DataRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "data_register", self),
                DataRegister.read,
                DataRegister.write
            );
        }
    } = .{},
    // 0x4014
    oam_dma_register: struct {
        const OamDmaRegister = @This();

        // TODO: Implement this function
        fn read(ppu: *Ppu, bus: *Bus, address: u16) u8 {
            _ = address;
            _ = bus;
            _ = ppu;

            return 0;
        }

        // TODO: Implement this function
        fn write(ppu: *Ppu, bus: *Bus, address: u16, value: u8) void {
            _ = value;
            _ = address;
            _ = bus;
            _ = ppu;
        }

        pub fn busCallback(self: *OamDmaRegister) BusCallback {
            return BusCallback.init(
                @fieldParentPtr(Ppu, "oam_dma_register", self), 
                OamDmaRegister.read,
                OamDmaRegister.write
            );
        }
    } = .{},

    /// Various PPU control flags
    /// 
    /// **N**
    /// Base nametable address
    /// `0`: $2000; `1`: $2400; `2`: $2800; `3`: $2C00
    /// 
    /// **I**
    /// VRAM addresss increment per CPU read/write of PPUDATA
    /// `0`: add 1, going across; `1`: add 32, going down
    /// 
    /// **S**
    /// Sprite pattern table address for 8x8 sprites
    /// `0`: $0000; `1`: $1000
    /// *Ignored in 8x16 mode*
    /// 
    /// **B**
    /// Background pattern table address
    /// `0`: $0000; `1`: $1000
    /// 
    /// **H**
    /// Sprite size
    /// `0`: 8x8 pixels; `1`: 8x16 pixels
    /// 
    /// **P**
    /// PPU master/slave select
    /// `0`: read backdrop from EXT pins; `1`: output color on EXT pins
    /// 
    /// **V**
    /// Generate an NMI at the start of v-blank
    /// `0`: off; `1`: on
    const ControlFlags = packed struct {
        N: u2 = 0,
        I: u1 = 0,
        S: u1 = 0,
        B: u1 = 0,
        H: u1 = 0,
        P: u1 = 0,
        V: u1 = 0
    }; 

    /// Various PPU mask flags
    /// 
    /// **G**
    /// Greyscale
    /// `0`: normal; `1`: greyscale
    /// 
    /// **m**
    /// `0`: Show background in leftmost 8 pixels of screen; `1`: Hide
    /// 
    /// **M**
    /// `0`: Show sprites in leftmost 8 pixels of screen; `1`: Hide 
    /// 
    /// **b**
    /// `0`: Show background; `1`: Hide
    /// 
    /// **s**
    /// `0`: Show spites; `1`: Hide
    /// 
    /// **R**
    /// Emphasize red
    /// 
    /// **G**
    /// Emphasize green
    /// 
    /// **B**
    /// Emphasize blue
    const MaskFlags = packed struct {
        Gr: u1 = 0,
        m: u1 = 0,
        M: u1 = 0, 
        b: u1 = 0,
        s: u1 = 0,
        R: u1 = 0,
        G: u1 = 0,
        B: u1 = 0
    };

    /// Reflects the state of PPU
    /// 
    /// **O**
    /// Sprite overflow
    /// 
    /// **S**
    /// Sprite 0 hit
    /// Set when a nonzero pixel of sprite 0 overlaps a nonzero background pixel;
    /// 
    /// **V**
    /// v-blank has started
    const StatusFlags = packed struct {
        _: u5 = 0,
        O: u1 = 0,
        S: u1 = 0,
        V: u1 = 0
    };

    pub fn init(ppu_bus: *PpuBus) Ppu {
        return .{
            .bus = &ppu_bus.bus,
            .main_bus = undefined
        };
    }

    pub fn setMainBus(self: *Self, main_bus: *MainBus) void {
        self.main_bus = &main_bus.bus;
    }
};