#!/usr/bin/env python3
"""Read one Tools/compare-rails.sh run: each power source against powermetrics, and the memory levels.

    python3 Tools/compare-rails-report.py build/rails-<time>

powermetrics stamps whole seconds, so the two logs are aligned by the lag that best lines the CPU
figures up, and phases are compared with their first three seconds and last second left out."""
import sys, re, csv, datetime, collections
D = sys.argv[1]
# ── powermetrics ──
pm = []
cur = None
for line in open(D + '/powermetrics.txt', errors='replace'):
    m = re.match(r'\*\*\* Sampled system activity \((.+?) ([+-]\d{4})\) \(([\d.]+)ms elapsed\)', line)
    if m:
        t = datetime.datetime.strptime(m[1] + ' ' + m[2], '%a %b %d %H:%M:%S %Y %z').timestamp()
        cur = {'t': t, 'ms': float(m[3])}; pm.append(cur); continue
    if cur is None: continue
    for key, pat in (('cpu', r'^CPU Power: (\d+) mW'), ('gpu', r'^GPU Power: (\d+) mW'), ('ane', r'^ANE Power: (\d+) mW'),
                     ('combined', r'^Combined Power.*: (\d+) mW')):
        m = re.match(pat, line)
        if m and key not in cur: cur[key] = int(m[1]) / 1000
    m = re.match(r'^Current pressure level: (\w+)', line)
    if m: cur['thermal'] = m[1]
pm = [p for p in pm if 'cpu' in p]
rows = [r for r in csv.DictReader((l for l in open(D + '/probe.tsv') if not l.startswith('#')), delimiter='\t')]
for r in rows:
    for k in r:
        if k != 'phase': r[k] = float(r[k])
print(f"powermetrics samples {len(pm)} · probe rows {len(rows)} · thermal levels seen by powermetrics: {sorted(set(p.get('thermal','?') for p in pm))}")

# align: powermetrics stamps whole seconds at the END of its window; find the lag that best lines CPU up
def at(ts, lag):
    best = min(pm, key=lambda p: abs(p['t'] + lag - ts)); return best if abs(best['t'] + lag - ts) <= 0.75 else None
def corr(lag):
    xs, ys = [], []
    for r in rows:
        p = at(r['epoch'], lag)
        if p: xs.append(r['clpc_cpu']); ys.append(p['cpu'])
    n = len(xs); mx, my = sum(xs)/n, sum(ys)/n
    sx = sum((x-mx)**2 for x in xs) ** .5; sy = sum((y-my)**2 for y in ys) ** .5
    return sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / (sx*sy), n
lags = [l/4 for l in range(-8, 9)]
best = max(lags, key=lambda l: corr(l)[0])
print(f"best alignment lag {best:+.2f} s (correlation of CLPC CPU with powermetrics CPU {corr(best)[0]:.4f} over {corr(best)[1]} s)")
for r in rows: r['pm'] = at(r['epoch'], best)

# ── per phase, trimmed ──
seq = []
for r in rows:
    if not seq or seq[-1][0] != r['phase']: seq.append([r['phase'], []])
    seq[-1][1].append(r)
def mean(xs): return sum(xs)/len(xs) if xs else float('nan')
print("\nphase (edges trimmed)        n |  powermetrics cpu  gpu   ane  |  CLPC cpu   gpu    ane   |  EM cpu   gpu  sram   ane  dram | hist cpu")
summary = {}
for i, (ph, rs) in enumerate(seq):
    core = [r for r in rs[3:-1] if r['pm']] if len(rs) > 6 else [r for r in rs if r['pm']]
    if not core: continue
    g = lambda k: mean([r[k] for r in core]); p = lambda k: mean([r['pm'][k] for r in core])
    summary[f"{i}:{ph}"] = dict(pm_cpu=p('cpu'), pm_gpu=p('gpu'), pm_ane=p('ane'), clpc_cpu=g('clpc_cpu'), clpc_gpu=g('clpc_gpu'), clpc_ane=g('clpc_ane'),
                                em_cpu=g('em_cpu'), em_gpu=g('em_gpu'), em_sram=g('em_gpusram'), em_ane=g('em_ane'), em_dram=g('em_dram'), hist=g('hist_cpu'), n=len(core))
    s = summary[f"{i}:{ph}"]
    print(f"{i} {ph:13s} t{int(core[0]['t']):3d}-{int(core[-1]['t']):3d} {s['n']:3d} |  {s['pm_cpu']:7.2f} {s['pm_gpu']:6.2f} {s['pm_ane']:6.3f}  | {s['clpc_cpu']:7.2f} {s['clpc_gpu']:6.2f} {s['clpc_ane']:6.3f}  | {s['em_cpu']:6.2f} {s['em_gpu']:6.2f} {s['em_sram']:5.2f} {s['em_ane']:5.3f} {s['em_dram']:5.2f} | {s['hist']:7.2f}")

