const std = @import("std");
const nostr_lib = @import("nostr");
const crypto = nostr_lib.crypto;

pub const Error = error{
    InvalidJson,
    MissingField,
    InvalidId,
    InvalidPubkey,
    InvalidSig,
    InvalidCreatedAt,
    InvalidKind,
    InvalidTags,
    InvalidContent,
    IdMismatch,
    SigMismatch,
    FutureEvent,
    ExpiredEvent,
    InvalidSubscriptionId,
    TooManyFilters,
    BufferTooSmall,
    AllocFailed,
    SignatureFailed,
    Unknown,
};

pub const Event = struct {
    id: [32]u8,
    pubkey: [32]u8,
    created_at: i64,
    kind: i32,
    tags: []const []const []const u8,
    content: []const u8,
    sig: [64]u8,

    allocator: ?std.mem.Allocator = null,
    raw_json: ?[]const u8 = null,

    pub fn deinit(self: *Event) void {
        if (self.allocator) |alloc| {
            if (self.raw_json) |json| {
                alloc.free(json);
            }
        }
    }

    pub fn serialize(self: *const Event, buf: []u8) ![]u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"id\":\"");
        try writeHex(writer, &self.id);
        try writer.writeAll("\",\"pubkey\":\"");
        try writeHex(writer, &self.pubkey);
        try writer.writeAll("\",\"created_at\":");
        try writer.print("{d}", .{self.created_at});
        try writer.writeAll(",\"kind\":");
        try writer.print("{d}", .{self.kind});
        try writer.writeAll(",\"tags\":[");

        for (self.tags, 0..) |tag, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeByte('[');
            for (tag, 0..) |elem, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.writeByte('"');
                try writeJsonEscaped(writer, elem);
                try writer.writeByte('"');
            }
            try writer.writeByte(']');
        }

        try writer.writeAll("],\"content\":\"");
        try writeJsonEscaped(writer, self.content);
        try writer.writeAll("\",\"sig\":\"");
        try writeHex(writer, &self.sig);
        try writer.writeAll("\"}");

        return fbs.getWritten();
    }

    fn writeHex(writer: anytype, bytes: []const u8) !void {
        for (bytes) |b| {
            try writer.print("{x:0>2}", .{b});
        }
    }

    fn writeJsonEscaped(writer: anytype, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        try writer.print("\\u{x:0>4}", .{c});
                    } else {
                        try writer.writeByte(c);
                    }
                },
            }
        }
    }
};

pub const Filter = struct {
    ids: ?[]const [32]u8 = null,
    authors: ?[]const [32]u8 = null,
    kinds: ?[]const i32 = null,
    since: ?i64 = null,
    until: ?i64 = null,
    limit: ?u32 = null,
    search: ?[]const u8 = null,

    pub fn serialize(self: *const Filter, buf: []u8) ![]u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeByte('{');
        var first = true;

        if (self.ids) |ids| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"ids\":[");
            for (ids, 0..) |id, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeByte('"');
                for (id) |b| {
                    try writer.print("{x:0>2}", .{b});
                }
                try writer.writeByte('"');
            }
            try writer.writeByte(']');
        }

        if (self.authors) |authors| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"authors\":[");
            for (authors, 0..) |author, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.writeByte('"');
                for (author) |b| {
                    try writer.print("{x:0>2}", .{b});
                }
                try writer.writeByte('"');
            }
            try writer.writeByte(']');
        }

        if (self.kinds) |kinds| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("\"kinds\":[");
            for (kinds, 0..) |kind, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.print("{d}", .{kind});
            }
            try writer.writeByte(']');
        }

        if (self.since) |since| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("\"since\":{d}", .{since});
        }

        if (self.until) |until| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("\"until\":{d}", .{until});
        }

        if (self.limit) |limit| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("\"limit\":{d}", .{limit});
        }

        if (self.search) |search_query| {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("\"search\":\"");
            try Event.writeJsonEscaped(writer, search_query);
            try writer.writeByte('"');
        }

        try writer.writeByte('}');

        return fbs.getWritten();
    }
};

pub const RelayMsgType = enum {
    event,
    ok,
    eose,
    closed,
    notice,
    auth,
    count,
    unknown,
};

