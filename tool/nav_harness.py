#!/usr/bin/env python3
"""Nav marker / tile harness (plan: docs/plans/navigate-v1-cartographer.md, phase 1).

Generates `0x0a` navigation batch files for the debug probe's batch mode
(BleManager.kt, `--es batch <name>`) and pushes them to the phone. Formats are
from the 1.66 firmware source (see docs/FINDINGS-nav-marker-tiles.md):

  PANORAMIC_MAP  488x136, two 1-bit layers (dim, bright) of 8296 bytes each,
                 row-major, LSB = leftmost pixel, raw (no RLE). Packets:
                 0a <len16> <seq> 03 <total16> <idx16> <flag> <=185 bytes
  MAP_OVERVIEW   136x136, two layers of 2312 bytes = 4624 raw, sent raw or
                 RLE (<count><byte> pairs). Packets:
                 0a <len16> <seq> 02 <total16> <idx16> <=185 bytes
  TRIP_STATUS    0a <len16> <seq> 01 <dir> <x16> <y16> 5 x NUL-terminated str

Usage:
  python3 tool/nav_harness.py gen            # write batch files to build/navharness
  python3 tool/nav_harness.py push           # gen + adb push to the app
  python3 tool/nav_harness.py run <name>     # broadcast one batch
  python3 tool/nav_harness.py stop
"""
import os
import subprocess
import sys

PKG = "com.eddie.evencompanion"
OUT = os.path.join(os.path.dirname(__file__), "..", "build", "navharness")
REMOTE = f"/sdcard/Android/data/{PKG}/files/probe"

PW, PH = 488, 136
OW, OH = 136, 136
CHUNK = 185

_seq = 0x20


def seq():
    global _seq
    s = _seq & 0xFF
    _seq += 1
    return s


def le16(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF])


def frame(body):
    """body starts at the seq byte position; prepend opcode + total length."""
    total = 3 + len(body)
    return bytes([0x0A]) + le16(total) + body


def init():
    return frame(bytes([seq(), 0x00, 0x01]))


def sync():
    return frame(bytes([seq(), 0x04, 0x01]))


def exit_():
    return frame(bytes([seq(), 0x05, 0x01]))


def trip(direction, x, y, t="", dist="", road="", turn="", speed=""):
    strs = b"".join(s.encode()[:23] + b"\0" for s in (t, dist, road[:63], turn, speed))
    return frame(bytes([seq(), 0x01, direction]) + le16(x) + le16(y) + strs)


# ---- bitmaps -----------------------------------------------------------------

