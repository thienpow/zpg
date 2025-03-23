const std = @import("std");

pub const Error = error{
    ConnectionFailed,
    AuthenticationFailed,
    QueryFailed,
    SSLError,
    ProtocolError,
    InvalidMessage,
    PoolExhausted,
    TransactionError,
    StatementError,
    Overflow,
    SystemResources,
    Unexpected,
    NameTooLong,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    FileSystem,
    PermissionDenied,
    InvalidCharacter,
    InvalidEnd,
    Incomplete,
    InvalidIpv4Mapping,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    InterfaceNotFound,
    InvalidIPAddressFormat,
    WouldBlock,
    ConnectionResetByPeer,
    FileNotFound,
    ConnectionTimedOut,
    AddressInUse,
    AddressNotAvailable,
    ConnectionRefused,
    NetworkUnreachable,
    ConnectionPending,
    NoSpaceLeft,
    InvalidUtf8,
    FileTooBig,
    InputOutput,
    DeviceBusy,
    AccessDenied,
    BrokenPipe,
    OperationAborted,
    LockViolation,
    ProcessNotFound,
    NoDevice,
    OutOfMemory,
    SharingViolation,
    PathAlreadyExists,
    PipeBusy,
    InvalidWtf8,
    BadPathName,
    NetworkNotFound,
    AntivirusInterference,
    SymLinkLoop,
    IsDir,
    NotDir,
    FileLocksNotSupported,
    FileBusy,
    NotOpenForReading,
    SocketNotConnected,
    Canceled,
    NonCanonical,
    ReadOnlyFileSystem,
    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    AlreadyBound,
    AlreadyConnected,
    InvalidProtocolOption,
    TimeoutTooBig,
    OperationNotSupported,
    SocketNotBound,
    NameServerFailure,
    UnknownHostName,
    ServiceUnavailable,
    HostLacksNetworkAddresses,
    InvalidHostname,
    TemporaryNameServerFailure,
    NoAddressesFound,
    DiskQuota,
    InvalidArgument,
    NotOpenForWriting,
    EndOfStream,
    BufferTooSmall,
    StreamTooLong,
    InvalidPadding,
    InvalidServerResponse,
    WeakParameters,
    OutputTooLong,
    NoClientNonce,
    MissingScramData,
    MissingPassword,
    ServerSignatureMismatch,
    NotConnected,
    StatementNotPrepared,
    UnexpectedEOF,
    KerberosNotSupported,
    CleartextPasswordNotSupported,
    Md5PasswordNotSupported,
    ScmCredentialsNotSupported,
    GssapiNotSupported,
    SspiNotSupported,
    UnknownAuthMethod,
};

pub const AuthType = enum(u32) {
    Cleartext = 3,
    MD5 = 5,
    // Add other auth types as needed
};

pub const MessageType = enum(u8) {
    AuthenticationRequest = 'R',
    ParameterStatus = 'S',
    BackendKeyData = 'K',
    ReadyForQuery = 'Z',
    RowDescription = 'T',
    DataRow = 'D',
    CommandComplete = 'C',
    ErrorResponse = 'E',
    // Add other message types as needed
};

pub const IsolationLevel = enum {
    ReadUncommitted,
    ReadCommitted,
    RepeatableRead,
    Serializable,
};

pub const TransactionStatus = enum {
    Idle,
    InTransaction,
    InFailedTransaction,
};

pub const ConnectionState = enum {
    Disconnected,
    Connecting,
    Connected,
    Querying,
    Error,
};

pub const Action = enum {
    Select,
    Insert,
    Update,
    Delete,
    Other,
};

// Metadata to associate a statement with a struct type
pub const StatementInfo = struct {
    query: []const u8, // The prepared statement query
    type_id: usize, // A unique identifier for the struct type
};

// Generic struct to represent a row in an EXPLAIN plan
pub const ExplainRow = struct {
    operation: []const u8, // e.g., "Seq Scan", "Index Scan"
    target: []const u8, // Table or index name
    cost: f64, // Estimated cost (could be startup + total in some systems)
    rows: u64, // Estimated number of rows
    details: ?[]const u8, // Additional info (e.g., filter conditions)

    // Cleanup function for allocated strings
    pub fn deinit(self: ExplainRow, allocator: std.mem.Allocator) void {
        allocator.free(self.operation);
        allocator.free(self.target);
        if (self.details) |d| allocator.free(d);
    }
};

// Define Result without T dependency for non-SELECT cases
pub fn Result(comptime T: type) type {
    return union(enum) {
        select: []const T,
        command: u64,
        success: bool,
        explain: []ExplainRow,
    };
}

pub const Empty = struct {
    placeholder: usize,
};
