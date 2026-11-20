"""Golden model of the Quidditch Match Engine (Lab09).  Pure python, spec-exact.

DRAM is a dict {beat_address(16B aligned): 128-bit int}.
Each command returns a Result with the DUT-visible outputs plus the AXI
traffic that a spec-conforming design is expected to issue.
"""
from dataclasses import dataclass, field

M16 = 0xFFFF
PROFILE_BASE, CTX_BASE, PAIR_BASE = 0x10000, 0x10500, 0x10800
WARN_NONE, WARN_DATE, WARN_TEAM, WARN_ROSTER, WARN_OPTION, WARN_EXP, WARN_SAT = 0, 1, 2, 3, 4, 5, 7
MDAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
CUM = [0]
for _d in MDAYS:
    CUM.append(CUM[-1] + _d)


def doy(month, day):
    return CUM[month - 1] + day


def prof_addr(team, pid):
    return PROFILE_BASE + (team * 16 + pid) * 16


def ctx_addr(team):
    return CTX_BASE + team * 16


def pair_index(home, away):
    return home * 3 + (away if away < home else away - 1)


def pair_addr(home, away):
    return PAIR_BASE + pair_index(home, away) * 16


def pack_prof(a, d, s, e):
    return (a << 112) | (d << 96) | (s << 80) | (e << 64)


def unpack_prof(v):
    return (v >> 112) & M16, (v >> 96) & M16, (v >> 80) & M16, (v >> 64) & M16


def pack_ctx(ids):  # ids = [K, C0, C1, C2, B0, B1, S]
    v = 0
    for i, p in enumerate(ids):
        v |= p << (124 - 4 * i)
    return v


def unpack_ctx(v):
    return [(v >> (124 - 4 * i)) & 0xF for i in range(7)]


def pack_pair(result, month, day, sh, sa):
    return (result << 126) | (month << 122) | (day << 117) | (sh << 108) | (sa << 99)


def unpack_pair(v):
    return ((v >> 126) & 3, (v >> 122) & 0xF, (v >> 117) & 0x1F,
            (v >> 108) & 0x1FF, (v >> 99) & 0x1FF)


@dataclass
class Result:
    complete: int = 0
    warn: int = WARN_NONE
    info: int = 0
    reads: list = field(default_factory=list)   # expected AR beats (addr list)
    writes: list = field(default_factory=list)  # expected AW beats (addr list, in order)
    extra: dict = field(default_factory=dict)


# ---------------------------------------------------------------- build team
def select_roster(profs):
    """profs: list of 16 (A,D,S,E).  Returns list of 7 PlayerIDs or None."""
    QD = [i for i in range(16) if profs[i][1] >= 4096]
    QS = [i for i in range(16) if profs[i][2] >= 4096]
    QA = [i for i in range(16) if profs[i][0] >= 4096]
    best = None
    for k in QD:
        for s in QS:
            if k == s:
                continue
            tot = profs[k][1] + profs[s][2]
            key = (-tot, k, s)
            if best is None or key < best:
                best = key
    if best is None:
        return None
    _, K, S = best
    used = {K, S}
    bq = sorted([i for i in QD if i not in used], key=lambda i: (-profs[i][1], i))
    if len(bq) < 2:
        return None
    B = bq[:2]
    used |= set(B)
    cq = sorted([i for i in QA if i not in used], key=lambda i: (-profs[i][0], i))
    if len(cq) < 3:
        return None
    C = cq[:3]
    return [K] + C + B + [S]


def build_team(dram, team):
    r = Result()
    addrs = [PROFILE_BASE + team * 256 + 0x40 * i for i in range(4)]
    r.reads = addrs
    profs = []
    for i in range(16):
        profs.append(unpack_prof(dram[prof_addr(team, i)]))
    ids = select_roster(profs)
    if ids is None:
        r.warn, r.complete, r.info = WARN_ROSTER, 0, 0
        return r
    beat = pack_ctx(ids)
    dram[ctx_addr(team)] = beat
    r.writes = [ctx_addr(team)]
    r.complete, r.warn, r.info = 1, WARN_NONE, beat
    return r


