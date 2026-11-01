//! The preview in each terminal profile's Appearance section (SPEC.md 5.5): a
//! few lines of sample text in the profile's font, colour scheme, cursor style,
//! opacity and padding. It follows the controls as they change, before Apply.

const std = @import("std");
const glib = @import("glib2");
const gtk = @import("gtk4");
const common = @import("common");
const termcore = @import("termcore");

const gpa = std.heap.c_allocator;

pub const TermPreview = struct {
    config: *const common.Config,
    group: [:0]const u8,
    box: *gtk.Box,
    label: *gtk.Label,
    provider: *gtk.CssProvider,

    pub fn create(config: *const common.Config, group: [:0]const u8) *TermPreview {
        const self = gpa.create(TermPreview) catch @panic("OOM");
        const box = gtk.Box.new(.vertical, 0);
        const label = gtk.Label.new("");
        label.setXalign(0);
        label.setSelectable(0);
        box.append(label.as(gtk.Widget));
        const provider = gtk.CssProvider.new();
        box.as(gtk.Widget).getStyleContext().addProvider(provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 20);
        box.as(gtk.Widget).setHalign(.start);
        self.* = .{ .config = config, .group = group, .box = box, .label = label, .provider = provider };
        self.refresh();
        return self;
    }

    pub fn destroy(self: *TermPreview) void {
        gpa.destroy(self);
    }

    pub fn widget(self: *TermPreview) *gtk.Widget {
        return self.box.as(gtk.Widget);
    }

    fn hex(c: u24) [7]u8 {
        var out: [7]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "#{x:0>6}", .{c}) catch unreachable;
        return out;
    }

    /// Reads the profile's current values and redraws.
    pub fn refresh(self: *TermPreview) void {
        const font = self.config.getString(gpa, self.group, "font", "Monospace 11") catch return;
        defer gpa.free(font);
        const scheme_name = self.config.getString(gpa, self.group, "color-scheme", "campbell") catch return;
        defer gpa.free(scheme_name);
        const cursor = self.config.getString(gpa, self.group, "cursor-style", "block") catch return;
        defer gpa.free(cursor);
        const opacity = std.math.clamp(self.config.getInt(self.group, "opacity", 100), 20, 100);
        const padding = std.math.clamp(self.config.getInt(self.group, "padding", 4), 0, 40);
        const s = termcore.schemes.scheme(scheme_name);

        var css_buf: [256]u8 = undefined;
        const css = std.fmt.bufPrintSentinel(&css_buf, "box {{ background-color: rgba({d},{d},{d},{d:.2}); padding: {d}px; border-radius: 4px; border: 1px solid rgba(128,128,128,0.4); }}", .{
            s.background >> 16 & 255, s.background >> 8 & 255, s.background & 255, @as(f32, @floatFromInt(opacity)) / 100.0, padding,
        }, 0) catch return;
        self.provider.loadFromString(css);

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;
        const fg = hex(s.foreground);
        const bg = hex(s.background);
        const font_z = gpa.dupeSentinel(u8, font, 0) catch return;
        defer gpa.free(font_z);
        const esc_font = glib.markupEscapeText(font_z.ptr, @intCast(font.len));
        defer glib.free(esc_font);
        const font_attr = std.mem.span(esc_font);
        w.print("<span font_desc=\"{s}\" foreground=\"{s}\">", .{ font_attr, &fg }) catch return;
        const green = hex(s.ansi[10]);
        const blue = hex(s.ansi[12]);
        w.print("<span foreground=\"{s}\">user@dkde</span>:<span foreground=\"{s}\">~/projects</span>$ ls --color\n", .{ &green, &blue }) catch return;
        w.writeAll("The quick brown fox jumps over the lazy dog\n0123456789 \u{E0}\u{E9}\u{EE}\u{F5}\u{FC} \u{391}\u{392}\u{393} \u{414}\u{416}\u{417}\n") catch return;
        // The sixteen colours, then the prompt with the cursor.
        for (s.ansi) |c| {
            const h = hex(c);
            w.print("<span background=\"{s}\">  </span>", .{&h}) catch return;
        }
        w.writeAll("\n$ ") catch return;
        const cur = hex(s.foreground);
        if (std.mem.eql(u8, cursor, "bar")) {
            w.print("<span foreground=\"{s}\">\u{258F}</span>", .{&cur}) catch return;
        } else if (std.mem.eql(u8, cursor, "underline")) {
            w.print("<span underline=\"single\" underline_color=\"{s}\"> </span>", .{&cur}) catch return;
        } else {
            w.print("<span foreground=\"{s}\" background=\"{s}\"> </span>", .{ &bg, &cur }) catch return;
        }
        w.writeAll("</span>") catch return;
        const text = aw.toOwnedSliceSentinel(0) catch return;
        defer gpa.free(text);
        self.label.setMarkup(text);
    }
};