class Layer:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = bytearray(w * h)

    def set(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = 1

    def rect(self, x0, y0, x1, y1, fill=False):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if fill or x in (x0, x1) or y in (y0, y1):
                    self.set(x, y)

    def line(self, x0, y0, x1, y1, thick=1):
        n = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(n + 1):
            x = round(x0 + (x1 - x0) * i / n)
            y = round(y0 + (y1 - y0) * i / n)
            for dx in range(thick):
                for dy in range(thick):
                    self.set(x + dx - thick // 2, y + dy - thick // 2)

    def pack(self):
        out = bytearray(self.w * self.h // 8)
        for i, p in enumerate(self.px):
            if p:
                out[i >> 3] |= 1 << (i & 7)
        return bytes(out)


def pano_grid():
    """A: dim 40 px grid; bright border, corner blocks, centre cross, x ticks."""
    dim, hi = Layer(PW, PH), Layer(PW, PH)
    for x in range(0, PW, 40):
        dim.line(x, 0, x, PH - 1)
    for y in range(0, PH, 34):
        dim.line(0, y, PW - 1, y)
    hi.rect(0, 0, PW - 1, PH - 1)
    for cx, cy in ((0, 0), (PW - 12, 0), (0, PH - 12), (PW - 12, PH - 12)):
        hi.rect(cx, cy, cx + 11, cy + 11, fill=True)
    hi.line(PW // 2 - 20, PH // 2, PW // 2 + 20, PH // 2, 3)
    hi.line(PW // 2, PH // 2 - 20, PW // 2, PH // 2 + 20, 3)
    for x in range(0, PW, 100):  # tick every 100 px along the top
        hi.line(x, 0, x, 16, 3)
    return dim.pack() + hi.pack()


def pano_route():
    """B: a plausible route: bright thick polyline over dim side streets."""
    dim, hi = Layer(PW, PH), Layer(PW, PH)
    for x in range(30, PW, 70):
        dim.line(x, 0, x + 30, PH - 1)
    for y in (20, 70, 115):
        dim.line(0, y, PW - 1, y + 10)
    pts = [(10, 120), (120, 110), (180, 60), (300, 55), (340, 20), (478, 15)]
    for a, b in zip(pts, pts[1:]):
        hi.line(*a, *b, thick=5)
    hi.rect(470, 8, 484, 22, fill=True)  # destination block
    return dim.pack() + hi.pack()


def overview_img():
    dim, hi = Layer(OW, OH), Layer(OW, OH)
    for x in range(0, OW, 17):
        dim.line(x, 0, x, OH - 1)
    hi.rect(0, 0, OW - 1, OH - 1)
    hi.line(68, 130, 68, 70, 7)
    hi.line(68, 70, 120, 30, 7)
    return dim.pack() + hi.pack()


def rle(data):
    out = bytearray()
    i = 0
    while i < len(data):
        b, n = data[i], 1
        while i + n < len(data) and data[i + n] == b and n < 255:
            n += 1
        out += bytes([n, b])
        i += n
    return bytes(out)


def overview_packets(raw):
    # The firmware treats exactly 4624 bytes as raw, anything else as RLE.
    data = min(rle(raw), raw, key=len)
    chunks = [data[i:i + CHUNK] for i in range(0, len(data), CHUNK)]
    n = len(chunks)
    return [frame(bytes([seq(), 0x02]) + le16(n) + le16(i + 1) + c) for i, c in enumerate(chunks)]


def pano_packets(raw):
    assert len(raw) == 2 * PW * PH // 8
    chunks = [raw[i:i + CHUNK] for i in range(0, len(raw), CHUNK)]
    n = len(chunks)
    return [frame(bytes([seq(), 0x03]) + le16(n) + le16(i + 1) + b"\0" + c) for i, c in enumerate(chunks)]


# ---- batch files -------------------------------------------------------------

def tx(lines, pkt, lr="B"):
    lines.append(f"{lr} {pkt.hex()}")


def pos_trip(x, y, d=2):
    return trip(d, x, y, t=f"y{y}", dist="", road=f"marker x={x} y={y}", turn="", speed=f"x{x}")


def tick(lines, x, y, d=2, ms=1000):
    tx(lines, pos_trip(x, y, d))
    tx(lines, sync(), "R")
    lines.append(f"sleep {ms}")


def send_pano(lines, raw, label, master_last=True):
    """master_last: hold the right (master) lens's final packet until the left
    has had time to finish, so the master's RUNNING transition is not pushed
    to the slave before the slave's own map is ready."""
    lines.append(f"mark pano {label} start")
    pk = pano_packets(raw)
    for p in pk[:-1]:
        tx(lines, p)
    if master_last:
        tx(lines, pk[-1], "L")
        lines.append("sleep 2000")
        tx(lines, pk[-1], "R")
    else:
        tx(lines, pk[-1])
    lines.append(f"mark pano {label} end")


def boot(name, pano):
    L = ["# clear + INIT + overview + panoramic, marker at centre"]
    # INIT does not take over a live 0x4E text surface (device, 2026-11-06)
    L.append("B 18")
    L.append("sleep 400")
    tx(L, init())
    L.append("sleep 100")
    tx(L, sync())
    tx(L, pos_trip(244, 68))
    L.append("mark overview start")
    ov = overview_packets(overview_img())
    for p in ov:
        tx(L, p)
    L.append(f"mark overview end packets={len(ov)}")
    send_pano(L, pano, name)
    tx(L, sync())
    # The slave (L) finishes its maps after the master; without a later
    # TRIP_STATUS it can stay on "route is being generated" (device, 2026-11-06).
    L.append("sleep 300")
    tx(L, pos_trip(244, 68))
    return L


def sweep():
    L = ["# 1 Hz marker sweep: corners, centre, horizontal, vertical"]
    for x, y in ((0, 0), (488, 0), (488, 136), (0, 136), (244, 68)):
        L.append(f"mark corner {x},{y}")
        tick(L, x, y)
        tick(L, x, y)
    for x in range(0, 489, 24):
        tick(L, x, 68)
    for y in range(0, 137, 8):
        tick(L, 244, y)
    L.append("mark out-of-range 489,68 (expect no marker)")
    tick(L, 489, 68)
    tick(L, 244, 68)
    return L


def fast_sweep(ms):
    L = [f"# marker sweep at {ms} ms per step"]
    for x in list(range(0, 489, 8)) + list(range(488, -1, -8)):
        tick(L, x, 68, ms=ms)
    return L


def overview_img_b():
    dim, hi = Layer(OW, OH), Layer(OW, OH)
    for y in range(0, OH, 17):
        dim.line(0, y, OW - 1, y)
    hi.rect(0, 0, OW - 1, OH - 1)
    hi.line(68, 130, 68, 60, 7)
    hi.line(68, 60, 16, 30, 7)
    hi.rect(60, 60, 76, 76, fill=True)
    return dim.pack() + hi.pack()


def overview_swaps(period, n=4):
    L = [f"# alternate overview mini-map A/B every {period} s (head level)"]
    imgs = [("B", overview_img_b()), ("A", overview_img())]
    for i in range(n):
        name, raw = imgs[i % 2]
        L.append(f"mark overview {name} #{i + 1} start")
        for p in overview_packets(raw):
            tx(L, p)
        L.append(f"mark overview {name} #{i + 1} end")
        for _ in range(period):
            tx(L, trip(4 if name == "B" else 5, 244, 68, road=f"overview {name} every {period}s", turn="50m"))
            tx(L, sync(), "R")
            L.append("sleep 1000")
    return L


def swaps(period, n=6):
    L = [f"# alternate panoramic A/B, {period} s between swaps, 1 Hz marker in between"]
    imgs = [("grid", pano_grid()), ("route", pano_route())]
    x = 20
    for i in range(n):
        name, raw = imgs[i % 2]
        send_pano(L, raw, f"{name} #{i + 1}")
        for _ in range(period):
            x = 20 + (x + 20) % 440
            tick(L, x, 68)
    return L


def arrows():
    L = ["# built-in direction arrows 1..0x23, 2 s each (look at head level)"]
    for d in range(1, 0x24):
        L.append(f"mark dir {d} 0x{d:02x}")
        for _ in range(2):
            tx(L, trip(d, 244, 68, t="", dist="", road=f"dir {d} (0x{d:02x})", turn=f"{d}m", speed=""))
            tx(L, sync(), "R")
            L.append("sleep 1000")
    return L


def keepalive(seconds):
    L = [f"# SYNC to R every second for {seconds} s"]
    for _ in range(seconds):
        tx(L, sync(), "R")
        L.append("sleep 1000")
    return L


def gen():
    os.makedirs(OUT, exist_ok=True)
    files = {
        "boot_grid.txt": boot("grid", pano_grid()),
        "boot_route.txt": boot("route", pano_route()),
        "sweep.txt": sweep(),
        "fast500.txt": fast_sweep(500),
        "fast250.txt": fast_sweep(250),
        "swap2.txt": swaps(2),
        "swap5.txt": swaps(5),
        "swap10.txt": swaps(10),
        "arrows.txt": arrows(),
        "keep60.txt": keepalive(60),
        "exit.txt": ["B " + exit_().hex()],
        "headup.txt": ["R 050101"],
        "headdown.txt": ["R 050100"],
    }
    # Self-contained sessions: boot, test, exit. Nav dies ~19 s after the last
    # SYNC, so each test must carry its own bootstrap.
    ex = ["mark exit", "B " + exit_().hex()]
    files["t0_headup.txt"] = (boot("grid", pano_grid()) + keepalive(5)
                              + ["mark headup", "R 050101"] + keepalive(10)
                              + ["mark headdown", "R 050100"] + keepalive(5) + ex)
    files["t1_sweep.txt"] = boot("grid", pano_grid()) + sweep() + ex
    files["t2_fast.txt"] = boot("route", pano_route()) + fast_sweep(500) + fast_sweep(250) + ex
    files["t3_swap.txt"] = boot("route", pano_route()) + swaps(2, 4) + swaps(5, 3) + ex
    files["t5_ovswap.txt"] = (boot("route", pano_route()) + overview_swaps(2) + overview_swaps(5, 3)
                              + ex)
    files["t4_arrows.txt"] = boot("route", pano_route()) + arrows() + ex
    for name, lines in files.items():
        with open(os.path.join(OUT, name), "w") as f:
            f.write("\n".join(lines) + "\n")
    ov = rle(overview_img())
    print(f"wrote {len(files)} files to {os.path.normpath(OUT)}; overview RLE {len(ov)} B "
          f"({len(overview_packets(overview_img()))} pkts) vs raw 4624 B")
    return files


def adb(*args):
    return subprocess.run(["adb", *args], check=True)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "gen"
    if cmd == "gen":
        gen()
    elif cmd == "push":
        files = gen()
        adb("shell", "mkdir", "-p", REMOTE)
        adb("push", *[os.path.join(OUT, n) for n in files], REMOTE)
    elif cmd == "run":
        adb("shell", "am", "broadcast", "-p", PKG, "-a", f"{PKG}.PROBE", "--es", "batch", sys.argv[2])
    elif cmd == "stop":
        adb("shell", "am", "broadcast", "-p", PKG, "-a", f"{PKG}.PROBE", "--es", "stop", "1")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
