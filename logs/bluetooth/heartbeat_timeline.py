"""Timeline analysis of heartbeat opcodes within each btsnoop capture.

Confirms whether 0x1f@2s and 0x25@8s coexist in the same official-app capture,
indicating a phase transition (e.g. pairing/handshake vs steady state).
"""
import struct
import datetime
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
LOGS = sorted(HERE.glob("btsnoop_hci_*.log"))
BTSNOOP_EPOCH_US = 62168256000 * 1_000_000


def ts_iso(ts_us):
    unix_us = ts_us - BTSNOOP_EPOCH_US
    return datetime.datetime.utcfromtimestamp(unix_us / 1_000_000).isoformat(timespec="seconds")


def parse(path):
    with path.open("rb") as f:
        if f.read(8) != b"btsnoop\x00":
            return
        f.read(8)
        while True:
            rec = f.read(24)
            if len(rec) < 24:
                return
            orig_len, incl_len, flags, drops, ts = struct.unpack(">IIIIQ", rec)
            payload = f.read(incl_len)
            if len(payload) < incl_len:
                return
            yield ts, payload


def att_writes(path):
    for ts, data in parse(path):
        if not data or data[0] != 0x02:
            continue
        body = data[1:]
        if len(body) < 4:
            continue
        acl_len = struct.unpack("<H", body[2:4])[0]
        l2cap = body[4:4 + acl_len]
        if len(l2cap) < 4:
            continue
        cid = struct.unpack("<H", l2cap[2:4])[0]
        if cid != 0x0004:
            continue
        l2cap_len = struct.unpack("<H", l2cap[:2])[0]
        att = l2cap[4:4 + l2cap_len]
        if len(att) < 4 or att[0] not in (0x52, 0x12):
            continue
        att_handle = struct.unpack("<H", att[1:3])[0]
        value = att[3:]
        if not value:
            continue
        yield ts, att_handle, value[0]


def analyse(path):
    # All 0x1f and 0x25 events, in time order
    events = []
    for ts, att, op in att_writes(path):
        if op in (0x1F, 0x25):
            events.append((ts, att, op))
    if not events:
        print(f"\n{path.name}: no 0x1f or 0x25 writes")
        return

    events.sort()
    t0 = events[0][0]
    print(f"\n{path.name}")
    print(f"  capture spans: {ts_iso(events[0][0])}  -  {ts_iso(events[-1][0])}")
    print(f"  total 0x1f writes: {sum(1 for _,_,o in events if o == 0x1F)}")
    print(f"  total 0x25 writes: {sum(1 for _,_,o in events if o == 0x25)}")

    # Bucketed timeline - 30-second windows showing which opcode is active
    print(f"\n  Timeline (30s buckets - which opcode dominated, count per leg):")
    BUCKET_S = 30
    buckets = defaultdict(lambda: defaultdict(int))  # bucket_idx -> {(op, att) -> count}
    end_idx = (events[-1][0] - t0) // (BUCKET_S * 1_000_000)
    for ts, att, op in events:
        idx = (ts - t0) // (BUCKET_S * 1_000_000)
        buckets[idx][(op, att)] += 1
    for idx in range(int(end_idx) + 1):
        bucket = buckets.get(idx, {})
        wall_start = t0 + idx * BUCKET_S * 1_000_000
        wall = ts_iso(wall_start)
        if not bucket:
            print(f"    {wall}  -  (none)")
            continue
        parts = []
        for (op, att), n in sorted(bucket.items()):
            parts.append(f"0x{op:02x}@h{att}={n}")
        print(f"    {wall}  -  {', '.join(parts)}")


def main():
    for log in LOGS:
        analyse(log)


if __name__ == "__main__":
    main()
