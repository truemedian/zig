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
        page,
    };

    pub const Info = struct {
        offset: i32,
        target: union(enum) {
            symbol: u32,
            section: u16,
        },
        addend: ?u32 = null,
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

    pub const Page = struct {
        base: Relocation = Relocation{ .@"type" = Type.page },
        kind: enum {
            page_off,
            page,
            page_off_page,
            got_page_off,
            got_page,
            got_page_off_page,
            tlvp_page_off,
            tlvp_page,
            tlvp_page_off_page,
        },
        page_op: Info,
        page_off_op: Info,

        pub const base_type: Relocation.Type = .page;
    };
};

pub fn parse(allocator: *Allocator, relocs: []const macho.relocation_info) ![]*Relocation {
    var it = RelocIterator{
        .buffer = relocs,
    };

    var parser = Parser{
        .allocator = allocator,
        .it = &it,
    };
    defer parser.deinit();

    var parsed = std.ArrayList(*Relocation).init(allocator);

    while (it.peek_type()) |tt| {
        switch (tt) {
            .ARM64_RELOC_BRANCH26 => {
                var branch = try parser.branch();
                log.warn("    | emitting {}", .{branch});
                try parsed.append(&branch.base);
            },
            .ARM64_RELOC_SUBTRACTOR, .ARM64_RELOC_UNSIGNED => {
                var unsigned = try parser.unsigned();
                log.warn("    | emitting {}", .{unsigned});
                try parsed.append(&unsigned.base);
            },
            else => {
                _ = it.next() orelse unreachable;
            },
        }
    }

    return parsed.toOwnedSlice();
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

    pub fn peek(self: *RelocIterator) ?macho.relocation_info {
        if (self.index + 1 < self.buffer.len) {
            return self.buffer[@intCast(u64, self.index + 1)];
        }
        return null;
    }

    pub fn peek_type(self: *RelocIterator) ?macho.reloc_type_arm64 {
        const reloc = self.peek() orelse return null;
        const tt = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
        return tt;
    }
};

const Parser = struct {
    allocator: *Allocator,
    it: *RelocIterator,

    fn deinit(parser: *Parser) void {}

    fn branch(parser: *Parser) !*Relocation.Branch {
        const reloc = parser.it.next() orelse unreachable;
        const reloc_type = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
        assert(reloc_type == .ARM64_RELOC_BRANCH26);
        assert(reloc.r_pcrel == 1);

        var node = try parser.allocator.create(Relocation.Branch);
        errdefer parser.allocator.destroy(node);

        node.* = .{
            .info = .{
                .offset = reloc.r_address,
                .target = if (reloc.r_extern == 1) .{
                    .symbol = reloc.r_symbolnum,
                } else .{
                    .section = @intCast(u16, reloc.r_symbolnum - 1),
                },
            },
        };

        return node;
    }

    fn unsigned(parser: *Parser) !*Relocation.Unsigned {
        const subtractor: ?Relocation.Info = if (parser.it.peek_type().? == .ARM64_RELOC_SUBTRACTOR) sub: {
            const reloc = parser.it.next() orelse unreachable;
            assert(reloc.r_pcrel == 0);

            break :sub .{
                .offset = reloc.r_address,
                .target = if (reloc.r_extern == 1) .{
                    .symbol = reloc.r_symbolnum,
                } else .{
                    .section = @intCast(u16, reloc.r_symbolnum - 1),
                },
            };
        } else null;

        const reloc = parser.it.next() orelse return error.MissingUnsignedReloc;
        const reloc_type = @intToEnum(macho.reloc_type_arm64, reloc.r_type);
        assert(reloc_type == .ARM64_RELOC_UNSIGNED); // TODO
        assert(reloc.r_pcrel == 0);

        var node = try parser.allocator.create(Relocation.Unsigned);
        errdefer parser.allocator.destroy(node);

        node.* = .{
            .info = .{
                .offset = reloc.r_address,
                .target = if (reloc.r_extern == 1) .{
                    .symbol = reloc.r_symbolnum,
                } else .{
                    .section = @intCast(u16, reloc.r_symbolnum - 1),
                },
            },
            .subtractor = subtractor,
        };

        return node;
    }
};
