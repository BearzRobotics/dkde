//! dkde-view: the image viewer (SPEC.md 5.6), on the lines of Eye of GNOME,
//! Loupe, gThumb and Gwenview.
//!
//! - Pictures are read on a worker thread (loader.zig); the neighbours are
//!   read ahead so the next one shows at once.
//! - Zoom to fit, to the width or any level, around the pointer, with the
//!   wheel, pinch or keys; a zoomed picture moves with the mouse (canvas.zig).
//! - Animated GIF and WebP play; SVG stays sharp at any zoom.
//! - Rotate, flip, crop and resize, with undo; a JPEG's rotation is saved
//!   without recompressing it, and re-saved photos keep their camera data.
//! - The folder's pictures in name, date or size order, watched for
//!   changes, with a thumbnail strip (gallery.zig, sharing the desktop's
//!   thumbnail cache) and a slideshow.
//! - Properties: the file and the camera's EXIF data (exif.zig), with the
//!   place it was taken on a map.
//! - Copy, rename, move to the Trash (with undo), print, open with another
//!   program, show in the folder, set as the wallpaper.

const std = @import("std");
const cli = @import("cli");
const cairo = @import("cairo1");
const gdk = @import("gdk4");
const gdkpixbuf = @import("gdkpixbuf2");
const gio = @import("gio2");
const giounix = @import("giounix2");
const glib = @import("glib2");
const gobject = @import("gobject2");
const gtk = @import("gtk4");
const common = @import("common");
const imgcodec = @import("imgcodec");

const pure = @import("pure.zig");
const exif = @import("exif.zig");
const loader_mod = @import("loader.zig");
const canvas_mod = @import("canvas.zig");
const gallery_mod = @import("gallery.zig");

const Picture = loader_mod.Picture;
const Canvas = canvas_mod.Canvas;
const Gallery = gallery_mod.Gallery;
const c_alloc = std.heap.c_allocator;
const t = common.tr;

/// One picture of the folder (or of the files named on the command line).
const Item = struct {
    uri: [:0]u8,
    name: []u8,
    content_type: []u8,
    mtime: i64,
    size: u64,

    fn deinit(self: Item, gpa: std.mem.Allocator) void {
        gpa.free(self.uri);
        gpa.free(self.name);
        gpa.free(self.content_type);
    }
};

/// An edit, for undo and redo.
const Op = union(enum) {
    cw,
    ccw,
    flip_h,
    flip_v,
    crop: pure.Rect,
    resize: [2]u32,

    fn lossy(op: Op) bool {
        return switch (op) {
            .crop, .resize => true,
            else => false,
        };
    }
};

const Edit = struct {
    op: Op,
    /// The pixels before a crop or resize (a turn is undone by turning back).
    before: ?imgcodec.Decoded = null,
    turn_before: pure.Turn,
    lossy_before: bool,

    fn deinit(self: Edit) void {
        if (self.before) |b| b.deinit(c_alloc);
    }
};

/// What to do once unsaved edits are saved or thrown away.
const Pending = union(enum) { none, show: usize, close, open: [:0]u8 };

const max_cached = 4;

