const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.reloc);
const macho = std.macho;
const mem = std.mem;

const Allocator = mem.Allocator;

pub const Relocation = struct {
    @"type": Type,

    pub fn cast(base: *Relocation, comptime T: type) ?*T {
        if (base.@"type" != T.base_type)
            return null;

        return @fieldParentPtr(T, "base", base);
    }

    pub const Type = enum {
        branch,
        unsigned,
        load,
    };

    pub const Info = struct {
        offset: i32,
        target: Target,
        addend: ?u32 = null,

        pub const Target = union(enum) {
            symbol: u32,
            section: u16,

            pub fn from_reloc(reloc: macho.relocation_info) Target {
                return if (reloc.r_extern == 1) .{
                    .symbol = reloc.r_symbolnum,
                } else .{
                    .section = @intCast(u16, reloc.r_symbolnum - 1),
                };
            }
        };
    };

    pub const Branch = struct {
        base: Relocation = Relocation{ .@"type" = Type.branch },
        info: Info,

        pub const base_type: Relocation.Type = .branch;
    };

    pub const Unsigned = struct {
        base: Relocation = Relocation{ .@"type" = Type.unsigned },
        info: Info,
        subtractor: ?Info = null,

        pub const base_type: Relocation.Type = .unsigned;
    };

    pub const Load = struct {
        base: Relocation = Relocation{ .@"type" = Type.load },
        kind: Kind,
        page_op: ?Info = null,
        page_off_op: ?Info = null,

        pub const base_type: Relocation.Type = .load;

        pub const Kind = enum {
            page_off,
            page,
            page_off_page,
        };
    };
};

pub fn parse(allocator: *Allocator, relocs: []const macho.relocation_info) ![]*Relocation {
    var it = RelocIterator{
        .buffer = relocs,
    };
    var parser = Parser.init(allocator, &it);
    defer parser.deinit();
    return parser.parse();
}

const RelocIterator = struct {
    buffer: []const macho.relocation_info,
    index: i64 = -1,

    pub fn next(self: *RelocIterator) ?macho.relocation_info {
        self.index += 1;
        if (self.index < self.buffer.len) {
            const reloc = self.buffer[@intCast(u64, self.index)];
            log.warn("{s}", .{@intToEnum(macho.reloc_type_arm64, reloc.r_type)});
            log.warn("    | offset = {}", .{reloc.r_address});
            log.warn("    | PC = {}", .{reloc.r_pcrel == 1});
            log.warn("    | length = {}", .{reloc.r_length});
            log.warn("    | symbolnum = {}", .{reloc.r_symbolnum});
            log.warn("    | extern = {}", .{reloc.r_extern == 1});
            return reloc;
        }
        return null;
    }

    pub fn peek(self: *RelocIterator) ?macho.reloc_type_arm64 {
        if (self.index + 1 < self.buffer.len) {
            const reloc = self.buffer[@intCast(u64, self.index + 1)];
            const tt = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
            return tt;
        }
        return null;
    }
};

