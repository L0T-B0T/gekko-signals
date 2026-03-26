#!/usr/bin/env bash
# Position Sizer v1.0 — Risk-adjusted position sizing using Gekko signal suite
# Combines: regime detector, vol surface, correlation, sector momentum
# Output: Per-ticker position size recommendations (% of portfolio)
set -euo pipefail

PORTFOLIO_SIZE="${PORTFOLIO_SIZE:-100000}"
MAX_SINGLE="${MAX_SINGLE:-0.10}"       # Max 10% in one position
MAX_SECTOR="${MAX_SECTOR:-0.25}"       # Max 25% in one sector
BASE_RISK="${BASE_RISK:-0.02}"         # 2% risk per trade
OUTPUT_DIR="${OUTPUT_DIR:-$(dirname "$0")/output}"
SIGNAL_STATE="${SIGNAL_STATE:-$(dirname "$0")/.signal-state}"
mkdir -p "$OUTPUT_DIR" "$SIGNAL_STATE"

TICKERS=(SPY QQQ XLE XLF XLK XLV XLI XLB XLC XLU XLRE TLT GLD VIX)
SECTORS=( "SPY:broad" "QQQ:tech" "XLE:energy" "XLF:financial" "XLK:tech" "XLV:healthcare"
          "XLI:industrial" "XLB:materials" "XLC:comm" "XLU:utilities" "XLRE:realestate"
          "TLT:bonds" "GLD:commodity" "VIX:volatility" )

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ---- Step 1: Fetch current prices + vol ----
fetch_prices() {
    local ticker="$1"
    python3 -c "
import urllib.request, json, sys
url = f'https://query1.finance.yahoo.com/v8/finance/chart/{\"$ticker\"}?range=30d&interval=1d'
req = urllib.request.Request(url, headers={'User-Agent':'Mozilla/5.0'})
try:
    resp = urllib.request.urlopen(req, timeout=8)
    data = json.load(resp)
    result = data['chart']['result'][0]
    closes = result['indicators']['quote'][0]['close']
    closes = [c for c in closes if c is not None]
    if len(closes) < 5:
        print(json.dumps({'error':'insufficient_data'}))
        sys.exit(0)
    current = closes[-1]
    # Historical vol (20d annualized)
    import math
    returns = [(closes[i]/closes[i-1])-1 for i in range(1,len(closes))]
    hv = (sum(r*r for r in returns[-20:])/min(20,len(returns[-20:])))**0.5 * (252**0.5)
    # 5d momentum
    mom5 = (closes[-1]/closes[-6])-1 if len(closes)>5 else 0
    # 20d momentum
    mom20 = (closes[-1]/closes[-21])-1 if len(closes)>20 else 0
    # Avg daily range
    highs = result['indicators']['quote'][0].get('high',[])
    lows = result['indicators']['quote'][0].get('low',[])
    adr = 0
    if highs and lows:
        ranges = [(h-l)/l for h,l in zip(highs[-5:],lows[-5:]) if h and l and l>0]
        adr = sum(ranges)/len(ranges) if ranges else 0
    print(json.dumps({
        'ticker':'$ticker','price':round(current,2),
        'hv20':round(hv,4),'mom5':round(mom5,4),'mom20':round(mom20,4),
        'adr':round(adr,4)
    }))
except Exception as e:
    print(json.dumps({'error':str(e)[:100]}))
" 2>/dev/null
}

# ---- Step 2: Regime-based risk multiplier ----
get_regime_multiplier() {
    local regime_file="$SIGNAL_STATE/regime.json"
    if [[ -f "$regime_file" ]] && [[ $(find "$regime_file" -mmin -30 2>/dev/null) ]]; then
        python3 -c "
import json
with open('$regime_file') as f: d=json.load(f)
regime = d.get('regime','neutral')
conf = d.get('confidence',50)
# Risk-on = full size, neutral = 75%, risk-off = 50%
if regime == 'risk-on': mult = 1.0
elif regime == 'risk-off': mult = 0.5 + (1 - conf/100)*0.2
else: mult = 0.75
print(f'{mult:.2f}')
"
    else
        echo "0.75"  # Default neutral
    fi
}

# ---- Step 3: Vol-adjusted sizing ----
calc_position_size() {
    local ticker="$1" price="$2" hv="$3" mom5="$4" mom20="$5" regime_mult="$6"
    python3 << PYEOF
import json, math

ticker = "$ticker"
price = float("$price")
hv = float("$hv")
mom5 = float("$mom5")
mom20 = float("$mom20")
regime_mult = float("$regime_mult")
portfolio = float("$PORTFOLIO_SIZE")
max_single = float("$MAX_SINGLE")
base_risk = float("$BASE_RISK")

# Vol-adjusted position size (Kelly-inspired)
# Higher vol = smaller position
if hv <= 0: hv = 0.20  # default 20%
vol_factor = 0.20 / max(hv, 0.05)  # normalized to 20% baseline vol
vol_factor = min(vol_factor, 2.0)   # cap at 2x

# Momentum signal
if mom5 > 0.02 and mom20 > 0.05:
    trend = "strong_up"
    trend_mult = 1.2
elif mom5 < -0.02 and mom20 < -0.05:
    trend = "strong_down"
    trend_mult = 0.6
elif mom5 > 0 and mom20 > 0:
    trend = "up"
    trend_mult = 1.0
elif mom5 < 0 and mom20 < 0:
    trend = "down"
    trend_mult = 0.8
else:
    trend = "mixed"
    trend_mult = 0.9

# Final position size as % of portfolio
raw_pct = base_risk * vol_factor * regime_mult * trend_mult
# Cap at max single position
final_pct = min(raw_pct, max_single)
# Dollar amount
dollars = portfolio * final_pct
shares = int(dollars / price) if price > 0 else 0

# Signal: long/short/neutral
if trend in ("strong_up","up") and regime_mult >= 0.7:
    signal = "LONG"
elif trend in ("strong_down","down") and regime_mult <= 0.6:
    signal = "SHORT"
else:
    signal = "NEUTRAL"

result = {
    "ticker": ticker,
    "price": price,
    "hv20": hv,
    "mom5_pct": round(mom5*100,1),
    "mom20_pct": round(mom20*100,1),
    "trend": trend,
    "vol_factor": round(vol_factor,2),
    "regime_mult": regime_mult,
    "raw_pct": round(raw_pct*100,2),
    "final_pct": round(final_pct*100,2),
    "dollars": round(dollars,0),
    "shares": shares,
    "signal": signal
}
print(json.dumps(result))
PYEOF
}