pub const RelayMsg = struct {
    msg_type: RelayMsgType,
    success: bool = false,
    is_duplicate: bool = false,
    is_rate_limited: bool = false,
    count: ?u64 = null,

    pub fn parse(json: []const u8, allocator: std.mem.Allocator) !RelayMsg {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        if (parsed.value != .array or parsed.value.array.items.len < 1) {
            return error.InvalidJson;
        }

        const arr = parsed.value.array.items;
        const type_str = if (arr[0] == .string) arr[0].string else return error.InvalidJson;

        var msg = RelayMsg{
            .msg_type = .unknown,
        };

        if (std.mem.eql(u8, type_str, "EVENT")) {
            msg.msg_type = .event;
        } else if (std.mem.eql(u8, type_str, "OK")) {
            msg.msg_type = .ok;
            if (arr.len > 2 and arr[2] == .bool) {
                msg.success = arr[2].bool;
            }
            if (arr.len > 3 and arr[3] == .string) {
                const reason = arr[3].string;
                if (std.mem.indexOf(u8, reason, "duplicate") != null) {
                    msg.is_duplicate = true;
                }
                if (std.mem.indexOf(u8, reason, "rate-limit") != null) {
                    msg.is_rate_limited = true;
                }
            }
        } else if (std.mem.eql(u8, type_str, "EOSE")) {
            msg.msg_type = .eose;
        } else if (std.mem.eql(u8, type_str, "CLOSED")) {
            msg.msg_type = .closed;
        } else if (std.mem.eql(u8, type_str, "NOTICE")) {
            msg.msg_type = .notice;
        } else if (std.mem.eql(u8, type_str, "AUTH")) {
            msg.msg_type = .auth;
        } else if (std.mem.eql(u8, type_str, "COUNT")) {
            msg.msg_type = .count;
            if (arr.len > 2 and arr[2] == .object) {
                if (arr[2].object.get("count")) |c| {
                    if (c == .integer) {
                        msg.count = @intCast(c.integer);
                    }
                }
            }
        }

        return msg;
    }
};

pub const ClientMsg = struct {
    pub fn event(ev: *const Event, buf: []u8) ![]u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeAll("[\"EVENT\",");
        const event_json = try ev.serialize(buf[fbs.pos..]);
        fbs.pos += event_json.len;
        try writer.writeAll("]");

        return fbs.getWritten();
    }

    pub fn req(sub_id: []const u8, filters: []const Filter, buf: []u8) ![]u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeAll("[\"REQ\",\"");
        try writer.writeAll(sub_id);
        try writer.writeByte('"');

        for (filters) |filter| {
            try writer.writeByte(',');
            const filter_json = try filter.serialize(buf[fbs.pos..]);
            fbs.pos += filter_json.len;
        }

        try writer.writeAll("]");

        return fbs.getWritten();
    }

    pub fn close(sub_id: []const u8, buf: []u8) ![]u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeAll("[\"CLOSE\",\"");
        try writer.writeAll(sub_id);
        try writer.writeAll("\"]");

        return fbs.getWritten();
    }
};

pub const Keypair = struct {
    secret_key: [32]u8,
    public_key: [32]u8,

    pub fn generate() Keypair {
        var secret_key: [32]u8 = undefined;
        std.crypto.random.bytes(&secret_key);

        var public_key: [32]u8 = undefined;
        crypto.getPublicKey(&secret_key, &public_key) catch {
            std.crypto.random.bytes(&public_key);
        };

        return .{
            .secret_key = secret_key,
            .public_key = public_key,
        };
    }
};

pub fn init() !void {
    try crypto.init();
}

pub fn cleanup() void {
    crypto.cleanup();
}

pub fn signEvent(event: *Event, keypair: *const Keypair) !void {
    @memcpy(&event.pubkey, &keypair.public_key);

    var commitment_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&commitment_buf);
    const writer = fbs.writer();

    writer.writeAll("[0,\"") catch unreachable;

    for (&keypair.public_key) |byte| {
        writer.print("{x:0>2}", .{byte}) catch unreachable;
    }

    writer.writeAll("\",") catch unreachable;
    writer.print("{d}", .{event.created_at}) catch unreachable;
    writer.writeAll(",") catch unreachable;
    writer.print("{d}", .{event.kind}) catch unreachable;
    writer.writeAll(",[],\"") catch unreachable;

    for (event.content) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch unreachable,
            '\\' => writer.writeAll("\\\\") catch unreachable,
            '\n' => writer.writeAll("\\n") catch unreachable,
            '\r' => writer.writeAll("\\r") catch unreachable,
            '\t' => writer.writeAll("\\t") catch unreachable,
            else => {
                if (c < 0x20) {
                    writer.print("\\u{x:0>4}", .{c}) catch unreachable;
                } else {
                    writer.writeByte(c) catch unreachable;
                }
            },
        }
    }

    writer.writeAll("\"]") catch unreachable;

    const commitment = fbs.getWritten();
    std.crypto.hash.sha2.Sha256.hash(commitment, &event.id, .{});

    crypto.sign(&keypair.secret_key, &event.id, &event.sig) catch {
        return error.SignatureFailed;
    };
}

test "event serialization" {
    const event = Event{
        .id = [_]u8{0} ** 32,
        .pubkey = [_]u8{0} ** 32,
        .created_at = 1234567890,
        .kind = 1,
        .tags = &[_][]const []const u8{},
        .content = "test",
        .sig = [_]u8{0} ** 64,
    };

    var buf: [4096]u8 = undefined;
    const json = try event.serialize(&buf);
    try std.testing.expect(json.len > 0);
}
