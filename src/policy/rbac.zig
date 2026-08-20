//! Role-based access control for the remote daemon / API surface.
//!
//! Roles are a linear hierarchy (owner > editor > viewer > auditor > none).
//! Each tool or daemon endpoint declares a minimum required role. When
//! the daemon is protected only by a bearer token, that principal is
//! implicitly `owner` (matches pre-RBAC behaviour). Once OIDC ID-token
//! verification is wired in, the role is derived from a claim.
//!
//! The auditor role sits just above viewer: it inherits read-only
//! session access and adds the exclusive ability to read the audit
//! log. If you need an auditor who is barred from reading session
//! bodies, rely on `privacy_redact_prompt_bodies=true` so no role can
//! see prompt content even through session reads.

const std = @import("std");

pub const Role = enum(u8) {
    none = 0,
    viewer = 1,
    auditor = 2, // above viewer: inherits session-list reads, adds audit-read
    editor = 3,
    owner = 4,

    pub fn fromString(s: []const u8) Role {
        if (std.ascii.eqlIgnoreCase(s, "owner")) return .owner;
        if (std.ascii.eqlIgnoreCase(s, "editor")) return .editor;
        if (std.ascii.eqlIgnoreCase(s, "viewer")) return .viewer;
        if (std.ascii.eqlIgnoreCase(s, "auditor")) return .auditor;
        return .none;
    }

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .none => "none",
            .auditor => "auditor",
            .viewer => "viewer",
            .editor => "editor",
            .owner => "owner",
        };
    }

    pub fn atLeast(self: Role, minimum: Role) bool {
        return @intFromEnum(self) >= @intFromEnum(minimum);
    }
};

/// Minimum role required for each daemon endpoint. Keep in sync with
/// the routing in remote_daemon.zig; adding a new route with auth
/// implications should force a change here to make the policy choice
/// explicit at review time.
pub const Endpoint = enum {
    health,
    share_read,
    view_render,
    session_list,
    session_read,
    session_write,
    audit_read,

    pub fn requiredRole(self: Endpoint) Role {
        return switch (self) {
            .health => .none, // reachable without a role for liveness probes
            .audit_read => .auditor,
            .share_read, .view_render, .session_list => .viewer,
            .session_read => .viewer,
            .session_write => .editor,
        };
    }
};

pub fn authorize(principal: Role, endpoint: Endpoint) bool {
    return principal.atLeast(endpoint.requiredRole());
}

// --- Tests ------------------------------------------------------------

const testing = std.testing;

test "role hierarchy" {
    try testing.expect(Role.owner.atLeast(.editor));
    try testing.expect(Role.owner.atLeast(.viewer));
    try testing.expect(Role.owner.atLeast(.auditor));
    try testing.expect(Role.owner.atLeast(.owner));
    try testing.expect(!Role.viewer.atLeast(.editor));
    // Auditor is above viewer, so it CAN perform viewer actions.
    try testing.expect(Role.auditor.atLeast(.viewer));
    try testing.expect(!Role.viewer.atLeast(.auditor));
}

test "endpoint requirements" {
    try testing.expect(authorize(.viewer, .session_list));
    try testing.expect(!authorize(.viewer, .session_write));
    try testing.expect(authorize(.editor, .session_write));
    // Owner sits above auditor in the linear hierarchy, so owner CAN
    // read the audit log. Pure-auditor roles can read audit but not
    // mutate sessions.
    try testing.expect(authorize(.owner, .audit_read));
    try testing.expect(authorize(.auditor, .audit_read));
    try testing.expect(!authorize(.auditor, .session_write));
}

test "role from string is case-insensitive" {
    try testing.expectEqual(Role.owner, Role.fromString("Owner"));
    try testing.expectEqual(Role.auditor, Role.fromString("AUDITOR"));
    try testing.expectEqual(Role.none, Role.fromString("unknown"));
}
