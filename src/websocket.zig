const std = @import("std");
const nostr = @import("nostr.zig");
const net = std.Io.net;

pub const WebSocketError = error{
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    InvalidUrl,
    Timeout,
    Closed,
};

/// Simple WebSocket client for Nostr relay connections
pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: ?net.Stream = null,
    host: []const u8,
    port: u16,
    path: []const u8,
    connected: bool = false,
    recv_buf: [65536]u8 = undefined,
    write_buf: [4096]u8 = undefined,
    stream_writer: ?net.Stream.Writer = null,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !Client {
        var client = Client{
            .allocator = allocator,
            .host = "",
            .port = 80,
            .path = "/",
        };

        // Parse URL: ws://host:port/path or wss://host:port/path
        var remaining = url;

        if (std.mem.startsWith(u8, remaining, "wss://")) {
            remaining = remaining[6..];
            client.port = 443;
        } else if (std.mem.startsWith(u8, remaining, "ws://")) {
            remaining = remaining[5..];
            client.port = 80;
        } else {
            return error.InvalidUrl;
        }

        // Find path
        if (std.mem.indexOf(u8, remaining, "/")) |path_start| {
            client.path = remaining[path_start..];
            remaining = remaining[0..path_start];
        }

        // Find port
        if (std.mem.indexOf(u8, remaining, ":")) |port_start| {
            const port_str = remaining[port_start + 1 ..];
            client.port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidUrl;
            remaining = remaining[0..port_start];
        }

        client.host = remaining;

        return client;
    }

    pub fn deinit(self: *Client) void {
        self.close();
    }

    pub fn connect(self: *Client) !void {
        const io = nostr.io.io();
        const host = if (std.mem.eql(u8, self.host, "localhost")) "127.0.0.1" else self.host;
        if (net.IpAddress.parse(host, self.port)) |address| {
            self.stream = address.connect(io, .{ .mode = .stream }) catch return error.ConnectionFailed;
        } else |_| {
            const host_name = net.HostName.init(host) catch return error.ConnectionFailed;
            self.stream = host_name.connect(io, self.port, .{ .mode = .stream }) catch return error.ConnectionFailed;
        }
        self.stream_writer = self.stream.?.writer(io, &self.write_buf);
        // Blocking-io requirement: handshake reads block until the relay responds,
        // so set socket send/recv timeouts before any handshake I/O.
        self.setReadTimeout(5000);
        self.setWriteTimeout(5000);
        try self.performHandshake();
        self.connected = true;
    }

    fn writeAll(self: *Client, data: []const u8) !void {
        const sw = if (self.stream_writer) |*w| w else return error.ConnectionFailed;
        sw.interface.writeAll(data) catch return error.SendFailed;
        sw.interface.flush() catch return error.SendFailed;
    }

    pub fn setReadTimeout(self: *Client, timeout_ms: u32) void {
        self.setSocketTimeout(std.posix.SO.RCVTIMEO, timeout_ms);
    }

    pub fn setWriteTimeout(self: *Client, timeout_ms: u32) void {
        self.setSocketTimeout(std.posix.SO.SNDTIMEO, timeout_ms);
    }

    fn setSocketTimeout(self: *Client, optname: u32, timeout_ms: u32) void {
        const stream = self.stream orelse return;
        const timeout = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, optname, std.mem.asBytes(&timeout)) catch {};
    }

    fn performHandshake(self: *Client) !void {
        const stream = self.stream orelse return error.ConnectionFailed;

        // Generate random key
        var key_bytes: [16]u8 = undefined;
        nostr.io.randomBytes(&key_bytes);

        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

        var request_buf: [1024]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ self.path, self.host, self.port, key }) catch return error.ConnectionFailed;

        try self.writeAll(request);

        // The 101 response may arrive across multiple packets; read until we see
        // the end of the headers (\r\n\r\n) or the buffer fills. Socket recv
        // timeout (set before this call) bounds a stalled handshake.
        var response_buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < response_buf.len) {
            const n = std.posix.read(stream.socket.handle, response_buf[total..]) catch return error.ReceiveFailed;
            if (n == 0) return error.ConnectionFailed;
            total += n;
            if (std.mem.indexOf(u8, response_buf[0..total], "\r\n\r\n") != null) break;
        }

        if (!std.mem.startsWith(u8, response_buf[0..total], "HTTP/1.1 101")) {
            return error.ConnectionFailed;
        }
    }

    pub fn close(self: *Client) void {
        if (self.stream) |stream| {
            // Send close frame
            const close_frame = [_]u8{ 0x88, 0x80, 0, 0, 0, 0 }; // Close frame with mask
            self.writeAll(&close_frame) catch {};
            stream.close(nostr.io.io());
            self.stream = null;
            self.stream_writer = null;
        }
        self.connected = false;
    }

    pub fn send(self: *Client, data: []const u8) !void {
        _ = self.stream orelse return error.ConnectionFailed;

        // Build WebSocket frame (text frame, masked)
        var frame_buf: [65546]u8 = undefined;
        var frame_len: usize = 0;

        // Opcode: text frame
        frame_buf[0] = 0x81; // FIN + text opcode
        frame_len += 1;

        // Payload length with mask bit
        if (data.len < 126) {
            frame_buf[1] = @as(u8, @intCast(data.len)) | 0x80;
            frame_len += 1;
        } else if (data.len < 65536) {
            frame_buf[1] = 126 | 0x80;
            frame_buf[2] = @intCast(data.len >> 8);
            frame_buf[3] = @intCast(data.len & 0xFF);
            frame_len += 3;
        } else {
            return error.SendFailed; // Message too large
        }

        // Masking key (random)
        var mask: [4]u8 = undefined;
        nostr.io.randomBytes(&mask);
        @memcpy(frame_buf[frame_len..][0..4], &mask);
        frame_len += 4;

        // Masked payload
        for (data, 0..) |byte, i| {
            frame_buf[frame_len + i] = byte ^ mask[i % 4];
        }
        frame_len += data.len;

        try self.writeAll(frame_buf[0..frame_len]);
    }

    pub fn receive(self: *Client) !?[]const u8 {
        const stream = self.stream orelse return error.ConnectionFailed;

        // Read frame header
        var header: [2]u8 = undefined;
        const header_read = std.posix.read(stream.socket.handle, &header) catch return error.ReceiveFailed;
        if (header_read == 0) return null;
        if (header_read < 2) return error.ReceiveFailed;

        const fin = (header[0] & 0x80) != 0;
        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            var ext_len: [2]u8 = undefined;
            _ = std.posix.read(stream.socket.handle, &ext_len) catch return error.ReceiveFailed;
            payload_len = (@as(u64, ext_len[0]) << 8) | ext_len[1];
        } else if (payload_len == 127) {
            var ext_len: [8]u8 = undefined;
            _ = std.posix.read(stream.socket.handle, &ext_len) catch return error.ReceiveFailed;
            payload_len = 0;
            for (ext_len) |b| {
                payload_len = (payload_len << 8) | b;
            }
        }

        if (payload_len > self.recv_buf.len) {
            return error.ReceiveFailed;
        }

        // Read masking key if present
        var mask: [4]u8 = undefined;
        if (masked) {
            _ = std.posix.read(stream.socket.handle, &mask) catch return error.ReceiveFailed;
        }

        // Read payload. posix.read blocks (thread-backed io); a peer closing
        // mid-frame returns 0, leaving the frame truncated.
        const payload_usize: usize = @intCast(payload_len);
        var total_read: usize = 0;
        while (total_read < payload_usize) {
            const n = std.posix.read(stream.socket.handle, self.recv_buf[total_read..payload_usize]) catch return error.ReceiveFailed;
            if (n == 0) break;
            total_read += n;
        }

        // A truncated frame would unmask/return uninitialized recv_buf bytes.
        if (total_read < payload_usize) return error.ReceiveFailed;

        // Unmask if needed
        if (masked) {
            for (self.recv_buf[0..payload_usize], 0..) |*byte, i| {
                byte.* ^= mask[i % 4];
            }
        }

        // Handle different opcodes
        switch (opcode) {
            0x01 => { // Text frame
                _ = fin;
                return self.recv_buf[0..payload_usize];
            },
            0x08 => { // Close frame
                self.close();
                return null;
            },
            0x09 => { // Ping
                // Send pong
                const pong_frame: [2]u8 = .{ 0x8A, 0x80 };
                self.writeAll(&pong_frame) catch {};
                return self.receive(); // Continue reading
            },
            0x0A => { // Pong
                return self.receive(); // Continue reading
            },
            else => {
                return self.receive(); // Skip unknown frames
            },
        }
    }

    /// Send a Nostr EVENT message
    pub fn sendEvent(self: *Client, event: *const nostr.Event) !void {
        var buf: [65536]u8 = undefined;

        var w = std.Io.Writer.fixed(&buf);

        try w.writeAll("[\"EVENT\",");

        // Serialize event
        const event_start = w.end;
        const event_json = try event.serialize(buf[event_start..]);
        w.end = event_start + event_json.len;

        try w.writeAll("]");

        try self.send(w.buffered());
    }

    /// Send a Nostr REQ message
    pub fn sendReq(self: *Client, sub_id: []const u8, filters: []const nostr.Filter) !void {
        var buf: [65536]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        try w.writeAll("[\"REQ\",\"");
        try w.writeAll(sub_id);
        try w.writeByte('"');

        for (filters) |filter| {
            try w.writeByte(',');
            const filter_start = w.end;
            const filter_json = try filter.serialize(buf[filter_start..]);
            w.end = filter_start + filter_json.len;
        }

        try w.writeAll("]");

        try self.send(w.buffered());
    }

    /// Send a Nostr CLOSE message
    pub fn sendClose(self: *Client, sub_id: []const u8) !void {
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        try w.writeAll("[\"CLOSE\",\"");
        try w.writeAll(sub_id);
        try w.writeAll("\"]");

        try self.send(w.buffered());
    }
};

test "url parsing" {
    const allocator = std.testing.allocator;

    const client1 = try Client.init(allocator, "ws://localhost:8080/");
    try std.testing.expectEqualStrings("localhost", client1.host);
    try std.testing.expectEqual(@as(u16, 8080), client1.port);
    try std.testing.expectEqualStrings("/", client1.path);

    const client2 = try Client.init(allocator, "wss://relay.example.com/nostr");
    try std.testing.expectEqualStrings("relay.example.com", client2.host);
    try std.testing.expectEqual(@as(u16, 443), client2.port);
    try std.testing.expectEqualStrings("/nostr", client2.path);
}
