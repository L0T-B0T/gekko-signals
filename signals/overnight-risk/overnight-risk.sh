#!/bin/bash
# Overnight Risk Monitor for Gekko
# Scans pre-market/overnight data for risk events that impact market open
# Generates risk assessment for position management before US market open
#
# Sources: Yahoo Finance pre-market, VIX futures, global indices, commodities
# Output: JSON signal compatible with Gekko's state consumption
# Dependencies: bash, python3, curl (stdlib only, no paid APIs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
DB_FILE="${SCRIPT_DIR}/overnight-risk.db"
mkdir -p "$OUTPUT_DIR"

# --- Configuration ---
LOOKBACK_DAYS=5
VIX_PANIC_THRESHOLD=30
VIX_ELEVATED_THRESHOLD=22
GAP_SIGNIFICANT_PCT=1.5
FUTURES_SYMBOLS="ES=F NQ=F YM=F RTY=F CL=F GC=F SI=F ZB=F"
GLOBAL_INDICES="^FTSE ^GDAXI ^FCHI ^N225 ^HSI ^AXJO ^GSPTSE"
ENERGY_SYMBOLS="CL=F BZ=F NG=F"
SAFE_HAVEN="GC=F SI=F ZB=F"
SECTORS="XLE XLF XLK XLV XLI XLC XLU XLRE XLB XLY XLP"

# --- Helper: Fetch Yahoo Finance data ---
fetch_quote() {
    local symbol="$1"
    curl -sf --max-time 8 \
        "https://query1.finance.yahoo.com/v8/finance/chart/${symbol}?interval=1d&range=5d" \
        -H "User-Agent: Mozilla/5.0" 2>/dev/null || echo "{}"
}

# --- Helper: Extract pre-market data ---
extract_premarket() {
    local symbol="$1"
    local data
    data=$(fetch_quote "$symbol")
    
    python3 -c "
import json, sys
try:
    d = json.loads('''$data''')
    meta = d.get('chart',{}).get('result',[{}])[0].get('meta',{})
    closes = d.get('chart',{}).get('result',[{}])[0].get('indicators',{}).get('quote',[{}])[0].get('close',[])
    
    prev_close = meta.get('chartPreviousClose', meta.get('previousClose', 0))
    current = meta.get('regularMarketPrice', 0)
    premarket = meta.get('preMarketPrice', current)
    
    # Calculate overnight gap
    gap_pct = ((premarket - prev_close) / prev_close * 100) if prev_close else 0
    
    # Calculate recent volatility (5-day)
    valid_closes = [c for c in closes if c is not None]
    if len(valid_closes) >= 2:
        returns = [(valid_closes[i] - valid_closes[i-1]) / valid_closes[i-1] * 100 
                   for i in range(1, len(valid_closes))]
        recent_vol = (sum(r**2 for r in returns) / len(returns)) ** 0.5
    else:
        recent_vol = 0
    
    print(json.dumps({
        'symbol': '$symbol',
        'prev_close': round(prev_close, 2),
        'current': round(current, 2),
        'premarket': round(premarket, 2),
        'gap_pct': round(gap_pct, 2),
        'recent_vol': round(recent_vol, 2)
    }))
except Exception as e:
    print(json.dumps({'symbol': '$symbol', 'error': str(e), 'prev_close': 0, 'current': 0, 'premarket': 0, 'gap_pct': 0, 'recent_vol': 0}))
" 2>/dev/null
}

