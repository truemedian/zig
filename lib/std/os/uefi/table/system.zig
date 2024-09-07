pub const System = extern struct {
    header: Header,

    /// A pointer to a null terminated string that identifies the vendor that
    /// produces the system firmware for the platform.
    firmware_vendor: [*:0]const u16,

    /// A firmware vendor specific value that identifies the revision of the
    /// system firmware for the platform.
    firmware_revision: u32,

    /// The handle for the active console input device. This device is
    /// always present and must support the `SimpleTextInput` and
    /// `SimpleTextInputEx` protocols. This handle becomes invalid after
    /// any call to `ExitBootServices()`.
    console_in_handle: bits.Handle,

    /// A pointer to the `SimpleTextInput` Protocol interface that is
    /// associated with console_in_handle. This protocol becomes invalid after
    /// any call to `ExitBootServices()`.
    console_in: *const protocol.SimpleTextInput,

    /// The handle for the active console output device. This device is
    /// always present and must support the `SimpleTextOutput` protocol. This
    /// handle becomes invalid after any call to `ExitBootServices()`.
    console_out_handle: bits.Handle,

    /// A pointer to the `SimpleTextOutput` Protocol interface that is
    /// associated with console_out_handle. This protocol becomes invalid after
    /// any call to `ExitBootServices()`.
    console_out: *const protocol.SimpleTextOutput,

    /// The handle for the active standard error output device. This device is
    /// always present and must support the `SimpleTextOutput` protocol. This
    /// handle becomes invalid after any call to `ExitBootServices()`.
    standard_error_handle: bits.Handle,

    /// A pointer to the `SimpleTextOutput` Protocol interface that is
    /// associated with standard_error_handle. This protocol becomes invalid
    /// after any call to `ExitBootServices()`.
    standard_error: *const protocol.SimpleTextOutput,

    /// The EFI Runtime Services table.
    runtime_services: *const RuntimeServices,

    /// The EFI Boot Services table.
    boot_services: *const BootServices,

    /// The number of entries present in the configuration_table field.
    configuration_table_entries: u64,

    /// A pointer to the system configuration tables.
    configuration_table: [*]const ConfigurationTableEntry,

    pub const signature: u64 = 0x5453595320494249;
};

const Header = @import("header.zig").Header;
const BootServices = @import("boot_services.zig").BootServices;
const RuntimeServices = @import("runtime_services.zig").RuntimeServices;
const ConfigurationTableEntry = @import("configuration_table.zig").Entry;

const bits = @import("../bits.zig");
const protocol = @import("../protocol.zig");
