#!/usr/bin/env bash
# Market Breadth Monitor v1.0 — Gekko Signal Tool #12
# Tracks market participation breadth across sectors and major indices
# Signals: breadth_thrust, divergence, rotation strength
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/../../output"
mkdir -p "$STATE_DIR"

# --- Configuration ---
LOOKBACK_DAYS=20
# Major ETFs representing different market segments
BREADTH_TICKERS=(
  SPY QQQ IWM DIA        # Major indices (large/tech/small/blue)
  XLB XLC XLE XLF XLI    # Sectors
  XLK XLP XLRE XLU XLV XLY  # More sectors
  TLT GLD SLV HYG         # Bonds/commodities/credit
  EEM EFA VWO              # International
)

usage() {
  cat <<EOF
Market Breadth Monitor v1.0 — Gekko Signal Tool

Usage: $(basename "$0") [OPTIONS]

Options:
  --json           Output JSON only
  --daemon [SEC]   Run continuously (default 300s interval)
  --push           Push alerts to Gekko via ClawTalk on breadth changes
  -h, --help       Show this help

Signals:
  breadth_thrust   >80% tickers above 20d SMA = strong bullish
  breadth_collapse <20% tickers above 20d SMA = strong bearish
  divergence       SPY rising but breadth declining = warning
  rotation         Sector dispersion + leadership changes
EOF
}

JSON_ONLY=false
DAEMON_MODE=false
DAEMON_INTERVAL=300
PUSH_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_ONLY=true; shift;;
    --daemon) DAEMON_MODE=true; DAEMON_INTERVAL="${2:-300}"; shift; shift 2>/dev/null || shift;;
    --push) PUSH_MODE=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown: $1"; usage; exit 1;;
  esac
done

fetch_price_data() {
  local ticker="$1"
  local period1 period2
  period2=$(date +%s)
  period1=$((period2 - LOOKBACK_DAYS * 86400 - 86400 * 5))  # extra buffer for weekends

  local url="https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?period1=${period1}&period2=${period2}&interval=1d"
  local data
  data=$(curl -sL --max-time 8 \
    -H "User-Agent: Mozilla/5.0" \
    "$url" 2>/dev/null) || { echo "FETCH_FAIL"; return; }
  echo "$data"
}

analyze_breadth() {
  python3 << 'PYEOF'
import json, sys, os, time
from datetime import datetime

tickers_str = os.environ.get("TICKERS", "")
lookback = int(os.environ.get("LOOKBACK", "20"))
tickers = tickers_str.split()

results = []
above_sma = 0
below_sma = 0
ticker_details = []

for ticker in tickers:
    try:
        # Fetch data
        import urllib.request
        period2 = int(time.time())
        period1 = period2 - (lookback + 10) * 86400
        url = f"https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?period1={period1}&period2={period2}&interval=1d"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read())

        result = data.get("chart", {}).get("result", [{}])[0]
        closes = result.get("indicators", {}).get("quote", [{}])[0].get("close", [])
        closes = [c for c in closes if c is not None]

        if len(closes) < lookback:
            continue

        # Calculate 20-day SMA
        sma20 = sum(closes[-lookback:]) / lookback
        current = closes[-1]
        prev = closes[-2] if len(closes) >= 2 else current

        # Price vs SMA
        above = current > sma20
        pct_from_sma = ((current - sma20) / sma20) * 100

        # 5-day return
        ret5d = ((current - closes[-6]) / closes[-6]) * 100 if len(closes) >= 6 else 0

        # Momentum (5d price change rate)
        momentum = ret5d

        if above:
            above_sma += 1
        else:
            below_sma += 1

        ticker_details.append({
            "ticker": ticker,
            "price": round(current, 2),
            "sma20": round(sma20, 2),
            "above_sma": above,
            "pct_from_sma": round(pct_from_sma, 2),
            "return_5d": round(ret5d, 2),
            "momentum": round(momentum, 2)
        })

        time.sleep(0.3)  # Rate limit

    except Exception as e:
        pass  # Skip failed tickers

total = above_sma + below_sma
if total == 0:
    print(json.dumps({"error": "no data"}))
    sys.exit(1)

breadth_pct = (above_sma / total) * 100

# Classify breadth regime
if breadth_pct >= 80:
    regime = "breadth_thrust"
    description = "Strong bullish — broad market participation"
elif breadth_pct >= 60:
    regime = "healthy"
    description = "Normal bull market breadth"
elif breadth_pct >= 40:
    regime = "neutral"
    description = "Mixed signals — selective participation"
elif breadth_pct >= 20:
    regime = "narrowing"
    description = "Weakening breadth — risk rising"
else:
    regime = "breadth_collapse"
    description = "Bearish — very few tickers participating"

# Check SPY divergence
spy_data = next((t for t in ticker_details if t["ticker"] == "SPY"), None)
divergence = False
divergence_type = "none"
if spy_data:
    if spy_data["return_5d"] > 0 and breadth_pct < 40:
        divergence = True
        divergence_type = "bearish_divergence"
    elif spy_data["return_5d"] < 0 and breadth_pct > 60:
        divergence = True
        divergence_type = "bullish_divergence"

# Sector rotation analysis
sector_etfs = ["XLB","XLC","XLE","XLF","XLI","XLK","XLP","XLRE","XLU","XLV","XLY"]
sector_data = [t for t in ticker_details if t["ticker"] in sector_etfs]

leaders = sorted(sector_data, key=lambda x: x["return_5d"], reverse=True)[:3]
laggards = sorted(sector_data, key=lambda x: x["return_5d"])[:3]

