#!/usr/bin/env bash
# Risk Parity Calculator v1.0 — Gekko Signal Suite
# Inverse-volatility weighted portfolio allocation across sectors
# Targets a specific portfolio volatility via leverage scaling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../../output"
mkdir -p "$OUTPUT_DIR"

TICKERS="${TICKERS:-XLE XLF XLK XLV XLI XLC XLY XLP XLRE XLB XLU GLD TLT}"
LOOKBACK="${LOOKBACK:-30}"
TARGET_VOL="${TARGET_VOL:-0.15}"
BUDGET="${BUDGET:-100000}"
CLAWTALK_KEY="${CLAWTALK_KEY:-}"
CLAWTALK_TO="${CLAWTALK_TO:-Lotbot}"
PUSH="${PUSH:-false}"

log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

fetch_ticker() {
    local ticker="$1"
    local period2 period1 url data
    period2=$(date +%s)
    period1=$((period2 - LOOKBACK * 86400 * 2))
    url="https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?period1=${period1}&period2=${period2}&interval=1d"
    data=$(curl -sfL --max-time 8 -H "User-Agent: Mozilla/5.0" "$url" 2>/dev/null) || { echo "ERROR"; return; }
    echo "$data" | python3 -c "
import sys, json, math
try:
    d = json.load(sys.stdin)
    closes = [c for c in d['chart']['result'][0]['indicators']['quote'][0]['close'] if c]
    if len(closes) < 5: print('ERROR'); sys.exit()
    rets = [math.log(closes[i]/closes[i-1]) for i in range(1,len(closes)) if closes[i-1]>0 and closes[i]>0]
    if len(rets) < 3: print('ERROR'); sys.exit()
    mu = sum(rets)/len(rets)
    vol = math.sqrt(sum((r-mu)**2 for r in rets)/(len(rets)-1)) * math.sqrt(252)
    r5d = sum(rets[-5:]) if len(rets)>=5 else sum(rets)
    print(f'{vol:.6f}|{r5d:.6f}|{closes[-1]:.2f}|{len(rets)}')
except: print('ERROR')
" 2>/dev/null
}

main() {
    log "Risk Parity Calculator v1.0"
    log "Tickers: $TICKERS | Lookback: ${LOOKBACK}d | Target vol: $TARGET_VOL | Budget: \$$BUDGET"

    local tmpdata
    tmpdata=$(mktemp)
    local count=0

    for ticker in $TICKERS; do
        local result
        result=$(fetch_ticker "$ticker")
        if [[ "$result" == "ERROR" ]] || [[ -z "$result" ]]; then
            log "SKIP $ticker"
            continue
        fi
        IFS='|' read -r vol ret price pts <<< "$result"
        echo "${ticker},${vol},${ret},${price},${pts}" >> "$tmpdata"
        count=$((count + 1))
        sleep 0.3
    done

    if [[ $count -lt 3 ]]; then
        log "ERROR: Only $count tickers (need ≥3)"
        rm -f "$tmpdata"
        exit 1
    fi

    log "Fetched $count tickers, computing allocations..."

    local output
    output=$(python3 << PYEOF
import sys, json, math

sector_map = {
    'XLE':'Energy','XLF':'Financials','XLK':'Technology','XLV':'Healthcare',
    'XLI':'Industrials','XLC':'Communication','XLY':'Cons.Disc.','XLP':'Cons.Staples',
    'XLRE':'Real Estate','XLB':'Materials','XLU':'Utilities','GLD':'Gold','TLT':'Bonds',
    'SPY':'S&P 500','QQQ':'Nasdaq','OXY':'Oil&Gas','DVN':'Oil&Gas','EOG':'Oil&Gas'
}

tickers,vols,r5ds,prices=[],[],[],[]
with open("$tmpdata") as f:
    for line in f:
        parts = line.strip().split(',')
        if len(parts)!=5: continue
        t,v,r,p,n = parts
        v=max(float(v),0.001)
        tickers.append(t); vols.append(v); r5ds.append(float(r)); prices.append(float(p))

n=len(tickers)
tv=float("$TARGET_VOL"); budget=float("$BUDGET")

# Inverse-vol weights
iv=[1.0/v for v in vols]; ti=sum(iv)
rw=[x/ti for x in iv]

# Portfolio vol & leverage
pv=math.sqrt(sum((w*v)**2 for w,v in zip(rw,vols)))
lev=min(tv/pv if pv>0 else 1.0, 2.0)
sw=[w*lev for w in rw]
tw=sum(sw)
da=[(w/tw)*budget for w in sw]

# Risk contributions
pvar=sum((w*v)**2 for w,v in zip(sw,vols))
rc=[(w*v)**2/pvar*100 if pvar>0 else 0 for w,v in zip(sw,vols)]

# Portfolio return
pr=sum(w*r for w,r in zip(rw,r5ds))
sp=pr/pv*math.sqrt(52) if pv>0 else 0

# Regime
hv=[t for t,v in zip(tickers,vols) if v>0.35]
regime="balanced"
if len(hv)>n*0.4: regime="high_stress"
elif any(t=='XLE' and v>0.40 for t,v in zip(tickers,vols)): regime="energy_stress"

allocs=[]
for i in range(n):
    allocs.append({
        "ticker":tickers[i],"sector":sector_map.get(tickers[i],tickers[i]),
        "ann_vol":f"{vols[i]:.1%}","weight":f"{sw[i]/tw:.1%}",
        "dollar":round(da[i]),"shares":round(da[i]/prices[i]) if prices[i]>0 else 0,
        "risk_contrib":f"{rc[i]:.1f}%","return_5d":f"{r5ds[i]:.2%}"
    })
allocs.sort(key=lambda x: float(x["weight"].rstrip('%')), reverse=True)

result={
    "timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "portfolio":{"target_vol":f"{tv:.1%}","realized_vol":f"{pv:.1%}",
                 "leverage":round(lev,2),"budget":budget,
                 "return_5d":f"{pr:.2%}","sharpe_proxy":round(sp,2)},
    "allocations":allocs, "risk_regime":regime
}
print(json.dumps(result,indent=2))
PYEOF
)

    rm -f "$tmpdata"

    echo "$output" > "$OUTPUT_DIR/risk-parity.json"

    # Human-readable output
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "   RISK PARITY ALLOCATION — $(date -u +'%Y-%m-%d %H:%M UTC')"
    echo "═══════════════════════════════════════════════════════════════════"
    echo "$output" | python3 -c "
