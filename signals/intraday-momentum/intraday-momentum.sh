#!/usr/bin/env bash
# Intraday Momentum Monitor v1.0
# Tracks momentum shifts during market hours for real-time Gekko signals
# Author: Aaron (RealAaron)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../../output"
mkdir -p "$OUTPUT_DIR"

TICKERS="SPY QQQ XLE XLF TLT GLD VIX=^VIX"

usage() {
  echo "Usage: $0 [--json] [--daemon INTERVAL_SEC] [--tickers 'SYM1 SYM2']"
  echo "  --json          JSON output only"
  echo "  --daemon SEC    Run continuously, check every SEC seconds"
  echo "  --tickers LIST  Override default tickers"
  exit 0
}

JSON_ONLY=false
DAEMON_INTERVAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_ONLY=true; shift ;;
    --daemon) DAEMON_INTERVAL="$2"; shift 2 ;;
    --tickers) TICKERS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) shift ;;
  esac
done

fetch_intraday() {
  local sym="$1"
  local yahoo_sym="$sym"
  # Handle aliases like VIX=^VIX
  if [[ "$sym" == *=* ]]; then
    yahoo_sym="${sym#*=}"
    sym="${sym%%=*}"
  fi
  
  python3 -c "
import urllib.request, json, sys
url = 'https://query1.finance.yahoo.com/v8/finance/chart/${yahoo_sym}?range=1d&interval=5m'
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
try:
    data = json.loads(urllib.request.urlopen(req, timeout=10).read())
    result = data['chart']['result'][0]
    meta = result['meta']
    quotes = result['indicators']['quote'][0]
    closes = [c for c in quotes['close'] if c is not None]
    volumes = [v for v in quotes['volume'] if v is not None]
    highs = [h for h in quotes['high'] if h is not None]
    lows = [l for l in quotes['low'] if l is not None]
    
    if len(closes) < 2:
        print(json.dumps({'symbol': '${sym}', 'error': 'insufficient_data'}))
        sys.exit(0)
    
    prev_close = meta.get('chartPreviousClose', meta.get('previousClose', closes[0]))
    current = closes[-1]
    day_open = closes[0]
    day_high = max(highs) if highs else current
    day_low = min(lows) if lows else current
    
    # Momentum: last 3 candles direction
    recent = closes[-min(4, len(closes)):]
    momentum = (recent[-1] - recent[0]) / recent[0] * 100 if len(recent) >= 2 else 0
    
    # VWAP approximation (volume-weighted average of closes)
    if volumes and len(volumes) == len(closes):
        total_vol = sum(volumes)
        vwap = sum(c*v for c,v in zip(closes, volumes)) / total_vol if total_vol > 0 else current
    else:
        vwap = sum(closes) / len(closes)
    
    # Price vs VWAP
    vwap_deviation = (current - vwap) / vwap * 100
    
    # Day change
    day_change = (current - prev_close) / prev_close * 100
    
    # Range position (0=at low, 100=at high)
    day_range = day_high - day_low
    range_position = ((current - day_low) / day_range * 100) if day_range > 0 else 50
    
    # Momentum classification
    if momentum > 0.3:
        mom_signal = 'strong_up'
    elif momentum > 0.1:
        mom_signal = 'up'
    elif momentum > -0.1:
        mom_signal = 'flat'
    elif momentum > -0.3:
        mom_signal = 'down'
    else:
        mom_signal = 'strong_down'
    
    print(json.dumps({
        'symbol': '${sym}',
        'current': round(current, 2),
        'prev_close': round(prev_close, 2),
        'day_change_pct': round(day_change, 3),
        'vwap': round(vwap, 2),
        'vwap_deviation_pct': round(vwap_deviation, 3),
        'momentum_15m': round(momentum, 3),
        'momentum_signal': mom_signal,
        'range_position': round(range_position, 1),
        'day_high': round(day_high, 2),
        'day_low': round(day_low, 2),
        'candles': len(closes),
        'above_vwap': current > vwap
    }))
except Exception as e:
    print(json.dumps({'symbol': '${sym}', 'error': str(e)}))
" 2>/dev/null
}

run_scan() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  local results=()
  local bullish=0
  local bearish=0
  local total=0
  
  for ticker in $TICKERS; do
    local sym="${ticker%%=*}"
    local data
    data=$(fetch_intraday "$ticker")
    if echo "$data" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
      results+=("$data")
      local signal
      signal=$(echo "$data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('momentum_signal','flat'))")
      total=$((total+1))
      case "$signal" in
        strong_up|up) bullish=$((bullish+1)) ;;
        strong_down|down) bearish=$((bearish+1)) ;;
      esac
    fi
    sleep 0.5
  done
  
  # Overall momentum score
  local score=0
  if [ $total -gt 0 ]; then
    score=$(python3 -c "print(round(($bullish - $bearish) / $total * 100, 1))")
  fi
  
  local market_momentum="neutral"
  if [ "$(echo "$score > 30" | bc -l 2>/dev/null || python3 -c "print('1' if $score > 30 else '0')")" = "1" ]; then
    market_momentum="bullish"
  elif [ "$(echo "$score < -30" | bc -l 2>/dev/null || python3 -c "print('1' if $score < -30 else '0')")" = "1" ]; then
    market_momentum="bearish"
  fi
  
  # Build JSON output
  local json
  json=$(python3 -c "
import json, sys
results = [json.loads(r) for r in '''$(printf '%s\n' "${results[@]}")'''.strip().split('\n') if r.strip()]
output = {
    'timestamp': '$ts',
    'market_momentum': '$market_momentum',
    'momentum_score': $score,
    'bullish_count': $bullish,
    'bearish_count': $bearish,
    'neutral_count': $total - $bullish - $bearish,
    'total_tickers': $total,
    'tickers': results
}
print(json.dumps(output, indent=2))
")
  
  echo "$json" > "$OUTPUT_DIR/intraday-momentum.json"
  
  if [ "$JSON_ONLY" = true ]; then
    echo "$json"
    return
  fi
  
  # Human-readable output
  echo "=== INTRADAY MOMENTUM MONITOR v1.0 ==="
  echo "Time: $ts"
  echo "Market Momentum: $market_momentum (score: ${score}%)"
  echo "Bullish: $bullish | Bearish: $bearish | Neutral: $((total - bullish - bearish))"
  echo ""
  echo "--- TICKER DETAILS ---"
  
  for r in "${results[@]}"; do
    echo "$r" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sym = d['symbol']
chg = d['day_change_pct']
mom = d['momentum_signal']
vwap_dev = d['vwap_deviation_pct']
rng = d['range_position']
above = '↑' if d['above_vwap'] else '↓'
icon = '🟢' if mom in ('strong_up','up') else '🔴' if mom in ('strong_down','down') else '⚪'
print(f'  {icon} {sym:5s} {chg:+6.2f}% | Mom: {mom:12s} | VWAP: {vwap_dev:+.2f}% {above} | Range: {rng:.0f}%')
"
  done
  
  echo ""
  echo "JSON output: $OUTPUT_DIR/intraday-momentum.json"
}

if [ "$DAEMON_INTERVAL" -gt 0 ]; then
  echo "[$(date -u +%H:%M:%S)] Starting Intraday Momentum Daemon (${DAEMON_INTERVAL}s interval)"
  while true; do
    run_scan
    echo "---"
    sleep "$DAEMON_INTERVAL"
  done
else
  run_scan
fi