const Parser = struct {
    allocator: *Allocator,
    it: *RelocIterator,
    parsed: std.ArrayList(*Relocation),
    addend: ?u32 = null,
    subtractor: ?Relocation.Info = null,

    fn init(allocator: *Allocator, it: *RelocIterator) Parser {
        return .{
            .allocator = allocator,
            .it = it,
            .parsed = std.ArrayList(*Relocation).init(allocator),
        };
    }

    fn deinit(parser: *Parser) void {
        parser.parsed.deinit();
    }

    fn parse(parser: *Parser) ![]*Relocation {
        while (parser.it.next()) |reloc| {
            switch (@intToEnum(macho.reloc_type_arm64, reloc.r_type)) {
                .ARM64_RELOC_BRANCH26 => {
                    try parser.parseBranch(reloc);
                },
                .ARM64_RELOC_SUBTRACTOR => {
                    try parser.parseSubtractor(reloc);
                },
                .ARM64_RELOC_UNSIGNED => {
                    try parser.parseUnsigned(reloc);
                },
                .ARM64_RELOC_ADDEND => {
                    try parser.parseAddend(reloc);
                },
                .ARM64_RELOC_PAGE21, .ARM64_RELOC_PAGEOFF12 => {
                    try parser.parseLoad(reloc);
                },
                else => {},
            }
        }

        return parser.parsed.toOwnedSlice();
    }

    fn parseAddend(parser: *Parser, reloc: macho.relocation_info) !void {
        const reloc_type = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
        assert(reloc_type == .ARM64_RELOC_ADDEND);
        assert(reloc.r_pcrel == 0);
        assert(reloc.r_extern == 0);
        assert(parser.addend == null);

        parser.addend = reloc.r_symbolnum;

        // Verify ADDEND is followed by a load.
        if (parser.it.peek()) |tt| {
            switch (tt) {
                .ARM64_RELOC_PAGE21,
                .ARM64_RELOC_PAGEOFF12,
                .ARM64_RELOC_GOT_LOAD_PAGE21,
                .ARM64_RELOC_GOT_LOAD_PAGEOFF12,
                .ARM64_RELOC_TLVP_LOAD_PAGE21,
                .ARM64_RELOC_TLVP_LOAD_PAGEOFF12,
                => {},
                else => |other| {
                    log.err("unexpected relocation type: expected PAGE21 or PAGEOFF12, found {s}", .{other});
                    return error.UnexpectedRelocationType;
                },
            }
        } else {
            log.err("unexpected end of stream", .{});
            return error.UnexpectedEndOfStream;
        }
    }

    fn parseBranch(parser: *Parser, reloc: macho.relocation_info) !void {
        const reloc_type = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
        assert(reloc_type == .ARM64_RELOC_BRANCH26);
        assert(reloc.r_pcrel == 1);

        var branch = try parser.allocator.create(Relocation.Branch);
        errdefer parser.allocator.destroy(branch);

        const target = Relocation.Info.Target.from_reloc(reloc);

        branch.* = .{
            .info = .{
                .offset = reloc.r_address,
                .target = target,
            },
        };

        log.warn("    | emitting {}", .{branch});
        try parser.parsed.append(&branch.base);
    }

    fn parseLoad(parser: *Parser, reloc: macho.relocation_info) !void {
        const reloc_type = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
        assert(reloc_type == .ARM64_RELOC_PAGEOFF12 or reloc_type == .ARM64_RELOC_PAGE21);

        // TODO find if we can combine the relocs together

        var load = try parser.allocator.create(Relocation.Load);
        errdefer parser.allocator.destroy(load);

        const kind: Relocation.Load.Kind = if (reloc_type == .ARM64_RELOC_PAGEOFF12) .page_off else .page;
        const target = Relocation.Info.Target.from_reloc(reloc);

        load.* = .{
            .kind = kind,
        };

        if (reloc_type == .ARM64_RELOC_PAGEOFF12) {
            load.page_off_op = .{
                .offset = reloc.r_address,
                .target = target,
                .addend = parser.addend,
            };
        } else {
            load.page_op = .{
                .offset = reloc.r_address,
                .target = target,
                .addend = parser.addend,
            };
        }

        // Reset parser's addend state
        parser.addend = null;

        log.warn("    | emitting {}", .{load});
        try parser.parsed.append(&load.base);
    }

    fn parseSubtractor(parser: *Parser, reloc: macho.relocation_info) !void {
        const reloc_type = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
        assert(reloc_type == .ARM64_RELOC_SUBTRACTOR);
        assert(reloc.r_pcrel == 0);
        assert(parser.subtractor == null);

        const target = Relocation.Info.Target.from_reloc(reloc);

        parser.subtractor = .{
            .offset = reloc.r_address,
            .target = target,
        };

        // Verify SUBTRACTOR is followed by UNSIGNED.
        if (parser.it.peek()) |tt| {
            if (tt != .ARM64_RELOC_UNSIGNED) {
                log.err("unexpected relocation type: expected UNSIGNED, found {s}", .{tt});
                return error.UnexpectedRelocationType;
            }
        } else {
            log.err("unexpected end of stream", .{});
            return error.UnexpectedEndOfStream;
        }
    }

    fn parseUnsigned(parser: *Parser, reloc: macho.relocation_info) !void {
        const reloc_type = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
        assert(reloc_type == .ARM64_RELOC_UNSIGNED);
        assert(reloc.r_pcrel == 0);

        var unsigned = try parser.allocator.create(Relocation.Unsigned);
        errdefer parser.allocator.destroy(unsigned);

        const target = Relocation.Info.Target.from_reloc(reloc);

        unsigned.* = .{
            .info = .{
                .offset = reloc.r_address,
                .target = target,
            },
            .subtractor = parser.subtractor,
        };

        // Reset parser's subtractor state
        parser.subtractor = null;

        log.warn("    | emitting {}", .{unsigned});
        try parser.parsed.append(&unsigned.base);
    }
};
