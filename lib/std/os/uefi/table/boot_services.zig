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
            memory_map: [*]align(@alignOf(bits.MemoryDescriptor)) u8,
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
        CreateEventEx: *const fn (
            type: bits.EventType,
            notify_tpl: bits.TaskPriorityLevel,
            notify_function: ?*const bits.EventNotifyFunction,
            notify_context: ?*const anyopaque,
            event_group: ?*const bits.Guid,
            event: *bits.Event,
        ) callconv(bits.EFIAPI) bits.Status,

        pub const EventType = packed struct(u32) {
            pad1: u8 = 0,
            notify_wait: bool = false,
            notify_signal: bool = false,
            pad2: u19 = 0,
            runtime_context: bool = false,
            runtime: bool = false,
            timer: bool = false,
        };

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

    pub const EventNotify = struct {
        tpl: bits.TaskPriorityLevel,
        function: bits.EventNotifyFunction,
        context: ?*const anyopaque,
    };

    pub const EventGroup = struct {
        guid: *const bits.Guid,

        /// Notified by the system when `ExitBootServices()` is called. These are invoked after
        /// all `.before_exit_boot_services` events.
        ///
        /// The notification function must not depend on timer events because the system firmware
        /// will have disabled timer services before any `.exit_boot_services` events are
        /// dispatched.
        ///
        /// The notification function must not use memory allocation services because these may
        /// modify the current memory map. Because the consumer of any service cannot know if
        /// any given service may allocate memory, the notification function must not use any
        /// external services outside of their own implementation to avoid modifying the memory map.
        pub const exit_boot_services: EventGroup = .{ .guid = &bits.Guid.parse("27abf055-b1b8-4c26-8048-748f37baa2df") };

        /// Notified by the system when `ExitBootServices()` is called. This present the last
        /// opportunity to use firmware interfaces in the boot environment.
        ///
        /// The notification function must not depend on any form of delayed processing such as
        /// timers because the system firmware disables timer services immediately after
        /// dispatching all `.before_exit_boot_services` events.
        pub const before_exit_boot_services: EventGroup = .{ .guid = &bits.Guid.parse("8be0e274-3970-4b44-80c5-1ab9502f3bfc") };

        /// Notified by the system when `SetVirtualAddressMap()` is called.
        pub const virtual_address_change: EventGroup = .{ .guid = &bits.Guid.parse("13fa7698-c831-49c7-87ea-8f43fcc25196") };

        /// Notified by the system when the memory map changes. The notification function shall
        /// not use any memory allocation services to avoid re-entrancy issues.
        pub const memory_map_change: EventGroup = .{ .guid = &bits.Guid.parse("78bee926-692f-48fd-9edb-01422ef0d7ab") };

        /// Notified by the system when the Boot Manager is about to load and execute a boot option.
        pub const ready_to_boot: EventGroup = .{ .guid = &bits.Guid.parse("7ce88fb3-4bd7-4679-87a8-a8d8dee50d2b") };

        /// Notified by the system immediately after all `.ready_to_boot` events. This is the last
        /// chance to modify the device or system configurations before passing control to the
        /// boot option.
        pub const after_ready_to_boot: EventGroup = .{ .guid = &bits.Guid.parse("3a2a00ad-98b9-4cdf-a478-702777f1c10b") };

        /// Notified by the system when `ExitBootServices()` has *not* been called and
        /// `ResetSystem()` has been invoked and the system is about to reset.
        pub const reset_system: EventGroup = .{ .guid = &bits.Guid.parse("62da6a56-13fb-485a-a8da-a3dd7912cb6b") };
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

    pub const MemoryMap = struct {
        /// Resize the memory map buffer to the last requested size.
        pub fn resize(
            map: *MemoryMap,
            /// The allocator that was used to allocate the buffer.
            allocator: std.mem.Allocator,
        ) !void {
            map.buffer = try allocator.realloc(map.buffer, map.requested_size);
        }

        /// Frees all memory associated with the memory map.
        pub fn deinit(
            map: *MemoryMap,
            allocator: std.mem.Allocator,
        ) void {
            allocator.free(map.buffer);
            map.* = undefined;
        }

        pub const init = MemoryMap{
            .buffer = &.{},
            .key = undefined,
            .descriptor_size = 0,
            .descriptor_version = 0,
            .requested_size = 0,
        };

        buffer: []align(@alignOf(bits.MemoryDescriptor)) u8,

        /// An opaque value that the firmware uses to track changes to the map.
        key: MemoryMapKey,
        /// The size of each memory descriptor in the map.
        descriptor_size: usize,
        /// The version of the memory descriptor structure.
        descriptor_version: u32,

        /// The last requested size of the memory map buffer.
        requested_size: usize,
    };

    header: Header,
    interface: Interface,

    pub fn createEvent(
        boot_services: *const BootServices,
        kind: Interface.EventType,
        notify: ?EventNotify,
        group: ?EventGroup,
    ) !bits.Event {
        assert(!(kind.notify_signal and kind.notify_wait)); // notify_signal and notify_wait are mutually exclusive

        var event: bits.Event = undefined;
        const group_guid: ?*const bits.Guid = if (group) |grp| grp.guid else null;

        if (notify) |notif| {
            try boot_services.interface.CreateEventEx(
                kind,
                notif.tpl,
                notif.function,
                notif.context,
                group_guid,
                &event,
            ).fail();
        } else {
            assert(!(kind.notify_signal or kind.notify_wait)); // must provide a notification function for these types
            try boot_services.interface.CreateEventEx(
                kind,
                .application,
                null,
                null,
                group_guid,
                &event,
            ).fail();
        }

        return event;
    }

    /// Removes the given event handle from all event groups it belongs to, and
    /// then closes the event handle. Will remove any associated notifications
    /// registered with the event.
    ///
    /// The event handle may no longer be used after this function is called.
    pub fn closeEvent(
        boot_services: *const BootServices,
        /// The event handle to close.
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
        /// The event handle to signal.
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
        /// The list of events to wait for
        events: []const bits.Event,
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
        /// The event handle to check.
        event: bits.Event,
    ) !bool {
        const status = boot_services.interface.CheckEvent(event);
        switch (status) {
            .success => return true,
            .not_ready => return false,
            else => |s| return s.fail(),
        }
    }

    test "check and signal event" {
        const boot_services = std.os.uefi.system_table.boot_services;
        const event = try boot_services.createEvent();
        assert(!try boot_services.checkEvent(event));
        boot_services.signalEvent(event);
        assert(try boot_services.checkEvent(event));
    }

    /// Sets the timer event to trigger at the specified time.
    ///
    /// Any previous timer event will be canceled.
    pub fn setTimer(
        boot_services: *const BootServices,
        /// The event that is to be signaled when the timer expires.
        event: bits.Event,
        /// The type of timer and time at which to trigger the event.
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
    /// The TPL provided **must** be greater than or equal to the current TPL,
    /// otherwise the system may exhibit indeterminate behavior.
    pub fn raiseTpl(
        boot_services: *const BootServices,
        /// The new priority level to raise to.
        new_tpl: bits.TaskPriorityLevel,
    ) bits.TaskPriorityLevel {
        return boot_services.interface.RaiseTPL(new_tpl);
    }

    /// Restores a task's priority level to its previous value.
    ///
    /// The TPL provided **must** be less than or equal to the current TPL,
    /// otherwise the system may exhibit indeterminate behavior.
    pub fn restoreTpl(
        boot_services: *const BootServices,
        /// The previous priority level to restore to.
        old_tpl: bits.TaskPriorityLevel,
    ) void {
        boot_services.interface.RestoreTPL(old_tpl);
    }

    test "raise and restore TPL" {
        const boot_services = std.os.uefi.system_table.boot_services;
        const old_tpl = boot_services.raiseTpl(.notify);
        boot_services.restoreTpl(old_tpl);
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
        /// How the memory should be allocated.
        allocate_type: AllocateType,
        /// The type of memory to allocate.
        memory_type: bits.MemoryType,
        /// The number of 4096 byte pages to allocate.
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
        /// The memory to free. Must have been allocated with `allocatePages`.
        memory: []align(4096) u8,
    ) void {
        const num_pages = @divExact(memory.len, 4096);
        assert(boot_services.interface.FreePages(@intFromPtr(memory), num_pages) == .success); // if this fails, then the memory was likely not allocated with allocatePages
    }

    test "allocate and free pages" {
        const boot_services = std.os.uefi.system_table.boot_services;
        const memory = try boot_services.allocatePages(.any, .loader_data, 1);
        boot_services.freePages(memory);
    }

    /// Returns the current memory map. The MemoryMap struct must be initialized
    /// with `MemoryMap.init` before calling this function.
    ///
    /// This function will return `true` if the buffer was too small to hold the
    /// memory map. In this case, you **must** call `MemoryMap.resize` and then
    /// call this function again.
    pub fn getMemoryMap(
        boot_services: *const BootServices,
        /// The memory map to fill.
        map: *MemoryMap,
    ) !true {
        var memory_map_size: usize = map.buffer.len;
        const status = boot_services.interface.GetMemoryMap(
            &memory_map_size,
            map.buffer.ptr,
            &map.key,
            &map.descriptor_size,
            &map.descriptor_version,
        );
        assert(map.descriptor_version == 1); // the only version supported

        map.requested_size = memory_map_size;
        switch (status) {
            .success => return false,
            .buffer_too_small => return true,
            else => |s| return s.fail(),
        }
        try status.fail();
    }

    test getMemoryMap {
        const boot_services = std.os.uefi.system_table.boot_services;
        var map: BootServices.MemoryMap = .init;
        defer map.deinit(std.testing.allocator);

        while (try boot_services.getMemoryMap(&map)) {
            try map.resize(std.testing.allocator);
        }
    }

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
        /// The type of memory to allocate.
        pool_type: bits.MemoryType,
        /// The number of bytes to allocate.
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
        /// The memory to free. Must have been allocated with `allocatePool`.
        buffer: []align(8) u8,
    ) void {
        assert(boot_services.interface.FreePool(buffer.ptr) == .success); // if this fails, then the memory was likely not allocated with allocatePool
    }

    test "allocate and free pool" {
        const boot_services = std.os.uefi.system_table.boot_services;
        const memory = try boot_services.allocatePool(.loader_data, 1);
        boot_services.freePool(memory);
    }

    //
    //
    //
    // TODO Protocol Handler Services
    //
    //
    //

    /// Loads an EFI image into memory. The image can be loaded from a device
    /// path or from a buffer in memory. **Either** `source_buffer` or
    /// `device_path` **must** be provided. If both are provided, then
    /// `source_buffer` is used and `device_path` is informative but may still
    /// be used to perform security policy decisions.
    pub fn loadImage(
        boot_services: *const BootServices,
        /// If `true`, this request originates from a boot manager and that the
        /// boot manager is attempting to load `device_path` as a boot
        /// selection. Ignored if `source_buffer` is provided.
        is_boot_policy: bool,
        /// The handle of the image that is loading the new image.
        parent_image: bits.Handle,
        /// A pointer to the memory location containing a copy of the image to
        /// be loaded. If `null`, then the image is loaded from the device path.
        source_buffer: ?[]const u8,
        /// A device handle specific path to the image to load.
        device_path: ?*const protocol.DevicePath,
    ) !bits.Handle {
        var image_handle: bits.Handle = undefined;
        if (source_buffer) |source| {
            try boot_services.interface.LoadImage(is_boot_policy, parent_image, device_path, source.ptr, source.len, &image_handle).fail();
        } else {
            try boot_services.interface.LoadImage(is_boot_policy, parent_image, device_path, null, 0, &image_handle).fail();
        }
        return image_handle;
    }

    /// Transfers control to a loaded image's entry point. An image may only be
    /// started once.
    ///
    /// Control returns to this function after the image returns or calls
    /// `Exit()`. If the image exits, any exit data is returned in the
    /// `exit_data` parameter.
    pub fn startImage(
        boot_services: *const BootServices,
        /// The handle of the image to start.
        image_handle: bits.Handle,
        /// Pointer to a slice that will be populated with the exit data. If the
        /// value is `null` then exit data will be ignored.
        exit_data: ?*[]const u16,
    ) bits.Status {
        if (exit_data) |data| {
            return boot_services.interface.StartImage(image_handle, &data.len, &data.ptr);
        } else {
            return boot_services.interface.StartImage(image_handle, null, null);
        }
    }

    /// Unloads an image.
    pub fn unloadImage(
        boot_services: *const BootServices,
        /// The handle of the image to unload.
        image_handle: bits.Handle,
    ) !void {
        try boot_services.interface.UnloadImage(image_handle).fail();
    }

    /// Terminates a loaded EFI application and returns control to the boot
    /// services.
    ///
    /// A EFI driver must free all resources allocated by the driver if the
    /// status code indcates an error. A successful status code indicates that
    /// the driver has successfully completed its initialization and is ready
    /// to accept requests.
    ///
    /// It is valid to call `exit` on an image that was loaded by `loadImage`
    /// and has not been started by `startImage`. Otherwise the `image_handle`
    /// must be the handle of the image that is calling `exit`.
    pub fn exit(
        boot_services: *const BootServices,
        /// The handle of the image to exit.
        image_handle: bits.Handle,
        /// The exit code for the image.
        exit_status: bits.Status,
        /// The exit data to return to the parent image. Must have been allocated by
        /// `allocatePool`.
        exit_data: ?[]const u16,
    ) !void {
        if (exit_data) |data| {
            try boot_services.interface.Exit(image_handle, exit_status, data.len, data.ptr).fail();
        } else {
            try boot_services.interface.Exit(image_handle, exit_status, 0, null).fail();
        }
    }

    /// Terminates all boot services. On success, the caller is now responsible
    /// for the continued operation of the system.
    /// 
    /// Calling any non-runtime service after this function will likely result
    /// in a system crash.
    pub fn exitBootServices(
        boot_services: *const BootServices,
        /// The handle of the image that is exiting boot services.
        image_handle: bits.Handle,
        /// The key returned by `getMemoryMap`.
        map_key: MemoryMapKey,
    ) !void {
        try boot_services.interface.ExitBootServices(image_handle, map_key).fail();
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
