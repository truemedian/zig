pub var system_table: *const SystemTable = undefined;
pub var image_handle: bits.Handle = undefined;

pub const SystemTable = @import("uefi/table/system.zig").System;
pub const BootServices = @import("uefi/table/boot_services.zig").BootServices;

pub const bits = @import("uefi/bits.zig");

const std = @import("../std.zig");
