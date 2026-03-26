#!/usr/bin/env bash
# Pre-Earnings Volatility Analyzer v1.0
# Analyzes implied vs realized vol before earnings, estimates expected move
# Usage: ./pre-earnings-vol.sh [TICKER] [--json] [--push]
set -euo pipefail

TICKER="${1:-NVDA}"
JSON_MODE=false
PUSH_MODE=false

for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        --push) PUSH_MODE=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/cache"
mkdir -p "$CACHE_DIR"

# Fetch stock data from Yahoo Finance
fetch_yahoo() {
    local ticker="$1"
    local period="${2:-5d}"
    local interval="${3:-1d}"
    
    # Get crumb + cookie
    local cookie_file="$CACHE_DIR/yahoo_cookie_$$"
    local crumb
    crumb=$(curl -s -c "$cookie_file" 'https://query2.finance.yahoo.com/v1/test/getcrumb' \
        -H 'User-Agent: Mozilla/5.0' 2>/dev/null || echo "")
    
    if [ -z "$crumb" ]; then
        # Fallback: use chart API without crumb
        curl -s "https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?range=${period}&interval=${interval}" \
            -H 'User-Agent: Mozilla/5.0' 2>/dev/null
    else
        curl -s -b "$cookie_file" \
            "https://query2.finance.yahoo.com/v8/finance/chart/${ticker}?range=${period}&interval=${interval}&crumb=${crumb}" \
            -H 'User-Agent: Mozilla/5.0' 2>/dev/null
    fi
    rm -f "$cookie_file"
}

# Fetch options chain
fetch_options() {
    local ticker="$1"
    curl -s "https://query1.finance.yahoo.com/v7/finance/options/${ticker}" \
        -H 'User-Agent: Mozilla/5.0' 2>/dev/null
}

