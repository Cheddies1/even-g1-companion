"""Cross-log heartbeat cadence analysis.

Parses every btsnoop_hci*.log file in this directory, identifies heartbeat
traffic by opcode (0x1f - official app, and 0x25 - our app's choice), and
reports inter-arrival time statistics per log and per leg (handle).

Output: prints a table to stdout - log | opcode | leg_handle | count | p50_ms | p95_ms | min_ms | max_ms
"""
import struct
import statistics
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
LOGS = sorted(HERE.glob("btsnoop_hci*.log"))

HEARTBEAT_OPCODES = {0x1F, 0x25}

UART_TX_UUID_LE = bytes.fromhex("9ECADC24-0EE5-A9E0-93F3-A3B5020040E6".replace("-", ""))


def parse(path: Path):
    with path.open("rb") as f:
        if f.read(8) != b"btsnoop\x00":
            return
        f.read(8)  # version + datalink
        while True:
            rec = f.read(24)
            if len(rec) < 24:
                return
            orig_len, incl_len, flags, drops, ts = struct.unpack(">IIIIQ", rec)
            payload = f.read(incl_len)
            if len(payload) < incl_len:
                return
            yield ts, flags, payload


def att_writes(records):
    """Yield (ts_us, conn_handle, att_handle, opcode_byte) for ATT writes.

    ATT Write Command = 0x52 (no response).
    ATT Write Request = 0x12.
    """
    for ts, flags, data in records:
        if not data or data[0] != 0x02:  # ACL
            continue
        body = data[1:]
        if len(body) < 4:
            continue
        handle_flags = struct.unpack("<H", body[:2])[0]
        conn_handle = handle_flags & 0x0FFF
        acl_len = struct.unpack("<H", body[2:4])[0]
        l2cap = body[4:4 + acl_len]
        if len(l2cap) < 4:
            continue
        l2cap_len = struct.unpack("<H", l2cap[:2])[0]
        cid = struct.unpack("<H", l2cap[2:4])[0]
        if cid != 0x0004:  # ATT
            continue
        att = l2cap[4:4 + l2cap_len]
        if len(att) < 4:
            continue
        att_op = att[0]
        if att_op not in (0x52, 0x12):
            continue
        att_handle = struct.unpack("<H", att[1:3])[0]
        value = att[3:]
        if not value:
            continue
        yield ts, conn_handle, att_handle, value[0], len(value)


def analyse(path: Path):
    # Bucket writes by (conn_handle, att_handle, opcode)
    series = defaultdict(list)  # (conn, att, op) -> [ts_us, ...]
    op_total = defaultdict(int)
    write_handle_count = defaultdict(int)  # (conn, att) -> count, to pick UART TX handle

    for ts, conn, att, op, vlen in att_writes(parse(path)):
        op_total[op] += 1
        write_handle_count[(conn, att)] += 1
        if op in HEARTBEAT_OPCODES:
            series[(conn, att, op)].append(ts)

    # Identify the dominant write handle per connection - that's the UART TX
    # (only useful if we want to filter heartbeats sent on non-UART handles, which
    # shouldn't happen but worth confirming)
    uart_tx_by_conn = {}
    handle_totals = defaultdict(list)  # conn -> [(count, att)]
    for (conn, att), count in write_handle_count.items():
        handle_totals[conn].append((count, att))
    for conn, lst in handle_totals.items():
        lst.sort(reverse=True)
        uart_tx_by_conn[conn] = lst[0][1] if lst else None

    rows = []
    for (conn, att, op), tss in series.items():
        if len(tss) < 3:
            continue
        tss.sort()
        deltas_ms = [(tss[i + 1] - tss[i]) / 1000.0 for i in range(len(tss) - 1)]
        # Filter out giant gaps (disconnects) - anything > 60s is not heartbeat cadence
        clean = [d for d in deltas_ms if d < 60_000]
        if len(clean) < 3:
            continue
        rows.append({
            "log": path.name,
            "conn": conn,
            "att": att,
            "is_uart_tx": uart_tx_by_conn.get(conn) == att,
            "opcode": f"0x{op:02x}",
            "count": len(tss),
            "deltas": clean,
            "p50_ms": statistics.median(clean),
            "p95_ms": statistics.quantiles(clean, n=20)[-1] if len(clean) >= 20 else max(clean),
            "min_ms": min(clean),
            "max_ms": max(clean),
        })
    return rows, op_total


def main():
    print(f"{'log':<32} {'opcode':>6} {'conn':>5} {'att':>5} {'uart_tx':>8} {'count':>7} {'p50_ms':>9} {'p95_ms':>9} {'min_ms':>9} {'max_ms':>9}")
    print("-" * 110)
    grand = defaultdict(list)
    for log in LOGS:
        rows, op_total = analyse(log)
        # Sort by op then count desc
        rows.sort(key=lambda r: (r["opcode"], -r["count"]))
        for r in rows:
            print(f"{r['log']:<32} {r['opcode']:>6} {r['conn']:>5} {r['att']:>5} {str(r['is_uart_tx']):>8} {r['count']:>7d} {r['p50_ms']:>9.0f} {r['p95_ms']:>9.0f} {r['min_ms']:>9.0f} {r['max_ms']:>9.0f}")
            if r["is_uart_tx"]:
                grand[r["opcode"]].extend(r["deltas"])
        # Also print totals for context
        op_summary = ", ".join(f"0x{op:02x}={n}" for op, n in sorted(op_total.items(), key=lambda x: -x[1])[:6])
        print(f"  {log.name} top opcodes (any handle): {op_summary}")
    print("-" * 110)
    print("CROSS-LOG AGGREGATE (UART TX only):")
    for op, deltas in grand.items():
        if len(deltas) < 3:
            continue
        deltas.sort()
        p50 = statistics.median(deltas)
        p95 = statistics.quantiles(deltas, n=20)[-1] if len(deltas) >= 20 else max(deltas)
        print(f"  {op}: n={len(deltas)}, p50={p50:.0f}ms, p95={p95:.0f}ms, min={min(deltas):.0f}ms, max={max(deltas):.0f}ms")


if __name__ == "__main__":
    main()