def pct(a, b): return f"{(a/b-1)*100:+5.1f}%" if b else "  n/a "
print("\nagainst powermetrics, per phase:")
print("phase            | CPU: CLPC      EM       hist     (abs W: CLPC, EM, hist)        | GPU: CLPC     EM      EM+SRAM | ANE: CLPC     EM")
for k, s in summary.items():
    print(f"{k:16s} | {pct(s['clpc_cpu'], s['pm_cpu'])}  {pct(s['em_cpu'], s['pm_cpu'])}  {pct(s['hist'], s['pm_cpu'])}   ({s['clpc_cpu']-s['pm_cpu']:+.2f}, {s['em_cpu']-s['pm_cpu']:+.2f}, {s['hist']-s['pm_cpu']:+.2f})"
          f"   | {pct(s['clpc_gpu'], s['pm_gpu'])} {pct(s['em_gpu'], s['pm_gpu'])} {pct(s['em_gpu']+s['em_sram'], s['pm_gpu'])}  | {pct(s['clpc_ane'], s['pm_ane'])} {pct(s['em_ane'], s['pm_ane'])}")

# ── per-second agreement ──
al = [r for r in rows if r['pm']]
def within(k_probe, k_pm, tol_abs, tol_rel):
    return sum(1 for r in al if abs(r[k_probe] - r['pm'][k_pm]) <= max(tol_abs, tol_rel * r['pm'][k_pm]))
print(f"\nper second, within max(0.15 W, 5 %) of powermetrics, of {len(al)} s:  CPU  CLPC {within('clpc_cpu','cpu',.15,.05)} · EM {within('em_cpu','cpu',.15,.05)} · hist {within('hist_cpu','cpu',.15,.05)}"
      f"   GPU  CLPC {within('clpc_gpu','gpu',.15,.05)} · EM {within('em_gpu','gpu',.15,.05)}   ANE  CLPC {within('clpc_ane','ane',.05,.05)} · EM {within('em_ane','ane',.05,.05)}")
em_live = sum(1 for r in rows if r['em_cpu'] > 0)
print(f"Energy Model CPU counter non-zero in {em_live} of {len(rows)} seconds while powermetrics ran")
worst = sorted(al, key=lambda r: -abs(r['hist_cpu'] - r['pm']['cpu']) / max(r['pm']['cpu'], .5))[:3]
print("largest histogram misses:", [(int(r['t']), r['phase'], round(r['hist_cpu'],2), round(r['pm']['cpu'],2)) for r in worst])

# ── memory ──
print("\nmemory, second by second around the simulated levels:")
prev = None
for r in rows:
    key = (int(r['mem_level']), r['phase'])
    if key != prev:
        print(f"  t={int(r['t']):3d} {r['phase']:13s} system level {int(r['mem_level'])} · {int(r['free_pct'])}% free (kern.memorystatus_level) · used ratio {r['used_ratio']:.3f} · app {r['app_gb']:.1f} GB · compressed {r['compressed_gb']:.1f} · cached {r['cached_gb']:.1f} · swap {r['swap_used_gb']:.2f} GB")
        prev = key
levels = collections.Counter(int(r['mem_level']) for r in rows)
print("  seconds at each level:", dict(levels))
sw = [r for r in rows if r['swapout_bps'] > 0 or r['swapin_bps'] > 500000]
print(f"  swap: out > 0 in {sum(1 for r in rows if r['swapout_bps'] > 0)} s; in > 0.5 MB/s in {sum(1 for r in rows if r['swapin_bps'] > 5e5)} s; peak in {max(r['swapin_bps'] for r in rows)/1e6:.2f} MB/s, out {max(r['swapout_bps'] for r in rows)/1e6:.2f} MB/s")
old = lambda r: 'hot' if r['free_pct'] < 45 else ('warm' if r['free_pct'] < 75 or r['used_ratio'] > 0.85 else 'calm')
new = {1: 'calm', 2: 'warm', 4: 'hot'}
dis = [(int(r['t']), r['phase'], old(r), new.get(int(r['mem_level']), '?')) for r in rows if old(r) != new.get(int(r['mem_level']), '?')]
print(f"  1.6.0's rule and the system level disagree in {len(dis)} of {len(rows)} s; first few: {dis[:4]}")
