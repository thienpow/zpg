const std = @import("std");

pub const AuthType = enum(i32) {
    AuthenticationOk = 0, // Successful authentication
    KerberosV5 = 2, // Kerberos V5 authentication
    CleartextPassword = 3, // Cleartext password
    Md5Password = 5, // MD5-hashed password
    ScmCredentials = 6, // SCM credentials (Unix domain sockets)
    Gssapi = 7, // GSSAPI authentication
    Sspi = 9, // SSPI (Windows-specific)
    Sasl = 10, // SASL (e.g., SCRAM-SHA-256)
    SaslContinue = 12, // SASL Continue
};

pub const RequestType = enum(u8) {
    Query = 'Q',
    Parse = 'P',
    Bind = 'B',
    Describe = 'D', // Note: Overlaps with DataRow, see below
    Execute = 'E', // Note: Overlaps with ErrorResponse, see below
    Sync = 'S', // Note: Overlaps with ParameterStatus, see below
    Close = 'C', // Note: Overlaps with CommandComplete, see below
    Terminate = 'X',
    PasswordMessage = 'p',
};

pub const ResponseType = enum(u8) {
    AuthenticationRequest = 'R',
    ParameterStatus = 'S',
    BackendKeyData = 'K',
    ReadyForQuery = 'Z',
    RowDescription = 'T',
    DataRow = 'D',
    CommandComplete = 'C',
    ErrorResponse = 'E',
    NoticeResponse = 'N',
    NotificationResponse = 'A',
    BindComplete = '2',
    ParseComplete = '1',
    CopyInResponse = 'G',
    CopyOutResponse = 'H',
    CopyData = 'd',
    CopyDone = 'c',
    EmptyQueryResponse = 'I',
    ParameterDescription = 't',
    PortalSuspended = 's', // Added for partial execution
    NoData = 'n', // Added for non-row-returning statements
    CloseComplete = '3', // Added for future Close support
    // FunctionCallResponse = 'V', // Optional, if you add function calls
    // NegotiateProtocolVersion = 'v', // Optional, if protocol negotiation
    _, // Catch-all for unhandled types
};

pub const ConnectionState = enum {
    Disconnected,
    Connecting,
    Connected,
    Querying,
    Error,
};

pub const CommandType = enum {
    Select,
    Insert,
    Update,
    Delete,
    Merge,
    Prepare,
    Create,
    Alter,
    Drop,
    Grant,
    Revoke,
    Commit,
    Rollback,
    Explain,
    Execute,
    Unknown,
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

pub const Oid = u32;

pub const TypeOids = struct {
    pub const INT4: Oid = 23;
    pub const TEXT: Oid = 25;
    pub const VARCHAR: Oid = 1043;
    pub const NUMERIC: Oid = 1700; // Important for Decimal
    pub const TIMESTAMP: Oid = 1114;
    pub const TIMESTAMPTZ: Oid = 1184;
    pub const INTERVAL: Oid = 1186;
    pub const UUID: Oid = 2950;
    // ... other OIDs ...
};

pub fn getCommandType(command: []const u8) CommandType {
    return if (std.mem.startsWith(u8, command, "SELECT")) .Select //SELECT
    else if (std.mem.startsWith(u8, command, "WITH")) .Select //WITH
    else if (std.mem.startsWith(u8, command, "INSERT")) .Insert //INSERT
    else if (std.mem.startsWith(u8, command, "UPDATE")) .Update //UPDATE
    else if (std.mem.startsWith(u8, command, "DELETE")) .Delete //DELETE
    else if (std.mem.startsWith(u8, command, "MERGE")) .Merge //MERGE
    else if (std.mem.startsWith(u8, command, "PREPARE")) .Prepare //PREPARE
    else if (std.mem.startsWith(u8, command, "CREATE")) .Create //CREATE
    else if (std.mem.startsWith(u8, command, "ALTER")) .Alter //ALTER
    else if (std.mem.startsWith(u8, command, "DROP")) .Drop //DROP
    else if (std.mem.startsWith(u8, command, "GRANT")) .Grant //GRANT
    else if (std.mem.startsWith(u8, command, "REVOKE")) .Revoke //REVOKE
    else if (std.mem.startsWith(u8, command, "COMMIT")) .Commit //COMMIT
    else if (std.mem.startsWith(u8, command, "ROLLBACK")) .Rollback //ROLLBACK
    else if (std.mem.startsWith(u8, command, "EXPLAIN")) .Explain //EXPLAIN
    else if (std.mem.startsWith(u8, command, "EXECUTE")) .Execute //EXECUTE
    else .Unknown;
}

pub const NoticeField = enum(u8) {
    Severity = 'S',
    Severity_Nonlocalized = 'V',
    Code = 'C',
    Message = 'M',
    Detail = 'D',
    Hint = 'H',
    Position = 'P',
    Internal_Position = 'q',
    Internal_Query = 'Q',
    Where = 'W',
    Schema_Name = 's',
    Table_Name = 't',
    Column_Name = 'c',
    Data_Type_Name = 'd',
    Constraint_Name = 'n',
    File = 'F',
    Line = 'L',
    Routine = 'R',
    _,
};

pub const Notice = struct {
    severity: ?[]const u8 = null,
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    code: ?[]const u8 = null,

    pub fn deinit(self: *Notice, allocator: std.mem.Allocator) void {
        if (self.severity) |s| allocator.free(s);
        if (self.message) |m| allocator.free(m);
        if (self.detail) |d| allocator.free(d);
        if (self.hint) |h| allocator.free(h);
        if (self.code) |c| allocator.free(c);
    }
};

pub const ErrorField = enum(u8) {
    Severity = 'S',
    Severity_Nonlocalized = 'V',
    Code = 'C',
    Message = 'M',
    Detail = 'D',
    Hint = 'H',
    Position = 'P',
    Internal_Position = 'q',
    Internal_Query = 'Q',
    Where = 'W',
    Schema_Name = 's',
    Table_Name = 't',
    Column_Name = 'c',
    Data_Type_Name = 'd',
    Constraint_Name = 'n',
    File = 'F',
    Line = 'L',
    Routine = 'R',
    _,
};

pub const PostgresError = struct {
    severity: ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,

    pub fn deinit(self: *PostgresError, allocator: std.mem.Allocator) void {
        if (self.severity) |s| allocator.free(s);
        if (self.code) |c| allocator.free(c);
        if (self.message) |m| allocator.free(m);
        if (self.detail) |d| allocator.free(d);
        if (self.hint) |h| allocator.free(h);
    }
};
