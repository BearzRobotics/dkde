//! A session written for reading (File > Export Session…): the entries and their
//! answers, then the variables and functions, as plain text or as one HTML page.
//! Unlike a .dkcalc file it cannot be opened again; it is for sharing and printing.

const std = @import("std");

pub const Entry = struct { expr: []const u8, result: []const u8 };
pub const Named = struct { name: []const u8, value: []const u8 };

pub const Session = struct {
    /// When it was exported, as text ("2026-11-14 10:30").
    when: []const u8,
    entries: []const Entry,
    variables: []const Named,
    functions: []const Named,
};

pub const Format = enum { text, html };

/// The format a file name asks for: .html and .htm are HTML, anything else text.
pub fn formatOf(path: []const u8) Format {
    if (std.ascii.endsWithIgnoreCase(path, ".html") or std.ascii.endsWithIgnoreCase(path, ".htm")) return .html;
    return .text;
}

pub fn text(a: std.mem.Allocator, s: Session) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "dkde-calc session, {s}\n", .{s.when});
    if (s.entries.len > 0) {
        try out.appendSlice(a, "\nCalculations\n");
        for (s.entries) |e| try out.print(a, "\n{s}\n    = {s}\n", .{ e.expr, e.result });
    }
    if (s.variables.len > 0) {
        try out.appendSlice(a, "\nVariables\n\n");
        for (s.variables) |v| try out.print(a, "{s} = {s}\n", .{ v.name, v.value });
    }
    if (s.functions.len > 0) {
        try out.appendSlice(a, "\nFunctions\n\n");
        for (s.functions) |f| try out.print(a, "{s} = {s}\n", .{ f.name, f.value });
    }
    return out.toOwnedSlice(a);
}

fn escape(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

pub fn html(a: std.mem.Allocator, s: Session) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>dkde-calc session</title>
        \\<style>
        \\:root { --fg: #1f2328; --bg: #ffffff; --dim: #59636e; --line: #d1d9e0; --accent: #0b4fc5; }
        \\@media (prefers-color-scheme: dark) { :root { --fg: #e6edf3; --bg: #0d1117; --dim: #9198a1; --line: #30363d; --accent: #7ab8ff; } }
        \\body { font: 16px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg); max-width: 46rem; margin: 2rem auto; padding: 0 1rem; }
        \\h1 { font-size: 1.4rem; margin-bottom: 0; } h2 { font-size: 1.1rem; margin-top: 2rem; }
        \\.when { color: var(--dim); margin-top: 0.2rem; }
        \\table { border-collapse: collapse; width: 100%; }
        \\td, th { text-align: left; padding: 0.35rem 0.6rem; border-bottom: 1px solid var(--line); vertical-align: top; }
        \\td.r { text-align: right; font-weight: 600; color: var(--accent); }
        \\code, td { font-family: ui-monospace, "DejaVu Sans Mono", monospace; }
        \\</style>
        \\</head>
        \\<body>
        \\<h1>dkde-calc session</h1>
        \\
    );
    try out.appendSlice(a, "<p class=\"when\">");
    try escape(a, &out, s.when);
    try out.appendSlice(a, "</p>\n");
    if (s.entries.len > 0) {
        try out.appendSlice(a, "<h2>Calculations</h2>\n<table>\n");
        for (s.entries) |e| {
            try out.appendSlice(a, "<tr><td>");
            try escape(a, &out, e.expr);
            try out.appendSlice(a, "</td><td class=\"r\">= ");
            try escape(a, &out, e.result);
            try out.appendSlice(a, "</td></tr>\n");
        }
        try out.appendSlice(a, "</table>\n");
    }
    inline for (.{ .{ "Variables", "variables" }, .{ "Functions", "functions" } }) |sec| {
        const items = @field(s, sec[1]);
        if (items.len > 0) {
            try out.print(a, "<h2>{s}</h2>\n<table>\n", .{sec[0]});
            for (items) |v| {
                try out.appendSlice(a, "<tr><td>");
                try escape(a, &out, v.name);
                try out.appendSlice(a, "</td><td>= ");
                try escape(a, &out, v.value);
                try out.appendSlice(a, "</td></tr>\n");
            }
            try out.appendSlice(a, "</table>\n");
        }
    }
    try out.appendSlice(a, "</body>\n</html>\n");
    return out.toOwnedSlice(a);
}

test "plain text and html exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Session = .{
        .when = "2026-11-14 10:30",
        .entries = &.{ .{ .expr = "2+2", .result = "4" }, .{ .expr = "5 < 7 & x > 1", .result = "true" } },
        .variables = &.{.{ .name = "x", .value = "5" }},
        .functions = &.{.{ .name = "f(x)", .value = "x²" }},
    };
    const t = try text(a, s);
    try std.testing.expect(std.mem.indexOf(u8, t, "2+2\n    = 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "Variables\n\nx = 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "f(x) = x²\n") != null);
    const h = try html(a, s);
    try std.testing.expect(std.mem.indexOf(u8, h, "<td>2+2</td><td class=\"r\">= 4</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "5 &lt; 7 &amp; x &gt; 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<td>f(x)</td><td>= x²</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "<script") == null);
    try std.testing.expectEqual(Format.html, formatOf("a/b.HTML"));
    try std.testing.expectEqual(Format.text, formatOf("notes.txt"));
    // Nothing to show: still a valid page.
    const empty = try html(a, .{ .when = "now", .entries = &.{}, .variables = &.{}, .functions = &.{} });
    try std.testing.expect(std.mem.endsWith(u8, empty, "</body>\n</html>\n"));
}
