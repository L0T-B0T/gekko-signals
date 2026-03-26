#!/bin/bash
# Bond Stress Monitor v1.0 — Treasury yield curve + credit stress
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_JSON="${SCRIPT_DIR}/latest.json"

TICKERS=("SHY" "IEF" "TLT" "HYG" "LQD" "%5ETNX" "%5ETYX" "%5EFVX")
KEYS=("SHY" "IEF" "TLT" "HYG" "LQD" "TNX" "TYX" "FVX")

JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

# Fetch all tickers and build combined data file
TMPDIR_SCAN=$(mktemp -d)
for i in "${!TICKERS[@]}"; do
    curl -sL --max-time 8 -H "User-Agent: Mozilla/5.0" \
        "https://query1.finance.yahoo.com/v8/finance/chart/${TICKERS[$i]}?interval=1d&range=30d" \
        -o "${TMPDIR_SCAN}/${KEYS[$i]}.json" 2>/dev/null &
done
wait
sleep 1

# Process all data in single Python call
python3 << PYEOF
import json, os, datetime, statistics, sys

tmpdir = "$TMPDIR_SCAN"
json_mode = "$JSON_MODE" == "true"
output_file = "$OUTPUT_JSON"
keys = ["SHY","IEF","TLT","HYG","LQD","TNX","TYX","FVX"]

data = {}
for key in keys:
    fpath = os.path.join(tmpdir, f"{key}.json")
    try:
        with open(fpath) as f:
            raw = json.load(f)
        r = raw.get('chart',{}).get('result',[{}])[0]
        closes = r.get('indicators',{}).get('quote',[{}])[0].get('close',[])
        closes = [c for c in closes if c is not None]
        if len(closes) >= 2:
            current, prev, first = closes[-1], closes[-2], closes[0]
            pct_1d = ((current-prev)/prev)*100 if prev else 0
            pct_30d = ((current-first)/first)*100 if first else 0
            if len(closes) >= 6:
                rets = [(closes[i]-closes[i-1])/closes[i-1] for i in range(max(1,len(closes)-5), len(closes))]
                rv5d = statistics.stdev(rets)*(252**0.5)*100 if len(rets)>1 else 0
            else: rv5d = 0
            data[key] = {'current':round(current,4),'prev':round(prev,4),'change_1d':round(pct_1d,3),'change_30d':round(pct_30d,3),'rv5d':round(rv5d,2)}
        else:
            data[key] = {}
    except:
        data[key] = {}

# Compute stress
stress = 0; signals = []; comps = {}

tnx = data.get('TNX',{}); fvx = data.get('FVX',{})
if tnx.get('current') and fvx.get('current'):
    sp = tnx['current'] - fvx['current']
    comps['10y_5y_spread'] = round(sp,3)
    if sp < 0: stress += 25; signals.append(f'INVERTED: 10Y-5Y spread {sp:.3f}%')
    elif sp < 0.15: stress += 15; signals.append(f'FLAT: 10Y-5Y spread {sp:.3f}%')
    else: signals.append(f'NORMAL: 10Y-5Y spread {sp:.3f}%')

hyg = data.get('HYG',{}); lqd = data.get('LQD',{})
if hyg.get('change_30d') is not None and lqd.get('change_30d') is not None:
    cs = hyg['change_30d'] - lqd['change_30d']
    comps['credit_spread_30d'] = round(cs,3)
    if cs < -3: stress += 25; signals.append(f'CREDIT STRESS: HYG vs LQD {cs:.1f}% (30d)')
    elif cs < -1: stress += 10; signals.append(f'CREDIT WATCH: HYG-LQD {cs:.1f}% (30d)')
    else: signals.append(f'CREDIT OK: HYG-LQD {cs:.1f}% (30d)')

tlt = data.get('TLT',{})
if tlt.get('rv5d'):
    comps['tlt_rv5d'] = tlt['rv5d']
    if tlt['rv5d'] > 25: stress += 20; signals.append(f'HIGH RATE VOL: TLT rv5d {tlt["rv5d"]:.1f}%')
    elif tlt['rv5d'] > 15: stress += 10; signals.append(f'ELEVATED RATE VOL: TLT rv5d {tlt["rv5d"]:.1f}%')
    else: signals.append(f'NORMAL RATE VOL: TLT rv5d {tlt["rv5d"]:.1f}%')

if tlt.get('change_1d'):
    comps['tlt_1d'] = tlt['change_1d']
    if abs(tlt['change_1d']) > 1.5: stress += 15; signals.append(f'LONG-END SHOCK: TLT {tlt["change_1d"]:+.2f}%')
    elif abs(tlt['change_1d']) > 0.75: stress += 5; signals.append(f'LONG-END MOVE: TLT {tlt["change_1d"]:+.2f}%')

if tlt.get('change_1d') is not None and hyg.get('change_1d') is not None:
    ftq = tlt['change_1d'] - hyg['change_1d']
    comps['flight_to_quality'] = round(ftq,3)
    if ftq > 1.5: stress += 15; signals.append(f'FLIGHT TO QUALITY: TLT > HYG by {ftq:.2f}%')

level = 'EXTREME' if stress >= 60 else 'HIGH' if stress >= 40 else 'ELEVATED' if stress >= 20 else 'LOW'

tickers = {}
for k,v in data.items():
    if v and v.get('current'):
        tickers[k] = {'price':v['current'],'change_1d':v.get('change_1d',0),'change_30d':v.get('change_30d',0),'rv5d':v.get('rv5d',0)}

result = {'stress_score':stress,'stress_level':level,'signals':signals,'components':comps,'tickers':tickers,'timestamp':datetime.datetime.utcnow().isoformat()+'Z'}
with open(output_file, 'w') as f:
    json.dump(result, f, indent=2)

if json_mode:
    print(json.dumps(result, indent=2))
else:
    icon = {'EXTREME':'🔴','HIGH':'🟠','ELEVATED':'🟡','LOW':'🟢'}.get(level,'⚪')
    print(f'BOND STRESS: {icon} {level} ({stress}/100)')
    print()
    for sig in signals:
        p = '🔴' if any(x in sig for x in ['INVERTED','STRESS','HIGH','SHOCK','FLIGHT']) else '🟢' if any(x in sig for x in ['NORMAL','OK']) else '🟡'
        print(f'  {p} {sig}')
    print()
    for tk,td in sorted(tickers.items()):
        print(f'  {tk:5s} {td["price"]:>8.2f}  1d:{td["change_1d"]:>+6.2f}%  30d:{td["change_30d"]:>+6.2f}%  rv5d:{td["rv5d"]:>5.1f}%')
    print()
    print(f'Timestamp: {result["timestamp"]}')
PYEOF

rm -rf "$TMPDIR_SCAN"
