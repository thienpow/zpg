const std = @import("std");

/// Represents PostgreSQL's `cidr` type: an IP network (e.g., "192.168.1.0/24")
pub const CIDR = struct {
    address: [16]u8, // Stores IPv4 (4 bytes) or IPv6 (16 bytes)
    mask: u8, // Subnet mask (0-32 for IPv4, 0-128 for IPv6)
    is_ipv6: bool, // True for IPv6, false for IPv4

    pub fn fromPostgresBinary(data: []const u8) !CIDR {
        if (data.len < 4) return error.InvalidCIDRBinaryFormat;

        const family = data[0];
        const mask = data[1];
        const addr_len = data[2];

        var address: [16]u8 = undefined;
        @memset(&address, 0); // Zero out to handle IPv4 in a 16-byte buffer

        if (family == 2) { // IPv4
            if (addr_len != 4 or mask > 32) return error.InvalidCIDRBinaryFormat;
            @memcpy(address[0..4], data[3..7]);
            return CIDR{ .address = address, .mask = mask, .is_ipv6 = false };
        } else if (family == 3) { // IPv6
            if (addr_len != 16 or mask > 128) return error.InvalidCIDRBinaryFormat;
            @memcpy(address[0..16], data[3..19]);
            return CIDR{ .address = address, .mask = mask, .is_ipv6 = true };
        } else {
            return error.UnknownCIDRFamily;
        }
    }

    pub fn fromPostgresText(text: []const u8) !CIDR {
        const slash_pos = std.mem.indexOf(u8, text, "/") orelse return error.InvalidCIDRFormat;
        const addr_str = text[0..slash_pos];
        const mask = try std.fmt.parseInt(u8, text[slash_pos + 1 ..], 10);

        var address: [16]u8 = undefined;
        const is_ipv6 = std.mem.indexOf(u8, addr_str, ":") != null;

        if (is_ipv6) {
            if (mask > 128) return error.InvalidCIDRMask;
            try parseIPv6(addr_str, &address);
        } else {
            if (mask > 32) return error.InvalidCIDRMask;
            try parseIPv4(addr_str, &address);
        }

        return CIDR{ .address = address, .mask = mask, .is_ipv6 = is_ipv6 };
    }

    pub fn toString(self: CIDR, allocator: std.mem.Allocator) ![]u8 {
        if (self.is_ipv6) {
            const addr_str = try formatIPv6(self.address, allocator);
            defer allocator.free(addr_str);
            return try std.fmt.allocPrint(allocator, "{s}/{d}", .{ addr_str, self.mask });
        } else {
            const addr_str = try formatIPv4(self.address, allocator);
            defer allocator.free(addr_str);
            return try std.fmt.allocPrint(allocator, "{s}/{d}", .{ addr_str, self.mask });
        }
    }
};

