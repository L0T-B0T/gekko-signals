#!/bin/bash
# Bond Stress Monitor v1.0 — Treasury yield curve + credit stress signals
# For L0T-B0T/gekko-signals suite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_JSON="${SCRIPT_DIR}/latest.json"
CLAWTALK_KEY="${CLAWTALK_API_KEY:-}"
PUSH_TO="${CLAWTALK_PUSH_TO:-Lotbot}"

TICKERS=("SHY" "IEF" "TLT" "HYG" "LQD" "%5ETNX" "%5ETYX" "%5EFVX")
KEYS=("SHY" "IEF" "TLT" "HYG" "LQD" "TNX" "TYX" "FVX")
LABELS=("2Y_Treasury" "10Y_Treasury" "20Y+_Treasury" "High_Yield" "Inv_Grade" "10Y_Yield" "30Y_Yield" "5Y_Yield")

fetch_ticker() {
    local ticker="$1"
    local url="https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?interval=1d&range=30d"
    local raw
    raw=$(curl -sL --max-time 8 -H "User-Agent: Mozilla/5.0" "$url" 2>/dev/null) || raw="{}"
    python3 << PYEOF
import json
try:
    d = json.loads(r'''$raw''')
    r = d.get('chart',{}).get('result',[{}])[0]
    closes = r.get('indicators',{}).get('quote',[{}])[0].get('close',[])
    closes = [c for c in closes if c is not None]
    if len(closes) >= 2:
        current, prev, first = closes[-1], closes[-2], closes[0]
        pct_1d = ((current-prev)/prev)*100 if prev else 0
        pct_30d = ((current-first)/first)*100 if first else 0
        import statistics
        if len(closes) >= 6:
            rets = [(closes[i]-closes[i-1])/closes[i-1] for i in range(max(1,len(closes)-5), len(closes))]
            rv5d = statistics.stdev(rets)*(252**0.5)*100 if len(rets)>1 else 0
        else: rv5d=0
        print(json.dumps({'current':round(current,4),'prev':round(prev,4),'change_1d':round(pct_1d,3),'change_30d':round(pct_30d,3),'rv5d':round(rv5d,2),'high_30d':round(max(closes),4),'low_30d':round(min(closes),4)}))
    else: print('{}')
except: print('{}')
PYEOF
}

compute_stress() {
    python3 << 'PYEOF'
import json, os, datetime
with open(os.environ.get('BOND_DATA','/tmp/bond-data.json')) as f:
    data = json.load(f)

stress = 0
signals = []
comps = {}

tnx = data.get('TNX',{})
fvx = data.get('FVX',{})
if tnx.get('current') and fvx.get('current'):
    sp = tnx['current'] - fvx['current']
    comps['10y_5y_spread'] = round(sp,3)
    if sp < 0:
        stress += 25; signals.append(f"INVERTED: 10Y-5Y spread {sp:.3f}% (recession signal)")
    elif sp < 0.15:
        stress += 15; signals.append(f"FLAT: 10Y-5Y spread {sp:.3f}% (tightening)")
    else:
        signals.append(f"NORMAL: 10Y-5Y spread {sp:.3f}%")

hyg = data.get('HYG',{})
lqd = data.get('LQD',{})
if hyg.get('change_30d') is not None and lqd.get('change_30d') is not None:
    cs = hyg['change_30d'] - lqd['change_30d']
    comps['credit_spread_30d'] = round(cs,3)
    if cs < -3: stress += 25; signals.append(f"CREDIT STRESS: HYG underperforming LQD by {abs(cs):.1f}% (30d)")
    elif cs < -1: stress += 10; signals.append(f"CREDIT WATCH: HYG-LQD divergence {cs:.1f}% (30d)")
    else: signals.append(f"CREDIT NORMAL: HYG-LQD spread {cs:.1f}% (30d)")

tlt = data.get('TLT',{})
if tlt.get('rv5d'):
    comps['tlt_rv5d'] = tlt['rv5d']
    if tlt['rv5d'] > 25: stress += 20; signals.append(f"HIGH RATE VOL: TLT rv5d {tlt['rv5d']:.1f}%")
    elif tlt['rv5d'] > 15: stress += 10; signals.append(f"ELEVATED RATE VOL: TLT rv5d {tlt['rv5d']:.1f}%")
    else: signals.append(f"NORMAL RATE VOL: TLT rv5d {tlt['rv5d']:.1f}%")

if tlt.get('change_1d'):
    comps['tlt_1d'] = tlt['change_1d']
    if abs(tlt['change_1d']) > 1.5: stress += 15; signals.append(f"LONG-END SHOCK: TLT {tlt['change_1d']:+.2f}%")
    elif abs(tlt['change_1d']) > 0.75: stress += 5; signals.append(f"LONG-END MOVE: TLT {tlt['change_1d']:+.2f}%")

if tlt.get('change_1d') is not None and hyg.get('change_1d') is not None:
    ftq = tlt['change_1d'] - hyg['change_1d']
    comps['flight_to_quality'] = round(ftq,3)
    if ftq > 1.5: stress += 15; signals.append(f"FLIGHT TO QUALITY: TLT > HYG by {ftq:.2f}%")

level = 'EXTREME' if stress >= 60 else 'HIGH' if stress >= 40 else 'ELEVATED' if stress >= 20 else 'LOW'

tickers = {}
for k,v in data.items():
    if v and v.get('current'):
        tickers[k] = {'price':v['current'],'change_1d':v.get('change_1d',0),'change_30d':v.get('change_30d',0),'rv5d':v.get('rv5d',0)}

print(json.dumps({'stress_score':stress,'stress_level':level,'signals':signals,'components':comps,'tickers':tickers,'timestamp':datetime.datetime.utcnow().isoformat()+'Z'},indent=2))
PYEOF
}

