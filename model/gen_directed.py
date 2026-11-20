#!/usr/bin/env python3
"""Directed pattern made of the worked examples (same data as model/spec_examples.py). usage: gen_directed.py <outdir>"""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from qme_model import *
from gen_pattern import dram_dat, full_dump

def fresh():
    dram = {}
    for a in range(PROFILE_BASE, PROFILE_BASE + 64 * 16, 16): dram[a] = 0
    for t in range(4): dram[ctx_addr(t)] = 0
    for i in range(12): dram[PAIR_BASE + 16 * i] = 0
    return dram

d = fresh()
# team 0 : the Build example candidates ; team 1 : the match example (ctx = identity, built by hand)
prof0 = [(30000, 9000, 8000, 0), (52000, 7000, 6000, 20000), (48000, 5000, 4500, 0), (47000, 4100, 5000, 0),
         (46000, 4096, 9000, 0), (45000, 3000, 7000, 0), (44000, 60000, 40000, 0), (43000, 20000, 61000, 0),
         (42000, 30000, 12000, 0), (41000, 25000, 11000, 0), (4000, 4097, 4096, 0), (4095, 12000, 4095, 0),
         (3000, 2000, 1000, 0), (6000, 18000, 5000, 0), (7000, 15000, 3000, 0), (8000, 16000, 2000, 0)]
for i, p in enumerate(prof0): d[prof_addr(0, i)] = pack_prof(*p)
d[ctx_addr(0)] = pack_ctx(select_roster(prof0))
H = [(0, 50000, 0, 0), (40000, 0, 0, 0), (40000, 0, 0, 0), (40000, 0, 0, 0), (0, 50000, 0, 0), (0, 50000, 0, 0), (0, 0, 50000, 0)]
A = [(0, 30000, 0, 0), (20000, 0, 0, 0), (20000, 0, 0, 0), (20000, 0, 0, 0), (0, 30000, 30000, 0), (0, 30000, 20000, 0), (0, 0, 60000, 0)]
for t, P in ((2, H), (3, A)):
    for i in range(7): d[prof_addr(t, i)] = pack_profile if False else pack_prof(*P[i])
    for i in range(7, 16): d[prof_addr(t, i)] = pack_prof(1000 + i, 1000 + i, 1000 + i, 5000)
    d[ctx_addr(t)] = pack_ctx([0, 1, 2, 3, 4, 5, 6])
for t in (1,):
    for i in range(16): d[prof_addr(t, i)] = pack_prof(10000 + 100 * i, 20000 + 10 * i, 15000 + i, 30000)
    d[ctx_addr(t)] = pack_ctx([0, 1, 2, 3, 4, 5, 6])
for h in range(4):
    for a in range(4):
        if h != a: d[pair_addr(h, a)] = pack_pair(0, 12, 26, 80, 160)
os.makedirs(sys.argv[1], exist_ok=True)
open(os.path.join(sys.argv[1], "dram.dat"), "w").write(dram_dat(d))
cmds = []  # (act, date, t1, t2, opt)
def build(t): cmds.append((0, 0, t, 0, 0))
def train(t, slot, ty, mo): cmds.append((1, 0, t, 0, (slot << 4) | (ty << 2) | mo))
def match(m, dd, h, a): cmds.append((2, (m << 5) | dd, h, a, 0))
def query(m, dd, h, a): cmds.append((3, (m << 5) | dd, h, a, 0))
build(0)                       # example 1
train(0, 1, 1, 2)              # example 2 : type B, hard
train(0, 1, 1, 2)              # same player again
train(0, 7, 0, 0)              # Option_Warn
train(0, 0, 0, 3)              # Option_Warn (mode 3)
match(3, 1, 2, 3)              # example 3 (spec example) : teams 2 vs 3
query(3, 1, 2, 3)              # read it back
query(3, 27, 2, 3); query(1, 5, 2, 3); query(1, 5, 2, 2)
match(9, 14, 1, 0)             # seed would be zero
match(4, 4, 0, 0)              # Team_Warn
for t in (0, 1, 2, 3): build(t)
exp = []
lines_c, lines_e = [], []
for (act, date, t1, t2, opt) in cmds:
    m, dd = date >> 5, date & 31
    if act == 0: r = build_team(d, t1)
    elif act == 1: r = training(d, t1, (opt >> 4) & 7, (opt >> 2) & 3, opt & 3)
    elif act == 2: r = match(d, m, dd, t1, t2) if False else __import__("qme_model").match(d, m, dd, t1, t2)
    else: r = __import__("qme_model").query(d, m, dd, t1, t2)
    a1, a2 = (t2, 0) if act in (0, 1) else (t1, t2)
    if act in (0, 1): a1, a2 = t1, 0
    lines_c.append("%d %03X %d %d %02X" % (act, date, a1, a2, opt))
    pw = r.extra.get("pair_write", 0) if r.extra else 0
    lines_e.append("%d %d %032X %d %s %d %s %d %05X" % (r.complete, r.warn, r.info, len(r.reads), " ".join("%05X" % a for a in r.reads) or "-",
                   len(r.writes), " ".join("%05X" % a for a in r.writes) or "-", 1 if pw else 0, pw))
open(os.path.join(sys.argv[1], "cmd.txt"), "w").write("\n".join(lines_c) + "\n")
open(os.path.join(sys.argv[1], "exp.txt"), "w").write("\n".join(lines_e) + "\n")
open(os.path.join(sys.argv[1], "golden_dram.dat"), "w").write(full_dump(d))
open(os.path.join(sys.argv[1], "ncmds.txt"), "w").write("%d\n" % len(cmds))
print("directed pattern:", len(cmds), "commands")
