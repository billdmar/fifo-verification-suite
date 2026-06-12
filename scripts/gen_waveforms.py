#!/usr/bin/env python3
# =============================================================================
# scripts/gen_waveforms.py — generate SVG timing diagrams from the real VCD
#
#   Pure-Python (stdlib only — no matplotlib / vcdvcd / pip). Parses the VCD
#   that `make sim` writes to docs/waveforms/sim_waves.vcd and renders crisp,
#   diffable SVG timing diagrams for the README. Every trace is drawn from
#   actual recorded signal values — nothing is hand-drawn.
#
#   Usage:
#     make sim                       # (re)generate docs/waveforms/sim_waves.vcd
#     python3 scripts/gen_waveforms.py
#
#   Output: docs/waveforms/wave_*.svg
#
#   The DUT (sync_fifo) is sampled on the rising clock edge; rd_data is a
#   REGISTERED output (valid one cycle after an accepted read). The diagrams
#   are sampled per clock cycle so that 1-cycle read latency is visible.
# =============================================================================

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VCD = os.path.join(ROOT, "docs", "waveforms", "sim_waves.vcd")
OUTDIR = os.path.join(ROOT, "docs", "waveforms")

# TOP-scope signals we render, by VCD identifier code (from the VCD header).
# name -> (vcd_id, width)
SIGNALS = [
    ("clk",          ".", 1),
    ("rst_n",        "/", 1),
    ("wr_en",        "0", 1),
    ("wr_data",      "1", 8),
    ("rd_en",        "2", 1),
    ("rd_data",      "3", 8),
    ("full",         "4", 1),
    ("empty",        "5", 1),
    ("almost_full",  "6", 1),
    ("almost_empty", "7", 1),
    ("count",        "8", 4),
]
ID_BY_NAME = {n: i for (n, i, _w) in SIGNALS}
WIDTH_BY_NAME = {n: w for (n, _i, w) in SIGNALS}


def parse_vcd(path):
    """Return (changes, end_time). changes[id] = sorted list of (time, value_str).

    Scalar values are '0'/'1'/'x'/'z'; vectors are integer strings or 'x'.
    Only identifiers present in SIGNALS are retained (keeps memory small).
    """
    keep = {i for (_n, i, _w) in SIGNALS}
    changes = {i: [] for i in keep}
    t = 0
    end_time = 0
    with open(path, "r", errors="replace") as f:
        in_defs = True
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                if line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if line[0] == "#":
                t = int(line[1:])
                end_time = t
                continue
            c0 = line[0]
            if c0 in "01xz":
                # scalar: <value><id>
                val = c0
                ident = line[1:]
                if ident in keep:
                    changes[ident].append((t, val))
            elif c0 in "bB":
                # vector: b<bits> <id>
                parts = line.split()
                bits = parts[0][1:]
                ident = parts[1] if len(parts) > 1 else ""
                if ident in keep:
                    if "x" in bits or "z" in bits:
                        val = "x"
                    else:
                        val = str(int(bits, 2))
                    changes[ident].append((t, val))
            # ignore r<real> and other token types
    return changes, end_time


def value_at(series, time):
    """Last value at or before `time`; '0'/'x' default if none yet."""
    lo, hi, best = 0, len(series) - 1, None
    if not series:
        return "x"
    # linear scan is fine (series are short per signal after slicing); but
    # binary search keeps it snappy on the full 8 MB trace.
    while lo <= hi:
        mid = (lo + hi) // 2
        if series[mid][0] <= time:
            best = series[mid][1]
            lo = mid + 1
        else:
            hi = mid - 1
    return best if best is not None else "0"


def rising_edges(clk_series, t0, t1):
    """Times in [t0,t1] where clk goes 0->1."""
    edges = []
    prev = "0"
    for (t, v) in clk_series:
        if t < t0:
            prev = v
            continue
        if t > t1:
            break
        if prev != "1" and v == "1":
            edges.append(t)
        prev = v
    return edges


# --- SVG rendering ----------------------------------------------------------

