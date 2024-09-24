/// The calling convention used by all UEFI interface functions.
pub const EFIAPI: std.builtin.CallingConvention = switch (builtin.target.cpu.arch) {
    .x86 => .C,
    .x86_64 => .Win64,
    .arm, .thumb, .aarch64 => .AAPCS,
    .armeb, .thumbeb => @compileError("UEFI does not support big endian arm or thumb"),
    .aarch64_be => @compileError("UEFI does not support big endian aarch64"),
    .riscv32, .riscv64 => .C,
    .loongarch32, .loongarch64 => .C,
    else => @compileError("UEFI does not support this architecture"),
};

pub const Guid = extern struct {
    time_low: u32,
    time_mid: u16,
    time_high_and_version: u16,
    clock_seq_high_and_reserved: u8,
    clock_seq_low: u8,
    node: [6]u8,

    pub fn parse(comptime str: *const [36]u8) Guid {
        if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') unreachable;
        const time_low = std.fmt.parseUnsigned(u32, str[0..8], 16) catch unreachable;
        const time_mid = std.fmt.parseUnsigned(u16, str[9..13], 16) catch unreachable;
        const time_high_and_version = std.fmt.parseUnsigned(u16, str[14..18], 16) catch unreachable;
        const clock_seq_high_and_reserved = std.fmt.parseUnsigned(u8, str[19..21], 16) catch unreachable;
        const clock_seq_low = std.fmt.parseUnsigned(u8, str[21..23], 16) catch unreachable;
        var node = [_]u8{ 0, 0, 0, 0, 0, 0 };
        for (&node, 0..) |*c, i| {
            c.* = std.fmt.parseUnsigned(u8, str[24 + 2 * i ..][0..2], 16) catch unreachable;
        }

        return Guid{
            .time_low = time_low,
            .time_mid = time_mid,
            .time_high_and_version = time_high_and_version,
            .clock_seq_high_and_reserved = clock_seq_high_and_reserved,
            .clock_seq_low = clock_seq_low,
            .node = node,
        };
    }

    pub fn format(guid: Guid, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        if (comptime std.mem.eql(u8, fmt, "x") or fmt.len == 0) {
            try writer.print("{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{:0>12}", .{
                guid.time_low,
                guid.time_mid,
                guid.time_high_and_version,
                guid.clock_seq_high_and_reserved,
                guid.clock_seq_low,
                std.fmt.fmtSliceHexLower(&guid.node),
            });
        } else if (comptime std.mem.eql(u8, fmt, "X")) {
            try writer.print("{X:0>8}-{X:0>4}-{X:0>4}-{X:0>2}{X:0>2}-{:0>12}", .{
                guid.time_low,
                guid.time_mid,
                guid.time_high_and_version,
                guid.clock_seq_high_and_reserved,
                guid.clock_seq_low,
                std.fmt.fmtSliceHexUpper(&guid.node),
            });
        } else {
            std.fmt.invalidFmtError(fmt, guid);
        }
    }

    pub fn eql(a: Guid, b: Guid) bool {
        return a.time_low == b.time_low and
            a.time_mid == b.time_mid and
            a.time_high_and_version == b.time_high_and_version and
            a.clock_seq_high_and_reserved == b.clock_seq_high_and_reserved and
            a.clock_seq_low == b.clock_seq_low and
            std.mem.eql(u8, &a.node, &b.node);
    }

    test parse {
        try std.testing.expectEqual(Guid{
            .time_low = 0x12345678,
            .time_mid = 0x9abc,
            .time_high_and_version = 0xdef0,
            .clock_seq_high_and_reserved = 0x12,
            .clock_seq_low = 0x34,
            .node = [_]u8{ 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 },
        }, Guid.parse("12345678-9abc-def0-1234-56789abcdef0"));
    }

    test format {
        var buf: [37]u8 = undefined;
        const res = try std.fmt.bufPrint(&buf, "{x}", .{Guid{
            .time_low = 0x12345678,
            .time_mid = 0x9abc,
            .time_high_and_version = 0xdef0,
            .clock_seq_high_and_reserved = 0x12,
            .clock_seq_low = 0x34,
            .node = [_]u8{ 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 },
        }});

        try std.testing.expectEqualSlices(u8, "12345678-9abc-def0-1234-56789abcdef0", res);
    }
    test eql {
        const a = parse("12345678-9abc-def0-1234-56789abcdef0");
        const b = Guid{
            .time_low = 0x12345678,
            .time_mid = 0x9abc,
            .time_high_and_version = 0xdef0,
            .clock_seq_high_and_reserved = 0x12,
            .clock_seq_low = 0x34,
            .node = [_]u8{ 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 },
        };
        const c = parse("12345678-9abc-def0-1234-56789abcdef1");

        try std.testing.expectEqual(true, eql(a, b));
        try std.testing.expectEqual(false, eql(a, c));
    }
};

