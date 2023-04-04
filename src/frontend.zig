//! Frontend interface.

const std = @import("std");
const os = std.os;
const debug = std.debug;

const Wayland = @import("frontend/Wayland.zig");
const TTY = @import("frontend/TTY.zig");

const InterfaceMode = enum {
    none,
    getpin,
    message,
};

pub const FrontendEvent = enum {
    none,
    user_abort,
    user_not_ok,
    user_ok,
};

pub const InitError = error{InitFailed};
pub const EnterModeError = error{EnterModeFailed};
pub const AbortModeError = error{AbortModeFailed};
pub const HandleEventError = error{HandleEventFailed};

const FrontendImpl = struct {
    impl: *anyopaque,
    initPtr: *const fn (*anyopaque) InitError!void,
    deinitPtr: *const fn (*anyopaque) void,
    getFdPtr: *const fn (*anyopaque) os.fd_t,
    enterModePtr: *const fn (*anyopaque, InterfaceMode) EnterModeError!void,
    handleEventPtr: *const fn (*anyopaque) HandleEventError!FrontendEvent,

    pub fn wrap(
        parent: anytype,
        comptime initImpl: *const fn (@TypeOf(parent)) InitError!void,
        comptime deinitImpl: *const fn (@TypeOf(parent)) void,
        comptime getFdImpl: *const fn (@TypeOf(parent)) os.fd_t,
        comptime enterModeImpl: *const fn (@TypeOf(parent), InterfaceMode) EnterModeError!void,
        comptime handleEventImpl: *const fn (@TypeOf(parent)) HandleEventError!FrontendEvent,
    ) Frontend {
        const T = @TypeOf(parent);
        const I = @typeInfo(T);

        debug.assert(I == .Pointer);
        debug.assert(I.Pointer.size == .One);
        debug.assert(@typeInfo(I.Pointer.child) == .Struct);

        const impl = struct {
            fn initImpl(ptr: T) !void {
                const self = @ptrCast(T, @alignCast(I.Pointer.alignment, ptr));
                try initImpl(self);
            }
            fn deinitImpl(ptr: T) !void {
                const self = @ptrCast(T, @alignCast(I.Pointer.alignment, ptr));
                deinitImpl(self);
            }
            fn getFdImpl(ptr: T) os.fd_t {
                const self = @ptrCast(T, @alignCast(I.Pointer.alignment, ptr));
                getFdImpl(self);
            }
            fn enterModeImpl(ptr: T, mode: InterfaceMode) !void {
                const self = @ptrCast(T, @alignCast(I.Pointer.alignment, ptr));
                try enterModeImpl(self, mode);
            }
            fn handleEventImpl(ptr: T) !FrontendEvent {
                const self = @ptrCast(T, @alignCast(I.Pointer.alignment, ptr));
                try handleEventImpl(self);
            }
        };

        return .{
            .impl = parent,
            .initPtr = impl.initImpl,
            .deinitPtr = impl.deinitImpl,
            .getFdPtr = impl.getFdImpl,
            .enterModePtr = impl.enterModeImpl,
            .handleEventPtr = impl.handleEventImpl,
        };
    }

    pub fn init(self: Frontend) !void {
        try self.initPtr(self.impl);
    }
    pub fn deinit(self: Frontend) !void {
        self.deinitPtr(self.impl);
    }
    pub fn getFd(self: Frontend) os.fd_t {
        try self.getFdPtr(self.impl);
    }
    pub fn enterMode(self: Frontend, mode: InterfaceMode) !void {
        try self.enterModePtr(self.impl, mode);
    }
    pub fn handleEvent(self: Frontend) !FrontendEvent {
        try self.handleEventPtr(self.impl);
    }
};

const Frontend = struct {
    wayland: Wayland = .{},
    tty: TTY = .{},
    impl: FrontendImpl = undefined,

    pub fn getInitFrontend(self: *Frontend) !FrontendImpl {
        var frontend = self.wayland.getFrontend();
        frontend.init() catch {
            frontend = self.tty.getFrontend();
            try frontend.init();
        };

        return frontend;
    }
};
