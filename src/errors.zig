const types = @import("types.zig");

pub const ErrorContext = struct {
    message: []const u8,
    code: []const u8,
    detail: []const u8,
};

pub fn wrapError(err: anyerror, context: ErrorContext) types.Error {
    _ = context;
    // Add context to the error
    return err;
}
