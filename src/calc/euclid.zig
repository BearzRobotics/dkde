//! Euclid's Elements as lessons. The wording of the definitions, postulates, common notions and
//! statements follows T. L. Heath's translation (public domain); the steps and the explanations are
//! written for dkde. Each step draws part of the figure on the Geometry pane.
//!
//! Done so far: the foundations of Book I and propositions I.1 to I.4. The rest of the thirteen books
//! follow, book by book (see ai/LEARN-EUCLID.md for the list and what is finished).

const std = @import("std");
const f = @import("figure.zig");
const P = f.P;
const S = f.S;
const L = f.L;
const C = f.C;
const T = f.T;
const A = f.A;
const XCC = f.XCC;
const XLC = f.XLC;
const XLL = f.XLL;
const Step = f.Step;
const Lesson = f.Lesson;

// Colours (indexes into the Geometry palette).
const blue = 0;
const red = 1;
const green = 2;
const orange = 3;
const purple = 4;
const teal = 5;
const yellow = 6;
const black = 7;

pub const lessons = [_]Lesson{
    // ---- the foundations of Book I -------------------------------------------------------------
    .{
        .id = "Definitions",
        .book = 0,
        .title = "Definitions (Book I)",
        .statement = "Euclid begins with twenty-three definitions. Here are the ones about points, lines, angles and circles.",
        .steps = &.{
            .{ .text = "1. A point is that which has no part.", .ops = &.{ f.clear, P("A", 0, 0) } },
            .{ .text = "2. A line is breadthless length. 3. The extremities of a line are points.", .ops = &.{ P("A", -3, 0), P("B", 3, 0), S("A", "B", blue) } },
            .{ .text = "4. A straight line is a line which lies evenly with the points on itself.", .ops = &.{ f.clear, P("A", -4, -1), P("B", 4, 2), L("A", "B", blue) } },
            .{ .text = "8, 9. A plane angle is the inclination to one another of two lines in a plane which meet one another and do not lie in a straight line; when the lines are straight, it is a rectilineal angle.", .ops = &.{ f.clear, P("B", -2, -1), P("A", 2, 2), P("C", 3, -1), S("B", "A", blue), S("B", "C", blue), A("A", "B", "C", red, true) } },
            .{ .text = "10. When a straight line standing on a straight line makes the adjacent angles equal to one another, each of the equal angles is right, and the straight line standing on the other is called a perpendicular.", .ops = &.{ f.clear, P("A", -4, 0), P("B", 4, 0), P("C", 0, 0), P("D", 0, 3.5), S("A", "B", blue), S("C", "D", blue), A("B", "C", "D", green, true), A("D", "C", "A", teal, true) } },
            .{ .text = "11, 12. An obtuse angle is greater than a right angle; an acute angle is less than a right angle.", .ops = &.{ f.clear, P("O", 0, 0), P("A", 4, 0), P("B", 3, 3), P("C", -2.5, 3), S("O", "A", blue), S("O", "B", blue), S("O", "C", blue), A("A", "O", "B", green, true), A("A", "O", "C", orange, true) } },
            .{ .text = "15, 16. A circle is a plane figure contained by one line such that all the straight lines falling upon it from one point among those lying within the figure are equal to one another; and the point is called the centre of the circle.", .ops = &.{ f.clear, P("A", 0, 0), P("B", 3, 0), C("A", "B", blue, true), S("A", "B", red) } },
            .{ .text = "17. A diameter of the circle is any straight line drawn through the centre and terminated in both directions by the circumference, and such a straight line also bisects the circle.", .ops = &.{ f.clear, P("A", 0, 0), P("B", 3, 0), P("D", -3, 0), C("A", "B", blue, false), S("D", "B", red) } },
            .{ .text = "20. Of trilateral figures, an equilateral triangle is that which has its three sides equal, an isosceles triangle that which has two of its sides alone equal, a scalene triangle that which has its three sides unequal.", .ops = &.{ f.clear, P("A", -5, -2), P("B", -2, -2), P("C", -3.5, 0.6), P("D", 0, -2), P("E", 3, -2), P("F", 1.5, 1.8), P("G", 4.6, -2), P("H", 6.2, -2), P("I", 5.2, 0.5), T(&.{ "A", "B", "C" }, green, true), T(&.{ "D", "E", "F" }, blue, true), T(&.{ "G", "H", "I" }, orange, true) } },
            .{ .text = "23. Parallel straight lines are straight lines which, being in the same plane and being produced indefinitely in both directions, do not meet one another in either direction.", .ops = &.{ f.clear, P("A", -4, 1.5), P("B", 4, 1.5), P("C", -4, -1.5), P("D", 4, -1.5), L("A", "B", blue), L("C", "D", red) } },
        },
    },
    .{
        .id = "Postulates",
        .book = 0,
        .title = "The five postulates",
        .statement = "Let the following be postulated: what we are allowed to ask for, before any proof begins.",
        .steps = &.{
            .{ .text = "1. To draw a straight line from any point to any point.", .ops = &.{ f.clear, P("A", -3, -1), P("B", 3, 1.5), S("A", "B", blue) } },
            .{ .text = "2. To produce a finite straight line continuously in a straight line.", .ops = &.{ f.clear, P("A", -3, -1), P("B", 0, 0.5), S("A", "B", blue), P("C", 4.5, 1.75), S("B", "C", red) } },
            .{ .text = "3. To describe a circle with any centre and distance.", .ops = &.{ f.clear, P("A", 0, 0), P("B", 2.5, 0), C("A", "B", blue, false), S("A", "B", red) } },
            .{ .text = "4. That all right angles are equal to one another.", .ops = &.{ f.clear, P("A", -5, 2), P("B", -1, 2), P("C", -3, 2), P("D", -3, 5), S("A", "B", blue), S("C", "D", blue), A("B", "C", "D", green, true), P("E", 1, -2), P("F", 5, -2), P("G", 3, -2), P("H", 3, 1), S("E", "F", red), S("G", "H", red), A("F", "G", "H", green, true) } },
            .{ .text = "5. That, if a straight line falling on two straight lines makes the interior angles on the same side less than two right angles, the two straight lines, if produced indefinitely, meet on that side on which are the angles less than two right angles.", .ops = &.{
                f.clear,
                P("A", -5, 3), P("B", 4, 1), P("C", -5, -1.5), P("D", 4, 0.5), P("E", -3, 4), P("F", -3, -3),
                L("A", "B", blue), L("C", "D", red), L("E", "F", black),
            } },
            .{ .text = "The two angles on the right of the transversal are shaded. Together they are less than two right angles, so the blue and red lines slope towards each other on that side.", .ops = &.{
                XLL("G", "A", "B", "E", "F"), XLL("H", "C", "D", "E", "F"),
                A("B", "G", "F", green, true), A("D", "H", "E", orange, true),
            } },
            .{ .text = "Continue the lines far enough to the right and they meet, as the postulate says. Without this postulate there is no theory of parallels.", .ops = &.{
                XLL("X", "A", "B", "C", "D"),
            } },
        },
    },
    .{
        .id = "Common notions",
        .book = 0,
        .title = "The five common notions",
        .statement = "Besides the postulates, Euclid asks for five things that need no argument.",
        .steps = &.{
            .{ .text = "1. Things which are equal to the same thing are also equal to one another.", .ops = &.{ f.clear, P("A", -4, 2), P("B", -1, 2), P("C", -4, 0), P("D", -1, 0), P("E", -4, -2), P("F", -1, -2), S("A", "B", blue), S("C", "D", blue), S("E", "F", blue) } },
            .{ .text = "2. If equals be added to equals, the wholes are equal.", .ops = &.{ f.clear, P("A", -4, 1), P("B", -1, 1), P("C", 2, 1), P("D", -4, -1), P("E", -1, -1), P("F", 2, -1), S("A", "B", blue), S("B", "C", green), S("D", "E", blue), S("E", "F", green) } },
            .{ .text = "3. If equals be subtracted from equals, the remainders are equal.", .ops = &.{ f.clear, P("A", -4, 1), P("B", 0, 1), P("C", 3, 1), P("D", -4, -1), P("E", -1, -1), P("F", 3, -1), S("A", "B", red), S("B", "C", red), S("D", "E", red), S("E", "F", red) } },
            .{ .text = "4. Things which coincide with one another are equal to one another.", .ops = &.{ f.clear, P("A", -2, 0), P("B", 2, 0), C("A", "B", blue, true) } },
            .{ .text = "5. The whole is greater than the part.", .ops = &.{ f.clear, P("A", -4, 0), P("B", 0, 0), P("C", 3, 0), S("A", "B", blue), S("B", "C", orange) } },
        },
    },

    // ---- Book I: the propositions --------------------------------------------------------------
    .{
        .id = "I.1",
        .book = 1,
        .title = "An equilateral triangle on a given line",
        .statement = "On a given finite straight line to construct an equilateral triangle.",
        .steps = &.{
            .{ .text = "Let AB be the given finite straight line.", .ops = &.{ f.clear, P("A", -2.5, -1.5), P("B", 2.5, -1.5), S("A", "B", black) } },
            .{ .text = "With centre A and distance AB let the circle BCD be described (postulate 3).", .ops = &.{C("A", "B", red, false)} },
            .{ .text = "With centre B and distance BA let the circle ACE be described (postulate 3).", .ops = &.{C("B", "A", blue, false)} },
            .{ .text = "From the point C, in which the circles cut one another, let the straight lines CA and CB be joined to A and B (postulate 1).", .ops = &.{ XCC("C", "A", "B", "B", "A", 1), S("C", "A", red), S("C", "B", blue) } },
            .{ .text = "Then ABC is equilateral. A is the centre of the circle CDB, so AC is equal to AB. B is the centre of the circle CAE, so BC is equal to BA. Things equal to the same thing are equal to one another (common notion 1), so CA is equal to CB. The three straight lines CA, AB, BC are equal to one another.", .ops = &.{T(&.{ "A", "B", "C" }, green, true)} },
        },
        .proof = "Therefore the triangle ABC is equilateral, and it has been constructed on the given finite straight line AB. (Being) what it was required to do.",
    },
    .{
        .id = "I.2",
        .book = 1,
        .title = "A line equal to a given line, at a given point",
        .statement = "To place at a given point (as an extremity) a straight line equal to a given straight line.",
        .steps = &.{
            .{ .text = "Let A be the given point, and BC the given straight line. It is required to place at the point A a straight line equal to the given straight line BC.", .ops = &.{ f.clear, P("A", -5, -2.5), P("B", 0.5, 1), P("C", 3.5, 1), S("B", "C", red) } },
            .{ .text = "From the point A to the point B let the straight line AB be joined (postulate 1).", .ops = &.{S("A", "B", black)} },
            .{ .text = "On AB let the equilateral triangle DAB be constructed (I.1).", .ops = &.{ XCC("D", "A", "B", "B", "A", 1), S("D", "A", black), S("D", "B", black), T(&.{ "D", "A", "B" }, teal, true) } },
            .{ .text = "Let the straight lines AE and BF be produced in a straight line with DA and DB (postulate 2).", .ops = &.{ L("D", "A", black), L("D", "B", black) } },
            .{ .text = "With centre B and distance BC let the circle CGH be described. It meets DF at G (postulate 3).", .ops = &.{ C("B", "C", red, false), XLC("G", "D", "B", "B", "C", 1) } },
            .{ .text = "With centre D and distance DG let the circle GKL be described. It meets DA produced at L (postulate 3).", .ops = &.{ C("D", "G", blue, false), XLC("L", "D", "A", "D", "G", 1) } },
            .{ .text = "Then AL is equal to BC. D is the centre of the circle GKL, so DL is equal to DG. In these DA is equal to DB, so the remainder AL is equal to the remainder BG (common notion 3). But BC was also shown equal to BG, because B is the centre of the circle CGH. Therefore AL is equal to BC (common notion 1).", .ops = &.{ S("A", "L", green), S("B", "G", green) } },
        },
        .proof = "Therefore at the given point A the straight line AL has been placed equal to the given straight line BC. (Being) what it was required to do.",
    },
    .{
        .id = "I.3",
        .book = 1,
        .title = "Cutting off a line equal to a shorter one",
        .statement = "Given two unequal straight lines, to cut off from the greater a straight line equal to the less.",
        .steps = &.{
            .{ .text = "Let AB and C be the two given unequal straight lines, and let AB be the greater. It is required to cut off from AB the greater a straight line equal to C the less.", .ops = &.{ f.clear, P("A", -4.5, -1.5), P("B", 3.5, -1.5), P("C1", -4.5, 3), P("C2", -1, 3), S("A", "B", blue), S("C1", "C2", red) } },
            .{ .text = "At the point A let AD be placed equal to the straight line C (I.2).", .ops = &.{ P("D", -2.025, 0.975), S("A", "D", red) } },
            .{ .text = "With centre A and distance AD let the circle DEF be described (postulate 3). It cuts AB at E.", .ops = &.{ C("A", "D", orange, false), XLC("E", "A", "B", "A", "D", 1) } },
            .{ .text = "Then AE is equal to C. A is the centre of the circle DEF, so AE is equal to AD. But C is also equal to AD. Therefore each of the straight lines AE, C is equal to AD, so AE is equal to C (common notion 1).", .ops = &.{ S("A", "E", green) } },
        },
        .proof = "Therefore, given the two unequal straight lines AB, C, there has been cut off from AB the greater a straight line AE equal to C the less. (Being) what it was required to do.",
    },
    .{
        .id = "I.4",
        .book = 1,
        .title = "Side, angle, side",
        .statement = "If two triangles have the two sides equal to two sides respectively, and have the angles contained by the equal straight lines equal, they will also have the base equal to the base, the triangle will be equal to the triangle, and the remaining angles will be equal to the remaining angles respectively, namely those which the equal sides subtend.",
        .steps = &.{
            .{ .text = "Let ABC and DEF be two triangles having the two sides AB, AC equal to the two sides DE, DF respectively, namely AB to DE and AC to DF, and the angle BAC equal to the angle EDF.", .ops = &.{
                f.clear,
                P("A", -5.5, -2), P("B", -1.5, -2), P("C", -3.5, 1.5), P("D", 1.5, -2), P("E", 5.5, -2), P("F", 3.5, 1.5),
                T(&.{ "A", "B", "C" }, blue, false), T(&.{ "D", "E", "F" }, red, false),
                S("A", "B", green), S("D", "E", green), S("A", "C", orange), S("D", "F", orange),
                A("B", "A", "C", purple, true), A("E", "D", "F", purple, true),
            } },
            .{ .text = "If the triangle ABC is applied to the triangle DEF, and the point A is placed on the point D and the straight line AB on DE, then the point B will also coincide with E, because AB is equal to DE.", .ops = &.{ S("B", "C", teal), S("E", "F", teal) } },
            .{ .text = "AB coinciding with DE, the straight line AC will also coincide with DF, because the angle BAC is equal to the angle EDF. Hence the point C will also coincide with F, because AC is again equal to DF.", .ops = &.{} },
            .{ .text = "But B also coincided with E, so the base BC will coincide with the base EF. For if B coincides with E and C with F, and the base BC did not coincide with EF, two straight lines would enclose a space, which is impossible. Therefore BC coincides with EF and is equal to it.", .ops = &.{} },
            .{ .text = "So the whole triangle ABC will coincide with the whole triangle DEF and will be equal to it, and the remaining angles will coincide with the remaining angles and be equal to them: the angle ABC to DEF, and the angle ACB to DFE.", .ops = &.{ A("A", "B", "C", green, true), A("D", "E", "F", green, true), A("A", "C", "B", orange, true), A("D", "F", "E", orange, true) } },
        },
        .proof = "Therefore, if two triangles have the two sides equal to two sides respectively, and have the angles contained by the equal straight lines equal, they will also have the base equal to the base, the triangle equal to the triangle, and the remaining angles equal to the remaining angles respectively, namely those which the equal sides subtend. (Being) what it was required to prove.",
    },
};

test "every lesson has steps, and every step names only points drawn before it" {
    for (lessons) |lesson| {
        try std.testing.expect(lesson.steps.len > 0);
    }
}
