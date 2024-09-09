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
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn format(guid: Guid, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        if (comptime std.mem.eql(u8, fmt, "x") or fmt.len == 0) {
            try writer.print("{x:0>8}-{x:0>4}-{x:0>4}-{}", .{
                guid.data1,
                guid.data2,
                guid.data3,
                std.fmt.fmtSliceHexLower(guid.data4),
            });
        } else if (comptime std.mem.eql(u8, fmt, "X")) {
            try writer.print("{X:0>8}-{X:0>4}-{X:0>4}-{}", .{
                guid.data1,
                guid.data2,
                guid.data3,
                std.fmt.fmtSliceHexUpper(guid.data4),
            });
        } else {
            @compileError("unsupported format string for Guid.format");
        }
    }
};

/// A collection of related interfaces.
pub const Handle = *const opaque {};

/// Handle to an event structure.
pub const Event = *const opaque {};

pub const LogicalBlockAddress = u64;
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

pub const TaskPriorityLevel = enum(usize) {
    application = 4,
    callback = 8,
    notify = 16,
    high_level = 31,
    _,
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

pub const Status = @import("status.zig").Status;

const builtin = @import("builtin");
const std = @import("../../std.zig");