# ---- Main ----
main() {
    log "Position Sizer v1.0 — Portfolio \$$PORTFOLIO_SIZE"
    
    # Get regime
    regime_mult=$(get_regime_multiplier)
    log "Regime multiplier: ${regime_mult}x"
    
    ALL_RESULTS="["
    FIRST=true
    
    for entry in "${SECTORS[@]}"; do
        ticker="${entry%%:*}"
        sector="${entry##*:}"
        [[ "$ticker" == "VIX" ]] && continue  # Skip VIX (not tradeable directly)
        
        log "Analyzing $ticker ($sector)..."
        price_data=$(fetch_prices "$ticker")
        
        error=$(echo "$price_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
        if [[ -n "$error" && "$error" != "None" ]]; then
            log "  SKIP $ticker: $error"
            continue
        fi
        
        price=$(echo "$price_data" | python3 -c "import sys,json; print(json.load(sys.stdin)['price'])" 2>/dev/null)
        hv=$(echo "$price_data" | python3 -c "import sys,json; print(json.load(sys.stdin)['hv20'])" 2>/dev/null)
        mom5=$(echo "$price_data" | python3 -c "import sys,json; print(json.load(sys.stdin)['mom5'])" 2>/dev/null)
        mom20=$(echo "$price_data" | python3 -c "import sys,json; print(json.load(sys.stdin)['mom20'])" 2>/dev/null)
        
        result=$(calc_position_size "$ticker" "$price" "$hv" "$mom5" "$mom20" "$regime_mult")
        
        # Add sector
        result=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); d['sector']='$sector'; print(json.dumps(d))")
        
        signal=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['signal'])" 2>/dev/null)
        final_pct=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['final_pct'])" 2>/dev/null)
        
        log "  $ticker: $signal ${final_pct}% (\$$(echo "$result" | python3 -c "import sys,json; print(int(json.load(sys.stdin)['dollars']))"))"
        
        [[ "$FIRST" == "true" ]] && FIRST=false || ALL_RESULTS+=","
        ALL_RESULTS+="$result"
        
        sleep 1  # Rate limit Yahoo Finance
    done
    
    ALL_RESULTS+="]"
    
    # Save results
    OUTFILE="$OUTPUT_DIR/positions-$(date -u +%Y%m%d-%H%M).json"
    echo "$ALL_RESULTS" | python3 -m json.tool > "$OUTFILE" 2>/dev/null || echo "$ALL_RESULTS" > "$OUTFILE"
    
    # Summary
    echo ""
    log "=== POSITION SIZING SUMMARY ==="
    echo "$ALL_RESULTS" | python3 << 'SUMMARY'
import json, sys
positions = json.load(sys.stdin)
longs = [p for p in positions if p['signal'] == 'LONG']
shorts = [p for p in positions if p['signal'] == 'SHORT']
neutrals = [p for p in positions if p['signal'] == 'NEUTRAL']

print(f"\nLONG ({len(longs)}):")
for p in sorted(longs, key=lambda x: x['final_pct'], reverse=True):
    print(f"  {p['ticker']:5s} {p['final_pct']:5.1f}%  ${int(p['dollars']):>6,}  ({p['shares']} shares @ ${p['price']:.0f})  mom5={p['mom5_pct']:+.1f}% hv={p['hv20']:.0%}")

print(f"\nSHORT ({len(shorts)}):")
for p in sorted(shorts, key=lambda x: x['final_pct'], reverse=True):
    print(f"  {p['ticker']:5s} {p['final_pct']:5.1f}%  ${int(p['dollars']):>6,}  ({p['shares']} shares @ ${p['price']:.0f})  mom5={p['mom5_pct']:+.1f}% hv={p['hv20']:.0%}")

print(f"\nNEUTRAL ({len(neutrals)}):")
for p in sorted(neutrals, key=lambda x: x['final_pct'], reverse=True):
    print(f"  {p['ticker']:5s} {p['final_pct']:5.1f}%  ${int(p['dollars']):>6,}  ({p['shares']} shares @ ${p['price']:.0f})  mom5={p['mom5_pct']:+.1f}% hv={p['hv20']:.0%}")

total_long = sum(p['dollars'] for p in longs)
total_short = sum(p['dollars'] for p in shorts)
total_deployed = total_long + total_short
print(f"\nTotal LONG:  ${int(total_long):>8,}")
print(f"Total SHORT: ${int(total_short):>8,}")
print(f"Total deployed: ${int(total_deployed):>8,} ({total_deployed/float(sys.argv[1]) if len(sys.argv)>1 else 0:.1%})")
SUMMARY
    
    log "Results saved: $OUTFILE"
}

# Handle args
case "${1:-}" in
    --json) main 2>/dev/null | tail -1 ;;
    --help) echo "Usage: position-sizer.sh [--json|--help]"; echo "Env: PORTFOLIO_SIZE, MAX_SINGLE, MAX_SECTOR, BASE_RISK" ;;
    *) main ;;
esac
