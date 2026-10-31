# Insert /pinctrl's nine properties into a flattened device tree.
# stdin: the DTB as one lowercase hex string.  stdout: the patched DTB, same form.
BEGIN {
    HEX = "0123456789abcdef"
    for (i = 32; i < 127; i++) CHARS = CHARS sprintf("%c", i)
}
function h2d(s,   i,c,n,v) {
    n = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); v = index(HEX, c) - 1
        if (v < 0) { print "bad hex digit " c > "/dev/stderr"; exit 1 }
        n = n * 16 + v
    }
    return n
}
function u32(b) { return h2d(substr(H, 2 * b + 1, 8)) }
function d2h(n) { return sprintf("%08x", n) }
function a2h(s,   i,r) { r = ""; for (i = 1; i <= length(s); i++) r = r sprintf("%02x", index(CHARS, substr(s, i, 1)) + 31); return r }
# offset of name in the string block, appending it if absent
function stroff(name,   pat,p,base) {
    pat = a2h(name) "00"
    # first entry has no leading NUL; later ones must be preceded by one
    if (substr(STR, 1, length(pat)) == pat) return 0
    p = 0; rest = STR
    while (1) {
        q = index(rest, "00" pat)
        if (q == 0) break
        p += q
        if ((p - 1) % 2 == 0) return (p - 1) / 2 + 1
        rest = substr(rest, q + 1)
    }
    base = length(STR) / 2 + length(ADD) / 2
    ADD = ADD pat
    return base
}
function prop(name, data,   n) {
    n = length(data) / 2
    while (length(data) % 8 != 0) data = data "00"
    return "00000003" d2h(n) d2h(stroff(name)) data
}
{
    H = $0
    if (substr(H, 1, 8) != "d00dfeed") { print "not a device tree" > "/dev/stderr"; exit 1 }
    totalsize = u32(4); off_struct = u32(8); off_strings = u32(12)
    size_strings = u32(32); size_struct = u32(36)
    if (off_strings + size_strings != totalsize) { print "strings block is not last" > "/dev/stderr"; exit 1 }

    STR = substr(H, 2 * off_strings + 1, 2 * size_strings); ADD = ""

    # /pinctrl's FDT_BEGIN_NODE, then its name "pinctrl\0"
    pat = "00000001" a2h("pinctrl") "00"
    p = index(H, pat)
    if (p == 0) { print "no /pinctrl node" > "/dev/stderr"; exit 1 }
    if (index(substr(H, p + 1), pat) > 0) { print "/pinctrl is ambiguous" > "/dev/stderr"; exit 1 }
    ins = p - 1 + length(pat)                      # char index, 0-based
    if (substr(H, ins + 1, 8) == "00000003") { print "already has properties" > "/dev/stderr"; exit 1 }

    recs = prop("compatible", a2h("rockchip,rk3568-pinctrl") "00")
    recs = recs prop("rockchip,grf", "1000001b")
    recs = recs prop("rockchip,pmu", "100000dc")
    recs = recs prop("#address-cells", "00000002")
    recs = recs prop("#size-cells", "00000002")
    recs = recs prop("ranges", "")
    recs = recs prop("u-boot,dm-spl", "")
    recs = recs prop("status", a2h("okay") "00")
    recs = recs prop("phandle", "100000dd")

    dstruct = length(recs) / 2
    dstrings = length(ADD) / 2
    if (dstruct % 4 != 0) { print "struct growth is not aligned" > "/dev/stderr"; exit 1 }

    OUT = substr(H, 1, ins) recs substr(H, ins + 1)
    # the strings block moved; rewrite it wholesale with the additions
    OUT = substr(OUT, 1, 2 * (off_strings + dstruct)) STR ADD

    OUT = substr(OUT, 1, 8) d2h(totalsize + dstruct + dstrings) substr(OUT, 17)
    OUT = substr(OUT, 1, 24) d2h(off_strings + dstruct) substr(OUT, 33)
    OUT = substr(OUT, 1, 64) d2h(size_strings + dstrings) substr(OUT, 73)
    OUT = substr(OUT, 1, 72) d2h(size_struct + dstruct) substr(OUT, 81)
    print OUT
}
