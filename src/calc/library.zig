// SPDX-License-Identifier: GPL-2.0-or-later
//! Functions that Qalculate defines by an expression (areas and volumes, finance, small helpers),
//! as a library: `find` gives the parameters and the body, which are worked out like a function of
//! your own. Generated from Qalculate's functions.xml, then checked against `qalc`.

const std = @import("std");

pub const Def = struct { names: []const []const u8, params: []const []const u8, body: []const u8 };

pub const defs = [_]Def{
    .{ .names = &.{ "triangle" }, .params = &.{ "x", "y" }, .body = "(x*y)/2" },
    .{ .names = &.{ "triangle_perimeter" }, .params = &.{ "x", "y", "z" }, .body = "x+y+z" },
    .{ .names = &.{ "circle" }, .params = &.{ "x" }, .body = "x^2*pi" },
    .{ .names = &.{ "circumference" }, .params = &.{ "x" }, .body = "x*2*pi" },
    .{ .names = &.{ "cylinder" }, .params = &.{ "x", "y" }, .body = "x^2*pi*y" },
    .{ .names = &.{ "cylinder_sa" }, .params = &.{ "x", "y" }, .body = "2*x^2*pi+2*pi*x*y" },
    .{ .names = &.{ "cone" }, .params = &.{ "x", "y" }, .body = "x^2*pi*y/3" },
    .{ .names = &.{ "cone_sa" }, .params = &.{ "x", "y" }, .body = "x^2*pi+pi*x*abs((y^2+x^2)^(1/2))" },
    .{ .names = &.{ "sphere" }, .params = &.{ "x" }, .body = "x^3*pi*4/3" },
    .{ .names = &.{ "sphere_sa" }, .params = &.{ "x" }, .body = "x^2*pi*4" },
    .{ .names = &.{ "square" }, .params = &.{ "x" }, .body = "x^2" },
    .{ .names = &.{ "square_perimeter" }, .params = &.{ "x" }, .body = "x*4" },
    .{ .names = &.{ "cube" }, .params = &.{ "x" }, .body = "x^3" },
    .{ .names = &.{ "cube_sa" }, .params = &.{ "x" }, .body = "(x^2)*6" },
    .{ .names = &.{ "rect" }, .params = &.{ "x", "y" }, .body = "x*y" },
    .{ .names = &.{ "rect_perimeter" }, .params = &.{ "x", "y" }, .body = "(x+y)*2" },
    .{ .names = &.{ "rectprism" }, .params = &.{ "x", "y", "z" }, .body = "x*y*z" },
    .{ .names = &.{ "rectprism_sa" }, .params = &.{ "x", "y", "z" }, .body = "(x*y)*2+(x*z)*2+(y*z)*2" },
    .{ .names = &.{ "triangleprism" }, .params = &.{ "x", "y", "z" }, .body = "x*y*z/2" },
    .{ .names = &.{ "pyramid" }, .params = &.{ "x", "y", "z" }, .body = "x*y*z/3" },
    .{ .names = &.{ "tetrahedron" }, .params = &.{ "x" }, .body = "sqrt(2)/12*x^3" },
    .{ .names = &.{ "tetrahedron_sa" }, .params = &.{ "x" }, .body = "sqrt(3)*x^2" },
    .{ .names = &.{ "tetrahedron_height" }, .params = &.{ "x" }, .body = "sqrt(6)/3*x" },
    .{ .names = &.{ "sqpyramid" }, .params = &.{ "x" }, .body = "sqrt(2)/6*x^3" },
    .{ .names = &.{ "sqpyramid_sa" }, .params = &.{ "x" }, .body = "(1+sqrt(3))*x^2" },
    .{ .names = &.{ "sqpyramid_height" }, .params = &.{ "x" }, .body = "sqrt(2)/2*x" },
    .{ .names = &.{ "parallelogram" }, .params = &.{ "x", "y" }, .body = "x*y" },
    .{ .names = &.{ "parallelogram_perimeter" }, .params = &.{ "x", "y" }, .body = "(x+y)*2" },
    .{ .names = &.{ "trapezoid" }, .params = &.{ "x", "y", "z" }, .body = "(x+y)/2*z" },
    .{ .names = &.{ "g_duration" }, .params = &.{ "x", "y", "z" }, .body = "ln(z/y)/ln(1+x)" },
    .{ .names = &.{ "level_coupon" }, .params = &.{ "x", "y", "z", "a", "b" }, .body = "(y*x/z)*((1-1/(((1+(b/z))^(a*z))))/(b/z))+(x/((1+(b/z))^(a*z)))" },
};

pub fn find(name: []const u8) ?*const Def {
    for (&defs) |*d| for (d.names) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return d;
    };
    return null;
}
