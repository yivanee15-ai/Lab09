#!/usr/bin/env python3
"""Pattern generator: dram.dat, cmd.txt, exp.txt, golden_dram.dat for one seed.

usage: gen_pattern.py <outdir> <seed> [ncmds] [profile_mode]
profile_mode: 0 mixed (default), 1 wide, 2 ties, 3 near-saturation, 4 mid-range, 5 thresholds
"""
import os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from qme_model import *

ACT_BUILD, ACT_TRAIN, ACT_MATCH, ACT_QUERY = range(4)


def rand_day(rng):
    m = rng.randint(1, 12)
    return m, rng.randint(1, MDAYS[m - 1])


def gen_profiles(rng, mode):
    """16 candidate profiles for one team."""
    ps = []
    style = rng.choice(["wide", "ties", "thresh", "high", "low", "mid", "mid"]) if mode == 0 else \
        {1: "wide", 2: "ties", 3: "high", 4: "mid", 5: "thresh"}[mode]
    palette = [rng.randint(0, 65535) for _ in range(4)]
    for _ in range(16):
        def val():
            if style == "wide":
                return rng.choice([rng.randint(0, 65535), rng.randint(4000, 9000), rng.randint(20000, 60000)])
            if style == "ties":
                return rng.choice(palette + [4095, 4096])
            if style == "thresh":
                return rng.choice([4095, 4096, 4097, rng.randint(4096, 7000), rng.randint(0, 4095)])
            if style == "mid":
                return rng.randint(9000, 56000)
            if style == "high":
                return rng.choice([65535, 65535 - rng.randint(0, 3000), rng.randint(50000, 65535)])
            return rng.choice([rng.randint(0, 6000), rng.randint(2000, 12000)])
        a, d, s = val(), val(), val()
        e = rng.randint(7000, 58000) if style == "mid" else rng.choice([rng.randint(0, 65535), rng.randint(0, 3000), rng.randint(16384, 65535),
                        2047, 2048, 8191, 8192, 16383, 16384])
        ps.append((a, d, s, e))
    return ps


def make_dram(rng, mode):
    dram = {}
    for t in range(4):
        # make sure initial team is buildable
        for _ in range(1000):
            ps = gen_profiles(rng, mode)
            if select_roster(ps) is not None:
                break
        else:
            raise RuntimeError("no buildable team")
        for i, p in enumerate(ps):
            dram[prof_addr(t, i)] = pack_prof(*p)
        dram[ctx_addr(t)] = pack_ctx(select_roster(ps))
    for h in range(4):
        for a in range(4):
            if h == a:
                continue
            gh, ga = rng.randint(0, 15), rng.randint(0, 15)
            catch = rng.choice([None, 0, 1])
            sh = gh * 10 + (150 if catch == 0 else 0)
            sa = ga * 10 + (150 if catch == 1 else 0)
            res = 0 if catch == 0 else 1 if catch == 1 else (0 if gh > ga else 1 if gh < ga else 2)
            m, d = rand_day(rng)
            dram[pair_addr(h, a)] = pack_pair(res, m, d, sh, sa)
    return dram


def dram_dat(dram):
    lines = []
    for addr in sorted(dram):
        v = dram[addr]
        b = [(v >> (8 * i)) & 0xFF for i in range(16)]  # b[0] = byte at addr
        for w in range(4):
            lines.append("@%X" % (addr + 4 * w))
            lines.append(" ".join("%02X" % x for x in b[4 * w:4 * w + 4]))
    return "\n".join(lines) + "\n"


def full_dump(dram):
    """golden image for all 3 regions, one beat per line: addr beat"""
    out = []
    for base, n in ((PROFILE_BASE, 64), (CTX_BASE, 4), (PAIR_BASE, 12)):
        for i in range(n):
            a = base + 16 * i
            out.append("%05X %032X" % (a, dram[a]))
    return "\n".join(out) + "\n"


