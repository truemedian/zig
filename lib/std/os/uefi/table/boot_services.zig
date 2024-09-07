pub const BootServices = extern struct {
    pub const Interface = extern struct {
        RaiseTPL: *const fn (
            new_tpl: bits.TaskPriorityLevel,
        ) callconv(bits.EFIAPI) bits.TaskPriorityLevel,
        RestoreTPL: *const fn (
            old_tpl: bits.TaskPriorityLevel,
        ) callconv(bits.EFIAPI) void,

        AllocatePages: *const fn (
            type: bits.AllocateType.Enum,
            memory_type: bits.MemoryType,
            pages: usize,
            memory: *bits.PhysicalAddress,
        ) callconv(bits.EFIAPI) bits.Status,
        FreePages: *const fn (
            memory: bits.PhysicalAddress,
            pages: usize,
        ) callconv(bits.EFIAPI) bits.Status,
        GetMemoryMap: *const fn (
            memory_map_size: *usize,
            memory_map: *align(@alignOf(bits.MemoryDescriptor)) anyopaque,
            map_key: *MemoryMapKey,
            descriptor_size: *usize,
            descriptor_version: *u32,
        ) callconv(bits.EFIAPI) bits.Status,
        AllocatePool: *const fn (
            pool_type: bits.MemoryType,
            size: usize,
            buffer: *[*]align(8) u8,
        ) callconv(bits.EFIAPI) bits.Status,
        FreePool: *const fn (
            buffer: [*]align(8) u8,
        ) callconv(bits.EFIAPI) bits.Status,

        CreateEvent: *const fn (
            type: bits.EventType,
            notify_tpl: bits.TaskPriorityLevel,
            notify_function: ?*const bits.EventNotifyFunction,
            notify_context: ?*const anyopaque,
            event: *bits.Event,
        ) callconv(bits.EFIAPI) bits.Status,
        SetTimer: *const fn (
            event: bits.Event,
            type: bits.TimerDelay.Enum,
            trigger_time: u64,
        ) callconv(bits.EFIAPI) bits.Status,
        WaitForEvent: *const fn (
            number_of_events: usize,
            event: [*]const bits.Event,
            index: *usize,
        ) callconv(bits.EFIAPI) bits.Status,
        SignalEvent: *const fn (
            event: bits.Event,
        ) callconv(bits.EFIAPI) bits.Status,
        CloseEvent: *const fn (
            event: bits.Event,
        ) callconv(bits.EFIAPI) bits.Status,
        CheckEvent: *const fn (
            event: bits.Event,
        ) callconv(bits.EFIAPI) bits.Status,

        InstallProtocolInterface: *const fn (
            handle: *?bits.Handle,
            protocol: *const bits.Guid,
            interface_type: bits.InterfaceType,
            interface: ?AnyInterface,
        ) callconv(bits.EFIAPI) bits.Status,
        ReinstallProtocolInterface: *const fn (
            handle: bits.Handle,
            protocol: *const bits.Guid,
            old_interface: ?AnyInterface,
            new_interface: ?AnyInterface,
        ) callconv(bits.EFIAPI) bits.Status,
        UninstallProtocolInterface: *const fn (
            handle: bits.Handle,
            protocol: *const bits.Guid,
            interface: ?AnyInterface,
        ) callconv(bits.EFIAPI) bits.Status,
        HandleProtocol: *const fn (
            handle: bits.Handle,
            protocol: *const bits.Guid,
            interface: *?AnyInterface,
        ) callconv(bits.EFIAPI) bits.Status,
        Reserved: *anyopaque = undefined,
        RegisterProtocolNotify: *const fn (
            protocol: *const bits.Guid,
            event: bits.Event,
            registration: *Registration,
        ) callconv(bits.EFIAPI) bits.Status,
        LocateHandle: *const fn (
            search_type: bits.LocateSearchType.Enum,
            protocol: ?*const bits.Guid,
            search_key: ?Registration,
            buffer_size: *usize,
            buffer: ?[*]const bits.Handle,
        ) callconv(bits.EFIAPI) bits.Status,
        LocateDevicePath: *const fn (
            protocol: *const bits.Guid,
            device_path: **const protocol.DevicePath,
            device: *bits.Handle,
        ) callconv(bits.EFIAPI) bits.Status,
        InstallConfigurationTable: *const fn (
            guid: *const bits.Guid,
            table: ?*const anyopaque,
        ) callconv(bits.EFIAPI) bits.Status,

        LoadImage: *const fn (
            boot_policy: bool,
            parent_image_handle: bits.Handle,
            device_path: ?*const protocol.DevicePath,
            source_buffer: ?[*]const u8,
            source_size: usize,
            image_handle: *bits.Handle,
        ) callconv(bits.EFIAPI) bits.Status,
        StartImage: *const fn (
            image_handle: bits.Handle,
            exit_data_size: ?*usize,
            exit_data: ?*[*]const u16,
        ) callconv(bits.EFIAPI) bits.Status,
        Exit: *const fn (
            image_handle: bits.Handle,
            exit_status: bits.Status,
            exit_data_size: usize,
            exit_data: ?[*]const u16,
        ) callconv(bits.EFIAPI) bits.Status,
        UnloadImage: *const fn (
            image_handle: bits.Handle,
        ) callconv(bits.EFIAPI) bits.Status,
        ExitBootServices: *const fn (
            image_handle: bits.Handle,
            map_key: MemoryMapKey,
        ) callconv(bits.EFIAPI) bits.Status,

        GetNextMonotonicCount: *const fn (
            count: *u64,
        ) callconv(bits.EFIAPI) bits.Status,
        Stall: *const fn (
            microseconds: usize,
        ) callconv(bits.EFIAPI) bits.Status,
        SetWatchdogTimer: *const fn (
            timeout: usize,
            watchdog_code: u64,
            data_size: usize,
            watchdog_data: ?[*]const u16,
        ) callconv(bits.EFIAPI) bits.Status,

        // EFI 1.1+

        ConnectController: *const fn (
            controller_handle: bits.Handle,
            driver_image_handle: ?*const bits.Handle,
            remaining_device_path: ?*const protocol.DevicePath,
            recursive: bool,
        ) callconv(bits.EFIAPI) bits.Status,
        DisconnectController: *const fn (
            controller_handle: bits.Handle,
            driver_image_handle: ?bits.Handle,
            child_handle: ?bits.Handle,
        ) callconv(bits.EFIAPI) bits.Status,

        OpenProtocol: *const fn (
            handle: bits.Handle,
            protocol: *const bits.Guid,
            interface: *?AnyInterface,
            agent_handle: bits.Handle,
            controller_handle: ?bits.Handle,
            attributes: OpenProtocolAttributes,
        ) callconv(bits.EFIAPI) bits.Status,
        CloseProtocol: *const fn (
            handle: bits.Handle,
            protocol: *const bits.Guid,
            agent_handle: bits.Handle,
            controller_handle: ?bits.Handle,
        ) callconv(bits.EFIAPI) bits.Status,
        OpenProtocolInformation: *const fn () callconv(bits.EFIAPI) bits.Status,

        ProtocolsPerHandle: *const fn (
            handle: bits.Handle,
            protocol_buffer: *[*]const *const bits.Guid,
            protocol_buffer_size: *usize,
        ) callconv(bits.EFIAPI) bits.Status,
        LocateHandleBuffer: *const fn (
            search_type: bits.LocateSearchType.Enum,
            protocol: ?*const bits.Guid,
            search_key: ?Registration,
            number_of_handles: *usize,
            buffer: *[*]const bits.Handle,
        ) callconv(bits.EFIAPI) bits.Status,
        LocateProtocol: *const fn (
            protocol: *const bits.Guid,
            registration: ?Registration,
            interface: *?AnyInterface,
        ) callconv(bits.EFIAPI) bits.Status,
        InstallMultipleProtocolInterfaces: *const fn (
            handle: *bits.Handle,
            ...,
        ) callconv(bits.EFIAPI) bits.Status,
        UninstallMultipleProtocolInterfaces: *const fn (
            handle: bits.Handle,
            ...,
        ) callconv(bits.EFIAPI) bits.Status,

        CalculateCrc32: *const fn (
            data: [*]const u8,
            data_size: usize,
            crc32: *u32,
        ) callconv(bits.EFIAPI) bits.Status,

        CopyMem: *const fn (
            destination: [*]align(8) u8,
            source: [*]align(8) const u8,
            length: usize,
        ) callconv(bits.EFIAPI) void,
        SetMem: *const fn (
            buffer: [*]align(8) u8,
            size: usize,
            value: u8,
        ) callconv(bits.EFIAPI) void,

        // UEFI 2.0+
        CreateEventEx: *const fn () callconv(bits.EFIAPI) bits.Status,

        pub const OpenProtocolAttributes = enum(u32) {
            by_handle_protocol = 0x00000001,
            get_protocol = 0x00000002,
            test_protocol = 0x00000004,
            by_child_controller = 0x00000008,
            by_driver = 0x00000010,
            exclusive = 0x00000020,
            exclusive_by_driver = 0x00000030, // exclusive | by_driver
        };
    };

    header: Header,
    interface: Interface,
};

const AnyInterface = *const anyopaque;
const Registration = *const anyopaque;
const MemoryMapKey = *const anyopaque;

const Header = @import("header.zig").Header;

const bits = @import("../bits.zig");
const protocol = @import("../protocol.zig");