# --- Main: Collect all overnight data ---
collect_overnight_data() {
    local tmpdir
    tmpdir=$(mktemp -d)
    
    echo "Collecting overnight data..." >&2
    
    # 1. US Futures
    local futures_data="["
    local first=true
    for sym in $FUTURES_SYMBOLS; do
        sleep 1  # Rate limit
        local quote
        quote=$(extract_premarket "$sym")
        if [ -n "$quote" ] && [ "$quote" != "{}" ]; then
            $first || futures_data+=","
            futures_data+="$quote"
            first=false
        fi
    done
    futures_data+="]"
    
    # 2. VIX
    sleep 1
    local vix_data
    vix_data=$(extract_premarket "^VIX")
    
    # 3. Global indices
    local global_data="["
    first=true
    for sym in $GLOBAL_INDICES; do
        sleep 1
        local quote
        quote=$(extract_premarket "$sym")
        if [ -n "$quote" ] && [ "$quote" != "{}" ]; then
            $first || global_data+=","
            global_data+="$quote"
            first=false
        fi
    done
    global_data+="]"
    
    # 4. Energy
    sleep 1
    local energy_data="["
    first=true
    for sym in $ENERGY_SYMBOLS; do
        sleep 1
        local quote
        quote=$(extract_premarket "$sym")
        if [ -n "$quote" ] && [ "$quote" != "{}" ]; then
            $first || energy_data+=","
            energy_data+="$quote"
            first=false
        fi
    done
    energy_data+="]"
    
    # 5. Safe haven
    local haven_data="["
    first=true
    for sym in $SAFE_HAVEN; do
        sleep 1
        local quote
        quote=$(extract_premarket "$sym")
        if [ -n "$quote" ] && [ "$quote" != "{}" ]; then
            $first || haven_data+=","
            haven_data+="$quote"
            first=false
        fi
    done
    haven_data+="]"
    
    echo "{\"futures\": $futures_data, \"vix\": $vix_data, \"global\": $global_data, \"energy\": $energy_data, \"safe_haven\": $haven_data}"
    
    rm -rf "$tmpdir"
}