def main():
    outdir, seed = sys.argv[1], int(sys.argv[2])
    ncmds = int(sys.argv[3]) if len(sys.argv) > 3 else 600
    mode = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    rng = random.Random(seed)
    os.makedirs(outdir, exist_ok=True)
    dram = make_dram(rng, mode)
    open(os.path.join(outdir, "dram.dat"), "w").write(dram_dat(dram))

    cmds, exps, stats = [], [], {}
    last_match = {}
    # directed seeds first (LFSR s0==0, DOY mod 256 etc) then random
    directed = [(ACT_MATCH, dict(month=9, day=14, home=1, away=0)),   # s0 == 0 -> seed 1
                (ACT_MATCH, dict(month=1, day=5, home=1, away=1)),    # Team_Warn
                (ACT_QUERY, dict(month=1, day=5, home=2, away=2)),
                (ACT_TRAIN, dict(team=0, slot=7, ttype=0, mode=0)),
                (ACT_TRAIN, dict(team=0, slot=0, ttype=0, mode=3))]
    for i in range(ncmds):
        if i < len(directed):
            act, kw = directed[i]
        else:
            act = rng.choices(range(4), weights=[16, 32, 32, 20])[0]
            kw = {}
        if act == ACT_BUILD:
            team = kw.get("team", rng.randint(0, 3))
            res = build_team(dram, team)
            cmd = (act, 0, 0, team, 0, 0)
        elif act == ACT_TRAIN:
            team = kw.get("team", rng.randint(0, 3))
            slot = kw.get("slot", rng.choice([0, 1, 2, 3, 4, 5, 6, 7]))
            ttype = kw.get("ttype", rng.randint(0, 3))
            mode_ = kw.get("mode", rng.choice([0, 1, 2, 3]) if rng.random() < 0.1 else rng.randint(0, 2))
            res = training(dram, team, slot, ttype, mode_)
            cmd = (act, 0, 0, team, 0, (slot << 4) | (ttype << 2) | mode_)
        else:
            if "month" in kw:
                m, d, h, a = kw["month"], kw["day"], kw["home"], kw["away"]
            else:
                h = rng.randint(0, 3)
                a = h if rng.random() < 0.06 else rng.choice([x for x in range(4) if x != h])
                if act == ACT_QUERY and rng.random() < 0.7 and (h, a) in last_match:
                    lm, ld = last_match[(h, a)]
                    off = rng.choice([0, 1, 30, 89, 90, 91, 92, 200, 364, rng.randint(0, 364)])
                    dd = (doy(lm, ld) - 1 + off) % 365 + 1
                    m = next(i for i in range(12) if CUM[i] < dd <= CUM[i + 1]) + 1
                    d = dd - CUM[m - 1]
                else:
                    m, d = rand_day(rng)
            if act == ACT_MATCH:
                res = match(dram, m, d, h, a)
                if res.complete:
                    last_match[(h, a)] = (m, d)
            else:
                res = query(dram, m, d, h, a)
            cmd = (act, (m << 5) | d, h, a, 0, 0)
        cmds.append(cmd)
        exps.append((res.complete, res.warn, res.info, res))
        k = ("act%d" % act, res.warn)
        stats[k] = stats.get(k, 0) + 1

    # cmd.txt : act date team1 team2 option(hex)
    with open(os.path.join(outdir, "cmd.txt"), "w") as f:
        for (act, date, t1, t2, _, opt) in cmds:
            if act in (ACT_BUILD, ACT_TRAIN):
                t1, t2 = t2, 0
            f.write("%d %03X %d %d %02X\n" % (act, date, t1, t2, opt))
    # exp.txt: complete warn info nR addrs.. nW addrs.. nPairW pairaddr  (profile-writes ordered)
    with open(os.path.join(outdir, "exp.txt"), "w") as f:
        for (c, w, info, r) in exps:
            pw = r.extra.get("pair_write", 0) if r.extra else 0
            wr = list(r.writes)
            f.write("%d %d %032X %d %s %d %s %d %05X\n" % (
                c, w, info, len(r.reads), " ".join("%05X" % a for a in r.reads) if r.reads else "-",
                len(wr), " ".join("%05X" % a for a in wr) if wr else "-",
                1 if pw else 0, pw))
    open(os.path.join(outdir, "golden_dram.dat"), "w").write(full_dump(dram))
    open(os.path.join(outdir, "ncmds.txt"), "w").write("%d\n" % len(cmds))
    print("seed %d: %d cmds" % (seed, len(cmds)), " ".join("%s/w%d=%d" % (k[0], k[1], v) for k, v in sorted(stats.items())))


if __name__ == "__main__":
    main()
