//! Leaf types shared across the library, kept dependency-free so every module
//! (public API, backends, daemon) can import them without an import cycle.

/// A device opened through a seat: an id to close it by, and the fd to use.
pub const Device = struct {
    id: i32,
    fd: i32,
};

/// Errors surfaced by the public API. `Denied` wraps a server-reported errno,
/// retrievable via `Seat.lastErrno`.
pub const Error = error{
    NoBackend,
    ConnectionFailed,
    Disconnected,
    ProtocolError,
    Denied,
    SeatInUse,
    InvalidArgument,
    OutOfMemory,
    WouldBlock,
    Interrupted,
    ConnectionReset,
    BrokenPipe,
    TooManyFds,
    Unexpected,
};
