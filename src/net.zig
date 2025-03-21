const std = @import("std");
const mem = std.mem;
const types = @import("types.zig"); // Assuming this is where your Error type is defined

/// Resolves a hostname to a network address with the specified port.
/// Returns the first valid address found or an error if resolution fails.
/// Supports both IPv4 and IPv6 addresses.
pub fn resolveHostname(
    allocator: mem.Allocator,
    host: []const u8,
    port: u16,
) types.Error!std.net.Address {
    // Handle empty hostname
    if (host.len == 0) {
        return error.InvalidHostname;
    }

    // First, try to parse as a direct IP address
    if (std.net.Address.parseIp4(host, port)) |addr| {
        return addr;
    } else |_| {
        if (std.net.Address.parseIp6(host, port)) |addr| {
            return addr;
        } else |_| {}
    }

    // If not an IP, perform DNS lookup
    const address_list = std.net.getAddressList(allocator, host, port) catch |err| {
        std.debug.print("DNS resolution failed for '{s}': {}\n", .{ host, err });
        return err;
    };
    defer address_list.deinit();

    // Check if we got any addresses
    if (address_list.addrs.len == 0) {
        std.debug.print("No addresses found for hostname: {s}\n", .{host});
        return error.NoAddressesFound;
    }

    // Return the first valid address
    const addr = address_list.addrs[0];

    // Log the successful resolution
    if (std.debug.runtime_safety) {
        const ip_str = switch (addr.any.family) {
            std.posix.AF.INET => blk: {
                var buf: [15]u8 = undefined;
                const ip = addr.in.sa.addr;
                break :blk std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{
                    (ip >> 24) & 0xFF,
                    (ip >> 16) & 0xFF,
                    (ip >> 8) & 0xFF,
                    ip & 0xFF,
                }) catch "IPv4 error";
            },
            std.posix.AF.INET6 => blk: {
                var buf: [45]u8 = undefined;
                const ip6_bytes = &addr.in6.sa.addr;
                break :blk std.fmt.bufPrint(&buf, "{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}", .{
                    (@as(u16, ip6_bytes[0]) << 8) | ip6_bytes[1],
                    (@as(u16, ip6_bytes[2]) << 8) | ip6_bytes[3],
                    (@as(u16, ip6_bytes[4]) << 8) | ip6_bytes[5],
                    (@as(u16, ip6_bytes[6]) << 8) | ip6_bytes[7],
                    (@as(u16, ip6_bytes[8]) << 8) | ip6_bytes[9],
                    (@as(u16, ip6_bytes[10]) << 8) | ip6_bytes[11],
                    (@as(u16, ip6_bytes[12]) << 8) | ip6_bytes[13],
                    (@as(u16, ip6_bytes[14]) << 8) | ip6_bytes[15],
                }) catch "IPv6 error";
            },
            else => "Unknown address family",
        };
        std.debug.print("Resolved {s} to {s}:{}\n", .{ host, ip_str, port });
    }

    return addr;
}