const Viewer = struct {
    gpa: std.mem.Allocator,
    app: *gtk.Application,
    window: *gtk.ApplicationWindow,
    config: common.Config,

    menu_bar: *gtk.Widget,
    status: *gtk.Label,
    banner: *gtk.Revealer,
    banner_label: *gtk.Label,
    banner_button: *gtk.Button,
    message: *gtk.Label,
    side: *gtk.ScrolledWindow,
    side_grid: *gtk.Grid,
    canvas: *Canvas,
    gallery: *Gallery,

    loader: loader_mod.Loader = undefined,
    outstanding: usize = 0,
    poll_timer: c_uint = 0,

    items: std.ArrayList(Item) = .empty,
    index: usize = 0,
    /// The files named on the command line (or dropped), instead of a folder.
    explicit: bool = false,
    folder: ?*gio.File = null,
    monitor: ?*gio.FileMonitor = null,
    rescan_timer: c_uint = 0,
    reload_timer: c_uint = 0,
    saved_at: i64 = 0,

    generation: u64 = 0,
    picture: ?*Picture = null,
    /// Pictures read ahead (the neighbours), owned.
    cache: std.ArrayList(*Picture) = .empty,
    /// The picture being read could not be shown.
    failed: bool = false,

    anim_iter: ?*gdkpixbuf.PixbufAnimationIter = null,
    anim_timer: c_uint = 0,
    vector_timer: c_uint = 0,

    undo: std.ArrayList(Edit) = .empty,
    redo: std.ArrayList(Edit) = .empty,
    turn: pure.Turn = .{},
    lossy: bool = false,
    pending: Pending = .none,

    sort: pure.Sort = .name,
    reverse: bool = false,
    loop: bool = true,
    fullscreen: bool = false,
    slideshow_timer: c_uint = 0,
    slideshow_paused: bool = false,
    cursor_timer: c_uint = 0,
    banner_timer: c_uint = 0,
    /// The Trash entry of the last picture moved there, for undo.
    trashed: ?struct { name: []u8, original: [:0]u8 } = null,
    recent_handler: c_ulong = 0,
    finished: bool = false,

    pub fn create(gpa: std.mem.Allocator, app: *gtk.Application) !*Viewer {
        const self = try gpa.create(Viewer);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .app = app,
            .window = gtk.ApplicationWindow.new(app),
            .config = try common.Config.load(gpa, "view.toml"),
            .menu_bar = undefined,
            .status = gtk.Label.new(""),
            .banner = gtk.Revealer.new(),
            .banner_label = gtk.Label.new(""),
            .banner_button = gtk.Button.newWithLabel(t("Undo")),
            .message = gtk.Label.new(""),
            .side = gtk.ScrolledWindow.new(),
            .side_grid = gtk.Grid.new(),
            .canvas = undefined,
            .gallery = undefined,
        };
        self.canvas = try Canvas.create(gpa, .{ .owner = self, .zoomed = onZoomed, .navigate = onNavigate, .context = onContext, .moved = onMoved, .selected = onSelected });
        self.gallery = try Gallery.create(gpa, .{ .owner = self, .activate = onGalleryActivate, .request = onGalleryRequest });
        self.loader.start();
        self.readSettings();

        const window = self.window;
        const win = window.as(gtk.Window);
        win.setTitle(t("Image Viewer"));
        win.setDefaultSize(self.config.getInt("view", "width", 960), self.config.getInt("view", "height", 680));
        if (self.config.getBool("view", "maximized", false)) win.maximize();
        window.as(gtk.Widget).addCssClass("dkde");
        _ = common.header.create(win, "image-x-generic", true);

        self.menu_bar = self.buildMenus().as(gtk.Widget);

        // The picture, with a message over it when one cannot be shown.
        const overlay = gtk.Overlay.new();
        overlay.setChild(self.canvas.widget());
        self.message.as(gtk.Widget).addCssClass("dim-label");
        self.message.setWrap(1);
        self.message.setJustify(.center);
        self.message.as(gtk.Widget).setHalign(.center);
        self.message.as(gtk.Widget).setValign(.center);
        self.message.as(gtk.Widget).setVisible(0);
        overlay.addOverlay(self.message.as(gtk.Widget));
        overlay.addOverlay(self.buildBanner());

        // Properties on the right.
        self.side_grid.setColumnSpacing(10);
        self.side_grid.setRowSpacing(4);
        self.side_grid.as(gtk.Widget).setMarginStart(10);
        self.side_grid.as(gtk.Widget).setMarginEnd(10);
        self.side_grid.as(gtk.Widget).setMarginTop(8);
        self.side_grid.as(gtk.Widget).setMarginBottom(8);
        self.side.setChild(self.side_grid.as(gtk.Widget));
        self.side.setPolicy(.never, .automatic);
        self.side.as(gtk.Widget).setSizeRequest(260, -1);
        self.side.as(gtk.Widget).addCssClass("dkde-view-properties");

        const paned = gtk.Paned.new(.horizontal);
        paned.setStartChild(overlay.as(gtk.Widget));
        paned.setEndChild(self.side.as(gtk.Widget));
        paned.setResizeEndChild(0);
        paned.setShrinkEndChild(0);
        paned.as(gtk.Widget).setVexpand(1);

        self.status.setXalign(0);
        self.status.setEllipsize(.middle);
        self.status.as(gtk.Widget).setMarginStart(8);
        self.status.as(gtk.Widget).setMarginTop(2);
        self.status.as(gtk.Widget).setMarginBottom(2);
        self.status.as(gtk.Widget).addCssClass("dim-label");

        const root = gtk.Box.new(.vertical, 0);
        root.append(self.menu_bar);
        root.append(paned.as(gtk.Widget));
        root.append(self.gallery.widget());
        root.append(self.status.as(gtk.Widget));
        win.setChild(root.as(gtk.Widget));

        self.side.as(gtk.Widget).setVisible(@intFromBool(self.config.getBool("view", "properties", false)));
        self.gallery.widget().setVisible(@intFromBool(self.config.getBool("view", "gallery", false)));
        self.status.as(gtk.Widget).setVisible(@intFromBool(self.config.getBool("view", "statusbar", true)));

        // Pictures dropped on the window are shown.
        const drop = gtk.DropTarget.new(gdk.FileList.getGObjectType(), .{ .copy = true });
        _ = gtk.DropTarget.signals.drop.connect(drop, *Viewer, &onDrop, self, .{});
        root.as(gtk.Widget).addController(drop.as(gtk.EventController));

        _ = gtk.Window.signals.close_request.connect(win, *Viewer, &onCloseRequest, self, .{});
        _ = gtk.Widget.signals.destroy.connect(window, *Viewer, &onDestroy, self, .{});
        self.recent_handler = gtk.RecentManager.signals.changed.connect(gtk.RecentManager.getDefault(), *Viewer, &onRecentChanged, self, .{});
        self.loadRecent();
        self.updateStatus();
        self.updateMenus();
        return self;
    }

    pub fn present(self: *Viewer) void {
        self.window.as(gtk.Window).present();
        var files: std.ArrayList(*gio.File) = .empty;
        defer {
            for (files.items) |f| f.as(gobject.Object).unref();
            files.deinit(self.gpa);
        }
        for (common.runapp.args) |arg| {
            const a = std.mem.span(arg);
            if (a.len > 0 and a[0] == '-') continue;
            files.append(self.gpa, gio.File.newForCommandlineArg(arg)) catch {};
        }
        self.openFiles(files.items);
    }

    fn readSettings(self: *Viewer) void {
        var buf: [32]u8 = undefined;
        self.sort = pure.Sort.parse(self.configString(&buf, "sort", "name"));
        self.reverse = self.config.getBool("view", "reverse", false);
        self.loop = self.config.getBool("view", "loop", true);
        self.canvas.upscale = self.config.getBool("view", "upscale", false);
        self.canvas.backdrop = canvas_mod.Backdrop.parse(self.configString(&buf, "backdrop", "checker"));
        self.canvas.smooth_up_to = std.math.clamp(self.config.getFloat("view", "sharp-from", 2), 1, 32);
        if (std.mem.eql(u8, self.configString(&buf, "fit", "best"), "width")) self.canvas.fit = .width;
    }

    fn configString(self: *Viewer, buf: []u8, key: [:0]const u8, default: []const u8) []const u8 {
        const v = self.config.getString(self.gpa, "view", key, default) catch return default;
        defer self.gpa.free(v);
        const n = @min(v.len, buf.len);
        @memcpy(buf[0..n], v[0..n]);
        return buf[0..n];
    }

    fn buildMenus(self: *Viewer) *gtk.PopoverMenuBar {
        const mb = common.menubar;
        const menus = [_]mb.Menu{
            .{ .label = "_File", .entries = &.{
                mb.item("_Open…", "open", "<Control>o"),
                mb.dynamic("Open _Recent", "recent"),
                mb.dynamic("Open _With", "openwith"),
                .separator,
                mb.item("_Save", "save", "<Control>s"),
                mb.item("Save _As…", "save-as", "<Control><Shift>s"),
                mb.item("_Print…", "print", "<Control>p"),
                .separator,
                mb.item("Set as _Wallpaper", "wallpaper", null),
                mb.item("Show in _Folder", "show-folder", null),
                .separator,
                mb.item("_Close", "close", "<Control>w"),
            } },
            .{ .label = "_Edit", .entries = &.{
                mb.item("_Undo", "undo", "<Control>z"),
                mb.item("_Redo", "redo", "<Control><Shift>z"),
                .separator,
                mb.item("_Copy Image", "copy", "<Control>c"),
                mb.item("Copy _Path", "copy-path", "<Control><Shift>c"),
                .separator,
                mb.item("Re_name…", "rename", "F2"),
                mb.item("Move to _Trash", "trash", "Delete"),
                mb.item("_Delete Permanently…", "delete", "<Shift>Delete"),
                .separator,
                mb.item("Rotate _Right", "rotate-right", "<Control>r"),
                mb.item("Rotate _Left", "rotate-left", "<Control><Shift>r"),
                mb.item("Flip _Horizontally", "flip-h", null),
                mb.item("Flip _Vertically", "flip-v", null),
                mb.item("Cr_op…", "crop", "<Shift>c"),
                mb.item("Re_size…", "resize", null),
            } },
            .{ .label = "_View", .entries = &.{
                mb.item("Zoom _In", "zoom-in", "plus"),
                mb.item("Zoom _Out", "zoom-out", "minus"),
                mb.item("_Best Fit", "fit", "0"),
                mb.item("Fit _Width", "fit-width", "w"),
                mb.item("_Actual Size", "actual", "1"),
                mb.check("_Enlarge Small Pictures", "upscale", self.canvas.upscale),
                .separator,
                mb.checkKey("_Gallery", "gallery", self.config.getBool("view", "gallery", false), "<Control>F9"),
                mb.checkKey("_Properties", "properties", self.config.getBool("view", "properties", false), "F9"),
                mb.check("_Status Bar", "statusbar", self.config.getBool("view", "statusbar", true)),
                .separator,
                mb.check("Checkerboard Behind Transparency", "backdrop-checker", self.canvas.backdrop == .checker),
                mb.check("Black Behind Transparency", "backdrop-black", self.canvas.backdrop == .black),
                mb.check("White Behind Transparency", "backdrop-white", self.canvas.backdrop == .white),
                .separator,
                mb.item("F_ull Screen", "fullscreen", "F11"),
                mb.item("_Slideshow", "slideshow", "F5"),
            } },
            .{ .label = "_Go", .entries = &.{
                mb.item("_Previous", "prev", "Left"),
                mb.item("_Next", "next", "Right"),
                mb.item("_First", "first", "Home"),
                mb.item("_Last", "last", "End"),
                .separator,
                mb.check("Sort by _Name", "sort-name", self.sort == .name),
                mb.check("Sort by _Date", "sort-date", self.sort == .date),
                mb.check("Sort by Si_ze", "sort-size", self.sort == .size),
                mb.check("_Reverse Order", "sort-reverse", self.reverse),
                mb.check("_Loop", "loop", self.loop),
            } },
        };
        const bar = mb.build(self.app, self.window, &menus, Viewer, onMenuAction, self);

        // Other keys for the same things (only the first shows in the menu).
        const extra = .{
            .{ "win.zoom-in", &[_:null]?[*:0]const u8{ "plus", "equal", "KP_Add", "<Control>plus", "<Control>equal" } },
            .{ "win.zoom-out", &[_:null]?[*:0]const u8{ "minus", "KP_Subtract", "<Control>minus" } },
            .{ "win.fit", &[_:null]?[*:0]const u8{ "0", "<Control>0", "f" } },
            .{ "win.prev", &[_:null]?[*:0]const u8{ "Left", "Page_Up", "BackSpace", "<Alt>Left" } },
            .{ "win.next", &[_:null]?[*:0]const u8{ "Right", "Page_Down", "space", "<Alt>Right" } },
            .{ "win.properties", &[_:null]?[*:0]const u8{ "F9", "<Alt>Return" } },
            .{ "win.redo", &[_:null]?[*:0]const u8{ "<Control><Shift>z", "<Control>y" } },
            .{ "win.rotate-right", &[_:null]?[*:0]const u8{ "<Control>r", "r" } },
            .{ "win.rotate-left", &[_:null]?[*:0]const u8{ "<Control><Shift>r", "<Shift>r" } },
            .{ "win.close", &[_:null]?[*:0]const u8{ "<Control>w", "<Control>q" } },
        };
        inline for (extra) |e| self.app.setAccelsForAction(e[0], e[1]);

        // Keys that depend on the moment (crop, slideshow, a zoomed picture).
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Viewer, &onKey, self, .{});
        self.window.as(gtk.Widget).addController(keys.as(gtk.EventController));

        // Items that carry a value: recent pictures and other programs.
        const string_type = glib.VariantType.new("s");
        defer string_type.free();
        inline for (.{ .{ "open-recent", &onOpenRecent }, .{ "open-with", &onOpenWith } }) |a| {
            const action = gio.SimpleAction.new(a[0], string_type);
            _ = gio.SimpleAction.signals.activate.connect(action, *Viewer, a[1], self, .{});
            self.window.as(gio.ActionMap).addAction(action.as(gio.Action));
            action.as(gobject.Object).unref();
        }
        return bar;
    }

    fn buildBanner(self: *Viewer) *gtk.Widget {
        const box = gtk.Box.new(.horizontal, 10);
        box.as(gtk.Widget).addCssClass("dkde-view-banner");
        box.as(gtk.Widget).addCssClass("osd");
        box.as(gtk.Widget).setMarginTop(10);
        self.banner_label.setEllipsize(.middle);
        self.banner_label.as(gtk.Widget).setMarginStart(10);
        box.append(self.banner_label.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.banner_button, *Viewer, &onBannerUndo, self, .{});
        box.append(self.banner_button.as(gtk.Widget));
        self.banner.setChild(box.as(gtk.Widget));
        self.banner.setTransitionType(.slide_down);
        self.banner.as(gtk.Widget).setHalign(.center);
        self.banner.as(gtk.Widget).setValign(.start);
        return self.banner.as(gtk.Widget);
    }

    // ---- closing ---------------------------------------------------------------------

    fn onCloseRequest(_: *gtk.Window, self: *Viewer) callconv(.c) c_int {
        if (self.modified()) {
            self.askToSave(.close);
            return 1;
        }
        self.finish();
        return 0;
    }

    fn finish(self: *Viewer) void {
        if (self.finished) return;
        self.finished = true;
        const win = self.window.as(gtk.Window);
        const w = self.window.as(gtk.Widget);
        if (win.isMaximized() == 0 and !self.fullscreen and w.getWidth() > 0) {
            self.config.setInt("view", "width", w.getWidth()) catch {};
            self.config.setInt("view", "height", w.getHeight()) catch {};
        }
        self.config.setBool("view", "maximized", win.isMaximized() != 0) catch {};
    }

    fn onDestroy(_: *gtk.ApplicationWindow, self: *Viewer) callconv(.c) void {
        if (self.recent_handler != 0) gobject.signalHandlerDisconnect(gtk.RecentManager.getDefault().as(gobject.Object), self.recent_handler);
        inline for (.{ "poll_timer", "rescan_timer", "reload_timer", "anim_timer", "vector_timer", "slideshow_timer", "cursor_timer", "banner_timer" }) |name| {
            if (@field(self, name) != 0) _ = glib.Source.remove(@field(self, name));
        }
        self.loader.stop();
        self.stopAnimation();
        if (self.monitor) |m| {
            _ = m.cancel();
            m.as(gobject.Object).unref();
        }
        if (self.folder) |f| f.as(gobject.Object).unref();
        if (self.picture) |p| p.destroy();
        for (self.cache.items) |p| p.destroy();
        self.cache.deinit(self.gpa);
        self.clearItems();
        self.items.deinit(self.gpa);
        self.clearEdits();
        self.undo.deinit(self.gpa);
        self.redo.deinit(self.gpa);
        self.setPending(.none);
        self.forgetTrashed();
        self.canvas.destroy(self.gpa);
        self.gallery.destroy();
        self.config.deinit();
        self.gpa.destroy(self);
    }

    fn clearItems(self: *Viewer) void {
        for (self.items.items) |it| it.deinit(self.gpa);
        self.items.clearRetainingCapacity();
    }

    // ---- actions ---------------------------------------------------------------------

    fn onMenuAction(self: *Viewer, action: []const u8) void {
        self.perform(action);
    }

    fn perform(self: *Viewer, action: []const u8) void {
        const eql = std.mem.eql;
        const a = action;
        if (eql(u8, a, "open")) return self.openDialog();
        if (eql(u8, a, "save")) return self.save();
        if (eql(u8, a, "save-as")) return self.saveAs();
        if (eql(u8, a, "print")) return self.print();
        if (eql(u8, a, "wallpaper")) return self.setWallpaper();
        if (eql(u8, a, "show-folder")) return self.showInFolder();
        if (eql(u8, a, "close")) return self.window.as(gtk.Window).close();
        if (eql(u8, a, "undo")) return self.undoEdit();
        if (eql(u8, a, "redo")) return self.redoEdit();
        if (eql(u8, a, "copy")) return self.copyImage();
        if (eql(u8, a, "copy-path")) return self.copyPath();
        if (eql(u8, a, "rename")) return self.rename();
        if (eql(u8, a, "trash")) return self.moveToTrash();
        if (eql(u8, a, "delete")) return self.deletePermanently();
        if (eql(u8, a, "rotate-right")) return self.edit(.cw);
        if (eql(u8, a, "rotate-left")) return self.edit(.ccw);
        if (eql(u8, a, "flip-h")) return self.edit(.flip_h);
        if (eql(u8, a, "flip-v")) return self.edit(.flip_v);
        if (eql(u8, a, "crop")) return self.startCrop();
        if (eql(u8, a, "resize")) return self.resizeDialog();
        if (eql(u8, a, "zoom-in")) return self.canvas.step(true);
        if (eql(u8, a, "zoom-out")) return self.canvas.step(false);
        if (eql(u8, a, "fit")) return self.canvas.setFit(.best);
        if (eql(u8, a, "fit-width")) return self.canvas.setFit(.width);
        if (eql(u8, a, "actual")) return self.canvas.zoomCentred(1);
        if (eql(u8, a, "upscale")) {
            self.canvas.upscale = !self.canvas.upscale;
            self.config.setBool("view", "upscale", self.canvas.upscale) catch {};
            return self.canvas.setFit(if (self.canvas.fit == .fixed) .best else self.canvas.fit);
        }
        if (eql(u8, a, "gallery")) return self.toggleBar(self.gallery.widget(), "gallery");
        if (eql(u8, a, "properties")) return self.toggleBar(self.side.as(gtk.Widget), "properties");
        if (eql(u8, a, "statusbar")) return self.toggleBar(self.status.as(gtk.Widget), "statusbar");
        if (std.mem.startsWith(u8, a, "backdrop-")) return self.setBackdrop(canvas_mod.Backdrop.parse(a["backdrop-".len..]));
        if (eql(u8, a, "fullscreen")) return self.setFullscreen(!self.fullscreen);
        if (eql(u8, a, "slideshow")) return if (self.slideshow_timer != 0) self.stopSlideshow() else self.startSlideshow();
        if (eql(u8, a, "prev")) return self.stepKey(false);
        if (eql(u8, a, "next")) return self.stepKey(true);
        if (eql(u8, a, "first")) return self.goTo(0);
        if (eql(u8, a, "last")) return if (self.items.items.len > 0) self.goTo(self.items.items.len - 1);
        if (std.mem.startsWith(u8, a, "sort-")) return self.setSort(a["sort-".len..]);
        if (eql(u8, a, "loop")) {
            self.loop = !self.loop;
            self.config.setBool("view", "loop", self.loop) catch {};
        }
    }

    /// Keys whose meaning depends on what is happening.
    fn onKey(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, state: gdk.ModifierType, self: *Viewer) callconv(.c) c_int {
        const plain = !state.control_mask and !state.alt_mask and !state.shift_mask;
        switch (keyval) {
            gdk.KEY_Escape => {
                if (self.canvas.cropping) {
                    self.canvas.endCrop();
                    self.updateStatus();
                } else if (self.slideshow_timer != 0) {
                    self.stopSlideshow();
                } else if (self.fullscreen) {
                    self.setFullscreen(false);
                } else self.window.as(gtk.Window).close();
                return 1;
            },
            gdk.KEY_Return, gdk.KEY_KP_Enter => if (self.canvas.cropping and plain) {
                self.applyCrop();
                return 1;
            },
            gdk.KEY_space => if (self.slideshow_timer != 0 and plain) {
                self.slideshow_paused = !self.slideshow_paused;
                self.updateStatus();
                return 1;
            },
            gdk.KEY_Left, gdk.KEY_Right, gdk.KEY_Up, gdk.KEY_Down => if (plain and self.canvas.pannable()) {
                // A zoomed picture moves; Alt+arrows or Page keys change picture.
                const d: f64 = 60;
                _ = switch (keyval) {
                    gdk.KEY_Left => self.canvas.pan(d, 0),
                    gdk.KEY_Right => self.canvas.pan(-d, 0),
                    gdk.KEY_Up => self.canvas.pan(0, d),
                    else => self.canvas.pan(0, -d),
                };
                return 1;
            },
            else => {},
        }
        return 0;
    }

    fn stepKey(self: *Viewer, forward: bool) void {
        if (self.items.items.len < 2) return;
        const next = pure.neighbour(self.index, self.items.items.len, forward, self.loop or self.slideshow_timer != 0);
        if (next != self.index) self.goTo(next);
    }

    fn toggleBar(self: *Viewer, widget: *gtk.Widget, key: [:0]const u8) void {
        const on = widget.getVisible() == 0;
        widget.setVisible(@intFromBool(on));
        self.config.setBool("view", key, on) catch {};
        if (widget == self.gallery.widget() and on) self.gallery.shown();
        if (widget == self.side.as(gtk.Widget) and on) self.fillProperties();
    }

    fn setBackdrop(self: *Viewer, b: canvas_mod.Backdrop) void {
        self.canvas.backdrop = b;
        inline for (.{ "checker", "black", "white" }) |name| {
            common.menubar.setChecked(self.window, "backdrop-" ++ name, std.mem.eql(u8, @tagName(b), name));
        }
        self.config.setString("view", "backdrop", @tagName(b)) catch {};
        self.canvas.redraw();
    }

    fn setSort(self: *Viewer, what: []const u8) void {
        if (std.mem.eql(u8, what, "reverse")) {
            self.reverse = !self.reverse;
            self.config.setBool("view", "reverse", self.reverse) catch {};
        } else {
            self.sort = pure.Sort.parse(what);
            self.config.setString("view", "sort", @tagName(self.sort)) catch {};
        }
        inline for (.{ "name", "date", "size" }) |name| {
            common.menubar.setChecked(self.window, "sort-" ++ name, std.mem.eql(u8, @tagName(self.sort), name));
        }
        common.menubar.setChecked(self.window, "sort-reverse", self.reverse);
        self.sortItems();
    }

    // ---- what to show ------------------------------------------------------------------

    fn openDialog(self: *Viewer) void {
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        const filter = gtk.FileFilter.new();
        defer filter.as(gobject.Object).unref();
        filter.setName(t("Pictures"));
        filter.addPixbufFormats();
        filter.addMimeType("image/*");
        dialog.setDefaultFilter(filter);
        if (self.folder) |f| dialog.setInitialFolder(f);
        dialog.openMultiple(self.window.as(gtk.Window), null, onOpenChosen, self);
    }

    fn onOpenChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const list = dialog.openMultipleFinish(result, null) orelse return;
        defer list.as(gobject.Object).unref();
        var files: std.ArrayList(*gio.File) = .empty;
        defer {
            for (files.items) |f| f.as(gobject.Object).unref();
            files.deinit(self.gpa);
        }
        var i: c_uint = 0;
        while (list.getItem(i)) |obj| : (i += 1) files.append(self.gpa, @ptrCast(@alignCast(obj))) catch {
            const o: *gobject.Object = @ptrCast(@alignCast(obj));
            o.unref();
        };
        self.openFiles(files.items);
    }

    fn onDrop(_: *gtk.DropTarget, value: *gobject.Value, _: f64, _: f64, self: *Viewer) callconv(.c) c_int {
        const boxed = value.getBoxed() orelse return 0;
        const list: *gdk.FileList = @ptrCast(@alignCast(boxed));
        var files: std.ArrayList(*gio.File) = .empty;
        defer files.deinit(self.gpa);
        var node: ?*glib.SList = list.getFiles();
        const head = node;
        while (node) |n| : (node = n.f_next) files.append(self.gpa, @ptrCast(@alignCast(n.f_data orelse continue))) catch {};
        defer if (head) |h| h.free();
        if (files.items.len == 0) return 0;
        self.openFiles(files.items);
        return 1;
    }

    /// Shows what was asked for: one picture (and the rest of its folder),
    /// a folder (its first picture), or several pictures (just those).
    fn openFiles(self: *Viewer, files: []const *gio.File) void {
        if (files.len == 0) return self.showEmpty();
        if (self.modified()) {
            const uri = files[0].getUri();
            defer glib.free(uri);
            const owned = self.gpa.dupeSentinel(u8, std.mem.span(uri), 0) catch return;
            return self.askToSave(.{ .open = owned });
        }
        self.clearEdits();
        if (files.len == 1) {
            const f = files[0];
            const kind = f.queryFileType(.{}, null);
            if (kind == .directory) {
                self.setFolder(f, null);
                return;
            }
            const parent = f.getParent() orelse return self.setExplicit(files);
            defer parent.as(gobject.Object).unref();
            const uri = f.getUri();
            defer glib.free(uri);
            self.setFolder(parent, std.mem.span(uri));
            return;
        }
        self.setExplicit(files);
    }

    fn openUri(self: *Viewer, uri: [:0]const u8) void {
        const f = gio.File.newForUri(uri);
        defer f.as(gobject.Object).unref();
        self.openFiles(&.{f});
    }

    fn setExplicit(self: *Viewer, files: []const *gio.File) void {
        self.stopWatching();
        self.explicit = true;
        self.clearItems();
        for (files) |f| {
            const info = f.queryInfo(item_attributes, .{}, null, null) orelse continue;
            defer info.as(gobject.Object).unref();
            self.addItem(f, info);
        }
        self.sortItems();
        self.goTo(0);
    }

    const item_attributes = "standard::name,standard::display-name,standard::fast-content-type,standard::size,standard::type,standard::is-hidden,time::modified";

    fn addItem(self: *Viewer, file: *gio.File, info: *gio.FileInfo) void {
        const uri = file.getUri();
        defer glib.free(uri);
        const ct = if (info.getAttributeString("standard::fast-content-type")) |c| std.mem.span(c) else "";
        const it: Item = .{
            .uri = self.gpa.dupeSentinel(u8, std.mem.span(uri), 0) catch return,
            .name = self.gpa.dupe(u8, std.mem.span(info.getDisplayName())) catch return,
            .content_type = self.gpa.dupe(u8, ct) catch return,
            .mtime = @intCast(info.getAttributeUint64("time::modified")),
            .size = @intCast(@max(0, info.getSize())),
        };
        self.items.append(self.gpa, it) catch it.deinit(self.gpa);
    }

    /// Shows the pictures of `folder`, starting with `uri` (or the first).
    fn setFolder(self: *Viewer, folder: *gio.File, uri: ?[]const u8) void {
        self.explicit = false;
        if (self.folder == null or self.folder.?.equal(folder) == 0) {
            self.stopWatching();
            self.folder = @ptrCast(folder.as(gobject.Object).ref());
            self.monitor = folder.monitorDirectory(.{ .watch_moves = true }, null, null);
            if (self.monitor) |m| _ = gio.FileMonitor.signals.changed.connect(m, *Viewer, &onFolderChanged, self, .{});
        }
        self.scan(uri);
    }

    fn stopWatching(self: *Viewer) void {
        if (self.monitor) |m| {
            _ = m.cancel();
            m.as(gobject.Object).unref();
        }
        self.monitor = null;
        if (self.folder) |f| f.as(gobject.Object).unref();
        self.folder = null;
    }

    /// Reads the folder's pictures again; `keep` is the picture to stay on.
    fn scan(self: *Viewer, keep: ?[]const u8) void {
        const folder = self.folder orelse return;
        const keep_owned: ?[]u8 = if (keep) |k| self.gpa.dupe(u8, k) catch null else null;
        defer if (keep_owned) |k| self.gpa.free(k);
        const old_index = self.index;
        self.clearItems();
        if (folder.enumerateChildren(item_attributes, .{}, null, null)) |children| {
            defer children.as(gobject.Object).unref();
            while (children.nextFile(null, null)) |info| {
                defer info.as(gobject.Object).unref();
                if (info.getIsHidden() != 0 or info.getFileType() != .regular) continue;
                const name = std.mem.span(info.getName());
                const ct = if (info.getAttributeString("standard::fast-content-type")) |c| std.mem.span(c) else "";
                if (!pure.isImageName(name) and !std.mem.startsWith(u8, ct, "image/")) continue;
                const child = folder.getChild(name);
                defer child.as(gobject.Object).unref();
                self.addItem(child, info);
            }
        }
        self.sortOnly();
        var index: ?usize = null;
        if (keep_owned) |k| for (self.items.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.uri, k)) index = i;
        };
        self.fillGallery();
        if (index) |i| {
            if (self.picture != null and std.mem.eql(u8, self.picture.?.uri, self.items.items[i].uri)) {
                self.index = i;
                self.gallery.select(i);
                self.updateStatus();
                return;
            }
            return self.goTo(i);
        }
        if (self.items.items.len == 0) return self.showEmpty();
        // The picture showing has gone: the one now in its place.
        self.goTo(@min(old_index, self.items.items.len - 1));
    }

    fn sortOnly(self: *Viewer) void {
        const Ctx = struct { sort: pure.Sort, reverse: bool };
        std.mem.sort(Item, self.items.items, Ctx{ .sort = self.sort, .reverse = self.reverse }, struct {
            fn less(c: Ctx, a: Item, b: Item) bool {
                return pure.entryLess(c.sort, c.reverse, .{ .name = a.name, .mtime = a.mtime, .size = a.size }, .{ .name = b.name, .mtime = b.mtime, .size = b.size });
            }
        }.less);
    }

    /// Sorts again, staying on the same picture.
    fn sortItems(self: *Viewer) void {
        const current: ?[:0]u8 = if (self.picture) |p| self.gpa.dupeSentinel(u8, p.uri, 0) catch null else null;
        defer if (current) |c| self.gpa.free(c);
        self.sortOnly();
        self.fillGallery();
        if (current) |c| for (self.items.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.uri, c)) {
                self.index = i;
                self.gallery.select(i);
            }
        };
        self.updateStatus();
    }

    fn fillGallery(self: *Viewer) void {
        var uris: std.ArrayList([:0]u8) = .empty;
        defer uris.deinit(self.gpa);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.gpa);
        for (self.items.items) |it| {
            uris.append(self.gpa, it.uri) catch return;
            names.append(self.gpa, it.name) catch return;
        }
        self.gallery.fill(uris.items, names.items);
    }

    fn onFolderChanged(_: *gio.FileMonitor, file: *gio.File, _: ?*gio.File, event: gio.FileMonitorEvent, self: *Viewer) callconv(.c) void {
        // Our own saves are not news.
        if (glib.getMonotonicTime() - self.saved_at < 2_000_000) return;
        switch (event) {
            .changes_done_hint => if (self.picture) |p| {
                const uri = file.getUri();
                defer glib.free(uri);
                if (std.mem.eql(u8, std.mem.span(uri), p.uri) and !self.modified()) {
                    if (self.reload_timer != 0) _ = glib.Source.remove(self.reload_timer);
                    self.reload_timer = glib.timeoutAdd(300, onReload, self);
                }
            },
            .created, .deleted, .moved_in, .moved_out, .renamed => {
                if (self.rescan_timer != 0) _ = glib.Source.remove(self.rescan_timer);
                self.rescan_timer = glib.timeoutAdd(300, onRescan, self);
            },
            else => {},
        }
    }

    fn onRescan(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        self.rescan_timer = 0;
        const keep: ?[:0]u8 = if (self.picture) |p| self.gpa.dupeSentinel(u8, p.uri, 0) catch null else null;
        defer if (keep) |k| self.gpa.free(k);
        self.scan(keep);
        return 0;
    }

    fn onReload(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        self.reload_timer = 0;
        // Read the changed file again, even if a copy is cached.
        if (self.index < self.items.items.len) self.request(self.index, true);
        return 0;
    }

    fn showEmpty(self: *Viewer) void {
        self.dropPicture();
        self.canvas.widget().setCursorFromName(null);
        self.canvas.show(null, false);
        self.showMessage(null);
        self.updateStatus();
        self.updateMenus();
        self.fillProperties();
    }

    /// Shows picture `index` of the list (asking about unsaved edits first).
    fn goTo(self: *Viewer, index: usize) void {
        if (index >= self.items.items.len) return self.showEmpty();
        if (self.modified() and self.picture != null and !std.mem.eql(u8, self.picture.?.uri, self.items.items[index].uri)) {
            return self.askToSave(.{ .show = index });
        }
        self.index = index;
        self.gallery.select(index);
        self.request(index, false);
    }

    /// Shows picture `index`: at once when it was read ahead, otherwise once
    /// the worker has read it.
    fn request(self: *Viewer, index: usize, fresh: bool) void {
        const uri = self.items.items[index].uri;
        self.generation += 1;
        if (!fresh) {
            for (self.cache.items, 0..) |p, i| if (std.mem.eql(u8, p.uri, uri)) {
                _ = self.cache.orderedRemove(i);
                self.display(p);
                return;
            };
        }
        self.loader.forget(.preload);
        self.ask(.show, uri, true);
        // Until it arrives the old picture stays, under a busy pointer.
        self.status.setText(t("Loading…"));
        self.canvas.widget().setCursorFromName("progress");
    }

    fn ask(self: *Viewer, kind: loader_mod.Kind, uri: [:0]const u8, urgent: bool) void {
        self.loader.ask(kind, uri, self.generation, urgent);
        self.outstanding += 1;
        if (self.poll_timer == 0) self.poll_timer = glib.timeoutAdd(15, onPoll, self);
    }

    fn onPoll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        var n: usize = 0;
        while (self.loader.poll()) |r| {
            self.outstanding -|= 1;
            self.collect(r);
            n += 1;
            // Leave time for drawing between thumbnails.
            if (n >= 8) break;
        }
        if (self.outstanding > 0) return 1;
        self.poll_timer = 0;
        return 0;
    }

    fn collect(self: *Viewer, r: *loader_mod.Result) void {
        defer r.destroy();
        switch (r.kind) {
            .thumb => if (r.thumb) |pb| self.gallery.setThumb(r.uri, pb),
            .show, .preload => {
                const current = self.index < self.items.items.len and std.mem.eql(u8, self.items.items[self.index].uri, r.uri);
                if (r.kind == .show and r.generation == self.generation and current) {
                    if (r.picture) |p| {
                        r.picture = null;
                        self.display(p);
                    } else self.showFailure(r.message);
                    return;
                }
                const p = r.picture orelse return;
                if (self.isNeighbour(p.uri) and !self.isCached(p.uri)) {
                    r.picture = null;
                    self.keepNear(p);
                }
            },
            .quit => {},
        }
    }

    fn isNeighbour(self: *Viewer, uri: []const u8) bool {
        const n = self.items.items.len;
        if (n == 0) return false;
        for ([_]usize{ pure.neighbour(self.index, n, true, true), pure.neighbour(self.index, n, false, true) }) |i| {
            if (std.mem.eql(u8, self.items.items[i].uri, uri)) return true;
        }
        return false;
    }

    fn isCached(self: *Viewer, uri: []const u8) bool {
        for (self.cache.items) |p| if (std.mem.eql(u8, p.uri, uri)) return true;
        return false;
    }

    /// Keeps a picture read ahead, dropping ones no longer next door.
    fn keepNear(self: *Viewer, p: *Picture) void {
        var i: usize = 0;
        while (i < self.cache.items.len) {
            if (!self.isNeighbour(self.cache.items[i].uri)) {
                self.cache.orderedRemove(i).destroy();
            } else i += 1;
        }
        if (self.cache.items.len >= max_cached) self.cache.orderedRemove(0).destroy();
        self.cache.append(self.gpa, p) catch p.destroy();
    }

    fn dropPicture(self: *Viewer) void {
        self.stopAnimation();
        if (self.picture) |p| {
            // Going back is instant too.
            if (self.isNeighbour(p.uri) and !self.isCached(p.uri)) self.keepNear(p) else p.destroy();
        }
        self.picture = null;
    }

    fn display(self: *Viewer, p: *Picture) void {
        self.dropPicture();
        self.picture = p;
        self.failed = false;
        self.clearEdits();
        self.turn = pure.Turn.fromExif(p.orientation);
        self.showMessage(null);
        if (self.canvas.cropping) self.canvas.endCrop();
        self.canvas.show(p, self.slideshow_timer != 0);
        if (p.animation) |anim| self.startAnimation(anim);
        self.noteRecent(p.uri);
        self.fillOpenWith();
        self.fillProperties();
        self.updateStatus();
        self.updateMenus();
        self.readAhead();
    }

    fn showFailure(self: *Viewer, message: ?[:0]const u8) void {
        self.dropPicture();
        self.canvas.widget().setCursorFromName(null);
        self.failed = true;
        self.canvas.show(null, false);
        const name = if (self.index < self.items.items.len) self.items.items[self.index].name else "";
        var buf: [1024]u8 = undefined;
        self.showMessage(std.fmt.bufPrintSentinel(&buf, "{s}\n\n{s}", .{ name, message orelse "" }, 0) catch null);
        self.updateStatus();
        self.updateMenus();
        self.fillProperties();
    }

    fn showMessage(self: *Viewer, text: ?[:0]const u8) void {
        self.message.setText(text orelse "");
        self.message.as(gtk.Widget).setVisible(@intFromBool(text != null));
    }

    /// Reads the neighbours ahead (unless they are too big to keep).
    fn readAhead(self: *Viewer) void {
        const n = self.items.items.len;
        if (n < 2) return;
        for ([_]usize{ pure.neighbour(self.index, n, true, true), pure.neighbour(self.index, n, false, true) }) |i| {
            if (i == self.index) continue;
            const it = self.items.items[i];
            if (self.isCached(it.uri) or it.size > 64 << 20) continue;
            self.ask(.preload, it.uri, false);
        }
    }

    fn onGalleryActivate(owner: *anyopaque, index: usize) void {
        const self: *Viewer = @ptrCast(@alignCast(owner));
        self.goTo(index);
    }

    fn onGalleryRequest(owner: *anyopaque, uri: [:0]const u8) void {
        const self: *Viewer = @ptrCast(@alignCast(owner));
        self.ask(.thumb, uri, false);
    }

    // ---- moving pictures and SVG ------------------------------------------------------------

    fn startAnimation(self: *Viewer, anim: *gdkpixbuf.PixbufAnimation) void {
        self.anim_iter = anim.getIter(null);
        self.scheduleFrame();
    }

    fn stopAnimation(self: *Viewer) void {
        if (self.anim_timer != 0) _ = glib.Source.remove(self.anim_timer);
        self.anim_timer = 0;
        if (self.anim_iter) |it| it.as(gobject.Object).unref();
        self.anim_iter = null;
    }

    fn scheduleFrame(self: *Viewer) void {
        const it = self.anim_iter orelse return;
        const delay = it.getDelayTime();
        if (delay < 0) return; // the last frame stays
        self.anim_timer = glib.timeoutAdd(@intCast(@max(20, delay)), onFrame, self);
    }

    fn onFrame(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        self.anim_timer = 0;
        const it = self.anim_iter orelse return 0;
        if (it.advance(null) != 0) {
            if (loader_mod.surfaceFromPixbuf(it.getPixbuf())) |s| self.canvas.setFrame(s) else |_| {}
        }
        self.scheduleFrame();
        return 0;
    }

    fn onZoomed(owner: *anyopaque) void {
        const self: *Viewer = @ptrCast(@alignCast(owner));
        self.updateStatus();
        const p = self.picture orelse return;
        if (p.vector) {
            if (self.vector_timer != 0) _ = glib.Source.remove(self.vector_timer);
            self.vector_timer = glib.timeoutAdd(150, onVector, self);
        }
    }

    /// Draws an SVG again at the size it is shown at.
    fn onVector(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        self.vector_timer = 0;
        const p = self.picture orelse return 0;
        if (!p.vector) return 0;
        const scale: f64 = @floatFromInt(self.canvas.widget().getScaleFactor());
        const w = @as(f64, @floatFromInt(p.width)) * self.canvas.zoom * scale;
        const h = @as(f64, @floatFromInt(p.height)) * self.canvas.zoom * scale;
        if (w < 1 or h < 1 or w > 8192 or h > 8192) return 0;
        if (@abs(w - @as(f64, @floatFromInt(p.width))) < 1) {
            self.canvas.setFrame(null);
            return 0;
        }
        if (loader_mod.renderVector(p.bytes, @intFromFloat(@round(w)), @intFromFloat(@round(h)))) |s| self.canvas.setFrame(s);
        return 0;
    }

    // ---- full screen and slideshow -------------------------------------------------------

    fn setFullscreen(self: *Viewer, on: bool) void {
        if (on == self.fullscreen) return;
        self.fullscreen = on;
        const win = self.window.as(gtk.Window);
        if (on) win.fullscreen() else win.unfullscreen();
        // Only the picture, on black.
        self.menu_bar.setVisible(@intFromBool(!on));
        self.status.as(gtk.Widget).setVisible(@intFromBool(!on and self.config.getBool("view", "statusbar", true)));
        self.gallery.widget().setVisible(@intFromBool(!on and self.config.getBool("view", "gallery", false)));
        self.side.as(gtk.Widget).setVisible(@intFromBool(!on and self.config.getBool("view", "properties", false)));
        self.canvas.dark = on;
        if (!on) {
            if (self.slideshow_timer != 0) self.stopSlideshow();
            self.canvas.hideCursor(false);
        } else self.armCursorTimer();
        self.canvas.redraw();
    }

    fn onMoved(owner: *anyopaque) void {
        const self: *Viewer = @ptrCast(@alignCast(owner));
        if (!self.fullscreen) return;
        self.canvas.hideCursor(false);
        self.armCursorTimer();
    }

    fn armCursorTimer(self: *Viewer) void {
        if (self.cursor_timer != 0) _ = glib.Source.remove(self.cursor_timer);
        self.cursor_timer = glib.timeoutAdd(2000, onCursorTimer, self);
    }

    fn onCursorTimer(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        self.cursor_timer = 0;
        if (self.fullscreen) self.canvas.hideCursor(true);
        return 0;
    }

    fn startSlideshow(self: *Viewer) void {
        if (self.items.items.len == 0) return;
        self.setFullscreen(true);
        self.slideshow_paused = false;
        self.canvas.setFit(.best);
        const seconds = std.math.clamp(self.config.getInt("view", "slideshow-seconds", 5), 1, 3600);
        self.slideshow_timer = glib.timeoutAddSeconds(@intCast(seconds), onSlide, self);
    }

    fn stopSlideshow(self: *Viewer) void {
        if (self.slideshow_timer != 0) _ = glib.Source.remove(self.slideshow_timer);
        self.slideshow_timer = 0;
        self.setFullscreen(false);
        self.updateStatus();
    }

    fn onSlide(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        if (!self.slideshow_paused and !self.modified()) self.stepKey(true);
        return 1;
    }

    // ---- edits -----------------------------------------------------------------------------

    fn modified(self: *const Viewer) bool {
        return self.undo.items.len > 0;
    }

    fn clearEdits(self: *Viewer) void {
        for (self.undo.items) |e| e.deinit();
        self.undo.clearRetainingCapacity();
        for (self.redo.items) |e| e.deinit();
        self.redo.clearRetainingCapacity();
        self.lossy = false;
    }

    fn canEdit(self: *Viewer) ?*Picture {
        const p = self.picture orelse return null;
        if (p.pixels == null) {
            self.flash(t("Moving pictures cannot be edited."));
            return null;
        }
        return p;
    }

    fn edit(self: *Viewer, op: Op) void {
        _ = self.canEdit() orelse return;
        for (self.redo.items) |e| e.deinit();
        self.redo.clearRetainingCapacity();
        self.apply(op);
    }

    /// Changes the pixels and records how to undo it.
    fn apply(self: *Viewer, op: Op) void {
        const p = self.picture orelse return;
        const d = p.pixels orelse return;
        var entry: Edit = .{ .op = op, .turn_before = self.turn, .lossy_before = self.lossy };
        if (op.lossy()) entry.before = .{ .width = d.width, .height = d.height, .rgba = c_alloc.dupe(u8, d.rgba) catch return };
        const result = transform(d, op) catch {
            entry.deinit();
            self.flash(t("Not enough memory for this edit."));
            return;
        };
        // `transform` consumed the old pixels, so they are replaced without freeing.
        p.pixels = null;
        p.setPixels(result) catch {
            result.deinit(c_alloc);
            entry.deinit();
            return;
        };
        switch (op) {
            .cw => self.turn = self.turn.clockwise(),
            .ccw => self.turn = self.turn.counterClockwise(),
            .flip_h => self.turn = self.turn.mirrored(),
            .flip_v => self.turn = self.turn.flippedVertically(),
            .crop, .resize => self.lossy = true,
        }
        p.vector = false;
        self.undo.append(self.gpa, entry) catch entry.deinit();
        self.afterEdit();
    }

    /// The pixels after `op`; `d` is consumed when it succeeds.
    fn transform(d: imgcodec.Decoded, op: Op) !imgcodec.Decoded {
        switch (op) {
            .cw => return imgcodec.orient(c_alloc, d, 6),
            .ccw => return imgcodec.orient(c_alloc, d, 8),
            .flip_h => return imgcodec.orient(c_alloc, d, 2),
            .flip_v => return imgcodec.orient(c_alloc, d, 4),
            .crop => |r| {
                const out = try c_alloc.alloc(u8, @as(usize, r.w) * r.h * 4);
                for (0..r.h) |y| {
                    const src = ((r.y + y) * d.width + r.x) * 4;
                    @memcpy(out[y * r.w * 4 ..][0 .. r.w * 4], d.rgba[src..][0 .. r.w * 4]);
                }
                d.deinit(c_alloc);
                return .{ .width = r.w, .height = r.h, .rgba = out };
            },
            .resize => |size| {
                const pb = loader_mod.pixbufFromDecoded(d) orelse return error.OutOfMemory;
                defer pb.as(gobject.Object).unref();
                const scaled = pb.scaleSimple(@intCast(size[0]), @intCast(size[1]), .hyper) orelse return error.OutOfMemory;
                defer scaled.as(gobject.Object).unref();
                const out = try loader_mod.decodedFromPixbuf(scaled);
                d.deinit(c_alloc);
                return out;
            },
        }
    }

    fn undoEdit(self: *Viewer) void {
        const p = self.picture orelse return;
        var entry = self.undo.pop() orelse return;
        const d = p.pixels orelse return;
        if (entry.before) |b| {
            p.pixels = null;
            d.deinit(c_alloc);
            p.setPixels(b) catch {};
            entry.before = null;
        } else {
            const back: Op = switch (entry.op) {
                .cw => .ccw,
                .ccw => .cw,
                else => entry.op,
            };
            if (transform(d, back)) |r| {
                p.pixels = null;
                p.setPixels(r) catch r.deinit(c_alloc);
            } else |_| {}
        }
        self.turn = entry.turn_before;
        self.lossy = entry.lossy_before;
        self.redo.append(self.gpa, entry) catch entry.deinit();
        self.afterEdit();
    }

    fn redoEdit(self: *Viewer) void {
        const entry = self.redo.pop() orelse return;
        defer entry.deinit();
        self.apply(entry.op);
    }

    fn afterEdit(self: *Viewer) void {
        self.canvas.changed();
        self.fillProperties();
        self.updateStatus();
        self.updateMenus();
    }

    fn startCrop(self: *Viewer) void {
        _ = self.canEdit() orelse return;
        self.canvas.startCrop();
        self.updateStatus();
    }

    fn onSelected(owner: *anyopaque) void {
        const self: *Viewer = @ptrCast(@alignCast(owner));
        self.updateStatus();
    }

    fn applyCrop(self: *Viewer) void {
        const r = self.canvas.selection() orelse return;
        self.canvas.endCrop();
        self.edit(.{ .crop = r });
    }

    fn resizeDialog(self: *Viewer) void {
        const p = self.canEdit() orelse return;
        ResizeDialog.open(self, p.width, p.height);
    }

    // ---- saving ------------------------------------------------------------------------------

    fn save(self: *Viewer) void {
        const p = self.picture orelse return;
        if (!self.modified()) return;
        const file = gio.File.newForUri(p.uri);
        defer file.as(gobject.Object).unref();
        const base = file.getBasename() orelse return self.saveAs();
        defer glib.free(base);
        if (pure.saveType(std.mem.span(base)) == null or !writable(pure.saveType(std.mem.span(base)).?)) return self.saveAs();
        if (self.writeTo(file, std.mem.span(base))) self.runPending() else self.setPending(.none);
    }

    fn saveAs(self: *Viewer) void {
        const p = self.picture orelse return;
        if (p.pixels == null) return self.flash(t("Moving pictures cannot be saved here."));
        const dialog = gtk.FileDialog.new();
        defer dialog.as(gobject.Object).unref();
        const file = gio.File.newForUri(p.uri);
        defer file.as(gobject.Object).unref();
        if (file.getParent()) |parent| {
            dialog.setInitialFolder(parent);
            parent.as(gobject.Object).unref();
        }
        if (file.getBasename()) |b| {
            defer glib.free(b);
            var buf: [512]u8 = undefined;
            const name = std.mem.span(b);
            // An SVG or GIF is saved as a PNG unless another name is chosen.
            const fallback = pure.saveType(name) == null;
            dialog.setInitialName(if (fallback) std.fmt.bufPrintSentinel(&buf, "{s}.png", .{std.fs.path.stem(name)}, 0) catch b else b);
        }
        dialog.save(self.window.as(gtk.Window), null, onSaveChosen, self);
    }

    fn onSaveChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        const dialog: *gtk.FileDialog = @ptrCast(@alignCast(source.?));
        const file = dialog.saveFinish(result, null) orelse {
            self.setPending(.none);
            return;
        };
        defer file.as(gobject.Object).unref();
        const base = file.getBasename() orelse return;
        defer glib.free(base);
        const name = std.mem.span(base);
        const kind = pure.saveType(name) orelse {
            common.dialogs.showError(self.window.as(gtk.Window), t("Choose a different file type"), t("End the name with .png, .jpg, .webp, .tif, .bmp or .ico."));
            return;
        };
        if (!writable(kind)) {
            common.dialogs.showError(self.window.as(gtk.Window), t("Choose a different file type"), t("This system cannot write that kind of picture. PNG and JPEG always work."));
            return;
        }
        if (!self.writeTo(file, name)) return self.setPending(.none);
        // The edits went into the new file.
        self.clearEdits();
        self.updateMenus();
        // Leaving (or closing) was waiting for this; otherwise show the new file.
        if (self.pending != .none) return self.runPending();
        const uri = file.getUri();
        defer glib.free(uri);
        const parent = file.getParent() orelse return;
        defer parent.as(gobject.Object).unref();
        self.setFolder(parent, std.mem.span(uri));
    }

    /// Writes the picture to `file`; true when it worked.
    fn writeTo(self: *Viewer, file: *gio.File, name: []const u8) bool {
        const p = self.picture orelse return false;
        const d = p.pixels orelse return false;
        const kind = pure.saveType(name) orelse return false;
        const uri = file.getUri();
        defer glib.free(uri);
        const same = std.mem.eql(u8, std.mem.span(uri), p.uri);
        const was_jpeg = std.mem.eql(u8, p.formatName(), "JPEG");

        var out: ?[]u8 = null;
        defer if (out) |o| c_alloc.free(o);
        var lossless = false;
        // Only turned: rewrite the JPEG's orientation tag, not its pixels.
        if (!self.lossy and was_jpeg and std.mem.eql(u8, kind, "jpeg")) {
            if (exif.withOrientation(c_alloc, p.bytes, self.turn.toExif()) catch null) |bytes| {
                out = bytes;
                lossless = true;
            }
        }
        if (out == null) {
            const pb = loader_mod.pixbufFromDecoded(d) orelse return false;
            defer pb.as(gobject.Object).unref();
            var buf: [*]u8 = undefined;
            var len: usize = 0;
            var err: ?*glib.Error = null;
            var qbuf: [8]u8 = undefined;
            const quality = std.fmt.bufPrintSentinel(&qbuf, "{d}", .{std.math.clamp(self.config.getInt("view", "jpeg-quality", 92), 10, 100)}, 0) catch "92";
            var keys = [_:null]?[*:0]const u8{"quality"};
            var values = [_:null]?[*:0]const u8{quality.ptr};
            const is_jpeg = std.mem.eql(u8, kind, "jpeg");
            const target = if (is_jpeg) dropAlpha(pb) else pb;
            defer if (target != pb) target.as(gobject.Object).unref();
            if (target.saveToBufferv(&buf, &len, kind, if (is_jpeg) @ptrCast(&keys) else null, if (is_jpeg) @ptrCast(&values) else null, &err) == 0) {
                self.showGError(t("Cannot save the picture"), err);
                return false;
            }
            defer glib.free(buf);
            // A re-saved photo keeps its camera data.
            if (is_jpeg and was_jpeg) out = exif.carryOver(c_alloc, p.bytes, buf[0..len]) catch null;
            if (out == null) out = c_alloc.dupe(u8, buf[0..len]) catch return false;
        }
        var err: ?*glib.Error = null;
        if (file.replaceContents(out.?.ptr, out.?.len, null, 0, .{}, null, null, &err) == 0) {
            self.showGError(t("Cannot save the picture"), err);
            return false;
        }
        self.saved_at = glib.getMonotonicTime();
        if (same) {
            // What is on disk now.
            c_alloc.free(p.bytes);
            p.bytes = out.?;
            out = null;
            p.orientation = if (lossless) self.turn.toExif() else 1;
            self.turn = pure.Turn.fromExif(p.orientation);
            self.lossy = false;
            self.clearEdits();
            self.afterEdit();
        }
        self.flash(t("Saved"));
        return true;
    }

    /// JPEG has no transparency: the picture over white.
    fn dropAlpha(pb: *gdkpixbuf.Pixbuf) *gdkpixbuf.Pixbuf {
        const w = pb.getWidth();
        const h = pb.getHeight();
        const out = gdkpixbuf.Pixbuf.new(.rgb, 0, 8, w, h) orelse return @ptrCast(pb.as(gobject.Object).ref());
        out.fill(0xffffffff);
        pb.composite(out, 0, 0, w, h, 0, 0, 1, 1, .nearest, 255);
        return out;
    }

    fn writable(kind: [:0]const u8) bool {
        const formats = gdkpixbuf.Pixbuf.getFormats();
        defer formats.free();
        var node: ?*glib.SList = formats;
        while (node) |n| : (node = n.f_next) {
            const f: *gdkpixbuf.PixbufFormat = @ptrCast(@alignCast(n.f_data orelse continue));
            const name = f.getName() orelse continue;
            if (std.mem.eql(u8, std.mem.span(name), kind)) return f.isWritable() != 0;
        }
        return false;
    }

    fn askToSave(self: *Viewer, then: Pending) void {
        self.setPending(then);
        var buf: [600]u8 = undefined;
        const name = if (self.picture) |p| std.fs.path.basename(p.uri) else "";
        const message = std.fmt.bufPrintSentinel(&buf, "Save the changes to “{s}”?", .{name}, 0) catch "Save the changes?";
        common.dialogs.choose(self.window.as(gtk.Window), message, t("Otherwise the rotation and edits are lost."), &.{ t("Cancel"), t("Save"), t("Discard") }, 0, Viewer, onSaveAnswer, self);
    }

    fn onSaveAnswer(self: *Viewer, answer: c_int) void {
        // Save is second, so Enter saves.
        switch (answer) {
            1 => {
                // `save` runs the pending step once the file is written.
                self.save();
            },
            2 => {
                self.clearEdits();
                self.revertPixels();
                self.runPending();
            },
            else => self.setPending(.none),
        }
    }

    /// After "Discard": read the picture again so the edits are gone.
    fn revertPixels(self: *Viewer) void {
        const p = self.picture orelse return;
        const fresh = loader_mod.load(p.uri) catch return;
        self.picture = fresh;
        p.destroy();
        self.canvas.show(fresh, true);
    }

    fn setPending(self: *Viewer, p: Pending) void {
        switch (self.pending) {
            .open => |uri| self.gpa.free(uri),
            else => {},
        }
        self.pending = p;
    }

    fn runPending(self: *Viewer) void {
        const p = self.pending;
        self.pending = .none;
        switch (p) {
            .none => {},
            .show => |i| self.goTo(i),
            .close => self.window.as(gtk.Window).close(),
            .open => |uri| {
                defer self.gpa.free(uri);
                self.openUri(uri);
            },
        }
    }

    // ---- other files and programs ---------------------------------------------------------

    fn currentFile(self: *Viewer) ?*gio.File {
        if (self.index >= self.items.items.len) return null;
        return gio.File.newForUri(self.items.items[self.index].uri);
    }

    fn copyImage(self: *Viewer) void {
        const p = self.picture orelse return;
        const pb: ?*gdkpixbuf.Pixbuf = if (p.pixels) |d| loader_mod.pixbufFromDecoded(d) else if (p.animation) |a| @as(*gdkpixbuf.Pixbuf, @ptrCast(a.getStaticImage().as(gobject.Object).ref())) else null;
        const pixbuf = pb orelse return;
        defer pixbuf.as(gobject.Object).unref();
        const texture = gdk.Texture.newForPixbuf(pixbuf);
        defer texture.as(gobject.Object).unref();
        self.window.as(gtk.Widget).getClipboard().setTexture(texture);
        self.flash(t("Picture copied"));
    }

    fn copyPath(self: *Viewer) void {
        const f = self.currentFile() orelse return;
        defer f.as(gobject.Object).unref();
        const text = f.getPath() orelse f.getUri();
        defer glib.free(text);
        self.window.as(gtk.Widget).getClipboard().setText(text);
        self.flash(t("Location copied"));
    }

    fn setWallpaper(self: *Viewer) void {
        const f = self.currentFile() orelse return;
        defer f.as(gobject.Object).unref();
        const path = f.getPath() orelse return self.flash(t("Only pictures on this computer can be the wallpaper."));
        defer glib.free(path);
        var cfg = common.Config.load(self.gpa, "panel.toml") catch return;
        defer cfg.deinit();
        // A slideshow folder would override the picture, so turn it off.
        cfg.setString("wallpaper", "slideshow-dir", "") catch return;
        cfg.setString("wallpaper", "image", std.mem.span(path)) catch return;
        self.flash(t("Wallpaper set"));
    }

    fn showInFolder(self: *Viewer) void {
        const f = self.currentFile() orelse return;
        defer f.as(gobject.Object).unref();
        const launcher = gtk.FileLauncher.new(f);
        defer launcher.as(gobject.Object).unref();
        launcher.openContainingFolder(self.window.as(gtk.Window), null, null, null);
    }

    fn fillOpenWith(self: *Viewer) void {
        const menu = common.menubar.submenu(self.window, "openwith") orelse return;
        menu.removeAll();
        if (self.index >= self.items.items.len) return;
        const ct = self.items.items[self.index].content_type;
        if (ct.len == 0) return;
        const ctz = self.gpa.dupeSentinel(u8, ct, 0) catch return;
        defer self.gpa.free(ctz);
        const apps = gio.AppInfo.getAllForType(ctz);
        defer apps.free();
        var node: ?*glib.List = apps;
        while (node) |n| : (node = n.f_next) {
            const app: *gio.AppInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            defer app.as(gobject.Object).unref();
            const id = app.getId() orelse continue;
            if (std.mem.eql(u8, std.mem.span(id), "dkde-view.desktop")) continue;
            const it = gio.MenuItem.new(app.getDisplayName(), null);
            defer it.as(gobject.Object).unref();
            it.setActionAndTargetValue("win.open-with", glib.Variant.newString(id));
            menu.appendItem(it);
        }
    }

    fn onOpenWith(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Viewer) callconv(.c) void {
        const v = param orelse return;
        const app = giounix.DesktopAppInfo.new(v.getString(null)) orelse return;
        defer app.as(gobject.Object).unref();
        const f = self.currentFile() orelse return;
        defer f.as(gobject.Object).unref();
        var list = glib.List{ .f_data = f, .f_next = null, .f_prev = null };
        var err: ?*glib.Error = null;
        if (app.as(gio.AppInfo).launch(&list, null, &err) == 0) self.showGError(t("Cannot open the program"), err);
    }

    fn print(self: *Viewer) void {
        if (self.picture == null) return;
        const op = gtk.PrintOperation.new();
        defer op.as(gobject.Object).unref();
        op.setNPages(1);
        op.setUnit(.points);
        if (self.index < self.items.items.len) {
            var buf: [256]u8 = undefined;
            op.setJobName(std.fmt.bufPrintSentinel(&buf, "{s}", .{self.items.items[self.index].name}, 0) catch "Picture");
        }
        _ = gtk.PrintOperation.signals.request_page_setup.connect(op, *Viewer, &onPrintSetup, self, .{});
        _ = gtk.PrintOperation.signals.draw_page.connect(op, *Viewer, &onPrintPage, self, .{});
        var err: ?*glib.Error = null;
        _ = op.run(.print_dialog, self.window.as(gtk.Window), &err);
        if (err != null) self.showGError(t("Cannot print"), err);
    }

    fn onPrintSetup(_: *gtk.PrintOperation, _: *gtk.PrintContext, _: c_int, setup: *gtk.PageSetup, self: *Viewer) callconv(.c) void {
        const p = self.picture orelse return;
        setup.setOrientation(if (p.width > p.height) .landscape else .portrait);
    }

    /// The picture as large as fits the page, centred.
    fn onPrintPage(_: *gtk.PrintOperation, context: *gtk.PrintContext, _: c_int, self: *Viewer) callconv(.c) void {
        const p = self.picture orelse return;
        const cr = context.getCairoContext();
        const pw = context.getWidth();
        const ph = context.getHeight();
        const sw: f64 = @floatFromInt(p.surface.imageGetWidth());
        const sh: f64 = @floatFromInt(p.surface.imageGetHeight());
        const k = @min(pw / sw, ph / sh);
        cr.save();
        defer cr.restore();
        cr.translate((pw - sw * k) / 2, (ph - sh * k) / 2);
        cr.scale(k, k);
        cr.setSourceSurface(p.surface, 0, 0);
        cr.getSource().setFilter(.good);
        cr.paint();
    }

    // ---- renaming and the Trash ------------------------------------------------------------

    fn rename(self: *Viewer) void {
        if (self.index >= self.items.items.len) return;
        RenameDialog.open(self, self.items.items[self.index].name);
    }

    fn renameTo(self: *Viewer, new_name: []const u8) void {
        const f = self.currentFile() orelse return;
        defer f.as(gobject.Object).unref();
        const z = self.gpa.dupeSentinel(u8, new_name, 0) catch return;
        defer self.gpa.free(z);
        var err: ?*glib.Error = null;
        const renamed = f.setDisplayName(z, null, &err) orelse return self.showGError(t("Cannot rename the file"), err);
        defer renamed.as(gobject.Object).unref();
        const uri = renamed.getUri();
        defer glib.free(uri);
        // The picture showing keeps its pixels under the new name.
        if (self.picture) |p| {
            const owned = c_alloc.dupeSentinel(u8, std.mem.span(uri), 0) catch return;
            c_alloc.free(p.uri);
            p.uri = owned;
        }
        if (self.explicit) {
            const it = &self.items.items[self.index];
            self.gpa.free(it.uri);
            self.gpa.free(it.name);
            it.uri = self.gpa.dupeSentinel(u8, std.mem.span(uri), 0) catch return;
            it.name = self.gpa.dupe(u8, new_name) catch return;
            self.sortItems();
        } else {
            self.saved_at = glib.getMonotonicTime();
            self.scan(std.mem.span(uri));
        }
    }

    fn moveToTrash(self: *Viewer) void {
        const f = self.currentFile() orelse return;
        defer f.as(gobject.Object).unref();
        var err: ?*glib.Error = null;
        if (f.trash(null, &err) == 0) {
            if (err) |e| e.free();
            // Not every place has a Trash (USB sticks, network shares).
            return self.deletePermanently();
        }
        self.forgetTrashed();
        if (f.getPath()) |path| {
            defer glib.free(path);
            if (self.findTrashed(std.mem.span(path))) |name| {
                self.trashed = .{ .name = name, .original = self.gpa.dupeSentinel(u8, std.mem.span(path), 0) catch {
                    self.gpa.free(name);
                    return self.removeCurrent();
                } };
            }
        }
        var buf: [600]u8 = undefined;
        self.showBanner(std.fmt.bufPrintSentinel(&buf, "“{s}” was moved to the Trash", .{self.items.items[self.index].name}, 0) catch "Moved to the Trash", self.trashed != null);
        self.removeCurrent();
    }

    /// The Trash's name for the file that was at `original`: its newest record.
    fn findTrashed(self: *Viewer, original: []const u8) ?[]u8 {
        const dir_path = std.fmt.allocPrintSentinel(self.gpa, "{s}/Trash/info", .{std.mem.span(glib.getUserDataDir())}, 0) catch return null;
        defer self.gpa.free(dir_path);
        const dir = gio.File.newForPath(dir_path);
        defer dir.as(gobject.Object).unref();
        const children = dir.enumerateChildren("standard::name,time::modified", .{}, null, null) orelse return null;
        defer children.as(gobject.Object).unref();
        var best: ?[]u8 = null;
        var best_time: u64 = 0;
        while (children.nextFile(null, null)) |info| {
            defer info.as(gobject.Object).unref();
            const name = std.mem.span(info.getName());
            if (!std.mem.endsWith(u8, name, ".trashinfo")) continue;
            const when = info.getAttributeUint64("time::modified");
            if (best != null and when < best_time) continue;
            const full = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ dir_path, name }) catch continue;
            defer self.gpa.free(full);
            const text = (common.fsio.readFile(self.gpa, full, 64 << 10) catch null) orelse continue;
            defer self.gpa.free(text);
            const path = (pure.trashInfoPath(self.gpa, text) catch null) orelse continue;
            defer self.gpa.free(path);
            if (!std.mem.eql(u8, path, original)) continue;
            if (best) |b| self.gpa.free(b);
            best = self.gpa.dupe(u8, name[0 .. name.len - ".trashinfo".len]) catch null;
            best_time = when;
        }
        return best;
    }

    fn forgetTrashed(self: *Viewer) void {
        if (self.trashed) |tr| {
            self.gpa.free(tr.name);
            self.gpa.free(tr.original);
        }
        self.trashed = null;
    }

    fn onBannerUndo(_: *gtk.Button, self: *Viewer) callconv(.c) void {
        self.hideBanner();
        const tr = self.trashed orelse return;
        const data = std.mem.span(glib.getUserDataDir());
        const from_path = std.fmt.allocPrintSentinel(self.gpa, "{s}/Trash/files/{s}", .{ data, tr.name }, 0) catch return;
        defer self.gpa.free(from_path);
        const info_path = std.fmt.allocPrintSentinel(self.gpa, "{s}/Trash/info/{s}.trashinfo", .{ data, tr.name }, 0) catch return;
        defer self.gpa.free(info_path);
        const from = gio.File.newForPath(from_path);
        defer from.as(gobject.Object).unref();
        const to = gio.File.newForPath(tr.original);
        defer to.as(gobject.Object).unref();
        var err: ?*glib.Error = null;
        if (from.move(to, .{}, null, null, null, &err) == 0) return self.showGError(t("Cannot put the picture back"), err);
        const info = gio.File.newForPath(info_path);
        defer info.as(gobject.Object).unref();
        _ = info.delete(null, null);
        const uri = to.getUri();
        defer glib.free(uri);
        const owned = self.gpa.dupeSentinel(u8, std.mem.span(uri), 0) catch return;
        defer self.gpa.free(owned);
        self.forgetTrashed();
        if (self.explicit) self.openUri(owned) else {
            self.saved_at = glib.getMonotonicTime();
            self.scan(owned);
        }
    }

    fn deletePermanently(self: *Viewer) void {
        if (self.index >= self.items.items.len) return;
        var buf: [600]u8 = undefined;
        const message = std.fmt.bufPrintSentinel(&buf, "Delete “{s}” permanently?", .{self.items.items[self.index].name}, 0) catch return;
        common.dialogs.choose(self.window.as(gtk.Window), message, t("It does not go to the Trash and cannot be brought back."), &.{ t("Cancel"), t("Delete") }, 0, Viewer, onDeleteAnswer, self);
    }

    fn onDeleteAnswer(self: *Viewer, answer: c_int) void {
        if (answer != 1) return;
        const f = self.currentFile() orelse return;
        defer f.as(gobject.Object).unref();
        var err: ?*glib.Error = null;
        if (f.delete(null, &err) == 0) return self.showGError(t("Cannot delete the file"), err);
        self.removeCurrent();
    }

    /// The picture showing is gone: show the next one.
    fn removeCurrent(self: *Viewer) void {
        if (self.index >= self.items.items.len) return;
        self.clearEdits();
        if (self.picture) |p| p.destroy();
        self.picture = null;
        self.stopAnimation();
        self.items.orderedRemove(self.index).deinit(self.gpa);
        self.saved_at = glib.getMonotonicTime();
        self.fillGallery();
        if (self.items.items.len == 0) return self.showEmpty();
        self.goTo(@min(self.index, self.items.items.len - 1));
    }

    // ---- recent pictures ---------------------------------------------------------------------

    fn noteRecent(_: *Viewer, uri: [:0]const u8) void {
        _ = gtk.RecentManager.getDefault().addItem(uri);
    }

    fn onRecentChanged(_: *gtk.RecentManager, self: *Viewer) callconv(.c) void {
        self.loadRecent();
    }

    fn loadRecent(self: *Viewer) void {
        const Found = struct { uri: [:0]u8, when: i64 };
        var found: std.ArrayList(Found) = .empty;
        defer {
            for (found.items) |f| self.gpa.free(f.uri);
            found.deinit(self.gpa);
        }
        const head: ?*glib.List = gtk.RecentManager.getDefault().getItems();
        defer if (head) |h| h.free();
        var node = head;
        while (node) |n| : (node = n.f_next) {
            const info: *gtk.RecentInfo = @ptrCast(@alignCast(n.f_data orelse continue));
            defer info.unref();
            if (!std.mem.startsWith(u8, std.mem.span(info.getMimeType()), "image/")) continue;
            if (info.exists() == 0) continue;
            const uri = self.gpa.dupeSentinel(u8, std.mem.span(info.getUri()), 0) catch continue;
            found.append(self.gpa, .{ .uri = uri, .when = info.getModified().toUnix() }) catch self.gpa.free(uri);
        }
        std.mem.sort(Found, found.items, {}, struct {
            fn newer(_: void, a: Found, b: Found) bool {
                return a.when > b.when;
            }
        }.newer);
        const menu = common.menubar.submenu(self.window, "recent");
        if (menu) |m| m.removeAll();
        const m = menu orelse return;
        for (found.items, 0..) |f, i| {
            if (i >= 10) break;
            const file = gio.File.newForUri(f.uri);
            defer file.as(gobject.Object).unref();
            const base = file.getBasename() orelse continue;
            defer glib.free(base);
            var buf: [300]u8 = undefined;
            const it = gio.MenuItem.new(mnemonicSafe(&buf, std.mem.span(base)), null);
            defer it.as(gobject.Object).unref();
            it.setActionAndTargetValue("win.open-recent", glib.Variant.newString(f.uri));
            m.appendItem(it);
        }
    }

    fn mnemonicSafe(buf: []u8, name: []const u8) [:0]const u8 {
        var n: usize = 0;
        for (name) |c| {
            if (n + 3 >= buf.len) break;
            buf[n] = c;
            n += 1;
            if (c == '_') {
                buf[n] = '_';
                n += 1;
            }
        }
        buf[n] = 0;
        return buf[0..n :0];
    }

    fn onOpenRecent(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Viewer) callconv(.c) void {
        const v = param orelse return;
        const uri = self.gpa.dupeSentinel(u8, std.mem.span(v.getString(null)), 0) catch return;
        defer self.gpa.free(uri);
        self.openUri(uri);
    }

    // ---- what is shown about the picture -------------------------------------------------------

    fn onNavigate(owner: *anyopaque, forward: bool) void {
        const self: *Viewer = @ptrCast(@alignCast(owner));
        self.stepKey(forward);
    }

    fn onContext(owner: *anyopaque, x: f64, y: f64) void {
        const self: *Viewer = @ptrCast(@alignCast(owner));
        const has = self.picture != null;
        const items = [_]common.contextmenu.Item{
            .{ .label = t("Copy Image"), .id = 0, .enabled = has },
            .{ .label = t("Copy Path"), .id = 1, .enabled = has },
            .{ .label = t("Rotate Right"), .id = 2, .enabled = has },
            .{ .label = t("Rotate Left"), .id = 3, .enabled = has },
            .{ .label = t("Set as Wallpaper"), .id = 7, .enabled = has },
            .{ .label = t("Show in Folder"), .id = 4, .enabled = has },
            .{ .label = t("Move to Trash"), .id = 5, .enabled = has },
            .{ .label = t("Properties"), .id = 6 },
        };
        common.contextmenu.show(self.canvas.widget(), x, y, &items, Viewer, onContextChosen, self);
    }

    fn onContextChosen(self: *Viewer, id: usize) void {
        const actions = [_][]const u8{ "copy", "copy-path", "rotate-right", "rotate-left", "show-folder", "trash", "properties", "wallpaper" };
        if (id >= actions.len) return;
        if (id == 6) {
            common.menubar.setChecked(self.window, "properties", self.side.as(gtk.Widget).getVisible() == 0);
        }
        self.perform(actions[id]);
    }

    fn updateMenus(self: *Viewer) void {
        const has = self.picture != null;
        const still = has and self.picture.?.pixels != null;
        const mb = common.menubar;
        inline for (.{ "save-as", "print", "copy", "rotate-right", "rotate-left", "flip-h", "flip-v", "crop", "resize" }) |name| {
            mb.setEnabled(self.window, name, if (comptime std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "copy")) has else still);
        }
        inline for (.{ "show-folder", "copy-path", "rename", "trash", "delete", "wallpaper" }) |name| mb.setEnabled(self.window, name, self.index < self.items.items.len);
        mb.setEnabled(self.window, "save", self.modified());
        mb.setEnabled(self.window, "undo", self.undo.items.len > 0);
        mb.setEnabled(self.window, "redo", self.redo.items.len > 0);
    }

    fn updateStatus(self: *Viewer) void {
        var buf: [1024]u8 = undefined;
        const win = self.window.as(gtk.Window);
        if (self.canvas.cropping) {
            const size = if (self.canvas.selection()) |r| std.fmt.bufPrint(buf[600..], "{d} × {d}", .{ r.w, r.h }) catch "" else "";
            self.status.setText(std.fmt.bufPrintSentinel(buf[0..600], "Drag over the part to keep {s}   Enter crops, Esc cancels", .{size}, 0) catch "");
            return;
        }
        if (self.index >= self.items.items.len) {
            self.status.setText(if (self.failed) "" else t("Open a picture with Ctrl+O, or drop one here"));
            win.setTitle(t("Image Viewer"));
            return;
        }
        const it = self.items.items[self.index];
        var size_buf: [32]u8 = undefined;
        const zoom: i64 = @intFromFloat(@round(self.canvas.zoom * 100));
        const paused = if (self.slideshow_timer != 0 and self.slideshow_paused) "   Paused" else "";
        const text = if (self.picture) |p|
            std.fmt.bufPrintSentinel(&buf, "{s}   {d} × {d}   {s}   {s}   {d}%   {d} / {d}{s}{s}", .{
                it.name,                         p.width,                p.height, p.formatName(),
                pure.humanSize(&size_buf, it.size), zoom, self.index + 1, self.items.items.len,
                if (self.modified()) "   Edited" else "",
                paused,
            }, 0) catch ""
        else
            std.fmt.bufPrintSentinel(&buf, "{s}   {d} / {d}", .{ it.name, self.index + 1, self.items.items.len }, 0) catch "";
        self.status.setText(text);
        var title: [600]u8 = undefined;
        win.setTitle(std.fmt.bufPrintSentinel(&title, "{s}{s} - Image Viewer", .{ if (self.modified()) "*" else "", it.name }, 0) catch "Image Viewer");
    }

    /// Fills the Properties pane (when it is open).
    fn fillProperties(self: *Viewer) void {
        if (self.side.as(gtk.Widget).getVisible() == 0) return;
        const grid = self.side_grid;
        while (grid.as(gtk.Widget).getFirstChild()) |c| grid.remove(c);
        var row: c_int = 0;
        if (self.index >= self.items.items.len) return;
        const it = self.items.items[self.index];
        var buf: [512]u8 = undefined;

        self.heading(&row, t("File"));
        self.property(&row, t("Name"), it.name);
        const file = gio.File.newForUri(it.uri);
        defer file.as(gobject.Object).unref();
        if (file.getParent()) |parent| {
            defer parent.as(gobject.Object).unref();
            const where = parent.getParseName();
            defer glib.free(where);
            self.property(&row, t("Folder"), std.mem.span(where));
        }
        self.property(&row, t("Size"), pure.humanSize(&buf, it.size));
        if (glib.DateTime.newFromUnixLocal(it.mtime)) |dt| {
            defer dt.unref();
            if (dt.format("%Y-%m-%d %H:%M")) |s| {
                defer glib.free(s);
                self.property(&row, t("Modified"), std.mem.span(s));
            }
        }
        const p = self.picture orelse return;
        self.property(&row, t("Type"), p.formatName());
        self.property(&row, t("Dimensions"), std.fmt.bufPrint(&buf, "{d} × {d} pixels ({d:.1} megapixels)", .{ p.width, p.height, @as(f64, @floatFromInt(@as(u64, p.width) * p.height)) / 1e6 }) catch "");
        if (p.animation != null) self.property(&row, t("Animation"), t("Yes"));
        if (p.has_alpha) self.property(&row, t("Transparency"), t("Yes"));

        const block = exif.find(p.bytes) orelse return;
        const info = exif.parse(block);
        if (!info.any()) return;
        self.heading(&row, t("Camera"));
        if (info.make != null or info.model != null) {
            const make = info.make orelse "";
            const model = info.model orelse "";
            // Models usually repeat the maker's name.
            const both = if (make.len > 0 and std.ascii.startsWithIgnoreCase(model, make)) model else std.fmt.bufPrint(&buf, "{s} {s}", .{ make, model }) catch model;
            self.property(&row, t("Camera"), both);
        }
        if (info.lens) |v| self.property(&row, t("Lens"), v);
        if (info.taken) |v| self.property(&row, t("Taken"), exif.dateText(&buf, v));
        if (info.exposure) |v| self.property(&row, t("Exposure"), exif.exposureText(&buf, v));
        if (info.f_number) |v| self.property(&row, t("Aperture"), std.fmt.bufPrint(&buf, "f/{d:.1}", .{v}) catch "");
        if (info.iso) |v| self.property(&row, t("ISO"), std.fmt.bufPrint(&buf, "{d}", .{v}) catch "");
        if (info.focal_length) |v| {
            const text = if (info.focal_35mm) |e| std.fmt.bufPrint(&buf, "{d:.0} mm ({d} mm in 35 mm terms)", .{ v, e }) catch "" else std.fmt.bufPrint(&buf, "{d:.0} mm", .{v}) catch "";
            self.property(&row, t("Focal length"), text);
        }
        if (info.flash) |v| self.property(&row, t("Flash"), exif.flashText(v));
        if (info.software) |v| self.property(&row, t("Software"), v);
        if (info.artist) |v| self.property(&row, t("Author"), v);
        if (info.copyright) |v| self.property(&row, t("Copyright"), v);
        if (info.description) |v| self.property(&row, t("Description"), v);
        if (info.latitude) |lat| if (info.longitude) |lon| {
            self.heading(&row, t("Place"));
            self.property(&row, t("Coordinates"), std.fmt.bufPrint(&buf, "{d:.5}, {d:.5}", .{ lat, lon }) catch "");
            if (info.altitude) |alt| self.property(&row, t("Altitude"), std.fmt.bufPrint(&buf, "{d:.0} m", .{alt}) catch "");
            var url_buf: [200]u8 = undefined;
            const url = std.fmt.bufPrintSentinel(&url_buf, "https://www.openstreetmap.org/?mlat={d:.6}&mlon={d:.6}#map=15/{d:.6}/{d:.6}", .{ lat, lon, lat, lon }, 0) catch return;
            const link = gtk.LinkButton.newWithLabel(url, t("Show on a Map"));
            link.as(gtk.Widget).setHalign(.start);
            grid.attach(link.as(gtk.Widget), 0, row, 2, 1);
            row += 1;
        };
    }

    fn heading(self: *Viewer, row: *c_int, text: [:0]const u8) void {
        const l = gtk.Label.new(text);
        l.setXalign(0);
        l.as(gtk.Widget).addCssClass("heading");
        if (row.* > 0) l.as(gtk.Widget).setMarginTop(10);
        self.side_grid.attach(l.as(gtk.Widget), 0, row.*, 2, 1);
        row.* += 1;
    }

    fn property(self: *Viewer, row: *c_int, name: [:0]const u8, value: []const u8) void {
        const key = gtk.Label.new(name);
        key.setXalign(1);
        key.setYalign(0);
        key.as(gtk.Widget).addCssClass("dim-label");
        var buf: [1024]u8 = undefined;
        const v = gtk.Label.new(std.fmt.bufPrintSentinel(&buf, "{s}", .{value}, 0) catch "");
        v.setXalign(0);
        v.setWrap(1);
        v.setWrapMode(.word_char);
        v.setSelectable(1);
        v.setMaxWidthChars(30);
        v.as(gtk.Widget).setHexpand(1);
        self.side_grid.attach(key.as(gtk.Widget), 0, row.*, 1, 1);
        self.side_grid.attach(v.as(gtk.Widget), 1, row.*, 1, 1);
        row.* += 1;
    }

    // ---- small messages ---------------------------------------------------------------------

    /// A short note in the status bar.
    fn flash(self: *Viewer, text: [:0]const u8) void {
        self.status.setText(text);
    }

    fn showBanner(self: *Viewer, text: [:0]const u8, undo: bool) void {
        self.banner_label.setText(text);
        self.banner_button.as(gtk.Widget).setVisible(@intFromBool(undo));
        self.banner.setRevealChild(1);
        if (self.banner_timer != 0) _ = glib.Source.remove(self.banner_timer);
        self.banner_timer = glib.timeoutAddSeconds(8, onBannerTimeout, self);
    }

    fn hideBanner(self: *Viewer) void {
        self.banner.setRevealChild(0);
        if (self.banner_timer != 0) _ = glib.Source.remove(self.banner_timer);
        self.banner_timer = 0;
    }

    fn onBannerTimeout(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Viewer = @ptrCast(@alignCast(data.?));
        self.banner_timer = 0;
        self.banner.setRevealChild(0);
        return 0;
    }

    fn showGError(self: *Viewer, title: [:0]const u8, err: ?*glib.Error) void {
        defer if (err) |e| e.free();
        const detail: ?[:0]const u8 = if (err) |e| (if (e.f_message) |m| std.mem.span(m) else null) else null;
        common.dialogs.showError(self.window.as(gtk.Window), title, detail);
    }
};

