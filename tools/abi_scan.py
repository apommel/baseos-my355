#!/usr/bin/env python3
"""What a frontend card needs from the rootfs: the interface a new rootfs keeps.

Reads every ELF and script copied from a card (tools/frontend-abi.sh pulls
them) and reports, for each rootfs library they link, who links it, which
symbols they import from it and which symbol versions those need. Also lists
library names the ELFs carry as strings without linking them (dlopen
candidates), and rootfs paths named by the ELFs and scripts (programs run by
path, config read in place).

The rootfs is read from tarballs, the first to provide a path winning: give
the stock harvest to measure the stock interface, rootfs.tar first to check a
build against it.

Usage:
    abi_scan.py CARD_DIR ROOTFS.tar [ROOTFS.tar ...] [--maps MAPS] [--json OUT]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import struct
import sys
import tarfile
from collections import defaultdict

# Per-platform subdirectories other devices' binaries live in; only my355's run here.
OTHER_PLATFORMS = {"tg5040", "tg5050", "h700", "miyoomini", "my282", "rg35xxplus",
                   "rg35xx", "rgb30", "trimuismart", "m17", "magicmini", "zero28"}
LIB_DIRS = ("usr/lib",)
PROG_DIRS = ("usr/bin", "usr/sbin", "usr/libexec", "usr/miyoo/bin", "etc/init.d",
             "etc/bluetooth", "etc/wifi")
SO_RE = re.compile(rb"lib[A-Za-z0-9_+.-]+\.so(?:\.[0-9]+)*")
PATH_RE = re.compile(rb"/(?:usr|etc|bin|sbin|lib|var|sys/class|dev)/[A-Za-z0-9_+./-]+")


class Elf:
    """The dynamic-linking view of a 64-bit little-endian ELF."""

    def __init__(self, data: bytes):
        if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
            raise ValueError("not a 64-bit LE ELF")
        self.machine, = struct.unpack_from("<H", data, 0x12)
        e_shoff, = struct.unpack_from("<Q", data, 0x28)
        e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)
        secs = [struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)
                for i in range(e_shnum)] if e_shoff else []
        by_type = defaultdict(list)
        for s in secs:
            by_type[s[1]].append(s)
        self.soname, self.needed, self.runpath = None, [], []
        self.imports: list[tuple[str, str | None, str | None]] = []  # sym, version, file
        self.exports: dict[str, str | None] = {}
        dyn = by_type.get(6)                                   # SHT_DYNAMIC
        if not dyn:
            return
        dyn = dyn[0]
        strs = self._sec(data, secs[dyn[6]])

        def s(off):
            return strs[off:strs.index(b"\0", off)].decode(errors="replace")

        for off in range(dyn[4], dyn[4] + dyn[5], 16):
            tag, val = struct.unpack_from("<qQ", data, off)
            if tag == 0:
                break
            if tag == 1:
                self.needed.append(s(val))
            elif tag == 14:
                self.soname = s(val)
            elif tag in (15, 29):                              # RPATH, RUNPATH
                self.runpath += s(val).split(":")

        # Version index -> (version name, file it is needed from); defined versions.
        vers: dict[int, tuple[str, str | None]] = {}
        for sec in by_type.get(0x6FFFFFFE, []):                # SHT_GNU_verneed
            vstr = self._sec(data, secs[sec[6]])
            vs = lambda o: vstr[o:vstr.index(b"\0", o)].decode(errors="replace")
            off = sec[4]
            while True:
                _v, cnt, file_, aux, nxt = struct.unpack_from("<HHIII", data, off)
                a = off + aux
                for _ in range(cnt):
                    _h, _f, other, name, anext = struct.unpack_from("<IHHII", data, a)
                    vers[other] = (vs(name), vs(file_))
                    a += anext
                if not nxt:
                    break
                off += nxt
        for sec in by_type.get(0x6FFFFFFD, []):                # SHT_GNU_verdef
            vstr = self._sec(data, secs[sec[6]])
            vs = lambda o: vstr[o:vstr.index(b"\0", o)].decode(errors="replace")
            off = sec[4]
            while True:
                _v, flags, ndx, cnt, _h, aux, nxt = struct.unpack_from("<HHHHIII", data, off)
                if not flags & 1:                              # skip VER_FLG_BASE
                    name, = struct.unpack_from("<I", data, off + aux)
                    vers[ndx] = (vs(name), None)
                if not nxt:
                    break
                off += nxt

        dynsym = by_type.get(11)                               # SHT_DYNSYM
        if not dynsym:
            return
        dynsym = dynsym[0]
        symstr = self._sec(data, secs[dynsym[6]])
        versym = by_type.get(0x6FFFFFFF)
        n = dynsym[5] // 24
        for i in range(1, n):
            name, info, _o, shndx, _v, _sz = struct.unpack_from(
                "<IBBHQQ", data, dynsym[4] + i * 24)
            sym = symstr[name:symstr.index(b"\0", name)].decode(errors="replace")
            bind = info >> 4
            if not sym or bind == 0:                           # local
                continue
            ver = None
            if versym:
                vi, = struct.unpack_from("<H", data, versym[0][4] + i * 2)
                ver = vers.get(vi & 0x7FFF)
            if shndx == 0:
                if bind == 2 and ver is None:                  # unversioned weak: optional
                    continue
                self.imports.append((sym, ver[0] if ver else None, ver[1] if ver else None))
            else:
                self.exports[sym] = ver[0] if ver else None

    @staticmethod
    def _sec(data, sec):
        return data[sec[4]:sec[4] + sec[5]]


def load_elf(data: bytes) -> Elf | None:
    try:
        return Elf(data)
    except (ValueError, struct.error, IndexError):
        return None


def read_rootfs(tars: list[str]):
    """Every rootfs library by name (first tarball wins), its origin, all paths,
    and the programs: executables that are not BusyBox applet links."""
    libs: dict[str, bytes] = {}
    origin: dict[str, str] = {}
    paths: set[str] = set()
    progs: dict[str, str] = {}
    for t in tars:
        with tarfile.open(t) as tar:
            members = {m.name.lstrip("./"): m for m in tar.getmembers()}
            for name, m in members.items():
                paths.add("/" + name)
                base = os.path.basename(name)
                if (os.path.dirname(name) in PROG_DIRS and base not in progs
                        and (m.isfile() and m.mode & 0o111
                             or m.issym() and "busybox" not in m.linkname)):
                    progs[base] = "/" + name
                if os.path.dirname(name) not in LIB_DIRS:
                    continue
                if base in libs or ".so" not in base:
                    continue
                hops, cur = 0, m
                while cur is not None and cur.issym() and hops < 8:
                    tgt = os.path.normpath(os.path.join(os.path.dirname(cur.name.lstrip("./")),
                                                        cur.linkname)).lstrip("/")
                    cur, hops = members.get(tgt), hops + 1
                if cur is None or not cur.isfile():
                    continue
                libs[base] = tar.extractfile(cur).read()
                origin[base] = os.path.basename(t)
    return libs, origin, paths, progs


def platform_ok(rel: str) -> bool:
    return not any(p in OTHER_PLATFORMS for p in rel.split("/"))


def pak_root(rel: str) -> str:
    parts = rel.split("/")
    for i, p in enumerate(parts):
        if p.endswith(".pak"):
            return "/".join(parts[:i + 1])
    return os.path.dirname(rel)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("card")
    ap.add_argument("rootfs", nargs="+")
    ap.add_argument("--maps", help="/proc/*/maps of the running stack, one file")
    ap.add_argument("--json")
    a = ap.parse_args()

    libs, origin, rpaths, progs = read_rootfs(a.rootfs)
    # A program named as the first word of a command: "amixer sset", "|wpa_cli -i".
    prog_re = re.compile(rb"(?:^|[\s;|&`(\"'/])(" + b"|".join(
        re.escape(p.encode()) for p in sorted(progs, key=len, reverse=True)) +
        rb")(?=[\s;|&>)\"']|$)", re.M) if progs else None
    rootfs_elf = {n: load_elf(d) for n, d in libs.items()}

    card: dict[str, Elf] = {}
    scripts: dict[str, bytes] = {}
    card_names: dict[str, set[str]] = defaultdict(set)         # basename -> dirs
    for dp, _d, files in os.walk(a.card):
        for f in files:
            full = os.path.join(dp, f)
            rel = os.path.relpath(full, a.card)
            with open(full, "rb") as fh:
                data = fh.read()
            if data[:2] == b"#!":
                if platform_ok(rel):
                    scripts[rel] = data
                continue
            e = load_elf(data)
            if e is None or e.machine != 183:                  # EM_AARCH64
                continue
            card_names[f].add(os.path.dirname(rel))
            if e.soname:
                card_names[e.soname].add(os.path.dirname(rel))
            if platform_ok(rel):
                card[rel] = e
                e.strings = data

    def bundled(rel: str, name: str) -> bool:
        """On the card where this program finds it: its pak or NextUI's lib dir."""
        root = pak_root(rel)
        return any(d == ".system/my355/lib" or d == root or d.startswith(root + "/")
                   for d in card_names.get(name, ()))

    # soname -> consumers, symbols imported, versions needed.
    users: dict[str, set[str]] = defaultdict(set)
    syms: dict[str, set[str]] = defaultdict(set)
    vneed: dict[str, set[str]] = defaultdict(set)
    missing: dict[str, set[str]] = defaultdict(set)
    unresolved: dict[str, set[str]] = defaultdict(set)
    dlopen: dict[str, set[str]] = defaultdict(set)
    paths_used: dict[str, set[str]] = defaultdict(set)
    run: dict[str, set[str]] = defaultdict(set)

    def scan_text(rel: str, data: bytes, chunks) -> None:
        for m in set(PATH_RE.findall(data)):
            p = m.decode().rstrip("./")
            if p in rpaths:
                paths_used[p].add(rel)
        if prog_re is not None:
            for c in chunks:
                for m in prog_re.finditer(c):
                    run[m.group(1).decode()].add(rel)

    for rel, e in sorted(card.items()):
        from_rootfs = [n for n in e.needed if not bundled(rel, n)]
        for n in from_rootfs:
            users[n].add(rel)
            if n not in libs:
                missing[n].add(rel)
        for sym, ver, file_ in e.imports:
            if file_ is not None:
                if file_ in from_rootfs:
                    syms[file_].add(f"{sym}@{ver}")
                    vneed[file_].add(ver)
                continue
            # Unversioned: the first rootfs library in DT_NEEDED order that defines it.
            for n in from_rootfs:
                re_ = rootfs_elf.get(n)
                if re_ is not None and sym in re_.exports:
                    syms[n].add(sym)
                    break
            else:
                if not any(bundled(rel, n) for n in e.needed):
                    unresolved[rel].add(sym)
        for m in set(SO_RE.findall(e.strings)):
            n = m.decode()
            if n not in e.needed and n in libs and not bundled(rel, n):
                dlopen[n].add(rel)
        # Only strings that read as shell commands: a space and no format noise.
        cmds = [c for c in re.findall(rb"[\x20-\x7e]{4,}", e.strings)
                if b" " in c and len(c) < 400]
        scan_text(rel, e.strings, cmds)
    for rel, data in scripts.items():
        lines = [l.split(b"#", 1)[0] for l in data.splitlines()]
        scan_text(rel, data, lines)

    mapped: set[str] = set()
    if a.maps:
        with open(a.maps, errors="replace") as fh:
            for line in fh:
                f = line.split()
                if f and f[-1].startswith("/usr/"):
                    mapped.add(os.path.basename(f[-1]))

    # The closure: what the needed rootfs libraries need in turn.
    closure, todo = set(), list(users) + list(dlopen)
    while todo:
        n = todo.pop()
        if n in closure:
            continue
        closure.add(n)
        e = rootfs_elf.get(n)
        if e is not None:
            todo += e.needed

    out = {
        "linked": {n: {"users": sorted(users[n]), "provider": origin.get(n),
                       "versions": sorted(vneed[n]), "symbols": sorted(syms[n]),
                       "mapped": n in mapped}
                   for n in sorted(users)},
        "dlopen": {n: sorted(v) for n, v in sorted(dlopen.items())},
        "closure": sorted(closure),
        "paths": {p: sorted(v) for p, v in sorted(paths_used.items())},
        "programs": {p: {"path": progs[p], "users": sorted(v)} for p, v in sorted(run.items())},
        "missing": {n: sorted(v) for n, v in sorted(missing.items())},
        "unresolved": {r: sorted(v) for r, v in sorted(unresolved.items())},
    }
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(out, fh, indent=1)

    print(f"# {len(card)} my355 ELFs, {len(scripts)} scripts\n")
    print("## Linked from the rootfs\n")
    for n, v in out["linked"].items():
        vers = ", ".join(x for x in v["versions"] if x) or "-"
        print(f"{n}  [{v['provider'] or 'MISSING'}]  {len(v['users'])} users, "
              f"{len(v['symbols'])} symbols, needs {vers}")
    print("\n## dlopen candidates (named, not linked)\n")
    for n, v in out["dlopen"].items():
        print(f"{n}  <- {', '.join(v[:4])}{' ...' if len(v) > 4 else ''}")
    print("\n## Rootfs closure of the above\n")
    print(" ".join(out["closure"]))
    print("\n## Rootfs programs run\n")
    for p, v in out["programs"].items():
        u = v["users"]
        print(f"{v['path']}  <- {', '.join(u[:3])}{' ...' if len(u) > 3 else ''}")
    print("\n## Rootfs paths named\n")
    for p, v in out["paths"].items():
        print(f"{p}  <- {', '.join(v[:3])}{' ...' if len(v) > 3 else ''}")
    if out["missing"]:
        print("\n## Linked but in no rootfs given\n")
        for n, v in out["missing"].items():
            print(f"{n}  <- {', '.join(v)}")
    if out["unresolved"]:
        print("\n## Unversioned imports no linked library defines\n")
        for r, v in out["unresolved"].items():
            print(f"{r}: {len(v)} ({', '.join(sorted(v)[:6])}{' ...' if len(v) > 6 else ''})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