# Main analysis
analyze() {
    local ticker="$TICKER"
    local ts_now
    ts_now=$(date +%s)
    
    # 1. Get current price + 30d history
    local hist_data
    hist_data=$(fetch_yahoo "$ticker" "1mo" "1d")
    
    # 2. Get options chain
    local opts_data
    opts_data=$(fetch_options "$ticker")
    
    # 3. Analyze with Python
    python3 << 'PYEOF'
import json, sys, math, datetime

ticker = "$TICKER"

# Parse historical data
try:
    hist = json.loads('''HIST_PLACEHOLDER''')
    chart = hist.get('chart', {}).get('result', [{}])[0]
    closes = chart.get('indicators', {}).get('quote', [{}])[0].get('close', [])
    timestamps = chart.get('timestamp', [])
    meta = chart.get('meta', {})
    current_price = meta.get('regularMarketPrice', 0) or (closes[-1] if closes else 0)
except:
    closes = []
    timestamps = []
    current_price = 0

# Parse options data
try:
    opts = json.loads('''OPTS_PLACEHOLDER''')
    opt_chain = opts.get('optionChain', {}).get('result', [{}])[0]
    quote = opt_chain.get('quote', {})
    if not current_price:
        current_price = quote.get('regularMarketPrice', 0)
    
    expiration_dates = opt_chain.get('expirationDates', [])
    options = opt_chain.get('options', [{}])[0]
    calls = options.get('calls', [])
    puts = options.get('puts', [])
except:
    quote = {}
    expiration_dates = []
    calls = []
    puts = []
    options = {}

# Calculate realized volatility (30d)
rv_30d = 0
if len(closes) >= 5:
    valid_closes = [c for c in closes if c is not None and c > 0]
    if len(valid_closes) >= 2:
        returns = []
        for i in range(1, len(valid_closes)):
            r = math.log(valid_closes[i] / valid_closes[i-1])
            returns.append(r)
        if returns:
            mean_r = sum(returns) / len(returns)
            var = sum((r - mean_r)**2 for r in returns) / max(len(returns)-1, 1)
            rv_30d = math.sqrt(var * 252) * 100  # annualized

# Find ATM straddle for nearest expiry
atm_call_iv = 0
atm_put_iv = 0
atm_call_price = 0
atm_put_price = 0
days_to_expiry = 0
nearest_expiry = ""

if calls and puts and current_price > 0:
    # Find nearest-to-ATM strikes
    best_call = min(calls, key=lambda c: abs(c.get('strike',0) - current_price))
    best_put = min(puts, key=lambda p: abs(p.get('strike',0) - current_price))
    
    atm_call_iv = best_call.get('impliedVolatility', 0) * 100
    atm_put_iv = best_put.get('impliedVolatility', 0) * 100
    atm_call_price = best_call.get('lastPrice', 0) or best_call.get('ask', 0)
    atm_put_price = best_put.get('lastPrice', 0) or best_put.get('ask', 0)
    
    # Days to expiry
    exp_ts = options.get('expirationDate', 0)
    if exp_ts:
        now = datetime.datetime.now().timestamp()
        days_to_expiry = max(1, int((exp_ts - now) / 86400))
        nearest_expiry = datetime.datetime.fromtimestamp(exp_ts).strftime('%Y-%m-%d')

# Expected move from straddle
straddle_price = atm_call_price + atm_put_price
expected_move_pct = (straddle_price / current_price * 100) if current_price > 0 else 0

# IV percentile (rough: compare current ATM IV to 30d HV)
avg_iv = (atm_call_iv + atm_put_iv) / 2 if atm_call_iv and atm_put_iv else 0
iv_rv_ratio = avg_iv / rv_30d if rv_30d > 0 else 0

# Put/Call skew
skew = atm_put_iv - atm_call_iv

# Price range (5d)
valid_5d = [c for c in closes[-5:] if c is not None]
range_5d_hi = max(valid_5d) if valid_5d else 0
range_5d_lo = min(valid_5d) if valid_5d else 0
range_5d_pct = ((range_5d_hi - range_5d_lo) / range_5d_lo * 100) if range_5d_lo > 0 else 0

# Determine signal
signal = "NEUTRAL"
if iv_rv_ratio > 1.5:
    signal = "VOL_PREMIUM_HIGH"  # IV much higher than HV = expensive options
elif iv_rv_ratio < 0.8:
    signal = "VOL_PREMIUM_LOW"  # IV low vs HV = cheap options
if skew > 10:
    signal += "_BEARISH_SKEW"
elif skew < -5:
    signal += "_BULLISH_SKEW"

result = {
    "ticker": ticker,
    "current_price": round(current_price, 2),
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    "realized_vol": {
        "rv_30d_annualized": round(rv_30d, 1),
        "range_5d_pct": round(range_5d_pct, 1),
        "range_5d": f"${round(range_5d_lo, 2)}-${round(range_5d_hi, 2)}"
    },
    "implied_vol": {
        "atm_call_iv": round(atm_call_iv, 1),
        "atm_put_iv": round(atm_put_iv, 1),
        "avg_iv": round(avg_iv, 1),
        "iv_rv_ratio": round(iv_rv_ratio, 2)
    },
    "expected_move": {
        "straddle_price": round(straddle_price, 2),
        "expected_move_pct": round(expected_move_pct, 1),
        "expected_range": f"${round(current_price * (1 - expected_move_pct/100), 2)}-${round(current_price * (1 + expected_move_pct/100), 2)}"
    },
    "skew": {
        "put_call_skew": round(skew, 1),
        "interpretation": "bearish" if skew > 5 else "bullish" if skew < -5 else "neutral"
    },
    "nearest_expiry": nearest_expiry,
    "days_to_expiry": days_to_expiry,
    "signal": signal,
    "trading_implications": []
}

# Add trading implications
if iv_rv_ratio > 1.3:
    result["trading_implications"].append(f"Options expensive — IV/RV ratio {round(iv_rv_ratio,1)}x. Consider selling premium or iron condor.")
else:
    result["trading_implications"].append(f"Options fairly priced — IV/RV ratio {round(iv_rv_ratio,1)}x.")

if expected_move_pct > 0:
    result["trading_implications"].append(f"Market expects ±{round(expected_move_pct,1)}% move ({result['expected_move']['expected_range']})")

if skew > 8:
    result["trading_implications"].append(f"Put skew elevated ({round(skew,1)}pts) — downside protection demand high")
elif skew < -5:
    result["trading_implications"].append(f"Call skew ({round(abs(skew),1)}pts) — upside speculation elevated")

print(json.dumps(result, indent=2))
PYEOF
}