# --- Analysis: Generate risk assessment ---
analyze_risk() {
    local raw_data="$1"
    
    python3 << 'PYEOF'
import json, sys, math
from datetime import datetime

raw = json.loads(sys.argv[1]) if len(sys.argv) > 1 else json.loads(sys.stdin.read())

# Extract key metrics
vix = raw.get('vix', {})
vix_level = vix.get('current', 0) or vix.get('premarket', 0)
vix_gap = vix.get('gap_pct', 0)

futures = raw.get('futures', [])
global_idx = raw.get('global', [])
energy = raw.get('energy', [])
safe_haven = raw.get('safe_haven', [])

# --- Risk Scoring ---
risk_score = 0
risk_factors = []
risk_signals = []

# 1. VIX Level (0-30 points)
if vix_level >= 35:
    risk_score += 30
    risk_factors.append(f"VIX PANIC: {vix_level:.1f} (>=35)")
elif vix_level >= 28:
    risk_score += 20
    risk_factors.append(f"VIX HIGH: {vix_level:.1f} (>=28)")
elif vix_level >= 22:
    risk_score += 10
    risk_factors.append(f"VIX ELEVATED: {vix_level:.1f} (>=22)")
else:
    risk_factors.append(f"VIX NORMAL: {vix_level:.1f}")

# 2. VIX overnight change (0-15 points)
if abs(vix_gap) >= 10:
    risk_score += 15
    risk_factors.append(f"VIX SPIKE: {vix_gap:+.1f}% overnight")
elif abs(vix_gap) >= 5:
    risk_score += 8
    risk_factors.append(f"VIX MOVE: {vix_gap:+.1f}% overnight")

# 3. Futures gap analysis (0-20 points)
es_gap = next((f.get('gap_pct', 0) for f in futures if 'ES' in f.get('symbol', '')), 0)
nq_gap = next((f.get('gap_pct', 0) for f in futures if 'NQ' in f.get('symbol', '')), 0)

avg_futures_gap = sum(f.get('gap_pct', 0) for f in futures) / max(len(futures), 1)
max_futures_gap = max((abs(f.get('gap_pct', 0)) for f in futures), default=0)

if max_futures_gap >= 2.0:
    risk_score += 20
    risk_factors.append(f"LARGE FUTURES GAP: max {max_futures_gap:.1f}%")
elif max_futures_gap >= 1.0:
    risk_score += 10
    risk_factors.append(f"NOTABLE FUTURES GAP: max {max_futures_gap:.1f}%")

# 4. Global index divergence (0-15 points)
global_gaps = [g.get('gap_pct', 0) for g in global_idx if g.get('gap_pct', 0) != 0]
if global_gaps:
    global_range = max(global_gaps) - min(global_gaps)
    global_avg = sum(global_gaps) / len(global_gaps)
    if global_range >= 3.0:
        risk_score += 15
        risk_factors.append(f"GLOBAL DIVERGENCE: {global_range:.1f}% range")
    elif abs(global_avg) >= 1.5:
        risk_score += 8
        risk_factors.append(f"GLOBAL SELLOFF: avg {global_avg:+.1f}%")

# 5. Energy overnight (0-10 points)
cl_gap = next((e.get('gap_pct', 0) for e in energy if 'CL' in e.get('symbol', '')), 0)
if abs(cl_gap) >= 5:
    risk_score += 10
    risk_factors.append(f"ENERGY SHOCK: crude {cl_gap:+.1f}%")
elif abs(cl_gap) >= 3:
    risk_score += 5
    risk_factors.append(f"ENERGY MOVE: crude {cl_gap:+.1f}%")

# 6. Safe haven bid (0-10 points)
gold_gap = next((h.get('gap_pct', 0) for h in safe_haven if 'GC' in h.get('symbol', '')), 0)
bond_gap = next((h.get('gap_pct', 0) for h in safe_haven if 'ZB' in h.get('symbol', '')), 0)
if gold_gap > 1.5 and bond_gap > 0.5:
    risk_score += 10
    risk_factors.append(f"SAFE HAVEN BID: gold {gold_gap:+.1f}%, bonds {bond_gap:+.1f}%")
elif gold_gap > 1.0:
    risk_score += 5
    risk_factors.append(f"GOLD BID: {gold_gap:+.1f}%")

# --- Risk Level Classification ---
if risk_score >= 60:
    risk_level = "EXTREME"
    confidence = min(95, 70 + risk_score - 60)
    action = "REDUCE_EXPOSURE"
elif risk_score >= 40:
    risk_level = "HIGH"
    confidence = min(90, 60 + risk_score - 40)
    action = "TIGHTEN_STOPS"
elif risk_score >= 20:
    risk_level = "ELEVATED"
    confidence = min(80, 50 + risk_score - 20)
    action = "MONITOR"
else:
    risk_level = "LOW"
    confidence = max(50, 80 - risk_score)
    action = "NORMAL"

# --- Direction bias ---
total_gap = avg_futures_gap
if total_gap > 0.5:
    direction = "BULLISH_OPEN"
elif total_gap < -0.5:
    direction = "BEARISH_OPEN"
else:
    direction = "FLAT_OPEN"

# --- Generate risk signals ---
risk_signals = []
for f in futures:
    if abs(f.get('gap_pct', 0)) >= 1.0:
        risk_signals.append({
            "type": "gap",
            "symbol": f['symbol'],
            "magnitude": f['gap_pct'],
            "severity": "high" if abs(f['gap_pct']) >= 2 else "moderate"
        })

# Energy-specific signals
for e in energy:
    if abs(e.get('gap_pct', 0)) >= 2.0:
        risk_signals.append({
            "type": "commodity_shock",
            "symbol": e['symbol'],
            "magnitude": e['gap_pct'],
            "impact": "energy_sector"
        })

# --- Output ---
result = {
    "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "risk_level": risk_level,
    "risk_score": risk_score,
    "confidence": confidence,
    "action": action,
    "direction": direction,
    "vix": {
        "level": round(vix_level, 2),
        "overnight_change": round(vix_gap, 2)
    },
    "futures": {
        "es_gap": round(es_gap, 2),
        "nq_gap": round(nq_gap, 2),
        "avg_gap": round(avg_futures_gap, 2),
        "max_gap": round(max_futures_gap, 2)
    },
    "global": {
        "avg_gap": round(sum(global_gaps) / max(len(global_gaps), 1), 2) if global_gaps else 0,
        "range": round(max(global_gaps) - min(global_gaps), 2) if len(global_gaps) >= 2 else 0,
        "count": len(global_gaps)
    },
    "energy": {
        "crude_gap": round(cl_gap, 2),
        "gold_gap": round(gold_gap, 2)
    },
    "risk_factors": risk_factors,
    "risk_signals": risk_signals,
    "recommendation": f"{risk_level} risk ({risk_score}/100). Action: {action}. Direction: {direction}."
}

print(json.dumps(result, indent=2))
PYEOF
}