import sys, json
d=json.load(sys.stdin); p=d['portfolio']
print(f'  Target Vol: {p[\"target_vol\"]}  |  Realized: {p[\"realized_vol\"]}  |  Leverage: {p[\"leverage\"]}x')
print(f'  Budget: \${p[\"budget\"]:,.0f}  |  5d Return: {p[\"return_5d\"]}  |  Sharpe: {p[\"sharpe_proxy\"]}')
print(f'  Regime: {d[\"risk_regime\"].upper()}')
print()
print('  TICKER  SECTOR          WEIGHT   DOLLAR      SHARES  VOL     RISK%   5d RET')
print('  ─────── ─────────────── ──────── ────────── ──────── ─────── ─────── ───────')
for a in d['allocations']:
    print(f'  {a[\"ticker\"]:7s} {a[\"sector\"][:14]:15s} {a[\"weight\"]:>7s}  \${a[\"dollar\"]:>8,d}  {a[\"shares\"]:>7d} {a[\"ann_vol\"]:>7s} {a[\"risk_contrib\"]:>7s} {a[\"return_5d\"]:>7s}')
"

    # Push to ClawTalk if requested
    if [[ "$PUSH" == "true" ]] && [[ -n "$CLAWTALK_KEY" ]]; then
        local summary
        summary=$(echo "$output" | python3 -c "
import sys, json
d=json.load(sys.stdin); p=d['portfolio']
lines=[f'Risk Parity Signal: {d[\"risk_regime\"].upper()}']
lines.append(f'Port vol: {p[\"realized_vol\"]} (target {p[\"target_vol\"]}), leverage {p[\"leverage\"]}x')
lines.append('Top allocations:')
for a in d['allocations'][:5]:
    lines.append(f'  {a[\"ticker\"]} ({a[\"sector\"]}): {a[\"weight\"]} = \${a[\"dollar\"]:,d}')
print('\n'.join(lines))
")
        local tmpmsg
        tmpmsg=$(mktemp)
        python3 -c "
import json
msg={'to':'$CLAWTALK_TO','type':'notification','topic':'gekko-signal',
     'encrypted':False,'payload':{'text':'''$summary''','metadata':{'signal':'risk-parity','version':'1.0'}}}
print(json.dumps(msg))
" > "$tmpmsg"
        curl -s -X POST "https://clawtalk.monkeymango.co/messages" \
            -H "Authorization: Bearer $CLAWTALK_KEY" \
            -H "Content-Type: application/json" \
            --data-binary @"$tmpmsg" >/dev/null 2>&1
        rm -f "$tmpmsg"
        log "Pushed to ClawTalk ($CLAWTALK_TO)"
    fi

    log "Done. Output: $OUTPUT_DIR/risk-parity.json"
}

main "$@"