/// Represents PostgreSQL's `inet` type: an IP address with optional mask (e.g., "192.168.1.5/24")
pub const Inet = struct {
    address: [16]u8, // IPv4 (4 bytes) or IPv6 (16 bytes)
    mask: u8, // Subnet mask (0-32 for IPv4, 0-128 for IPv6), 255 if not specified
    is_ipv6: bool, // True for IPv6, false for IPv4

    pub fn fromPostgresBinary(data: []const u8) !Inet {
        if (data.len < 4) return error.InvalidInetBinaryFormat;

        const family = data[0];
        const mask = data[1];
        const addr_len = data[2];

        var address: [16]u8 = undefined;
        @memset(&address, 0); // Zero out unused bytes for IPv4

        if (family == 2) { // IPv4
            if (addr_len != 4 or mask > 32) return error.InvalidInetBinaryFormat;
            @memcpy(address[0..4], data[3..7]);
            return Inet{ .address = address, .mask = mask, .is_ipv6 = false };
        } else if (family == 3) { // IPv6
            if (addr_len != 16 or mask > 128) return error.InvalidInetBinaryFormat;
            @memcpy(address[0..16], data[3..19]);
            return Inet{ .address = address, .mask = mask, .is_ipv6 = true };
        } else {
            return error.UnknownInetFamily;
        }
    }

    pub fn fromPostgresText(text: []const u8) !Inet {
        const slash_pos = std.mem.indexOf(u8, text, "/");
        const addr_str = if (slash_pos) |pos| text[0..pos] else text;
        const mask = if (slash_pos) |pos| try std.fmt.parseInt(u8, text[pos + 1 ..], 10) else @as(u8, 255);

        var address: [16]u8 = undefined;
        const is_ipv6 = std.mem.indexOf(u8, addr_str, ":") != null;

        if (is_ipv6) {
            if (mask > 128 and mask != 255) return error.InvalidInetMask;
            try parseIPv6(addr_str, &address);
        } else {
            if (mask > 32 and mask != 255) return error.InvalidInetMask;
            try parseIPv4(addr_str, &address);
        }

        return Inet{ .address = address, .mask = mask, .is_ipv6 = is_ipv6 };
    }

    pub fn toString(self: Inet, allocator: std.mem.Allocator) ![]u8 {
        if (self.is_ipv6) {
            const addr_str = try formatIPv6(self.address, allocator);
            defer allocator.free(addr_str);
            return if (self.mask == 255)
                try std.fmt.allocPrint(allocator, "{s}", .{addr_str})
            else
                try std.fmt.allocPrint(allocator, "{s}/{d}", .{ addr_str, self.mask });
        } else {
            const addr_str = try formatIPv4(self.address, allocator);
            defer allocator.free(addr_str);
            return if (self.mask == 255)
                try std.fmt.allocPrint(allocator, "{s}", .{addr_str})
            else
                try std.fmt.allocPrint(allocator, "{s}/{d}", .{ addr_str, self.mask });
        }
    }
};

/// Represents PostgreSQL's `macaddr` type: a 6-byte MAC address (e.g., "08:00:2b:01:02:03")
pub const MACAddress = struct {
    bytes: [6]u8,

    pub fn fromPostgresBinary(data: []const u8) !MACAddress {
        if (data.len != 6) return error.InvalidMACBinaryFormat;

        var bytes: [6]u8 = undefined;
        @memcpy(&bytes, data[0..6]);

        return MACAddress{ .bytes = bytes };
    }

    pub fn fromPostgresText(text: []const u8) !MACAddress {
        var bytes: [6]u8 = undefined;
        var iter = std.mem.splitScalar(u8, text, ':');
        var i: usize = 0;

        while (iter.next()) |octet| {
            if (i >= 6) return error.InvalidMACFormat;
            bytes[i] = try std.fmt.parseInt(u8, octet, 16);
            i += 1;
        }
        if (i != 6) return error.InvalidMACFormat;

        return MACAddress{ .bytes = bytes };
    }

    pub fn toString(self: MACAddress, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            self.bytes[0], self.bytes[1], self.bytes[2],
            self.bytes[3], self.bytes[4], self.bytes[5],
        });
    }
};

/// Represents PostgreSQL's `macaddr8` type: an 8-byte MAC address (e.g., "08:00:2b:ff:fe:01:02:03")
pub const MACAddress8 = struct {
    bytes: [8]u8,

    pub fn fromPostgresBinary(data: []const u8) !MACAddress8 {
        if (data.len != 8) return error.InvalidMAC8BinaryFormat;

        var bytes: [8]u8 = undefined;
        @memcpy(&bytes, data[0..8]);

        return MACAddress8{ .bytes = bytes };
    }

    pub fn fromPostgresText(text: []const u8) !MACAddress8 {
        var bytes: [8]u8 = undefined;
        var iter = std.mem.splitScalar(u8, text, ':');
        var i: usize = 0;

        while (iter.next()) |octet| {
            if (i >= 8) return error.InvalidMAC8Format;
            bytes[i] = try std.fmt.parseInt(u8, octet, 16);
            i += 1;
        }
        if (i != 8) return error.InvalidMAC8Format;

        return MACAddress8{ .bytes = bytes };
    }

    pub fn toString(self: MACAddress8, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            self.bytes[4], self.bytes[5], self.bytes[6], self.bytes[7],
        });
    }
};

