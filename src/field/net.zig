const std = @import("std");

/// Represents PostgreSQL's `cidr` type: an IP network (e.g., "192.168.1.0/24")
pub const CIDR = struct {
    address: [16]u8, // Stores IPv4 (4 bytes) or IPv6 (16 bytes)
    mask: u8, // Subnet mask (0-32 for IPv4, 0-128 for IPv6)
    is_ipv6: bool, // True for IPv6, false for IPv4

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !CIDR {
        _ = allocator; // Included for consistency
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

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !Inet {
        _ = allocator;
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

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !MACAddress {
        _ = allocator;
        var bytes: [6]u8 = undefined;
        var iter = std.mem.split(u8, text, ":");
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

    pub fn fromPostgresText(text: []const u8, allocator: std.mem.Allocator) !MACAddress8 {
        _ = allocator;
        var bytes: [8]u8 = undefined;
        var iter = std.mem.split(u8, text, ":");
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
fn parseIPv4(text: []const u8, address: *[16]u8) !void {
    var iter = std.mem.split(u8, text, ".");
    var i: usize = 0;
    while (iter.next()) |octet| {
        if (i >= 4) return error.InvalidIPv4Format;
        address[i] = try std.fmt.parseInt(u8, octet, 10);
        i += 1;
    }
    if (i != 4) return error.InvalidIPv4Format;
    @memset(address[4..], 0); // Zero out unused bytes
}

fn parseIPv6(text: []const u8, address: *[16]u8) !void {
    // Simplified: assumes full format (no :: abbreviation)
    var iter = std.mem.split(u8, text, ":");
    var i: usize = 0;
    while (iter.next()) |segment| {
        if (i >= 8) return error.InvalidIPv6Format;
        const val = try std.fmt.parseInt(u16, segment, 16);
        address[i * 2] = @intCast(val >> 8);
        address[i * 2 + 1] = @intCast(val & 0xFF);
        i += 1;
    }
    if (i != 8) return error.InvalidIPv6Format;
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

// Tests
test "Network Address Types" {
    const allocator = std.testing.allocator;

    // CIDR
    const cidr = try CIDR.fromPostgresText("192.168.1.0/24", allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &cidr.address);
    const cidr_str = try cidr.toString(allocator);
    defer allocator.free(cidr_str);
    try std.testing.expectEqualStrings("192.168.1.0/24", cidr_str);

    // Inet
    const inet = try Inet.fromPostgresText("192.168.1.5", allocator);
    try std.testing.expectEqual(@as(u8, 255), inet.mask);
    const inet_str = try inet.toString(allocator);
    defer allocator.free(inet_str);
    try std.testing.expectEqualStrings("192.168.1.5", inet_str);

    // MACAddress
    const mac = try MACAddress.fromPostgresText("08:00:2b:01:02:03", allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00, 0x2b, 0x01, 0x02, 0x03 }, &mac.bytes);
    const mac_str = try mac.toString(allocator);
    defer allocator.free(mac_str);
    try std.testing.expectEqualStrings("08:00:2b:01:02:03", mac_str);

    // MACAddress8
    const mac8 = try MACAddress8.fromPostgresText("08:00:2b:ff:fe:01:02:03", allocator);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x00, 0x2b, 0xff, 0xfe, 0x01, 0x02, 0x03 }, &mac8.bytes);
    const mac8_str = try mac8.toString(allocator);
    defer allocator.free(mac8_str);
    try std.testing.expectEqualStrings("08:00:2b:ff:fe:01:02:03", mac8_str);
}
