#!/usr/bin/env bash
# Sector Momentum Scanner v1.0 — Gekko Signal Tool #7
# Tracks relative strength of 11 GICS sectors vs SPY
# Identifies rotational momentum (money flow between sectors)
# Outputs structured JSON for Gekko integration

set -euo pipefail

CLAWTALK_KEY="${CLAWTALK_API_KEY:-$(cat /data/workspace/clawtalk/.env 2>/dev/null | grep CLAWTALK_API_KEY | cut -d= -f2)}"
CLAWTALK_URL="https://clawtalk.monkeymango.co/messages"
SIGNAL_NAME="sector-momentum-v1"

# 11 GICS Sector ETFs + benchmark
SECTORS="XLB XLC XLE XLF XLI XLK XLP XLRE XLU XLV XLY"
BENCHMARK="SPY"
ALL_TICKERS="$BENCHMARK $SECTORS"

usage() {
    echo "Sector Momentum Scanner v1.0"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --json         JSON output only"
    echo "  --push         Push signal to Lotbot via ClawTalk"
    echo "  --daemon N     Run every N seconds (default: 900)"
    echo "  --lookback N   Lookback days (default: 20)"
    echo "  -h, --help     Show this help"
}

JSON_MODE=false
PUSH_MODE=false
DAEMON_MODE=false
DAEMON_INTERVAL=900
LOOKBACK=20

while [[ $# -gt 0 ]]; do
    case $1 in
        --json) JSON_MODE=true; shift ;;
        --push) PUSH_MODE=true; shift ;;
        --daemon) DAEMON_MODE=true; DAEMON_INTERVAL="${2:-900}"; shift 2 ;;
        --lookback) LOOKBACK="${2:-20}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown: $1"; usage; exit 1 ;;
    esac
done

fetch_data() {
    local ticker="$1"
    local period1=$(date -d "-${LOOKBACK} days" +%s 2>/dev/null || date -v-${LOOKBACK}d +%s 2>/dev/null)
    local period2=$(date +%s)
    
    curl -sf "https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?period1=${period1}&period2=${period2}&interval=1d" \
        -H "User-Agent: Mozilla/5.0" 2>/dev/null
}

