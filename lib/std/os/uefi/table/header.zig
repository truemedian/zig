const Crc32 = std.hash.crc.Crc32IsoHdlc;

pub const Header = extern struct {
    signature: u64,

    /// The revision of the UEFI Specification to which this table conforms.
    revision: u32,

    /// The size of the entire table, including the header, in bytes.
    header_size: u32,

    /// The 32-bit CRC for the entire table, with this field set to 0.
    crc32: u32,

    /// Must be zero.
    reserved: u32,

    /// Validates the table is correct and of the expected type.
    pub fn validate(header: *const Header, signature: u64) bool {
        if (header.reserved != 0) return false;
        if (header.signature != signature) return false;

        const bytes: [*]const u8 = @ptrCast(header);

        var crc = Crc32.init();
        crc.update(bytes[0..16]);
        crc.update(&.{ 0, 0, 0, 0 }); // crc32 field filled with zeroes
        crc.update(bytes[20..header.header_size]);
        return crc.final() == header.crc32;
    }

    pub fn conformsTo(header: *const Header, major: u16, minor: u16, patch: u8) bool {
        return header.revision >= (@as(u32, major) << 16) | (minor * 10) | (patch % 10);
    }
};

const std = @import("../../../std.zig");