# --- Main execution ---
main() {
    local mode="${1:-scan}"
    
    case "$mode" in
        scan)
            echo "=== Overnight Risk Monitor ===" >&2
            echo "Scanning pre-market data..." >&2
            
            local raw_data
            raw_data=$(collect_overnight_data)
            
            # Save raw data
            echo "$raw_data" > "$OUTPUT_DIR/raw_overnight.json"
            
            # Analyze
            local result
            result=$(echo "$raw_data" | python3 -c "
import json, sys
raw = json.load(sys.stdin)
$(cat << 'INLINE'
vix = raw.get('vix', {})
vix_level = vix.get('current', 0) or vix.get('premarket', 0)
vix_gap = vix.get('gap_pct', 0)
futures = raw.get('futures', [])
global_idx = raw.get('global', [])
energy = raw.get('energy', [])
safe_haven = raw.get('safe_haven', [])

risk_score = 0
risk_factors = []

# VIX
if vix_level >= 35: risk_score += 30; risk_factors.append(f'VIX PANIC: {vix_level:.1f}')
elif vix_level >= 28: risk_score += 20; risk_factors.append(f'VIX HIGH: {vix_level:.1f}')
elif vix_level >= 22: risk_score += 10; risk_factors.append(f'VIX ELEVATED: {vix_level:.1f}')
else: risk_factors.append(f'VIX NORMAL: {vix_level:.1f}')

if abs(vix_gap) >= 10: risk_score += 15; risk_factors.append(f'VIX SPIKE: {vix_gap:+.1f}%')
elif abs(vix_gap) >= 5: risk_score += 8

# Futures gaps
avg_gap = sum(f.get('gap_pct', 0) for f in futures) / max(len(futures), 1)
max_gap = max((abs(f.get('gap_pct', 0)) for f in futures), default=0)
es_gap = next((f.get('gap_pct', 0) for f in futures if 'ES' in f.get('symbol', '')), 0)
nq_gap = next((f.get('gap_pct', 0) for f in futures if 'NQ' in f.get('symbol', '')), 0)

if max_gap >= 2.0: risk_score += 20; risk_factors.append(f'LARGE GAP: {max_gap:.1f}%')
elif max_gap >= 1.0: risk_score += 10; risk_factors.append(f'GAP: {max_gap:.1f}%')

# Global
global_gaps = [g.get('gap_pct', 0) for g in global_idx if g.get('gap_pct', 0) != 0]
if global_gaps:
    gr = max(global_gaps) - min(global_gaps)
    ga = sum(global_gaps) / len(global_gaps)
    if gr >= 3: risk_score += 15; risk_factors.append(f'GLOBAL DIVERGE: {gr:.1f}%')
    elif abs(ga) >= 1.5: risk_score += 8

# Energy
cl_gap = next((e.get('gap_pct', 0) for e in energy if 'CL' in e.get('symbol', '')), 0)
if abs(cl_gap) >= 5: risk_score += 10; risk_factors.append(f'ENERGY SHOCK: crude {cl_gap:+.1f}%')
elif abs(cl_gap) >= 3: risk_score += 5

# Safe haven
gold_gap = next((h.get('gap_pct', 0) for h in safe_haven if 'GC' in h.get('symbol', '')), 0)
if gold_gap > 1.5: risk_score += 10; risk_factors.append(f'SAFE HAVEN BID: gold {gold_gap:+.1f}%')

# Classify
if risk_score >= 60: level = 'EXTREME'; action = 'REDUCE_EXPOSURE'
elif risk_score >= 40: level = 'HIGH'; action = 'TIGHTEN_STOPS'
elif risk_score >= 20: level = 'ELEVATED'; action = 'MONITOR'
else: level = 'LOW'; action = 'NORMAL'

direction = 'BULLISH_OPEN' if avg_gap > 0.5 else ('BEARISH_OPEN' if avg_gap < -0.5 else 'FLAT_OPEN')

from datetime import datetime
result = {
    'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'risk_level': level, 'risk_score': risk_score, 'action': action, 'direction': direction,
    'vix': {'level': round(vix_level, 2), 'overnight_change': round(vix_gap, 2)},
    'futures': {'es_gap': round(es_gap, 2), 'nq_gap': round(nq_gap, 2), 'avg_gap': round(avg_gap, 2), 'max_gap': round(max_gap, 2)},
    'energy': {'crude_gap': round(cl_gap, 2)},
    'gold_gap': round(gold_gap, 2),
    'risk_factors': risk_factors,
    'recommendation': f'{level} risk ({risk_score}/100). {action}. {direction}.'
}
print(json.dumps(result, indent=2))
INLINE
)
")
            echo "$result"
            echo "$result" > "$OUTPUT_DIR/overnight-risk.json"
            
            # Print human-readable
            echo "" >&2
            echo "$result" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(f'Risk Level: {r[\"risk_level\"]} ({r[\"risk_score\"]}/100)')
print(f'Action: {r[\"action\"]}')
print(f'Direction: {r[\"direction\"]}')
print(f'VIX: {r[\"vix\"][\"level\"]} ({r[\"vix\"][\"overnight_change\"]:+.1f}%)')
print(f'ES gap: {r[\"futures\"][\"es_gap\"]:+.2f}%  NQ gap: {r[\"futures\"][\"nq_gap\"]:+.2f}%')
print(f'Crude gap: {r[\"energy\"][\"crude_gap\"]:+.2f}%')
print(f'Gold gap: {r.get(\"gold_gap\", 0):+.2f}%')
print()
print('Risk Factors:')
for f in r.get('risk_factors', []):
    print(f'  • {f}')
print()
print(r['recommendation'])
" >&2
            ;;
            
        daemon)
            local interval="${2:-300}"  # 5 min default
            echo "Starting overnight risk daemon (${interval}s interval)..." >&2
            
            local prev_level=""
            while true; do
                local result
                result=$("$0" scan 2>/dev/null) || true
                
                if [ -n "$result" ]; then
                    local curr_level
                    curr_level=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('risk_level',''))" 2>/dev/null)
                    
                    # Alert on level change
                    if [ -n "$prev_level" ] && [ "$curr_level" != "$prev_level" ]; then
                        echo "⚠️ RISK LEVEL CHANGE: $prev_level → $curr_level" >&2
                        
                        # Push to Gekko via ClawTalk if configured
                        if [ -n "${CLAWTALK_API_KEY:-}" ]; then
                            local msg="🚨 RISK LEVEL CHANGE: $prev_level → $curr_level\n$(echo "$result" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['recommendation'])" 2>/dev/null)"
                            local payload
                            payload=$(python3 -c "import json; print(json.dumps({'to':'Lotbot','type':'notification','topic':'overnight-risk','encrypted':False,'payload':{'text':'''$msg'''}}))" 2>/dev/null)
                            if [ -n "$payload" ]; then
                                curl -sf --max-time 5 -X POST "https://clawtalk.monkeymango.co/messages" \
                                    -H "Authorization: Bearer $CLAWTALK_API_KEY" \
                                    -H "Content-Type: application/json" \
                                    -d "$payload" >/dev/null 2>&1 || true
                            fi
                        fi
                    fi
                    
                    prev_level="$curr_level"
                fi
                
                sleep "$interval"
            done
            ;;
            
        *)
            echo "Usage: $0 [scan|daemon [interval_seconds]]"
            echo "  scan   - One-shot risk assessment (default)"
            echo "  daemon - Continuous monitoring with alerts"
            exit 1
            ;;
    esac
}

main "$@"