/// A collection of related interfaces.
pub const Handle = *const opaque {};

/// Handle to an event structure.
pub const Event = *const opaque {};

pub const LogicalBlockAddress = u64;
pub const PhysicalAddress = u64;
pub const VirtualAddress = u64;

pub const TaskPriorityLevel = enum(usize) {
    application = 4,
    callback = 8,
    notify = 16,
    high_level = 31,
    _,
};

pub const TimerDelay = enum(u32) {
    cancel,
    periodic,
    relative,
};

pub const AllocateType = enum(u32) {
    any,
    max_address,
    exact_address,
};

pub const MemoryType = enum(u32) {
    reserved,
    loader_code,
    loader_data,
    boot_services_code,
    boot_services_data,
    runtime_services_code,
    runtime_services_data,
    conventional,
    unusable,
    acpi_reclaim,
    acpi_nvs,
    memory_mapped_io,
    memory_mapped_io_port_space,
    pal_code,
    persistent,
    unaccepted,
    _,
};

pub const MemoryDescriptor = extern struct {
    pub const Attribute = packed struct(u64) {
        /// The memory region supports being configured as not cacheable.
        supports_non_cacheable: bool,

        /// The memory region supports being configured as write combining.
        supports_write_combining: bool,

        /// The memory region supports being configured as cacheable with a
        /// "write-through" policy. Writes that hit in the cache will also be
        /// written to main memory.
        supports_write_through: bool,

        /// The memory region supports being configured as cacheable with a
        /// "write-back" policy. Reads and writes that hit in the cache do not
        /// propagate to main memory. Dirty data is written back to main memory
        /// when a new cache line is allocated.
        supports_write_back: bool,

        /// The memory region supports being configured as not cacheable,
        /// exported, and supports the "fetch and add" semaphore mechanism.
        supports_non_cacheable_exported: bool,

        _pad1: u7 = 0,

        /// The memory region supports being configured as write-protected by
        /// system hardware. This is typically used as a cacheability attribute
        /// today. The memory region supports being configured as cacheable with
        /// a "write protected" policy. Reads come from cache lines when
        /// possible, and read misses cause cache fills. Writes are propagated
        /// to the system bus and cause corresponding cache lines on all
        /// processors on the bus to be invalidated.
        supports_write_protected: bool,

        /// The memory region supports being configured as read-protected by
        /// system hardware.
        supports_read_protected: bool,

        /// The memory region supports being configured so it is protected by
        /// system hardware from executing code.
        supports_execute_protected: bool,

        /// The memory region refers to persistent memory.
        non_volatile: bool,

        /// The memory region provides higher reliability relative to other
        /// memory in the system. If all memory has the same reliability, then
        /// this bit is not used.
        more_reliable: bool,

        /// The memory region supports making this memory range read-only by
        /// system hardware.
        supports_read_only: bool,

        /// The memory is earmarked for specific purposes such as for specific
        /// device drivers or applications. The SPM attribute serves as a hint
        /// to the OS to avoid allocating this memory for core OS data or code
        /// that can not be relocated. Prolonged use of this memory for purposes
        /// other than the intended purpose may result in suboptimal platform
        /// performance.
        specific_purpose: bool,

        /// The memory region is capable of being protected with the CPU's
        /// memory cryptographic capabilities.
        supports_crypto: bool,

        _pad2: u24 = 0,

        /// When `memory_isa_valid` is set, this field contains ISA specific
        /// cacheability attributes not covered above.
        memory_isa: u16,

        _pad3: u2 = 0,

        /// When set, the `memory_isa` field is valid.
        memory_isa_valid: bool,

        /// This memory must be given a virtual mapping by the operating system
        /// when `setVirtualAddressMap()` is called.
        memory_runtime: bool,
    };

    type: MemoryType,
    physical_start: PhysicalAddress,
    virtual_start: VirtualAddress,
    number_of_pages: u64,
    attribute: Attribute,
};

pub const MacAddress = extern struct {
    addr: [32]u8,
};

pub const Ip4Address = extern struct {
    addr: [4]u8,
};

pub const Ip6Address = extern struct {
    addr: [16]u8,
};

pub const IpAddress = extern union {
    Ip4: Ip4Address align(4),
    Ip6: Ip6Address,
};

pub const EventNotifyFunction = fn (
    event: Event,
    context: ?*const anyopaque,
) callconv(EFIAPI) void;

pub const Status = @import("status.zig").Status;

const builtin = @import("builtin");
const std = @import("../../std.zig");

test {
    std.testing.refAllDecls(@This());
}
