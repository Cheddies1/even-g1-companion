"""Deep-dive on official-app heartbeat payloads and surrounding behaviour.

Goes beyond cadence:
- Full payload of 0x1f and 0x25 writes (sub-types, counters, length, hex)
- ACK / notification correlation - looking for any RX packets right after each heartbeat
- Inter-leg timing - are the two legs in lock-step or offset?
- Are heartbeats suspended during any specific TX windows (e.g. 0x52 streaming, 0x0a nav)?
"""
import struct
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).parent
LOGS = sorted(HERE.glob("btsnoop_hci_*.log"))


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
            direction = "rx" if (flags & 1) else "tx"
            yield ts, direction, payload


def att_pdus(path):
    """Yield (ts, direction, conn_handle, att_handle, att_op, value_bytes)."""
    for ts, direction, data in parse(path):
        if not data or data[0] != 0x02:
            continue
        body = data[1:]
        if len(body) < 4:
            continue
        handle_flags = struct.unpack("<H", body[:2])[0]
        conn = handle_flags & 0x0FFF
        acl_len = struct.unpack("<H", body[2:4])[0]
        l2cap = body[4:4 + acl_len]
        if len(l2cap) < 4:
            continue
        cid = struct.unpack("<H", l2cap[2:4])[0]
        if cid != 0x0004:
            continue
        l2cap_len = struct.unpack("<H", l2cap[:2])[0]
        att = l2cap[4:4 + l2cap_len]
        if len(att) < 1:
            continue
        att_op = att[0]
        # Writes (TX): 0x52 (cmd) or 0x12 (req) - 1 byte op + 2 byte handle + value
        # Notifications (RX): 0x1B (handle value notif) - 1 byte op + 2 byte handle + value
        # Indications (RX): 0x1D - same shape
        # Write resp (RX): 0x13 - 1 byte op only
        # Error (RX): 0x01 - opcode + handle + error code
        if att_op in (0x52, 0x12, 0x1B, 0x1D):
            if len(att) < 4:
                continue
            att_handle = struct.unpack("<H", att[1:3])[0]
            yield ts, direction, conn, att_handle, att_op, att[3:]


def analyse_payloads(path, hb_op):
    """Examine payload shapes for one heartbeat opcode across this log."""
    pdus = list(att_pdus(path))
    hb_writes = [(ts, direction, conn, att, value) for ts, direction, conn, att, att_op, value in pdus
                 if direction == "tx" and att_op in (0x52, 0x12) and value and value[0] == hb_op]
    if not hb_writes:
        return None

    # Group by payload length
    by_len = Counter()
    samples_by_len = defaultdict(list)
    for _, _, _, _, value in hb_writes:
        by_len[len(value)] += 1
        if len(samples_by_len[len(value)]) < 6:
            samples_by_len[len(value)].append(value.hex())

    # If 0x1f, look at sub-byte distribution (second byte after opcode)
    sub_counts = Counter()
    counter_positions = []  # potential counter bytes
    if hb_op in (0x1F, 0x25):
        for _, _, _, _, value in hb_writes:
            if len(value) >= 2:
                sub_counts[value[1]] += 1
            if len(value) >= 4:
                counter_positions.append(value[2:4].hex())

    # ACK / response detection: any RX packet within 200ms of each heartbeat write
    rx_times_by_conn = defaultdict(list)
    for ts, direction, conn, att, att_op, value in pdus:
        if direction == "rx" and att_op in (0x1B, 0x1D):
            rx_times_by_conn[conn].append((ts, att, att_op, value))
    ack_observed = 0
    ack_samples = []
    for ts, _, conn, _, _ in hb_writes:
        rxs = rx_times_by_conn.get(conn, [])
        # Binary search for nearest later RX within 500ms
        for rts, ratt, rop, rval in rxs:
            if 0 < rts - ts < 500_000:
                ack_observed += 1
                if len(ack_samples) < 4:
                    ack_samples.append((rts - ts, rval.hex()))
                break

    # Inter-leg offset: take first heartbeat on each connection, compare
    per_conn_first = {}
    for ts, _, conn, _, _ in hb_writes:
        per_conn_first.setdefault(conn, ts)
    legs = sorted(per_conn_first.values())
    inter_leg_offset_ms = None
    if len(legs) >= 2:
        inter_leg_offset_ms = (legs[1] - legs[0]) / 1000.0

    return {
        "total_writes": len(hb_writes),
        "by_len": dict(by_len),
        "len_samples": dict(samples_by_len),
        "sub_distribution": dict(sub_counts),
        "counter_samples": counter_positions[:20],
        "ack_count_within_500ms": ack_observed,
        "ack_samples": ack_samples,
        "inter_leg_first_offset_ms": inter_leg_offset_ms,
    }


def main():
    for log in LOGS:
        print(f"\n=== {log.name} ===")
        for op in (0x1F, 0x25):
            r = analyse_payloads(log, op)
            if r is None:
                continue
            print(f"\n  0x{op:02x} heartbeats: {r['total_writes']} total writes")
            print(f"    payload lengths (byte count): {r['by_len']}")
            for ln, samples in sorted(r['len_samples'].items()):
                print(f"    length {ln} sample payloads (first {len(samples)}):")
                for s in samples:
                    print(f"      {s}")
            if r['sub_distribution']:
                top = sorted(r['sub_distribution'].items(), key=lambda x: -x[1])[:8]
                print(f"    second-byte distribution (top 8): {[(f'0x{k:02x}', v) for k,v in top]}")
            if r['counter_samples']:
                print(f"    bytes [2:4] across first 20 writes: {r['counter_samples']}")
            print(f"    ACKs/notifications within 500ms after a heartbeat: {r['ack_count_within_500ms']} / {r['total_writes']}")
            for delta_us, hexv in r['ack_samples']:
                print(f"      sample ACK: +{delta_us/1000:.1f}ms  payload={hexv}")
            if r['inter_leg_first_offset_ms'] is not None:
                print(f"    first heartbeat per leg, inter-leg offset: {r['inter_leg_first_offset_ms']:.0f} ms")


if __name__ == "__main__":
    main()
