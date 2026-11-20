#!/usr/bin/env python3
"""Replay generated patterns with the golden model and count which corner cases were exercised.
usage: coverage.py <patdir>..."""
import sys, os, collections
sys.path.insert(0, os.path.dirname(__file__))
from qme_model import *
from replay import load_dram

cov = collections.Counter()

def build_cov(dram, team):
    profs = [unpack_prof(dram[prof_addr(team, i)]) for i in range(16)]
    QD = [i for i in range(16) if profs[i][1] >= 4096]
    QS = [i for i in range(16) if profs[i][2] >= 4096]
    QA = [i for i in range(16) if profs[i][0] >= 4096]
    cov["build.qd_count_lt4"] += len(QD) < 4
    cov["build.qs_count_lt2"] += len(QS) < 2
    cov["build.qa_count_lt7"] += len(QA) < 7
    if QD and QS:
        ks = sorted(QD, key=lambda i: (-profs[i][1], i))
        ss = sorted(QS, key=lambda i: (-profs[i][2], i))
        if ks[0] == ss[0]:
            cov["build.Kstar==Sstar"] += 1
            if len(ks) > 1 and len(ss) > 1:
                t1 = profs[ks[0]][1] + profs[ss[1]][2]
                t2 = profs[ks[1]][1] + profs[ss[0]][2]
                cov["build.opt1_better"] += t1 > t2
                cov["build.opt2_better"] += t2 > t1
                if t1 == t2:
                    cov["build.opt_tie"] += 1
                    cov["build.opt_tie_K0<K1"] += ks[0] < ks[1]
                    cov["build.opt_tie_K0>K1"] += ks[0] > ks[1]
            else:
                cov["build.Kstar==Sstar_one_option_only"] += 1
        # ties inside the lists
        cov["build.tie_in_QD_top"] += len(ks) > 1 and profs[ks[0]][1] == profs[ks[1]][1]
        cov["build.tie_in_QS_top"] += len(ss) > 1 and profs[ss[0]][2] == profs[ss[1]][2]
    cs = sorted(QA, key=lambda i: (-profs[i][0], i))
    cov["build.tie_in_QA_top3"] += any(profs[cs[j]][0] == profs[cs[j + 1]][0] for j in range(min(3, len(cs) - 1)))
    ids = select_roster(profs)
    if ids:
        cov["build.ok"] += 1
        K, S = ids[0], ids[6]
        B = ids[4:6]
        cov["build.chaser_skips_chosen"] += any(c in (K, S, *B) for c in cs[:3])
        cov["build.S_in_QD"] += S in QD
    else:
        cov["build.roster_warn"] += 1
        cov["build.roster_warn.no_KS"] += not (QD and QS and (len(set(QD) | set(QS)) > 1 or (QD and QS and QD != QS)))

for pd in sys.argv[1:]:
    dram = load_dram(os.path.join(pd, 'dram.dat'))
    for line in open(os.path.join(pd, 'cmd.txt')):
        act, date, t1, t2, opt = line.split()
        act, date, t1, t2, opt = int(act), int(date, 16), int(t1), int(t2), int(opt, 16)
        m, d = date >> 5, date & 31
        if act == 0:
            build_cov(dram, t1)
            r = build_team(dram, t1)
        elif act == 1:
            slot, ty, mo = (opt >> 4) & 7, (opt >> 2) & 3, opt & 3
            r = training(dram, t1, slot, ty, mo)
            cov["train.type%d.mode%d" % (ty, mo)] += 1
            cov["train.warn%d" % r.warn] += 1
            if r.warn in (0, 7):
                a, dd, s, e = unpack_prof(dram[prof_addr(t1, unpack_ctx(dram[ctx_addr(t1)])[slot])]) if False else (0, 0, 0, 0)
        elif act == 2:
            r = match(dram, m, d, t1, t2)
            cov["match.warn%d" % r.warn] += 1
            if r.complete:
                e = r.extra
                cov["match.res%d" % e["res"]] += 1
                cov["match.catchH"] += e["catchH"]
                cov["match.catchA"] += e["catchA"]
                cov["match.nocatch"] += not (e["catchH"] or e["catchA"])
                cov["match.goals_H>0"] += e["gH"] > 0
                cov["match.goals_both0"] += e["gH"] == 0 and e["gA"] == 0
                cov["match.seed_zero"] += e["seed"] == 1 and ((doy(m, d) & 0xFF) ^ t1 ^ (t2 << 2)) == 0
                cov["match.catchA_after_H_miss"] += e["catchA"]
                cov["match.res_goal_vs_catch_conflict"] += (e["catchH"] and e["gH"] < e["gA"]) or (e["catchA"] and e["gA"] < e["gH"])
        else:
            r = query(dram, m, d, t1, t2)
            cov["query.warn%d" % r.warn] += 1
            if r.warn in (0, 1):
                res, mm, md, sh, sa = unpack_pair(dram[pair_addr(t1, t2)])
                dl = (doy(m, d) - doy(mm, md)) % 365
                cov["query.delta==0"] += dl == 0
                cov["query.delta==90"] += dl == 90
                cov["query.delta==91"] += dl == 91
                cov["query.wrap_year"] += doy(m, d) < doy(mm, md)
                cov["query.delta>=275"] += dl >= 275
for k in sorted(cov):
    print("%-40s %d" % (k, cov[k]))