# Dispersion (std of sector returns)
if sector_data:
    sector_rets = [s["return_5d"] for s in sector_data]
    mean_ret = sum(sector_rets) / len(sector_rets)
    variance = sum((r - mean_ret)**2 for r in sector_rets) / len(sector_rets)
    dispersion = variance ** 0.5
else:
    dispersion = 0

# Safe haven check
safe_havens = ["TLT", "GLD", "SLV"]
safe_haven_data = [t for t in ticker_details if t["ticker"] in safe_havens]
safe_haven_bid = sum(1 for s in safe_haven_data if s["return_5d"] > 0) / max(len(safe_haven_data), 1)

# International check
intl_tickers = ["EEM", "EFA", "VWO"]
intl_data = [t for t in ticker_details if t["ticker"] in intl_tickers]
intl_strength = sum(t["return_5d"] for t in intl_data) / max(len(intl_data), 1) if intl_data else 0

output = {
    "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "signal": "breadth_monitor",
    "version": "1.0",
    "breadth": {
        "above_sma20": above_sma,
        "below_sma20": below_sma,
        "total": total,
        "pct_above": round(breadth_pct, 1),
        "regime": regime,
        "description": description
    },
    "divergence": {
        "detected": divergence,
        "type": divergence_type,
        "spy_5d": spy_data["return_5d"] if spy_data else None,
        "breadth_pct": round(breadth_pct, 1)
    },
    "rotation": {
        "dispersion": round(dispersion, 2),
        "leaders": [{"ticker": l["ticker"], "return_5d": l["return_5d"]} for l in leaders],
        "laggards": [{"ticker": l["ticker"], "return_5d": l["return_5d"]} for l in laggards],
        "safe_haven_bid": round(safe_haven_bid * 100, 1),
        "intl_strength": round(intl_strength, 2)
    },
    "tickers_analyzed": total,
    "details": ticker_details
}

print(json.dumps(output, indent=2))
PYEOF
}

run_scan() {
  export TICKERS="${BREADTH_TICKERS[*]}"
  export LOOKBACK="$LOOKBACK_DAYS"

  local result
  result=$(analyze_breadth 2>/dev/null)

  if [[ -z "$result" ]] || echo "$result" | grep -q '"error"'; then
    echo "ERROR: Breadth scan failed" >&2
    return 1
  fi

  # Save latest
  echo "$result" > "$STATE_DIR/breadth-latest.json"

  if $JSON_ONLY; then
    echo "$result"
    return
  fi

  # Human-readable output
  local regime pct_above disp
  regime=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['breadth']['regime'])")
  pct_above=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['breadth']['pct_above'])")
  disp=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['rotation']['dispersion'])")
  local divergence_detected
  divergence_detected=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['divergence']['detected'])")
  local safe_haven
  safe_haven=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['rotation']['safe_haven_bid'])")

  echo "═══════════════════════════════════════"
  echo "  MARKET BREADTH MONITOR v1.0"
  echo "  $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "═══════════════════════════════════════"
  echo ""
  echo "BREADTH: ${pct_above}% above 20d SMA → ${regime^^}"
  echo ""

  # Leaders/Laggards
  echo "SECTOR LEADERS (5d):"
  echo "$result" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for l in d['rotation']['leaders']:
    print(f\"  {l['ticker']:5s} {l['return_5d']:+.1f}%\")
"
  echo ""
  echo "SECTOR LAGGARDS (5d):"
  echo "$result" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for l in d['rotation']['laggards']:
    print(f\"  {l['ticker']:5s} {l['return_5d']:+.1f}%\")
"
  echo ""
  echo "DISPERSION: ${disp}%  |  SAFE HAVEN BID: ${safe_haven}%"

  if [[ "$divergence_detected" == "True" ]]; then
    local div_type
    div_type=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['divergence']['type'])")
    echo ""
    echo "⚠️  DIVERGENCE DETECTED: ${div_type}"
  fi

  echo ""
  echo "═══════════════════════════════════════"
}

if $DAEMON_MODE; then
  echo "[breadth-monitor] Starting daemon (interval: ${DAEMON_INTERVAL}s)"
  prev_regime=""
  while true; do
    result=$(run_scan 2>/dev/null || echo "")
    if [[ -n "$result" ]]; then
      current_regime=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('breadth',{}).get('regime','unknown'))" 2>/dev/null || echo "unknown")
      if [[ "$current_regime" != "$prev_regime" ]] && [[ -n "$prev_regime" ]]; then
        echo "[breadth-monitor] REGIME CHANGE: $prev_regime → $current_regime"
        if $PUSH_MODE; then
          # Push via ClawTalk
          source /data/workspace/clawtalk/.env 2>/dev/null || true
          local alert_text="🔄 BREADTH REGIME CHANGE: ${prev_regime} → ${current_regime}"
          local payload="{\"to\":\"Lotbot\",\"type\":\"notification\",\"topic\":\"breadth-alert\",\"encrypted\":false,\"payload\":{\"text\":\"${alert_text}\"}}"
          local tmpf=$(mktemp)
          echo "$payload" > "$tmpf"
          curl -s -X POST "https://clawtalk.monkeymango.co/messages" \
            -H "Authorization: Bearer $CLAWTALK_API_KEY" \
            -H "Content-Type: application/json" \
            --data-binary "@$tmpf" >/dev/null 2>&1
          rm -f "$tmpf"
        fi
      fi
      prev_regime="$current_regime"
    fi
    sleep "$DAEMON_INTERVAL"
  done
else
  run_scan
fi