analyze() {
    python3 << 'PYEOF'
import json, sys, os, math
from datetime import datetime, timezone

lookback = int(os.environ.get("LOOKBACK", "20"))
sectors = os.environ.get("SECTORS", "").split()
benchmark = os.environ.get("BENCHMARK", "SPY")
all_tickers = [benchmark] + sectors

# Fetch and parse price data
prices = {}
for ticker in all_tickers:
    try:
        import urllib.request
        url = f"https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?range={lookback}d&interval=1d"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        resp = urllib.request.urlopen(req, timeout=10)
        data = json.loads(resp.read())
        closes = data["chart"]["result"][0]["indicators"]["quote"][0]["close"]
        # Filter None values
        closes = [c for c in closes if c is not None]
        if len(closes) >= 5:
            prices[ticker] = closes
    except Exception as e:
        pass

if benchmark not in prices:
    print(json.dumps({"error": "Could not fetch benchmark data"}))
    sys.exit(1)

spy_prices = prices[benchmark]
spy_return_total = (spy_prices[-1] / spy_prices[0] - 1) * 100
spy_return_5d = (spy_prices[-1] / spy_prices[-5] - 1) * 100 if len(spy_prices) >= 5 else 0

# Calculate sector metrics
results = []
for sector in sectors:
    if sector not in prices:
        continue
    p = prices[sector]
    sp = spy_prices[-len(p):] if len(p) < len(spy_prices) else spy_prices
    
    # Total period return
    total_return = (p[-1] / p[0] - 1) * 100
    
    # 5-day return (short-term momentum)
    ret_5d = (p[-1] / p[-5] - 1) * 100 if len(p) >= 5 else 0
    
    # Relative strength vs SPY (alpha)
    alpha_total = total_return - spy_return_total
    alpha_5d = ret_5d - spy_return_5d
    
    # Momentum score: weighted combo of short + long term alpha
    # 60% weight on 5d (recent), 40% on full period
    momentum_score = alpha_5d * 0.6 + alpha_total * 0.4
    
    # Trend consistency: count of positive daily returns
    daily_returns = [(p[i]/p[i-1] - 1) for i in range(1, len(p))]
    win_rate = sum(1 for r in daily_returns if r > 0) / len(daily_returns) * 100 if daily_returns else 50
    
    # Volatility (annualized)
    if daily_returns:
        vol = (sum((r - sum(daily_returns)/len(daily_returns))**2 for r in daily_returns) / len(daily_returns)) ** 0.5
        vol_annual = vol * (252 ** 0.5) * 100
    else:
        vol_annual = 0
    
    # Risk-adjusted momentum (Sharpe-like)
    risk_adj = momentum_score / (vol_annual / 100) if vol_annual > 0 else 0
    
    # Acceleration: is 5d momentum stronger than full-period?
    acceleration = "accelerating" if abs(alpha_5d) > abs(alpha_total) and alpha_5d * alpha_total > 0 else \
                   "decelerating" if abs(alpha_5d) < abs(alpha_total) and alpha_5d * alpha_total > 0 else \
                   "reversing"
    
    results.append({
        "sector": sector,
        "price": round(p[-1], 2),
        "return_total": round(total_return, 2),
        "return_5d": round(ret_5d, 2),
        "alpha_total": round(alpha_total, 2),
        "alpha_5d": round(alpha_5d, 2),
        "momentum_score": round(momentum_score, 2),
        "risk_adjusted": round(risk_adj, 2),
        "win_rate": round(win_rate, 1),
        "volatility": round(vol_annual, 1),
        "acceleration": acceleration
    })

# Sort by momentum score (strongest first)
results.sort(key=lambda x: x["momentum_score"], reverse=True)

# Identify leaders and laggards (top/bottom 3)
leaders = results[:3]
laggards = results[-3:]

# Rotation signal
# If leaders are defensive (XLU, XLP, XLV, XLRE) = risk-off rotation
# If leaders are cyclical (XLE, XLF, XLI, XLB, XLY, XLK, XLC) = risk-on rotation
defensive = {"XLU", "XLP", "XLV", "XLRE"}
cyclical = {"XLE", "XLF", "XLI", "XLB", "XLY", "XLK", "XLC"}

leader_sectors = {r["sector"] for r in leaders}
def_count = len(leader_sectors & defensive)
cyc_count = len(leader_sectors & cyclical)

if cyc_count >= 2:
    rotation = "risk-on"
    rotation_conf = min(0.95, 0.5 + cyc_count * 0.15)
elif def_count >= 2:
    rotation = "risk-off"
    rotation_conf = min(0.95, 0.5 + def_count * 0.15)
else:
    rotation = "mixed"
    rotation_conf = 0.4

# Sector breadth (% of sectors outperforming SPY)
breadth = sum(1 for r in results if r["alpha_total"] > 0) / len(results) * 100 if results else 50

# Dispersion (spread between best and worst sector)
if results:
    dispersion = results[0]["return_total"] - results[-1]["return_total"]
else:
    dispersion = 0

timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

output = {
    "signal_type": "sector-momentum",
    "timestamp": timestamp,
    "source": "sector-momentum-v1",
    "lookback_days": lookback,
    "benchmark": {
        "ticker": benchmark,
        "return_total": round(spy_return_total, 2),
        "return_5d": round(spy_return_5d, 2),
        "price": round(spy_prices[-1], 2)
    },
    "rotation": {
        "signal": rotation,
        "confidence": round(rotation_conf, 2),
        "breadth_pct": round(breadth, 1),
        "dispersion": round(dispersion, 2)
    },
    "leaders": [{"sector": r["sector"], "alpha": r["alpha_total"], "momentum": r["momentum_score"], "accel": r["acceleration"]} for r in leaders],
    "laggards": [{"sector": r["sector"], "alpha": r["alpha_total"], "momentum": r["momentum_score"], "accel": r["acceleration"]} for r in laggards],
    "sectors": results,
    "confidence": round(rotation_conf, 2)
}

print(json.dumps(output, indent=2))
PYEOF
}