// Helper functions for IP parsing and formatting
// fn parseIPv4(text: []const u8, address: *[16]u8) !void {
//     var iter = std.mem.splitScalar(u8, text, '.');
//     var i: usize = 0;
//     while (iter.next()) |octet| {
//         if (i >= 4) return error.InvalidIPv4Format;
//         address[i] = try std.fmt.parseInt(u8, octet, 10);
//         i += 1;
//     }
//     if (i != 4) return error.InvalidIPv4Format;
//     @memset(address[4..], 0);
// }
fn parseIPv4(text: []const u8, address: *[16]u8) !void {
    @memset(address, 0); // Zero out the full address
    var iter = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;

    while (iter.next()) |octet| {
        if (i >= 4) return error.InvalidIPv4Format;
        address[i] = try std.fmt.parseInt(u8, octet, 10);
        i += 1;
    }
    if (i != 4) return error.InvalidIPv4Format;
}

fn parseIPv6(text: []const u8, address: *[16]u8) !void {
    @memset(address, 0); // Initialize all to zero first

    const double_colon_pos = std.mem.indexOf(u8, text, "::");

    if (double_colon_pos == null) {
        // Full form: expect exactly 8 segments
        var iter = std.mem.splitScalar(u8, text, ':');
        var i: usize = 0;
        while (iter.next()) |segment| {
            if (i >= 16) return error.InvalidIPv6Format;
            const val = try std.fmt.parseInt(u16, segment, 16);
            address[i] = @intCast(val >> 8);
            address[i + 1] = @intCast(val & 0xFF);
            i += 2;
        }
        if (i != 16) return error.InvalidIPv6Format;
    } else {
        // Handle abbreviated form
        var iter = std.mem.splitScalar(u8, text, ':');
        var segments: [8]?u16 = [1]?u16{null} ** 8; // Store parsed segments
        var segment_count: usize = 0;

        // Parse all segments into an array
        while (iter.next()) |segment| {
            if (segment.len > 0) {
                if (segment_count >= 8) return error.InvalidIPv6Format;
                segments[segment_count] = try std.fmt.parseInt(u16, segment, 16);
                segment_count += 1;
            }
        }

        // Count segments before ::
        var temp_iter = std.mem.splitScalar(u8, text, ':');
        var segments_before: usize = 0;
        var seen_double_colon = false;
        while (temp_iter.next()) |seg| {
            if (seg.len == 0 and !seen_double_colon) {
                seen_double_colon = true;
                break;
            }
            if (seg.len > 0) segments_before += 1;
        }

        const total_segments = segment_count;
        const zero_segments = 8 - total_segments;

        var i: usize = 0;

        // Write segments before ::
        for (segments[0..segments_before]) |maybe_val| {
            if (maybe_val) |val| {
                address[i] = @intCast(val >> 8);
                address[i + 1] = @intCast(val & 0xFF);
                i += 2;
            }
        }

        // Skip zero segments
        i += zero_segments * 2;

        // Write segments after ::
        for (segments[segments_before..total_segments]) |maybe_val| {
            if (maybe_val) |val| {
                address[i] = @intCast(val >> 8);
                address[i + 1] = @intCast(val & 0xFF);
                i += 2;
            }
        }
    }
}

fn formatIPv4(address: [16]u8, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
        address[0], address[1], address[2], address[3],
    });
}

fn formatIPv6(address: [16]u8, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
        address[0],  address[1],  address[2],  address[3],
        address[4],  address[5],  address[6],  address[7],
        address[8],  address[9],  address[10], address[11],
        address[12], address[13], address[14], address[15],
    });
}
