#!/usr/bin/env python3
"""Worked examples (numbers come from the golden model, not typed by hand)."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from qme_model import *

def fresh():
    dram = {}
    for a in range(PROFILE_BASE, PROFILE_BASE + 64 * 16, 16): dram[a] = 0
    for t in range(4): dram[ctx_addr(t)] = 0
    for i in range(12): dram[PAIR_BASE + 16 * i] = 0
    return dram

def hexw(v): return "%032x" % v

print("=" * 70); print("Example 1: Build Team (team 0)"); print("=" * 70)
d = fresh()
prof = [  # (A, D, S, E) for PlayerID 0..15
 (30000, 9000, 8000, 0), (52000, 7000, 6000, 0), (48000, 5000, 4500, 0), (47000, 4100, 5000, 0),
 (46000, 4096, 9000, 0), (45000, 3000, 7000, 0), (44000, 60000, 40000, 0), (43000, 20000, 61000, 0),
 (42000, 30000, 12000, 0), (41000, 25000, 11000, 0), (4000, 4097, 4096, 0), (4095, 12000, 4095, 0),
 (3000, 2000, 1000, 0), (6000, 18000, 5000, 0), (7000, 15000, 3000, 0), (8000, 16000, 2000, 0)]
for i, p in enumerate(prof): d[prof_addr(0, i)] = pack_prof(*p)
QD = [i for i, p in enumerate(prof) if p[1] >= 4096]; QS = [i for i, p in enumerate(prof) if p[2] >= 4096]
QA = [i for i, p in enumerate(prof) if p[0] >= 4096]
print("QD (Defense>=4096):", QD); print("QS (Speed>=4096):  ", QS); print("QA (Attack>=4096): ", QA)
ids = select_roster(prof)
r = build_team(d, 0)
print("Keeper=%d (Defense %d)  Seeker=%d (Speed %d)  [pair with largest D[K]+S[S], K!=S]" % (ids[0], prof[ids[0]][1], ids[6], prof[ids[6]][2]))
print("Beaters=%s  Chasers=%s" % (ids[4:6], ids[1:4]))
print("Team Context beat written to 0x%X : %s  (warn=%d complete=%d)" % (ctx_addr(0), hexw(r.info), r.warn, r.complete))
print("AXI: 4 reads (AR_LEN=3) at", ["0x%X" % a for a in r.reads], " 1 write at", ["0x%X" % a for a in r.writes])

print(); print("=" * 70); print("Example 2: Training (team 0, slot 1 = Chaser0, type B, mode Hard)"); print("=" * 70)
pid = unpack_ctx(d[ctx_addr(0)])[1]
d[prof_addr(0, pid)] = pack_prof(1000, 20000, 5000, 20000)
print("Player %d before (A,D,S,E) = %s" % (pid, unpack_prof(d[prof_addr(0, pid)])))
print("type B: sorted values q0<=q1<=q2 = 1000 <= 5000 <= 20000 -> D(lowest)=q1-q0=4000 (Attack), D(middle)=q2-q1=15000 (Speed), D(highest)=0 (Defense)")
print("mode Hard (Exp_needed 16384, Exp=20000 ok): delta_final = delta + floor(delta/4): Attack 4000+1000=5000, Speed 15000+3750=18750")
r = training(d, 0, 1, 1, 2)
print("after =", unpack_prof(d[prof_addr(0, pid)]), " warn=%d complete=%d" % (r.warn, r.complete))
print("AXI: read ctx 0x%X then profile 0x%X, write profile 0x%X" % (r.reads[0], r.reads[1], r.writes[0]))
d[prof_addr(0, pid)] = pack_prof(1000, 20000, 5000, 3000)
r = training(d, 0, 1, 1, 2)
print("with Exp=3000 < 16384: warn=%d (Exp_Warn=5) complete=%d out_info=%d, nothing written" % (r.warn, r.complete, r.info))
r = training(d, 0, 7, 0, 0); print("slot=7: warn=%d (Option_Warn=4), no AXI traffic at all: reads=%s" % (r.warn, r.reads))

print(); print("=" * 70); print("Example 3: Match = the example of the spec (3/1, Home 0 vs Away 1)"); print("=" * 70)
d = fresh()
d[ctx_addr(0)] = pack_ctx([0, 1, 2, 3, 4, 5, 6]); d[ctx_addr(1)] = pack_ctx([0, 1, 2, 3, 4, 5, 6])
H = [(0, 50000, 0, 0), (40000, 0, 0, 0), (40000, 0, 0, 0), (40000, 0, 0, 0), (0, 50000, 0, 0), (0, 50000, 0, 0), (0, 0, 50000, 0)]
A = [(0, 30000, 0, 0), (20000, 0, 0, 0), (20000, 0, 0, 0), (20000, 0, 0, 0), (0, 30000, 30000, 0), (0, 30000, 20000, 0), (0, 0, 60000, 0)]
for i in range(7):
    d[prof_addr(0, i)] = pack_prof(*H[i]); d[prof_addr(1, i)] = pack_prof(*A[i])
r = match(d, 3, 1, 0, 1); e = r.extra
print("TeamAttack H=%d  TeamDefense H=%d | TeamAttack A=%d TeamDefense A=%d" % (e["taH"], e["tdH"], e["taA"], e["tdA"]))
print("Goals_Home=%d Goals_Away=%d -> %d : %d before the Snitch" % (e["gH"], e["gA"], e["gH"] * 10, e["gA"] * 10))
print("DOY=60 seed s0=%d seed=%d  r1=%d  Interference=%d  Catch_Home=%s ; r2=%d Catch_Away=%s" % (60 ^ 0 ^ 4, e["seed"], e["r1"], e["interf"], e["catchH"], e["r2"], e["catchA"]))
print("Result=%d (1 = Away wins)  ScoreHome=%d ScoreAway=%d -> Pair Record index %d @0x%X = %s" % (e["res"], e["sH"], e["sA"], pair_index(0, 1), pair_addr(0, 1), hexw(r.info)))
print("Winner (Away) players +2048, loser (Home) players -2048; Saturation_Warn=%s (warn=%d, complete=%d)" % (r.warn == 7, r.warn, r.complete))
print("player H0 (K) before/after:", (0, 50000, 0, 0), "->", unpack_prof(d[prof_addr(0, 0)]), "  (Attack 0-2048 clamps to 0 => Saturation_Warn)")
print("AXI: 2 ctx reads + 14 profile reads (Home slot0..6, Away slot0..6), 14 profile writes (same order) + 1 Pair Record write")

print(); print("=" * 70); print("Example 4: Query (today 3/27, Home 0, Away 1)  record written 12/26"); print("=" * 70)
d[pair_addr(0, 1)] = pack_pair(1, 12, 26, 80, 160)
for (m_, dd_) in [(1, 5), (3, 26), (3, 27)]:
    r = query(d, m_, dd_, 0, 1)
    print("today %2d/%2d: DeltaDays=%3d -> warn=%d complete=%d out_info=%s" % (m_, dd_, (doy(m_, dd_) - doy(12, 26)) % 365, r.warn, r.complete, hexw(r.info)))
