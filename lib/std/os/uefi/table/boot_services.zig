pub const BootServices = extern struct {
    pub const Interface = extern struct {
        RaiseTPL: *const fn (
            new_tpl: bits.TaskPriorityLevel,
        ) callconv(bits.EFIAPI) bits.TaskPriorityLevel,
        RestoreTPL: *const fn (
            old_tpl: bits.TaskPriorityLevel,
        ) callconv(bits.EFIAPI) void,

        AllocatePages: *const fn (
            type: bits.AllocateType,
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
            type: u32,
            notify_tpl: bits.TaskPriorityLevel,
            notify_function: ?*const bits.EventNotifyFunction,
            notify_context: ?*const anyopaque,
            event: *bits.Event,
        ) callconv(bits.EFIAPI) bits.Status,
        SetTimer: *const fn (
            event: bits.Event,
            type: bits.TimerDelay,
            trigger_time: u64,
        ) callconv(bits.EFIAPI) bits.Status,
        WaitForEvent: *const fn (
            number_of_events: usize,
            event: [*]const ?bits.Event,
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

    pub const TimerKind = union(bits.TimerDelay) {
        /// Cancel any pending timer event.
        cancel,

        /// The timer will be triggered periodically at `.periodic * 100ns`
        /// intervals. The event does not need to be reset after each trigger.
        periodic: u64,

        /// The timer will be triggered in `.relative * 100ns`.
        relative: u64,
    };

    pub const AllocateType = union(bits.AllocateType) {
        any,
        max_address: bits.PhysicalAddress,
        exact_address: bits.PhysicalAddress,
    };

    header: Header,
    interface: Interface,

    pub fn createEvent() void {}

    /// Removes the given event handle from all event groups it belongs to, and
    /// then closes the event handle. Will remove any associated notifications
    /// registered with the event.
    ///
    /// The event handle may no longer be used after this function is called.
    pub fn closeEvent(
        boot_services: *const BootServices,
        event: bits.Event,
    ) void {
        // only documented status returned is .success
        _ = boot_services.interface.CloseEvent(event);
    }

    /// Place the supplied event into the signaled state. If the event is
    /// already in the signaled state then this function will have no effect.
    ///
    /// If the event is of type EVT_NOTIFY_SIGNAL, then the event's notification
    /// function will be scheduled to be invoked at the current TPL.
    ///
    /// This may be called from any TPL. And if the event is a member of an
    /// event group, then all events in the group will be signaled as above.
    pub fn signalEvent(
        boot_services: *const BootServices,
        event: bits.Event,
    ) void {
        // only documented status returned is .success
        _ = boot_services.interface.SignalEvent(event);
    }

    /// Stops execution until an event is signaled. Must not be used with any
    /// event of type EVT_NOTIFY_SIGNAL.
    ///
    /// Must be called at TPL .application
    ///
    /// The events are evaluated in the order they are provided:
    ///
    /// 1. If an event is already in the signaled state, then the index of that
    ///    event is returned.
    ///
    /// 2. If an event is not in the signaled state, but does have a
    ///    notification function, then that function is scheduled to be invoked
    ///    at the requested TPL. If execution of the notification function
    ///    causes the event to be signaled, then the index of that event is
    ///    returned.
    ///
    /// 3. Repeat until a signaled event is found or an error occurs.
    ///
    /// If this function returns an event index, then the signaled state of the
    /// event is cleared.
    pub fn waitForEvents(
        boot_services: *const BootServices,
        events: [:null]const ?bits.Event,
    ) !usize {
        assert(events.len > 0); // must provide at least one event

        var index: usize = 0;
        try boot_services.interface.WaitForEvent(events.len, events.ptr, &index).fail();
        return index;
    }

    /// Checks whether an event is in the signaled state. Must not be used with
    /// event of type EVT_NOTIFY_SIGNAL. There are 3 possibilities:
    ///
    /// 1. If the event is in the signaled state, then `true` is returned.
    ///
    /// 2. If the event is not in the signaled state, and has no notification
    ///    function then `false` is returned.
    ///
    /// 3. If the event is not in the signaled state, but does have a
    ///    notification function, then that function is scheduled to be invoked
    ///    at the requested TPL. If execution of the notification function
    ///    causes the event to be signaled, then `true` is returned.
    ///
    /// When this function returns `true`, the signaled state of the event is
    /// cleared.
    pub fn checkEvent(
        boot_services: *const BootServices,
        event: bits.Event,
    ) !bool {
        const status = boot_services.interface.CheckEvent(event);
        switch (status) {
            .success => return true,
            .not_ready => return false,
            else => |s| return s.fail(),
        }
    }

    /// Sets the timer event to trigger at the specified time.
    ///
    /// Any previous timer event will be canceled.
    pub fn setTimer(
        boot_services: *const BootServices,
        event: bits.Event,
        delay: TimerKind,
    ) !void {
        const trigger_time = switch (delay) {
            .cancel => 0,
            .periodic => delay.periodic,
            .relative => delay.relative,
        };

        try boot_services.interface.SetTimer(event, delay, trigger_time).fail();
    }

    /// Raises a task's priority level and returns its previous level.
    ///
    /// The TPL provided **must** be lower than or equal to the current TPL,
    /// otherwise the system may exhibit indeterminate behavior.
    pub fn raiseTpl(
        boot_services: *const BootServices,
        new_tpl: bits.TaskPriorityLevel,
    ) bits.TaskPriorityLevel {
        return boot_services.interface.RaiseTPL(new_tpl);
    }

    /// Restores a task's priority level to its previous value.
    ///
    /// The TPL provided **must** be higher than or equal to the current TPL,
    /// otherwise the system may exhibit indeterminate behavior.
    pub fn restoreTpl(
        boot_services: *const BootServices,
        old_tpl: bits.TaskPriorityLevel,
    ) void {
        boot_services.interface.RestoreTPL(old_tpl);
    }

    /// Allocates memory pages from the system. The requested chunk of memory
    /// will be allocated from the firmware's memory map.
    ///
    /// In general, UEFI OS loaders and UEFI applications should allocate memory
    /// of type `.loader_data`.
    ///
    /// UEFI Boot Service Drivers **must** allocate memory of type
    /// `.boot_services_data`
    ///
    /// UEFI Runtime Service Drivers **must** allocate memory of type
    /// `.runtime_services_data` (although such allocations must be made during
    /// boot services time).
    /// 
    /// Should be freed with `freePages`.
    pub fn allocatePages(
        boot_services: *const BootServices,
        allocate_type: AllocateType,
        memory_type: bits.MemoryType,
        pages: usize,
    ) ![]align(4096) u8 {
        assert(memory_type != .persistent and memory_type != .unaccepted); // these are not allowed

        var memory: bits.PhysicalAddress = switch (allocate_type) {
            .any => 0,
            .max_address => |addr| addr,
            .exact_address => |addr| addr,
        };

        try boot_services.interface.AllocatePages(allocate_type, memory_type, pages, &memory).fail();
        const allocation: [*]align(4096) u8 = @ptrFromInt(memory);
        const length = pages * 4096;

        return allocation[0..length];
    }

    /// Frees memory pages allocated with `allocatePages`. The memory is
    /// returned to the system's memory map.
    pub fn freePages(
        boot_services: *const BootServices,
        memory: []align(4096) u8,
    ) void {
        const num_pages = @divExact(memory.len, 4096);
        try boot_services.interface.FreePages(@intFromPtr(memory), num_pages).fail();
    }

    pub fn getMemoryMap() void {}

    /// Allocates memory from the firmware's memory pool. 
    ///
    /// In general, UEFI OS loaders and UEFI applications should allocate memory
    /// of type `.loader_data`.
    ///
    /// UEFI Boot Service Drivers **must** allocate memory of type
    /// `.boot_services_data`
    ///
    /// UEFI Runtime Service Drivers **must** allocate memory of type
    /// `.runtime_services_data` (although such allocations must be made during
    /// boot services time).
    /// 
    /// Should be freed with `freePool`.
    pub fn allocatePool(
        boot_services: *const BootServices,
        pool_type: bits.MemoryType,
        size: usize,
    ) ![]align(8) u8 {
        var buffer: [*]align(8) u8 = undefined;
        try boot_services.interface.AllocatePool(pool_type, size, &buffer).fail();
        return buffer[0..size];
    }

    /// Frees memory allocated with `allocatePool`. The memory is returned to
    /// the firmware's memory pool.
    pub fn freePool(
        boot_services: *const BootServices,
        buffer: []align(8) u8,
    ) void {
        try boot_services.interface.FreePool(buffer.ptr).fail();
    }
};

const AnyInterface = *const anyopaque;
const Registration = *const anyopaque;
const MemoryMapKey = *const anyopaque;

const Header = @import("header.zig").Header;

const bits = @import("../bits.zig");
const protocol = @import("../protocol.zig");

const assert = std.debug.assert;
const std = @import("../../../std.zig");