/// Asks for a new name, with the part before the extension selected.
const RenameDialog = struct {
    viewer: *Viewer,
    window: *gtk.Window,
    entry: *gtk.Entry,

    fn open(viewer: *Viewer, name: []const u8) void {
        const self = c_alloc.create(RenameDialog) catch return;
        self.* = .{ .viewer = viewer, .window = gtk.Window.new(), .entry = gtk.Entry.new() };
        const win = self.window;
        win.setTitle(t("Rename"));
        win.setTransientFor(viewer.window.as(gtk.Window));
        win.setModal(1);
        win.setResizable(0);
        win.setDefaultSize(380, -1);
        win.as(gtk.Widget).addCssClass("dkde");
        const box = gtk.Box.new(.vertical, 10);
        box.as(gtk.Widget).setMarginStart(14);
        box.as(gtk.Widget).setMarginEnd(14);
        box.as(gtk.Widget).setMarginTop(14);
        box.as(gtk.Widget).setMarginBottom(14);
        const label = gtk.Label.new(t("New name:"));
        label.setXalign(0);
        box.append(label.as(gtk.Widget));
        var buf: [512]u8 = undefined;
        self.entry.as(gtk.Editable).setText(std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch "");
        self.entry.setActivatesDefault(1);
        box.append(self.entry.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 6);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(t("Cancel"));
        const ok = gtk.Button.newWithLabel(t("Rename"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        box.append(buttons.as(gtk.Widget));
        win.setChild(box.as(gtk.Widget));
        win.setDefaultWidget(ok.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(cancel, *RenameDialog, &onCancel, self, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *RenameDialog, &onOk, self, .{});
        _ = gtk.Widget.signals.destroy.connect(win, *RenameDialog, &onDestroy, self, .{});
        win.present();
        // Select the name without its extension, as file managers do.
        const stem = std.fs.path.stem(name);
        self.entry.as(gtk.Editable).selectRegion(0, @intCast(std.unicode.utf8CountCodepoints(stem) catch stem.len));
    }

    fn onCancel(_: *gtk.Button, self: *RenameDialog) callconv(.c) void {
        self.window.destroy();
    }

    fn onOk(_: *gtk.Button, self: *RenameDialog) callconv(.c) void {
        const text = std.mem.span(self.entry.as(gtk.Editable).getText());
        const name = std.mem.trim(u8, text, " ");
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            common.dialogs.showError(self.window, t("This name cannot be used"), t("A name cannot be empty or contain “/”."));
            return;
        }
        const viewer = self.viewer;
        const owned = viewer.gpa.dupe(u8, name) catch return;
        defer viewer.gpa.free(owned);
        self.window.destroy();
        viewer.renameTo(owned);
    }

    fn onDestroy(_: *gtk.Window, self: *RenameDialog) callconv(.c) void {
        c_alloc.destroy(self);
    }
};

/// Asks for a new size, keeping the proportions unless told not to.
const ResizeDialog = struct {
    viewer: *Viewer,
    window: *gtk.Window,
    width: *gtk.SpinButton,
    height: *gtk.SpinButton,
    keep: *gtk.CheckButton,
    w0: u32,
    h0: u32,
    busy: bool = false,

    fn open(viewer: *Viewer, w: u32, h: u32) void {
        const self = c_alloc.create(ResizeDialog) catch return;
        self.* = .{
            .viewer = viewer,
            .window = gtk.Window.new(),
            .width = gtk.SpinButton.newWithRange(1, 65535, 1),
            .height = gtk.SpinButton.newWithRange(1, 65535, 1),
            .keep = gtk.CheckButton.newWithLabel(t("Keep the proportions")),
            .w0 = w,
            .h0 = h,
        };
        const win = self.window;
        win.setTitle(t("Resize"));
        win.setTransientFor(viewer.window.as(gtk.Window));
        win.setModal(1);
        win.setResizable(0);
        win.as(gtk.Widget).addCssClass("dkde");
        const grid = gtk.Grid.new();
        grid.setRowSpacing(8);
        grid.setColumnSpacing(10);
        grid.as(gtk.Widget).setMarginStart(14);
        grid.as(gtk.Widget).setMarginEnd(14);
        grid.as(gtk.Widget).setMarginTop(14);
        grid.as(gtk.Widget).setMarginBottom(14);
        self.width.setValue(@floatFromInt(w));
        self.height.setValue(@floatFromInt(h));
        self.keep.setActive(1);
        const wl = gtk.Label.new(t("Width (pixels):"));
        wl.setXalign(1);
        const hl = gtk.Label.new(t("Height (pixels):"));
        hl.setXalign(1);
        grid.attach(wl.as(gtk.Widget), 0, 0, 1, 1);
        grid.attach(self.width.as(gtk.Widget), 1, 0, 1, 1);
        grid.attach(hl.as(gtk.Widget), 0, 1, 1, 1);
        grid.attach(self.height.as(gtk.Widget), 1, 1, 1, 1);
        grid.attach(self.keep.as(gtk.Widget), 0, 2, 2, 1);
        const buttons = gtk.Box.new(.horizontal, 6);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = gtk.Button.newWithLabel(t("Cancel"));
        const ok = gtk.Button.newWithLabel(t("Resize"));
        ok.as(gtk.Widget).addCssClass("suggested-action");
        buttons.append(cancel.as(gtk.Widget));
        buttons.append(ok.as(gtk.Widget));
        grid.attach(buttons.as(gtk.Widget), 0, 3, 2, 1);
        win.setChild(grid.as(gtk.Widget));
        win.setDefaultWidget(ok.as(gtk.Widget));
        _ = gtk.SpinButton.signals.value_changed.connect(self.width, *ResizeDialog, &onWidth, self, .{});
        _ = gtk.SpinButton.signals.value_changed.connect(self.height, *ResizeDialog, &onHeight, self, .{});
        _ = gtk.Button.signals.clicked.connect(cancel, *ResizeDialog, &onCancel, self, .{});
        _ = gtk.Button.signals.clicked.connect(ok, *ResizeDialog, &onOk, self, .{});
        _ = gtk.Widget.signals.destroy.connect(win, *ResizeDialog, &onDestroy, self, .{});
        win.present();
    }

    fn onWidth(_: *gtk.SpinButton, self: *ResizeDialog) callconv(.c) void {
        if (self.busy or self.keep.getActive() == 0) return;
        self.busy = true;
        defer self.busy = false;
        self.height.setValue(@floatFromInt(pure.keepRatio(@intCast(self.width.getValueAsInt()), self.w0, self.h0)));
    }

    fn onHeight(_: *gtk.SpinButton, self: *ResizeDialog) callconv(.c) void {
        if (self.busy or self.keep.getActive() == 0) return;
        self.busy = true;
        defer self.busy = false;
        self.width.setValue(@floatFromInt(pure.keepRatio(@intCast(self.height.getValueAsInt()), self.h0, self.w0)));
    }

    fn onCancel(_: *gtk.Button, self: *ResizeDialog) callconv(.c) void {
        self.window.destroy();
    }

    fn onOk(_: *gtk.Button, self: *ResizeDialog) callconv(.c) void {
        const w: u32 = @intCast(self.width.getValueAsInt());
        const h: u32 = @intCast(self.height.getValueAsInt());
        const viewer = self.viewer;
        self.window.destroy();
        if (w == self.w0 and h == self.h0) return;
        if (@as(u64, w) * h > imgcodec.max_pixels) return common.dialogs.showError(viewer.window.as(gtk.Window), t("That is too large"), null);
        viewer.edit(.{ .resize = .{ w, h } });
    }

    fn onDestroy(_: *gtk.Window, self: *ResizeDialog) callconv(.c) void {
        c_alloc.destroy(self);
    }
};

pub const std_options: std.Options = .{ .logFn = common.log.logFn, .log_level = .debug };

pub fn main(init: std.process.Init.Minimal) !void {
    cli.handle(init.args, .{ .name = "dkde-view", .summary = "Image viewer", .usage = "[FILE|FOLDER...]" });
    try common.runapp.run("org.dkde.view", Viewer, init);
}

test {
    _ = @import("pure.zig");
    _ = @import("exif.zig");
}
