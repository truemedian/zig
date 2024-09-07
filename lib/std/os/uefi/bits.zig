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

pub const Guid = extern struct {};

/// A collection of related interfaces.
pub const Handle = *const opaque {};

/// Handle to an event structure.
pub const Event = *const opaque {};

pub const LogicalBlockAddress = u64;
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
