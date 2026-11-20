#!/usr/bin/env python3
"""Tiny static timing analysis on a yosys-written gate netlist (toy45 cells).
usage: sta.py netlist.v [top_paths]
Reports T_min implied by reg2reg, in2reg (input delay = 0.5T) and reg2out (output delay = 0.5T) paths."""
import re, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from cells import cells
src = open(sys.argv[1]).read()
TOP = int(sys.argv[2]) if len(sys.argv) > 2 else 3
CAP = 0.0017
inst = re.findall(r"^\s*(\w+_X1)\s+(\S+)\s*\((.*?)\);", src, re.S | re.M)
driver = {}      # net -> (cellname, inst, delay params)
fanout = {}
gates = []       # (inst, type, inputs[list], out)
ffs = []         # (inst, D net, Q net)
def pins(txt):
    return dict(re.findall(r"\.(\w+)\(([^)]*)\)", txt))
for typ, name, body in inst:
    p = pins(body)
    p = {k: v.strip() for k, v in p.items()}
    if typ.startswith("DFF"):
        ffs.append((name, p["D"], p["Q"]))
        fanout[p["D"]] = fanout.get(p["D"], 0) + 1
    else:
        ins = [p[k] for k in cells[typ][2]]
        gates.append((name, typ, ins, p["Y"]))
        for n in ins: fanout[n] = fanout.get(n, 0) + 1
# primary outputs / inputs
outs = set(); ins_ = set()
for m in re.finditer(r"^\s*(input|output)\s+(?:reg\s+)?(?:\[(\d+):(\d+)\]\s+)?(\w+)\s*[,;)]", src, re.M):
    kind, hi, lo, nm = m.groups()
    names = [nm] if hi is None else ["%s[%d]" % (nm, i) for i in range(int(lo), int(hi) + 1)]
    (outs if kind == "output" else ins_).update(names)
for n in outs: fanout[n] = fanout.get(n, 0) + 30   # output load ~0.05pF
import math
def gdelay(typ, out):
    area, fn, ins, d0, k = cells[typ]
    fo = fanout.get(out, 1)
    eff = CAP * min(fo, 6) + 0.002
    extra = 0.035 * math.ceil(math.log(fo / 6.0, 4)) if fo > 6 else 0.0   # buffer tree for big fanout
    return d0 + k * eff + extra
CLKQ = 0.08
SETUP = 0.03
# topological order of gates
order = []
pending = gates[:]
known = set(ins_) | {q for _, _, q in ffs}
while pending:
    nxt = []
    for g in pending:
        if all((i in known) or re.fullmatch(r"\d+'[bh][01]", i) for i in g[2]):
            order.append(g); known.add(g[3])
        else:
            nxt.append(g)
    if len(nxt) == len(pending):          # undriven nets (constants): treat as known
        for g in nxt:
            for i in g[2]: known.add(i)
    pending = nxt
def propagate(starts):
    """starts: {net: arrival}.  Returns {net: (arrival, path)} for all nets reachable from the start set."""
    A = {n: (t, [n]) for n, t in starts.items()}
    for name, typ, gi, go in order:
        best = None
        for i in gi:
            if i in A and (best is None or A[i][0] > best[0]): best = A[i]
        if best is not None:
            A[go] = (best[0] + gdelay(typ, go), best[1] + [go])
    return A
A_reg = propagate({q: CLKQ + 3.0 * (CAP * min(fanout.get(q, 1), 6) + 0.002) for _, _, q in ffs})
A_in = propagate({n: 0.0 for n in ins_ if n not in ("clk", "rst_n")})
def base(n): return re.sub(r"\[\d+\]$", "", n)
res = {"reg2reg": [], "in2reg": [], "reg2out": [], "in2out": []}
for name, d, q in ffs:
    if d in A_reg: res["reg2reg"].append((A_reg[d][0] + SETUP, base(q), A_reg[d][1]))
    if d in A_in:  res["in2reg"].append((A_in[d][0] + SETUP, base(q), A_in[d][1]))
for o in outs:
    if o in A_reg: res["reg2out"].append((A_reg[o][0], o, A_reg[o][1]))
    if o in A_in:  res["in2out"].append((A_in[o][0], o, A_in[o][1]))
tmin = {}
for k in res:
    res[k].sort(reverse=True)
    if not res[k]: tmin[k] = 0; continue
    worst = res[k][0][0]
    tmin[k] = worst if k == "reg2reg" else (2 * worst if k != "in2out" else worst)
for k in res:
    print("%-8s worst=%.3f ns -> T>=%.3f ns" % (k, res[k][0][0] if res[k] else 0, tmin[k]))
    seen = set()
    for t, end, path in res[k]:
        key = (base(path[0]), end)
        if key in seen: continue
        seen.add(key)
        print("    %.3f  %s -> %s  (levels=%d)" % (t, base(path[0]), end, len(path) - 1))
        if len(seen) >= TOP: break
print("T_min(estimate, toy45) = %.3f ns" % max(tmin.values()))