# ------------------------------------------------------------------ training
EXP_NEED = [2048, 8192, 16384]


def training_delta(ttype, a, d, s):
    if ttype == 0:
        x = (a + d + s) // 8
        return x, x, x
    if ttype == 1:
        vals = [a, d, s]
        order = sorted(range(3), key=lambda i: (vals[i], i))  # stable: ties keep A,D,S order
        q0, q1, q2 = (vals[i] for i in order)
        dl = [0, 0, 0]
        dl[order[0]] = q1 - q0
        dl[order[1]] = q2 - q1
        dl[order[2]] = 0
        return tuple(dl)
    if ttype == 2:
        return tuple((16383 - v) if v < 16383 else 0 for v in (a, d, s))
    return tuple(min(3000 + ((65535 - v) >> 4), 5047) for v in (a, d, s))


def training(dram, team, slot, ttype, mode):
    r = Result()
    if slot == 7 or mode == 3:
        r.warn = WARN_OPTION
        return r
    ctx = dram[ctx_addr(team)]
    pid = unpack_ctx(ctx)[slot]
    r.reads = [ctx_addr(team), prof_addr(team, pid)]
    a, d, s, e = unpack_prof(dram[prof_addr(team, pid)])
    if e < EXP_NEED[mode]:
        r.warn = WARN_EXP
        return r
    da, dd, ds = training_delta(ttype, a, d, s)

    def scale(x):
        if mode == 0:
            return x - (x >> 2)
        if mode == 2:
            return x + (x >> 2)
        return x
    sat = 0
    out = []
    for v, x in zip((a, d, s), (da, dd, ds)):
        t = v + scale(x)
        if t > M16:
            t, sat = M16, 1
        out.append(t)
    beat = pack_prof(out[0], out[1], out[2], e)
    dram[prof_addr(team, pid)] = beat
    r.writes = [prof_addr(team, pid)]
    r.complete, r.info = 1, beat
    r.warn = WARN_SAT if sat else WARN_NONE
    return r


# --------------------------------------------------------------------- match
def lfsr_next(x):
    return ((x << 1) & 0xFF) | (((x >> 7) ^ (x >> 5) ^ (x >> 4) ^ (x >> 3)) & 1)


