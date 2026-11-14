#pragma description PDF document
#pragma MIME application/pdf
#pragma magic [ 25 50 44 46 2D ] @ 0x00

// The skeleton of a PDF: the header, the last "startxref" with the offset it
// gives, the cross-reference table it points to and the end marker.

fn count_digits(u128 at) {
    u128 n = 0;
    while (at + n < std::mem::size() && std::mem::read_unsigned(at + n, 1) >= 0x30 && std::mem::read_unsigned(at + n, 1) <= 0x39) {
        n = n + 1;
    }
    return n;
};

fn last_startxref() {
    s128 found = -1;
    s128 n = 0;
    s128 next = std::mem::find_sequence_in_range(0, 0, std::mem::size(), 0x73, 0x74, 0x61, 0x72, 0x74, 0x78, 0x72, 0x65, 0x66);
    while (next >= 0) {
        found = next;
        n = n + 1;
        next = std::mem::find_sequence_in_range(n, 0, std::mem::size(), 0x73, 0x74, 0x61, 0x72, 0x74, 0x78, 0x72, 0x65, 0x66);
    }
    return found;
};

struct Header {
    char marker[5];
    char version[3];
};

struct StartXref {
    char keyword[9];
    char gap[1];
    char xref_offset[count_digits($)];
};

struct XrefMark {
    char keyword[4];
};

Header header @ 0x00;

s128 startxref_at = last_startxref();
if (startxref_at >= 0) {
    StartXref startxref @ startxref_at;
    s128 xref_at = std::string::parse_int(startxref.xref_offset, 10);
    if (xref_at > 0 && xref_at + 4 <= std::mem::size()) {
        XrefMark xref @ xref_at;
    }
}