push_signal() {
    local signal_json="$1"
    local text=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
rot = d['rotation']
ldrs = d['leaders']
lags = d['laggards']
bm = d['benchmark']

lines = ['📊 SECTOR MOMENTUM SCANNER']
lines.append(f'Rotation: {rot[\"signal\"].upper()} ({rot[\"confidence\"]*100:.0f}% conf)')
lines.append(f'Breadth: {rot[\"breadth_pct\"]:.0f}% sectors beating SPY')
lines.append(f'Dispersion: {rot[\"dispersion\"]:.1f}% (best-worst spread)')
lines.append(f'SPY: {bm[\"return_total\"]:+.2f}% ({d[\"lookback_days\"]}d), {bm[\"return_5d\"]:+.2f}% (5d)')
lines.append('')
lines.append('🟢 LEADERS:')
for l in ldrs:
    lines.append(f'  {l[\"sector\"]}: α={l[\"alpha\"]:+.2f}%, mom={l[\"momentum\"]:.2f} ({l[\"accel\"]})')
lines.append('')
lines.append('🔴 LAGGARDS:')
for l in lags:
    lines.append(f'  {l[\"sector\"]}: α={l[\"alpha\"]:+.2f}%, mom={l[\"momentum\"]:.2f} ({l[\"accel\"]})')

print('\n'.join(lines))
" <<< "$signal_json")

    local tmpfile=$(mktemp)
    cat > "$tmpfile" << MSGEOF
{
  "to": "Lotbot",
  "type": "notification",
  "topic": "gekko-signal",
  "encrypted": false,
  "payload": {
    "signal_type": "sector-momentum",
    "text": $(python3 -c "import json; print(json.dumps('''$text'''))" 2>/dev/null || echo "\"Sector momentum signal\""),
    "data": $signal_json,
    "source": "$SIGNAL_NAME"
  }
}
MSGEOF

    curl -sf -X POST "$CLAWTALK_URL" \
        -H "Authorization: Bearer $CLAWTALK_KEY" \
        -H "Content-Type: application/json" \
        --data-binary @"$tmpfile" > /dev/null 2>&1
    local rc=$?
    rm -f "$tmpfile"
    return $rc
}

run_scan() {
    export LOOKBACK SECTORS BENCHMARK
    local result
    result=$(analyze 2>/dev/null)
    
    if [[ -z "$result" ]] || echo "$result" | grep -q '"error"'; then
        echo "Error: Failed to fetch/analyze data" >&2
        return 1
    fi
    
    if $JSON_MODE; then
        echo "$result"
    else
        # Human-readable output
        python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
rot = d['rotation']
bm = d['benchmark']

print('=' * 60)
print('  SECTOR MOMENTUM SCANNER v1.0')
print('=' * 60)
print(f'  Timestamp: {d[\"timestamp\"]}')
print(f'  Lookback:  {d[\"lookback_days\"]} days')
print()
print(f'  ROTATION:  {rot[\"signal\"].upper()} ({rot[\"confidence\"]*100:.0f}% confidence)')
print(f'  Breadth:   {rot[\"breadth_pct\"]:.0f}% sectors > SPY')
print(f'  Dispersion: {rot[\"dispersion\"]:.1f}% (best-worst)')
print()
print(f'  SPY: \${bm[\"price\"]} | {bm[\"return_total\"]:+.2f}% ({d[\"lookback_days\"]}d) | {bm[\"return_5d\"]:+.2f}% (5d)')
print()
print('  ┌─────────────────────────────────────────────────────┐')
print('  │  Sector  Return   Alpha   Mom    Vol   Win%  Accel  │')
print('  ├─────────────────────────────────────────────────────┤')
for i, s in enumerate(d['sectors']):
    marker = '🟢' if i < 3 else '🔴' if i >= len(d['sectors'])-3 else '  '
    print(f'  │{marker}{s[\"sector\"]:>5} {s[\"return_total\"]:>+7.2f}% {s[\"alpha_total\"]:>+6.2f}% {s[\"momentum_score\"]:>+6.2f} {s[\"volatility\"]:>5.1f}% {s[\"win_rate\"]:>4.0f}% {s[\"acceleration\"]:>11} │')
print('  └─────────────────────────────────────────────────────┘')
print()
print('  LEADERS:', ', '.join(f'{l[\"sector\"]}({l[\"alpha\"]:+.1f}%)' for l in d['leaders']))
print('  LAGGARDS:', ', '.join(f'{l[\"sector\"]}({l[\"alpha\"]:+.1f}%)' for l in d['laggards']))
print()
" <<< "$result"
    fi
    
    if $PUSH_MODE; then
        if push_signal "$result"; then
            echo "  ✅ Signal pushed to Lotbot via ClawTalk" >&2
        else
            echo "  ❌ Failed to push signal" >&2
        fi
    fi
}

if $DAEMON_MODE; then
    echo "Sector Momentum Scanner daemon started (interval: ${DAEMON_INTERVAL}s)"
    while true; do
        run_scan > /dev/null
        sleep "$DAEMON_INTERVAL"
    done
else
    run_scan
fi