def match(dram, month, day, home, away):
    r = Result()
    if home == away:
        r.warn = WARN_TEAM
        return r
    cH, cA = unpack_ctx(dram[ctx_addr(home)]), unpack_ctx(dram[ctx_addr(away)])
    r.reads = [ctx_addr(home), ctx_addr(away)]  # order free
    addrsH = [prof_addr(home, p) for p in cH]
    addrsA = [prof_addr(away, p) for p in cA]
    r.reads += addrsH + addrsA
    PH = [unpack_prof(dram[a]) for a in addrsH]  # slot order: K,C0,C1,C2,B0,B1,S
    PA = [unpack_prof(dram[a]) for a in addrsA]

    def tv(P):
        ta = (P[1][0] + P[2][0] + P[3][0]) // 3
        td = (P[0][1] + P[4][1] + P[5][1]) // 3
        return ta, td
    taH, tdH = tv(PH)
    taA, tdA = tv(PA)
    interf = max(PA[4][2], PA[5][2]) >> 2
    gH = max(0, (taH >> 12) - (tdA >> 14))
    gA = max(0, (taA >> 12) - (tdH >> 14))
    d = doy(month, day)
    s0 = (d & 0xFF) ^ home ^ (away << 2)
    seed = 1 if s0 == 0 else s0
    r1 = lfsr_next(seed)
    catchH = ((PH[6][2] >> 1) + (r1 << 8) - interf) >= 65536
    catchA = False
    r2 = None
    if not catchH:
        r2 = lfsr_next(r1)
        catchA = ((PA[6][2] >> 1) + (r2 << 8)) >= 65536
    sH = gH * 10 + (150 if catchH else 0)
    sA = gA * 10 + (150 if catchA else 0)
    if catchH:
        res = 0
    elif catchA:
        res = 1
    else:
        res = 0 if gH > gA else (1 if gH < gA else 2)
    sat = 0

    def upd(P, delta_fn):
        nonlocal sat
        out = []
        for (a, dd, s_, e) in P:
            na, nd, ns, ne = delta_fn(a, dd, s_, e)
            out.append((na, nd, ns, ne))
        return out

    def clamp(v):
        nonlocal sat
        if v > M16:
            sat = 1
            return M16
        if v < 0:
            sat = 1
            return 0
        return v

    def up(P, delta, exp_delta):
        return [tuple(clamp(v + (delta if i < 3 else exp_delta)) for i, v in enumerate(p)) for p in P]
    if res == 0:
        NH, NA = up(PH, 2048, 2048), up(PA, -2048, -2048)
    elif res == 1:
        NH, NA = up(PH, -2048, -2048), up(PA, 2048, 2048)
    else:
        NH, NA = up(PH, -1024, 0), up(PA, -1024, 0)
    pbeat = pack_pair(res, month, day, sH, sA)
    dram[pair_addr(home, away)] = pbeat
    for a, p in zip(addrsH + addrsA, NH + NA):
        dram[a] = pack_prof(*p)
    r.writes = addrsH + addrsA            # profile order is fixed; pair record position free
    r.extra = dict(pair_write=pair_addr(home, away))
    r.complete, r.info = 1, pbeat
    r.warn = WARN_SAT if sat else WARN_NONE
    r.extra.update(dict(gH=gH, gA=gA, catchH=catchH, catchA=catchA, r1=r1, r2=r2, seed=seed,
                        interf=interf, taH=taH, tdH=tdH, taA=taA, tdA=tdA, res=res, sH=sH, sA=sA))
    return r


# --------------------------------------------------------------------- query
def query(dram, month, day, home, away):
    r = Result()
    if home == away:
        r.warn = WARN_TEAM
        return r
    r.reads = [pair_addr(home, away)]
    res, mm, md, sh, sa = unpack_pair(dram[pair_addr(home, away)])
    delta = (doy(month, day) - doy(mm, md)) % 365
    if delta > 90:
        r.warn = WARN_DATE
        return r
    r.complete = 1
    r.info = (month << 124) | (day << 119) | (mm << 115) | (md << 110) | (delta << 103) | \
             (res << 101) | (sh << 92) | (sa << 83)
    return r


if __name__ == "__main__":
    # --- spec examples ---------------------------------------------------
    assert lfsr_next(0x38) == 0x71 and lfsr_next(0x71) == 0xE2
    assert doy(3, 1) == 60
    # Table 9 example: Home catch fails, Away catches
    s0 = 60 ^ 0 ^ (1 << 2)
    assert s0 == 0x38
    r1 = lfsr_next(s0)
    assert (50000 >> 1) + (r1 << 8) - (30000 >> 2) == 46428 < 65536
    r2 = lfsr_next(r1)
    assert (60000 >> 1) + (r2 << 8) == 87856 >= 65536
    assert max(0, (40000 >> 12) - (30000 >> 14)) == 8 and max(0, (20000 >> 12) - (50000 >> 14)) == 1
    # Query example: match 12/26
    for (m, d, exp) in [((1, 5), None, 10), ((3, 26), None, 90), ((3, 27), None, 91)]:
        pass
    assert (doy(1, 5) - doy(12, 26)) % 365 == 10
    assert (doy(3, 26) - doy(12, 26)) % 365 == 90
    assert (doy(3, 27) - doy(12, 26)) % 365 == 91
    print("spec examples OK")