run_scan() {
    local json_mode="${1:-false}"
    local data="{"
    local first=true
    for i in "${!TICKERS[@]}"; do
        [[ "$json_mode" != "true" ]] && echo -ne "  Fetching ${LABELS[$i]}...\r" >&2
        local result
        result=$(fetch_ticker "${TICKERS[$i]}") || result="{}"
        [[ "$first" == "true" ]] && first=false || data+=","
        data+="\"${KEYS[$i]}\": ${result:-{}}"
        sleep 1
    done
    data+="}"
    echo "$data" > /tmp/bond-data.json
    export BOND_DATA="/tmp/bond-data.json"
    local stress_result
    stress_result=$(compute_stress)
    echo "$stress_result" > "$OUTPUT_JSON"
    if [[ "$json_mode" == "true" ]]; then
        echo "$stress_result"
    else
        echo "$stress_result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s,l = d['stress_score'], d['stress_level']
icon = {'EXTREME':'🔴','HIGH':'🟠','ELEVATED':'🟡','LOW':'🟢'}.get(l,'⚪')
print(f'╔══════════════════════════════════════╗')
print(f'║  BOND STRESS MONITOR — {icon} {l:<10s}  ║')
print(f'║  Score: {s}/100                       ║')
print(f'╚══════════════════════════════════════╝')
print()
for sig in d.get('signals',[]):
    p = '🔴' if any(x in sig for x in ['INVERTED','STRESS','HIGH','SHOCK','FLIGHT']) else '🟢' if 'NORMAL' in sig else '🟡'
    print(f'  {p} {sig}')
print()
for tk,td in d.get('tickers',{}).items():
    print(f'  {tk:5s} {td[\"price\"]:>8.2f}  1d:{td[\"change_1d\"]:>+6.2f}%  30d:{td[\"change_30d\"]:>+6.2f}%  rv5d:{td[\"rv5d\"]:>5.1f}%')
print()
print(f'⏰ {d[\"timestamp\"]}')
"
    fi
}

# Parse args
JSON_MODE=false
PUSH=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_MODE=true; shift ;;
        --push) PUSH=true; shift ;;
        --help|-h) echo "Usage: $0 [--json] [--push]"; exit 0 ;;
        *) shift ;;
    esac
done

run_scan "$JSON_MODE"
if [[ "$PUSH" == "true" && -n "$CLAWTALK_KEY" ]]; then
    summary=$(python3 -c "import json;d=json.load(open('$OUTPUT_JSON'));sigs=' | '.join(d.get('signals',[])[:3]);print(f'Bond Stress: {d[\"stress_level\"]} ({d[\"stress_score\"]}/100). {sigs}')")
    payload=$(python3 -c "import json;print(json.dumps({'to':'$PUSH_TO','type':'notification','topic':'bond-stress','encrypted':False,'payload':{'text':r'''$summary'''}}))")
    tmpf=$(mktemp); echo "$payload" > "$tmpf"
    curl -s -X POST "https://clawtalk.monkeymango.co/messages" -H "Authorization: Bearer $CLAWTALK_KEY" -H "Content-Type: application/json" --data-binary "@$tmpf" >/dev/null 2>&1
    rm -f "$tmpf"
fi
