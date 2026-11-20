"""Replay cmd.txt on dram.dat with the golden model; print details of selected commands. usage: replay.py patdir idx..."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from qme_model import *

def load_dram(path):
    mem = {}
    addr = None
    for line in open(path):
        line = line.strip()
        if line.startswith('@'):
            addr = int(line[1:], 16)
        elif line:
            for b in line.split():
                mem[addr] = int(b, 16); addr += 1
    dram = {}
    for a in sorted({k & ~0xF for k in mem}):
        v = 0
        for i in range(16):
            v |= mem.get(a + i, 0) << (8 * i)
        dram[a] = v
    return dram

def run(patdir, show):
    dram = load_dram(os.path.join(patdir, 'dram.dat'))
    for i, line in enumerate(open(os.path.join(patdir, 'cmd.txt'))):
        act, date, t1, t2, opt = line.split()
        act, date, t1, t2, opt = int(act), int(date, 16), int(t1), int(t2), int(opt, 16)
        m, d = date >> 5, date & 31
        if i in show:
            if act == 1:
                pid = unpack_ctx(dram[ctx_addr(t1)])[(opt >> 4) & 7] if (opt >> 4) & 7 < 7 else None
                print("cmd#%d TRAIN team%d slot%d type%d mode%d" % (i, t1, (opt >> 4) & 7, (opt >> 2) & 3, opt & 3),
                      "profile(A,D,S,E)=", unpack_prof(dram[prof_addr(t1, pid)]) if pid is not None else None)
            elif act == 2:
                print("cmd#%d MATCH %d/%d home%d away%d ctxH=%s ctxA=%s" % (i, m, d, t1, t2, unpack_ctx(dram[ctx_addr(t1)]), unpack_ctx(dram[ctx_addr(t2)])))
            else:
                print("cmd#%d act%d" % (i, act), line.strip())
        if act == 0: r = build_team(dram, t1)
        elif act == 1: r = training(dram, t1, (opt >> 4) & 7, (opt >> 2) & 3, opt & 3)
        elif act == 2: r = match(dram, m, d, t1, t2)
        else: r = query(dram, m, d, t1, t2)
        if i in show:
            print("   -> complete=%d warn=%d info=%032x" % (r.complete, r.warn, r.info), {k: v for k, v in r.extra.items()})
    return dram

if __name__ == "__main__":
    run(sys.argv[1], set(int(x) for x in sys.argv[2:]))
