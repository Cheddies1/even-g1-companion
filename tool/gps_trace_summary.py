#!/usr/bin/env python3
"""Summarise a GpsTraceService CSV for gate C (navigate-v1 plan, phase 3).

Pull a trace first:
  adb shell ls /sdcard/Android/data/com.eddie.evencompanion/files/gps/
  adb pull /sdcard/Android/data/com.eddie.evencompanion/files/gps/<trace>.csv logs/gps/

Usage: tool/gps_trace_summary.py <trace.csv> [--gap-ms 2000]
"""
import argparse
import csv
import statistics
import sys


def pct(values, p):
    if not values:
        return float("nan")
    s = sorted(values)
    k = min(len(s) - 1, max(0, round(p / 100 * (len(s) - 1))))
    return s[k]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--gap-ms", type=int, default=2000, help="interval counted as a gap")
    args = ap.parse_args()

    with open(args.trace, newline="") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        sys.exit("empty trace")

    fixes = [r for r in rows if r["kind"] == "fix"]
    events = [r for r in rows if r["kind"] != "fix"]
    t = [int(r["t_ms"]) for r in fixes]
    intervals = [b - a for a, b in zip(t, t[1:])]
    gaps = [(t[i], d) for i, d in enumerate(intervals) if d > args.gap_ms]
    acc = [float(r["acc_m"]) for r in fixes if r["acc_m"]]
    span_ms = int(rows[-1]["t_ms"]) - int(rows[0]["t_ms"])
    b0, b1 = int(rows[0]["battery_pct"]), int(rows[-1]["battery_pct"])
    hours = span_ms / 3_600_000

    print(f"trace          {args.trace}")
    print(f"span           {span_ms / 60000:.1f} min, {len(fixes)} fixes "
          f"({len(fixes) / max(span_ms / 1000, 1):.2f}/s)")
    if fixes:
        print(f"first fix      {t[0] / 1000:.1f} s after start")
    if intervals:
        print(f"interval ms    p50 {pct(intervals, 50)}  p95 {pct(intervals, 95)}  "
              f"p99 {pct(intervals, 99)}  max {max(intervals)}")
    print(f"gaps >{args.gap_ms} ms  {len(gaps)}, total {sum(d for _, d in gaps) / 1000:.1f} s")
    for at, d in sorted(gaps, key=lambda g: -g[1])[:10]:
        print(f"  at {at / 60000:6.1f} min  {d / 1000:6.1f} s")
    if acc:
        print(f"accuracy m     p50 {pct(acc, 50):.1f}  p95 {pct(acc, 95):.1f}  "
              f"max {max(acc):.1f}  mean {statistics.mean(acc):.1f}")
    print(f"battery        {b0}% -> {b1}%  ({(b0 - b1) / hours:.1f} %/h)" if hours else "")
    screen_off = sum(1 for r in fixes if r["screen"] == "off")
    doze = sum(1 for r in fixes if r["idle"] == "doze")
    print(f"screen off     {screen_off}/{len(fixes)} fixes; doze {doze}")
    providers = sorted({r["provider"] for r in fixes})
    print(f"providers      {', '.join(providers)}")
    for e in events:
        print(f"event          {int(e['t_ms']) / 1000:8.1f} s  {e['kind']}  {e['note']}")
    if rows[-1]["kind"] != "stop":
        print("WARNING        no stop row - service killed or still running")


if __name__ == "__main__":
    main()