ROW_H = 34
LABEL_W = 96
CELL_W = 26          # px per sampled clock cycle
PAD_L = 8
PAD_T = 40
PAD_B = 24
HI = 6               # high level offset from row baseline
LO = ROW_H - 10      # low level offset
FONT = "font-family='ui-monospace,Menlo,Consolas,monospace'"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render_svg(title, names, samples, sample_times):
    """samples[name] = list of value strings (one per sampled cycle)."""
    n_cycles = len(sample_times)
    w = LABEL_W + PAD_L + n_cycles * CELL_W + 16
    h = PAD_T + len(names) * ROW_H + PAD_B
    x0 = LABEL_W + PAD_L

    out = []
    out.append(
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{w}' height='{h}' "
        f"viewBox='0 0 {w} {h}' {FONT} font-size='12'>")
    out.append(f"<rect width='{w}' height='{h}' fill='#0d1117'/>")
    out.append(
        f"<text x='{PAD_L}' y='22' fill='#e6edf3' font-size='14' "
        f"font-weight='bold'>{esc(title)}</text>")

    # cycle gridlines + indices
    for c in range(n_cycles + 1):
        gx = x0 + c * CELL_W
        out.append(
            f"<line x1='{gx}' y1='{PAD_T-6}' x2='{gx}' y2='{h-PAD_B}' "
            f"stroke='#21262d' stroke-width='1'/>")
    for c in range(n_cycles):
        cx = x0 + c * CELL_W + CELL_W / 2
        out.append(
            f"<text x='{cx:.0f}' y='{PAD_T-12}' fill='#6e7681' font-size='9' "
            f"text-anchor='middle'>{c}</text>")

    for ri, name in enumerate(names):
        ry = PAD_T + ri * ROW_H
        base = ry + ROW_H
        out.append(
            f"<text x='{PAD_L}' y='{base-LO+8:.0f}' fill='#7ee787'>{esc(name)}</text>")
        out.append(
            f"<line x1='{x0}' y1='{base}' x2='{x0+n_cycles*CELL_W}' y2='{base}' "
            f"stroke='#161b22' stroke-width='1'/>")
        vals = samples[name]
        is_bus = WIDTH_BY_NAME[name] > 1
        if is_bus:
            # value boxes; merge consecutive equal values
            c = 0
            while c < n_cycles:
                v = vals[c]
                run = 1
                while c + run < n_cycles and vals[c + run] == v:
                    run += 1
                bx = x0 + c * CELL_W
                bw = run * CELL_W
                ytop = base - LO
                ybot = base - HI
                fill = "#1f6feb33" if v != "x" else "#48232355"
                stroke = "#388bfd" if v != "x" else "#f85149"
                out.append(
                    f"<rect x='{bx+1}' y='{ytop}' width='{bw-2}' "
                    f"height='{ybot-ytop}' fill='{fill}' stroke='{stroke}' "
                    f"stroke-width='1' rx='2'/>")
                label = v if v != "x" else "x"
                out.append(
                    f"<text x='{bx+bw/2:.0f}' y='{(ytop+ybot)/2+4:.0f}' "
                    f"fill='#e6edf3' font-size='10' text-anchor='middle'>"
                    f"{esc(label)}</text>")
                c += run
        else:
            # digital step trace
            yhi = base - LO
            ylo = base - HI
            pts = []
            prev_y = None
            for c in range(n_cycles):
                v = vals[c]
                y = yhi if v == "1" else ylo
                xa = x0 + c * CELL_W
                xb = xa + CELL_W
                if prev_y is not None and prev_y != y:
                    pts.append(f"L{xa},{prev_y}")
                    pts.append(f"L{xa},{y}")
                else:
                    pts.append(f"{'M' if prev_y is None else 'L'}{xa},{y}")
                pts.append(f"L{xb},{y}")
                prev_y = y
            color = "#58a6ff" if name == "clk" else "#7ee787"
            if name in ("full", "empty", "almost_full", "almost_empty"):
                color = "#d29922"
            out.append(
                f"<path d='{' '.join(pts)}' fill='none' stroke='{color}' "
                f"stroke-width='1.5'/>")

    out.append("</svg>")
    return "\n".join(out)