# Run analysis with data substitution
run_analysis() {
    local hist_data opts_data
    hist_data=$(fetch_yahoo "$TICKER" "1mo" "1d" 2>/dev/null | tr "'" "'")
    opts_data=$(fetch_options "$TICKER" 2>/dev/null | tr "'" "'")
    
    # Write data to temp files for Python to read
    local tmp_hist="$CACHE_DIR/hist_$$.json"
    local tmp_opts="$CACHE_DIR/opts_$$.json"
    echo "$hist_data" > "$tmp_hist"
    echo "$opts_data" > "$tmp_opts"
    
    python3 << PYEOF
import json, sys, math, datetime

ticker = "${TICKER}"

# Load data from files
try:
    with open("$tmp_hist") as f:
        hist = json.load(f)
    chart = hist.get('chart', {}).get('result', [{}])[0]
    closes = chart.get('indicators', {}).get('quote', [{}])[0].get('close', [])
    timestamps = chart.get('timestamp', [])
    meta = chart.get('meta', {})
    current_price = meta.get('regularMarketPrice', 0) or (closes[-1] if closes else 0)
except:
    closes = []
    timestamps = []
    current_price = 0

try:
    with open("$tmp_opts") as f:
        opts = json.load(f)
    opt_chain = opts.get('optionChain', {}).get('result', [{}])[0]
    quote = opt_chain.get('quote', {})
    if not current_price:
        current_price = quote.get('regularMarketPrice', 0)
    
    options = opt_chain.get('options', [{}])[0]
    calls = options.get('calls', [])
    puts = options.get('puts', [])
except:
    quote = {}
    calls = []
    puts = []
    options = {}

# Realized volatility (30d)
rv_30d = 0
valid_closes = [c for c in closes if c is not None and c > 0]
if len(valid_closes) >= 2:
    returns = [math.log(valid_closes[i] / valid_closes[i-1]) for i in range(1, len(valid_closes))]
    if returns:
        mean_r = sum(returns) / len(returns)
        var = sum((r - mean_r)**2 for r in returns) / max(len(returns)-1, 1)
        rv_30d = math.sqrt(var * 252) * 100

# ATM straddle
atm_call_iv = atm_put_iv = atm_call_price = atm_put_price = 0
days_to_expiry = 0
nearest_expiry = ""

if calls and puts and current_price > 0:
    best_call = min(calls, key=lambda c: abs(c.get('strike',0) - current_price))
    best_put = min(puts, key=lambda p: abs(p.get('strike',0) - current_price))
    
    atm_call_iv = best_call.get('impliedVolatility', 0) * 100
    atm_put_iv = best_put.get('impliedVolatility', 0) * 100
    atm_call_price = best_call.get('lastPrice', 0) or best_call.get('ask', 0)
    atm_put_price = best_put.get('lastPrice', 0) or best_put.get('ask', 0)
    
    exp_ts = options.get('expirationDate', 0)
    if exp_ts:
        now = datetime.datetime.now().timestamp()
        days_to_expiry = max(1, int((exp_ts - now) / 86400))
        nearest_expiry = datetime.datetime.fromtimestamp(exp_ts).strftime('%Y-%m-%d')

straddle_price = atm_call_price + atm_put_price
expected_move_pct = (straddle_price / current_price * 100) if current_price > 0 else 0
avg_iv = (atm_call_iv + atm_put_iv) / 2 if atm_call_iv and atm_put_iv else 0
iv_rv_ratio = avg_iv / rv_30d if rv_30d > 0 else 0
skew = atm_put_iv - atm_call_iv

valid_5d = [c for c in closes[-5:] if c is not None]
range_5d_hi = max(valid_5d) if valid_5d else 0
range_5d_lo = min(valid_5d) if valid_5d else 0
range_5d_pct = ((range_5d_hi - range_5d_lo) / range_5d_lo * 100) if range_5d_lo > 0 else 0

signal = "NEUTRAL"
if iv_rv_ratio > 1.5: signal = "VOL_PREMIUM_HIGH"
elif iv_rv_ratio < 0.8: signal = "VOL_PREMIUM_LOW"
if skew > 10: signal += "_BEARISH_SKEW"
elif skew < -5: signal += "_BULLISH_SKEW"

result = {
    "ticker": ticker,
    "price": round(current_price, 2),
    "ts": datetime.datetime.utcnow().isoformat() + "Z",
    "rv30d": round(rv_30d, 1),
    "range5d_pct": round(range_5d_pct, 1),
    "atm_call_iv": round(atm_call_iv, 1),
    "atm_put_iv": round(atm_put_iv, 1),
    "avg_iv": round(avg_iv, 1),
    "iv_rv_ratio": round(iv_rv_ratio, 2),
    "straddle": round(straddle_price, 2),
    "expected_move_pct": round(expected_move_pct, 1),
    "skew": round(skew, 1),
    "nearest_expiry": nearest_expiry,
    "dte": days_to_expiry,
    "signal": signal,
    "implications": []
}

if iv_rv_ratio > 1.3:
    result["implications"].append(f"Options expensive (IV/RV {round(iv_rv_ratio,1)}x) — sell premium or iron condor")
elif iv_rv_ratio > 0:
    result["implications"].append(f"Options fair (IV/RV {round(iv_rv_ratio,1)}x)")
if expected_move_pct > 0:
    lo = round(current_price * (1 - expected_move_pct/100), 2)
    hi = round(current_price * (1 + expected_move_pct/100), 2)
    result["implications"].append(f"Expected ±{round(expected_move_pct,1)}% move (\\${lo}-\\${hi})")
if skew > 8:
    result["implications"].append(f"Elevated put skew ({round(skew,1)}pts) — downside protection bid")
elif skew < -5:
    result["implications"].append(f"Call skew ({round(abs(skew),1)}pts) — upside speculation")

print(json.dumps(result, indent=2))
PYEOF
    
    rm -f "$tmp_hist" "$tmp_opts"
}

