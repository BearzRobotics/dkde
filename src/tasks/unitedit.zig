//! Editing a service from the Services page: a systemd drop-in override (what `systemctl edit` writes), reverting it,
//! and dinit's service description file. Names are validated here and reach the tools as arguments or on standard
//! input, never inside shell text.

const std = @import("std");

/// A unit name as systemd writes it: letters, digits and : _ . @ - \ , ending in a known type.
pub fn validUnit(name: []const u8) bool {
    if (name.len < 3 or name.len > 120) return false;
    const types = [_][]const u8{ ".service", ".timer", ".socket", ".target", ".path", ".mount" };
    var ok_type = false;
    for (types) |ty| if (std.mem.endsWith(u8, name, ty)) {
        ok_type = true;
    };
    if (!ok_type) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == ':' or c == '_' or c == '.' or c == '@' or c == '-' or c == '\\')) return false;
    return name[0] != '.' and name[0] != '-';
}

/// A dinit service name: its file name in the service directory.
pub fn validDinit(name: []const u8) bool {
    if (name.len == 0 or name.len > 100) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '@')) return false;
    return name[0] != '.';
}

/// What to show when a unit has no override yet.
pub const template =
    \\[Service]
    \\# Anything written here changes the unit without touching the package's own file.
    \\# For example:
    \\#Environment=NAME=value
    \\#Restart=on-failure
    \\#ExecStart=
    \\#ExecStart=/usr/bin/program --option
    \\
;

/// Whether the text has anything but comments, blank lines and bare section headers.
pub fn hasContent(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] != '#' and line[0] != ';' and line[0] != '[') return true;
    }
    return false;
}

/// Reads the system override of unit $1 (nothing, not an error, when there is none).
pub const read_system_script = "cat \"/etc/systemd/system/$1.d/override.conf\" 2>/dev/null; true";

/// Writes the new override from standard input, or removes it when it says nothing, then reloads systemd ($1 = unit).
pub const write_system_script =
    \\d="/etc/systemd/system/$1.d"; f="$d/override.conf"; c=$(cat)
    \\if [ -z "$(printf '%s' "$c" | tr -d ' \t\n\r')" ]; then rm -f "$f"; rmdir "$d" 2>/dev/null
    \\else mkdir -p "$d" && printf '%s\n' "$c" > "$f" || exit 1; fi
    \\systemctl daemon-reload
;

/// Writes dinit's service file from standard input ($1 = the file).
pub const write_dinit_script =
    \\f="$1"; [ -f "$f" ] && [ ! -f "$f.dkde-backup" ] && cp "$f" "$f.dkde-backup"
    \\cat > "$f"
;

test "unit and service names are checked" {
    try std.testing.expect(validUnit("cups.service") and validUnit("getty@tty1.service") and validUnit("apt-daily.timer") and validUnit("dbus.socket"));
    try std.testing.expect(!validUnit("cups") and !validUnit("a b.service") and !validUnit("x;y.service") and !validUnit("$(id).service") and !validUnit(".service") and !validUnit("../a.service"));
    try std.testing.expect(validDinit("sshd") and validDinit("agetty-tty1") and !validDinit("a/b") and !validDinit("") and !validDinit(".hidden") and !validDinit("a b"));
}

test "an override with only comments says nothing" {
    try std.testing.expect(!hasContent(template));
    try std.testing.expect(hasContent("[Service]\nRestart=always\n"));
    try std.testing.expect(!hasContent("  \n# x\n"));
}