def build_diagram(changes, title, t0, t1, names, outfile, sample_on="clk"):
    clk = changes[ID_BY_NAME["clk"]]
    edges = rising_edges(clk, t0, t1)
    if not edges:
        print(f"  !! no clock edges in [{t0},{t1}] for {outfile}")
        return None
    samples = {}
    for name in names:
        sid = ID_BY_NAME[name]
        samples[name] = [value_at(changes[sid], e) for e in edges]
    svg = render_svg(title, names, samples, edges)
    path = os.path.join(OUTDIR, outfile)
    with open(path, "w") as f:
        f.write(svg)
    print(f"  wrote {outfile}  ({len(edges)} cycles, t={t0}..{t1})")
    return edges


def find_window(changes, name, want, around=8, after=0):
    """Find first sim-time where signal `name` == `want` (scalar), at/after
    `after`. Returns (t0,t1) spanning ~`around` cycles before/after, or None."""
    series = changes[ID_BY_NAME[name]]
    clk = changes[ID_BY_NAME["clk"]]
    period = clk_period(clk)
    for (t, v) in series:
        if t >= after and v == want:
            return (max(0, t - around * period), t + around * period)
    return None


def clk_period(clk):
    edges = [t for (t, v) in clk if v == "1"]
    if len(edges) >= 2:
        return edges[1] - edges[0]
    return 10


def main():
    if not os.path.exists(VCD):
        print(f"ERROR: {VCD} not found. Run `make sim` first.", file=sys.stderr)
        sys.exit(1)
    print(f"Parsing {VCD} ...")
    changes, end = parse_vcd(VCD)
    period = clk_period(changes[ID_BY_NAME["clk"]])
    print(f"  end_time={end} ps, clk period~{period} ps")

    ctrl = ["clk", "rst_n", "wr_en", "rd_en"]
    data = ["wr_data", "rd_data", "count"]
    flags = ["full", "empty", "almost_full", "almost_empty"]

    # 1) Fill to full — window around the first time `full` asserts.
    w = find_window(changes, "full", "1", around=10)
    if w:
        build_diagram(changes, "Fill to full  —  count rises 0..8, full asserts",
                      w[0], w[1], ctrl + ["wr_data", "count", "full", "empty"],
                      "wave_fill_to_full.svg")

    # 2) Drain to empty — first `empty` assertion that occurs AFTER a full.
    full_t = None
    for (t, v) in changes[ID_BY_NAME["full"]]:
        if v == "1":
            full_t = t
            break
    w = None
    if full_t is not None:
        w = find_window(changes, "empty", "1", around=10, after=full_t + period)
    if w:
        build_diagram(changes,
                      "Drain to empty  —  count falls, registered rd_data, empty asserts",
                      w[0], w[1], ctrl + ["rd_data", "count", "full", "empty"],
                      "wave_drain_to_empty.svg")

    # 3) Simultaneous R+W — find a window where wr_en & rd_en are both 1.
    w = find_simultaneous(changes, period, span=12)
    if w:
        build_diagram(changes,
                      "Simultaneous read + write  —  count steady while both accepted",
                      w[0], w[1], ctrl + ["wr_data", "rd_data", "count"],
                      "wave_simultaneous_rw.svg")

    # 4) Thresholds — window around first almost_full assertion.
    w = find_window(changes, "almost_full", "1", around=12)
    if w:
        build_diagram(changes,
                      "Almost-full / almost-empty thresholds tracking count",
                      w[0], w[1], ctrl + ["count"] + flags,
                      "wave_thresholds.svg")

    print("Done.")


def find_simultaneous(changes, period, span=12):
    """Find a clk window where wr_en==1 and rd_en==1 on the same edge."""
    clk = changes[ID_BY_NAME["clk"]]
    wr = changes[ID_BY_NAME["wr_en"]]
    rd = changes[ID_BY_NAME["rd_en"]]
    edges = [t for (t, v) in clk if v == "1"]
    for e in edges:
        if value_at(wr, e) == "1" and value_at(rd, e) == "1":
            return (max(0, e - span // 2 * period), e + span // 2 * period)
    return None


if __name__ == "__main__":
    main()