# Execute
RESULT=$(run_analysis 2>/dev/null)

if $JSON_MODE; then
    echo "$RESULT"
else
    echo "=== PRE-EARNINGS VOL ANALYSIS: $TICKER ==="
    echo "$RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f'Price: \${d[\"price\"]}')
    print(f'RV(30d): {d[\"rv30d\"]}% | ATM IV: {d[\"avg_iv\"]}% | IV/RV: {d[\"iv_rv_ratio\"]}x')
    print(f'Straddle: \${d[\"straddle\"]} | Expected Move: ±{d[\"expected_move_pct\"]}%')
    print(f'Put/Call Skew: {d[\"skew\"]}pts | Expiry: {d[\"nearest_expiry\"]} ({d[\"dte\"]}d)')
    print(f'Signal: {d[\"signal\"]}')
    for imp in d.get('implications', []):
        print(f'  → {imp}')
except Exception as e:
    print(f'Parse error: {e}')
    print(sys.stdin.read() if hasattr(sys.stdin, 'read') else '')
"
fi

# Push to ClawTalk if requested
if $PUSH_MODE && [ -n "${CLAWTALK_API_KEY:-}" ]; then
    SIGNAL=$(echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
lines = [f'📊 Pre-Earnings Vol: {d[\"ticker\"]}']
lines.append(f'Price: \${d[\"price\"]} | RV30d: {d[\"rv30d\"]}% | ATM IV: {d[\"avg_iv\"]}%')
lines.append(f'IV/RV: {d[\"iv_rv_ratio\"]}x | Straddle: \${d[\"straddle\"]}')
lines.append(f'Expected: ±{d[\"expected_move_pct\"]}% | Skew: {d[\"skew\"]}pts')
lines.append(f'Signal: {d[\"signal\"]}')
for imp in d.get('implications',[]):
    lines.append(f'→ {imp}')
print('\n'.join(lines))
" 2>/dev/null)
    
    if [ -n "$SIGNAL" ]; then
        TMP_MSG=$(mktemp)
        cat > "$TMP_MSG" << MSGEOF
{"to":"Lotbot","type":"notification","topic":"gekko-signal","encrypted":false,"payload":{"text":"$SIGNAL"}}
MSGEOF
        curl -s -X POST "https://clawtalk.monkeymango.co/messages" \
            -H "Authorization: Bearer $CLAWTALK_API_KEY" \
            -H "Content-Type: application/json" \
            --data-binary "@$TMP_MSG" > /dev/null 2>&1
        rm -f "$TMP_MSG"
        echo "Pushed to Lotbot ✅"
    fi
fi
