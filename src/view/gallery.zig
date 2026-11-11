//! The strip of thumbnails along the bottom (Ctrl+F9), as in Eye of GNOME
//! and Gwenview: every picture of the folder, the one showing marked;
//! clicking one shows it. Thumbnails are asked for only as they scroll into
//! view.

const std = @import("std");
const gdk = @import("gdk4");
const gdkpixbuf = @import("gdkpixbuf2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");

pub const Hooks = struct {
    owner: *anyopaque,
    /// A thumbnail clicked.
    activate: *const fn (*anyopaque, index: usize) void,
    /// A thumbnail is needed for `uri`; it comes back through `setThumb`.
    request: *const fn (*anyopaque, uri: [:0]const u8) void,
};

const item_width = 104;

const Item = struct {
    button: *gtk.Button,
    picture: *gtk.Picture,
    uri: [:0]u8,
    asked: bool = false,
};

const Click = struct { gallery: *Gallery, index: usize };

pub const Gallery = struct {
    gpa: std.mem.Allocator,
    hooks: Hooks,
    scroller: *gtk.ScrolledWindow,
    box: *gtk.Box,
    items: std.ArrayList(Item) = .empty,
    clicks: std.ArrayList(*Click) = .empty,
    current: ?usize = null,

    pub fn create(gpa: std.mem.Allocator, hooks: Hooks) !*Gallery {
        const self = try gpa.create(Gallery);
        self.* = .{ .gpa = gpa, .hooks = hooks, .scroller = gtk.ScrolledWindow.new(), .box = gtk.Box.new(.horizontal, 4) };
        self.scroller.setPolicy(.automatic, .never);
        self.scroller.setChild(self.box.as(gtk.Widget));
        self.scroller.as(gtk.Widget).setSizeRequest(-1, 100);
        self.scroller.as(gtk.Widget).addCssClass("dkde-view-gallery");
        self.box.as(gtk.Widget).setMarginStart(4);
        self.box.as(gtk.Widget).setMarginEnd(4);
        _ = gtk.Adjustment.signals.value_changed.connect(self.scroller.getHadjustment(), *Gallery, &onScrolled, self, .{});
        _ = gtk.Adjustment.signals.changed.connect(self.scroller.getHadjustment(), *Gallery, &onScrolled, self, .{});
        return self;
    }

    pub fn destroy(self: *Gallery) void {
        self.clear();
        self.items.deinit(self.gpa);
        self.clicks.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn widget(self: *Gallery) *gtk.Widget {
        return self.scroller.as(gtk.Widget);
    }

    fn clear(self: *Gallery) void {
        for (self.items.items) |it| {
            self.box.remove(it.button.as(gtk.Widget));
            self.gpa.free(it.uri);
        }
        self.items.clearRetainingCapacity();
        for (self.clicks.items) |c| self.gpa.destroy(c);
        self.clicks.clearRetainingCapacity();
        self.current = null;
    }

    /// Shows one thumbnail place per picture, in this order.
    pub fn fill(self: *Gallery, uris: []const [:0]u8, names: []const []const u8) void {
        self.clear();
        for (uris, names, 0..) |uri, name, i| {
            const picture = gtk.Picture.new();
            picture.setContentFit(.contain);
            picture.setCanShrink(1);
            picture.as(gtk.Widget).setSizeRequest(item_width - 8, 80);
            const button = gtk.Button.new();
            button.setChild(picture.as(gtk.Widget));
            button.setHasFrame(0);
            button.as(gtk.Widget).addCssClass("dkde-view-thumb");
            var buf: [512]u8 = undefined;
            button.as(gtk.Widget).setTooltipText(std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch null);
            const click = self.gpa.create(Click) catch continue;
            click.* = .{ .gallery = self, .index = i };
            self.clicks.append(self.gpa, click) catch {
                self.gpa.destroy(click);
                continue;
            };
            _ = gtk.Button.signals.clicked.connect(button, *Click, &onClicked, click, .{});
            const owned = self.gpa.dupeSentinel(u8, uri, 0) catch continue;
            self.items.append(self.gpa, .{ .button = button, .picture = picture, .uri = owned }) catch {
                self.gpa.free(owned);
                continue;
            };
            self.box.append(button.as(gtk.Widget));
        }
        self.askVisible();
    }

    /// Marks picture `index` and scrolls it into view.
    pub fn select(self: *Gallery, index: usize) void {
        if (self.current) |c| if (c < self.items.items.len) self.items.items[c].button.as(gtk.Widget).removeCssClass("selected");
        if (index >= self.items.items.len) return;
        self.current = index;
        self.items.items[index].button.as(gtk.Widget).addCssClass("selected");
        const adj = self.scroller.getHadjustment();
        const x = @as(f64, @floatFromInt(index)) * (item_width + 4);
        const page = adj.getPageSize();
        if (x < adj.getValue() or x + item_width > adj.getValue() + page) adj.setValue(x - (page - item_width) / 2);
        self.askVisible();
    }

    pub fn setThumb(self: *Gallery, uri: []const u8, pixbuf: *gdkpixbuf.Pixbuf) void {
        for (self.items.items) |it| {
            if (!std.mem.eql(u8, it.uri, uri)) continue;
            const texture = gdk.Texture.newForPixbuf(pixbuf);
            defer texture.as(gobject.Object).unref();
            it.picture.setPaintable(texture.as(gdk.Paintable));
        }
    }

    /// Asks for the thumbnails in view (and a screenful either side).
    fn askVisible(self: *Gallery) void {
        if (self.scroller.as(gtk.Widget).getVisible() == 0) return;
        const adj = self.scroller.getHadjustment();
        const w: f64 = item_width + 4;
        const page = @max(adj.getPageSize(), 800);
        const first: usize = @intFromFloat(@max(0, (adj.getValue() - page) / w));
        const last: usize = @intFromFloat(@max(0, (adj.getValue() + 2 * page) / w));
        var i = first;
        while (i <= last and i < self.items.items.len) : (i += 1) {
            const it = &self.items.items[i];
            if (it.asked) continue;
            it.asked = true;
            self.hooks.request(self.hooks.owner, it.uri);
        }
    }

    /// The strip was shown: ask for what is now in view.
    pub fn shown(self: *Gallery) void {
        self.askVisible();
    }

    fn onScrolled(_: *gtk.Adjustment, self: *Gallery) callconv(.c) void {
        self.askVisible();
    }

    fn onClicked(_: *gtk.Button, click: *Click) callconv(.c) void {
        click.gallery.hooks.activate(click.gallery.hooks.owner, click.index);
    }
};
