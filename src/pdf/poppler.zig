//! The few poppler-glib calls dkde-pdf needs, declared by hand (as for
//! gtk4-layer-shell), so no generated bindings or headers are required. The
//! library is linked by name (`pkg-config poppler-glib`).

const cairo = @import("cairo1");
const glib = @import("glib2");
const gobject = @import("gobject2");

pub const Document = opaque {};
pub const Page = opaque {};

/// A rectangle in PDF points, y measured upward from the bottom of the page.
pub const Rectangle = extern struct { x1: f64, y1: f64, x2: f64, y2: f64 };

/// POPPLER_ERROR_ENCRYPTED.
pub const error_encrypted: c_int = 1;

extern fn poppler_document_new_from_file(uri: [*:0]const u8, password: ?[*:0]const u8, err: ?*?*glib.Error) ?*Document;
extern fn poppler_document_get_n_pages(doc: *Document) c_int;
extern fn poppler_document_get_page(doc: *Document, index: c_int) ?*Page;
extern fn poppler_document_get_title(doc: *Document) ?[*:0]u8;
extern fn poppler_page_get_size(page: *Page, width: *f64, height: *f64) void;
extern fn poppler_page_render(page: *Page, cr: *cairo.Context) void;
extern fn poppler_page_get_text(page: *Page) ?[*:0]u8;
extern fn poppler_page_find_text(page: *Page, text: [*:0]const u8) ?*glib.List;
extern fn poppler_rectangle_free(rect: *Rectangle) void;

pub const newFromFile = poppler_document_new_from_file;
pub const pageCount = poppler_document_get_n_pages;
pub const getPage = poppler_document_get_page;
pub const title = poppler_document_get_title;
pub const pageSize = poppler_page_get_size;
pub const render = poppler_page_render;
pub const pageText = poppler_page_get_text;

pub fn unref(object: anytype) void {
    @as(*gobject.Object, @ptrCast(@alignCast(object))).unref();
}

/// Rectangles of every match of `text` on the page, copied out; the caller frees them.
pub fn find(page: *Page, text: [*:0]const u8, out: *[64]Rectangle) usize {
    var node = poppler_page_find_text(page, text);
    const head = node;
    var n: usize = 0;
    while (node) |item| : (node = item.f_next) {
        const rect: *Rectangle = @ptrCast(@alignCast(item.f_data orelse continue));
        if (n < out.len) {
            out[n] = rect.*;
            n += 1;
        }
        poppler_rectangle_free(rect);
    }
    if (head) |h| h.free();
    return n;
}
