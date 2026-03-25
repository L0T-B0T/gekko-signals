#!/usr/bin/env bash
# Volatility Surface Monitor v1.0 — Gekko Signal Tool #9
# Tracks historical vs implied volatility across key assets
# Detects vol compression/expansion for mean-reversion signals
set -euo pipefail

LOOKBACK_DAYS=30
ASSETS=(SPY QQQ XLE VIX GLD TLT IWM)
OUTPUT_JSON=""
OUTPUT_HUMAN=""

fetch_vol() {
    local sym=$1
    python3 << PYEOF
import urllib.request, json, sys, math
from datetime import datetime, timedelta

sym = "$sym"
end = datetime.now()
start = end - timedelta(days=${LOOKBACK_DAYS} + 10)
p1 = int(start.timestamp())
p2 = int(end.timestamp())

url = f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}?period1={p1}&period2={p2}&interval=1d"
headers = {"User-Agent": "Mozilla/5.0"}
req = urllib.request.Request(url, headers=headers)

try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.load(resp)
    
    result = data["chart"]["result"][0]
    closes = result["indicators"]["quote"][0]["close"]
    closes = [c for c in closes if c is not None]
    
    if len(closes) < 5:
        print(json.dumps({"symbol": sym, "error": "insufficient_data"}))
        sys.exit(0)
    
    # Calculate daily returns
    returns = [(closes[i] - closes[i-1]) / closes[i-1] for i in range(1, len(closes))]
    
    # Historical volatility (annualized)
    if len(returns) >= 2:
        mean_ret = sum(returns) / len(returns)
        variance = sum((r - mean_ret)**2 for r in returns) / (len(returns) - 1)
        hv = math.sqrt(variance) * math.sqrt(252) * 100  # Annualized %
    else:
        hv = 0
    
    # Recent vol (5-day)
    recent = returns[-5:] if len(returns) >= 5 else returns
    if len(recent) >= 2:
        mean_r = sum(recent) / len(recent)
        var_r = sum((r - mean_r)**2 for r in recent) / (len(recent) - 1)
        rv5 = math.sqrt(var_r) * math.sqrt(252) * 100
    else:
        rv5 = 0
    
    # Vol ratio (recent/historical) — >1.5 = expansion, <0.7 = compression
    vol_ratio = rv5 / hv if hv > 0 else 1.0
    
    # Max drawdown in period
    peak = closes[0]
    max_dd = 0
    for c in closes:
        if c > peak: peak = c
        dd = (peak - c) / peak
        if dd > max_dd: max_dd = dd
    
    # Current price and 30d return
    current = closes[-1]
    ret_30d = (closes[-1] - closes[0]) / closes[0] * 100
    
    # Signal
    if vol_ratio > 2.0:
        signal = "VOL_SPIKE"
    elif vol_ratio > 1.5:
        signal = "EXPANDING"
    elif vol_ratio < 0.5:
        signal = "COMPRESSED"
    elif vol_ratio < 0.7:
        signal = "CONTRACTING"
    else:
        signal = "NORMAL"
    
    print(json.dumps({
        "symbol": sym,
        "current": round(current, 2),
        "return_30d_pct": round(ret_30d, 2),
        "hv_30d_pct": round(hv, 2),
        "rv_5d_pct": round(rv5, 2),
        "vol_ratio": round(vol_ratio, 2),
        "max_drawdown_pct": round(max_dd * 100, 2),
        "signal": signal
    }))
    
except Exception as e:
    print(json.dumps({"symbol": sym, "error": str(e)}))
PYEOF
}

echo "=== Volatility Surface Monitor v1.0 ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Lookback: ${LOOKBACK_DAYS}d | Recent: 5d"
echo ""

ALL_JSON="[]"
for sym in "${ASSETS[@]}"; do
    result=$(fetch_vol "$sym" 2>/dev/null)
    if [ -n "$result" ]; then
        ALL_JSON=$(echo "$ALL_JSON" | python3 -c "
import sys, json
arr = json.load(sys.stdin)
arr.append(json.loads('$result'))
print(json.dumps(arr))
" 2>/dev/null || echo "$ALL_JSON")
        
        # Human output
        signal=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('signal','?'))" 2>/dev/null)
        sym_out=$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'error' in d:
    print(f\"  {d['symbol']}: ERROR — {d['error']}\")
else:
    emoji = {'VOL_SPIKE':'🔴','EXPANDING':'🟠','COMPRESSED':'🟢','CONTRACTING':'🟡','NORMAL':'⚪'}
    e = emoji.get(d['signal'], '⚪')
    print(f\"  {e} {d['symbol']:4s} | HV30d:{d['hv_30d_pct']:5.1f}% | RV5d:{d['rv_5d_pct']:5.1f}% | Ratio:{d['vol_ratio']:.2f} | 30dRet:{d['return_30d_pct']:+.1f}% | MaxDD:{d['max_drawdown_pct']:.1f}% | {d['signal']}\")
" 2>/dev/null)
        echo "$sym_out"
    fi
    sleep 1  # Rate limit
done

echo ""

# Summary analysis
echo "$ALL_JSON" | python3 -c "
import sys, json
assets = json.load(sys.stdin)
valid = [a for a in assets if 'error' not in a]

if not valid:
    print('No valid data')
    sys.exit(0)

spikes = [a for a in valid if a['signal'] in ('VOL_SPIKE', 'EXPANDING')]
compressed = [a for a in valid if a['signal'] in ('COMPRESSED', 'CONTRACTING')]
avg_ratio = sum(a['vol_ratio'] for a in valid) / len(valid)

print('--- SUMMARY ---')
print(f'Avg vol ratio: {avg_ratio:.2f}')
if avg_ratio > 1.5:
    print('REGIME: HIGH VOL — mean-reversion opportunities likely')
elif avg_ratio < 0.7:
    print('REGIME: LOW VOL — breakout/expansion imminent')
else:
    print('REGIME: NORMAL — no extreme positioning signal')

if spikes:
    print(f'Vol spikes ({len(spikes)}): {\" \".join(a[\"symbol\"] for a in spikes)}')
if compressed:
    print(f'Compressed ({len(compressed)}): {\" \".join(a[\"symbol\"] for a in compressed)}')

# Cross-asset divergence
if any(a['symbol'] == 'XLE' for a in valid) and any(a['symbol'] == 'SPY' for a in valid):
    xle = next(a for a in valid if a['symbol'] == 'XLE')
    spy = next(a for a in valid if a['symbol'] == 'SPY')
    if abs(xle['vol_ratio'] - spy['vol_ratio']) > 0.5:
        leader = 'XLE' if xle['vol_ratio'] > spy['vol_ratio'] else 'SPY'
        print(f'⚠️  XLE/SPY vol divergence: {leader} leading (ratio gap {abs(xle[\"vol_ratio\"] - spy[\"vol_ratio\"]):.2f})')

# Output JSON
print()
print('--- JSON OUTPUT ---')
output = {
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'regime': 'high_vol' if avg_ratio > 1.5 else ('low_vol' if avg_ratio < 0.7 else 'normal'),
    'avg_vol_ratio': round(avg_ratio, 2),
    'assets': valid,
    'alerts': [a['symbol'] for a in spikes],
    'compressed': [a['symbol'] for a in compressed]
}
print(json.dumps(output, indent=2))
" 2>/dev/null

