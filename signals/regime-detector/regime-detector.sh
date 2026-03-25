#!/usr/bin/env bash
# Market Regime Detector v1.0 — Gekko Signal Feed
# Classifies market regime using VIX + sector rotation + bond/gold signals
# Output: ClawTalk signal message conforming to gekko-signals spec
#
# Usage: ./regime-detector.sh [--daemon] [--json] [--dry-run]
#   --daemon   Run continuously, push on regime changes + every 15 min
#   --json     Output raw JSON to stdout (no ClawTalk send)
#   --dry-run  Detect regime but don't send to ClawTalk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="${STATE_FILE:-/tmp/regime-detector-state.json}"
CLAWTALK_ENV="${CLAWTALK_ENV:-/data/workspace/clawtalk/.env}"
SIGNAL_VERSION="regime-detector-v1"
POLL_INTERVAL_SECS=900  # 15 min
CHANGE_COOLDOWN_SECS=60 # Min time between change signals

# Parse args
DAEMON=false
JSON_ONLY=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --daemon) DAEMON=true ;;
        --json) JSON_ONLY=true ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

# Load ClawTalk API key
load_clawtalk_key() {
    if [[ -f "$CLAWTALK_ENV" ]]; then
        CLAWTALK_API_KEY=$(grep 'CLAWTALK_API_KEY' "$CLAWTALK_ENV" | cut -d'=' -f2)
    fi
    if [[ -z "${CLAWTALK_API_KEY:-}" ]]; then
        echo "WARNING: No ClawTalk API key found" >&2
        return 1
    fi
}

# Fetch Yahoo Finance quote (returns: price, change%, 52w range)
fetch_quote() {
    local symbol="$1"
    local url="https://query1.finance.yahoo.com/v8/finance/chart/${symbol}?range=1mo&interval=1d"
    local data
    data=$(curl -sf --max-time 10 "$url" 2>/dev/null) || echo "{}"
    echo "$data"
}

# Detect market regime from multiple signals
detect_regime() {
    python3 << 'PYEOF'
import json, sys, subprocess, datetime

def fetch(sym):
    """Fetch 1mo daily data from Yahoo Finance."""
    import urllib.request
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}?range=1mo&interval=1d"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        resp = urllib.request.urlopen(req, timeout=10)
        return json.loads(resp.read())
    except:
        return None

def get_latest_close(data):
    """Extract latest close price from Yahoo chart data."""
    if not data:
        return None
    try:
        result = data["chart"]["result"][0]
        closes = result["indicators"]["quote"][0]["close"]
        # Find last non-None close
        for c in reversed(closes):
            if c is not None:
                return round(c, 2)
    except:
        pass
    return None

def get_pct_change(data, days=5):
    """Calculate % change over N trading days."""
    if not data:
        return 0.0
    try:
        result = data["chart"]["result"][0]
        closes = [c for c in result["indicators"]["quote"][0]["close"] if c is not None]
        if len(closes) < days + 1:
            return 0.0
        return round((closes[-1] / closes[-1 - days] - 1) * 100, 2)
    except:
        return 0.0

# Fetch core instruments
symbols = {
    "VIX": "^VIX",
    "SPY": "SPY",
    "QQQ": "QQQ",
    "XLE": "XLE",  # Energy
    "XLK": "XLK",  # Tech
    "XLY": "XLY",  # Consumer Discretionary
    "XLU": "XLU",  # Utilities (defensive)
    "XLP": "XLP",  # Consumer Staples (defensive)
    "XLF": "XLF",  # Financials
    "TLT": "TLT",  # Long-term bonds
    "GLD": "GLD",  # Gold
    "XLV": "XLV",  # Healthcare
    "XLI": "XLI",  # Industrials
    "XLB": "XLB",  # Materials
    "XLRE": "XLRE", # Real Estate
    "XLC": "XLC",  # Communication Services
}

data = {}
for name, sym in symbols.items():
    d = fetch(sym)
    data[name] = {
        "price": get_latest_close(d),
        "chg_5d": get_pct_change(d, 5),
        "chg_20d": get_pct_change(d, 20),
    }

vix = data["VIX"]["price"] or 20
vix_5d = data["VIX"]["chg_5d"]

# Sector performance (5-day change)
sectors = {}
sector_names = ["XLE", "XLK", "XLY", "XLU", "XLP", "XLF", "XLV", "XLI", "XLB", "XLRE", "XLC"]
for s in sector_names:
    sectors[s] = data[s]["chg_5d"]

# Sort sectors by 5d performance
sorted_sectors = sorted(sectors.items(), key=lambda x: x[1], reverse=True)
leading = [s[0] for s in sorted_sectors[:3]]
lagging = [s[0] for s in sorted_sectors[-3:]]

# Growth vs Defensive spread
growth = ["XLK", "XLY", "XLC"]
defensive = ["XLU", "XLP", "XLV"]
growth_avg = sum(sectors.get(s, 0) for s in growth) / len(growth)
defensive_avg = sum(sectors.get(s, 0) for s in defensive) / len(defensive)
gd_spread = round(growth_avg - defensive_avg, 2)

# Safe haven signals
tlt_5d = data["TLT"]["chg_5d"]
gld_5d = data["GLD"]["chg_5d"]

# Regime classification
confidence = 0.5
regime = "neutral"
vix_trend = "flat"

# VIX trend
if vix_5d > 10:
    vix_trend = "rising"
elif vix_5d < -10:
    vix_trend = "falling"

# Primary regime signal: VIX level
if vix > 30:
    regime = "risk-off"
    confidence = 0.90
elif vix > 25:
    regime = "risk-off"
    confidence = 0.75
elif vix < 15:
    regime = "risk-on"
    confidence = 0.80
elif vix < 20:
    regime = "risk-on"
    confidence = 0.65

# Sector rotation confirmation
if gd_spread > 2.0:
    if regime == "risk-on":
        confidence = min(confidence + 0.10, 0.95)
    elif regime == "risk-off":
        confidence = max(confidence - 0.15, 0.40)
        regime = "neutral"
elif gd_spread < -2.0:
    if regime == "risk-off":
        confidence = min(confidence + 0.10, 0.95)
    elif regime == "risk-on":
        confidence = max(confidence - 0.15, 0.40)
        regime = "neutral"

# Safe haven check
safe_haven_bid = (tlt_5d > 1.5) or (gld_5d > 2.0)
if safe_haven_bid and regime == "risk-on":
    confidence = max(confidence - 0.10, 0.40)
elif safe_haven_bid and regime == "risk-off":
    confidence = min(confidence + 0.05, 0.95)

# Build signal payload
now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
signal = {
    "signal_type": "regime",
    "timestamp": now,
    "data": {
        "regime": regime,
        "vix_level": round(vix, 2),
        "vix_trend": vix_trend,
        "vix_5d_change": vix_5d,
        "sector_rotation": {
            "leading": leading,
            "lagging": lagging,
        },
        "regime_change": False,  # Will be set by daemon
        "previous_regime": None,
        "growth_defensive_spread": gd_spread,
        "safe_haven_bid": safe_haven_bid,
        "spy_5d": data["SPY"]["chg_5d"],
        "tlt_5d": tlt_5d,
        "gld_5d": gld_5d,
    },
    "confidence": round(confidence, 2),
    "source": "regime-detector-v1",
}

print(json.dumps(signal, indent=2))
PYEOF
}

# Send signal via ClawTalk
send_signal() {
    local payload="$1"
    
    if $JSON_ONLY; then
        echo "$payload"
        return 0
    fi
    
    if $DRY_RUN; then
        echo "[DRY RUN] Would send regime signal via ClawTalk"
        echo "$payload" | python3 -m json.tool 2>/dev/null || echo "$payload"
        return 0
    fi
    
    load_clawtalk_key || return 1
    
    # Build ClawTalk message
    local msg
    msg=$(python3 -c "
import json, sys
signal = json.loads('''$payload''')
msg = {
    'to': 'Lotbot',
    'type': 'notification',
    'topic': 'gekko-signal',
    'encrypted': False,
    'payload': signal
}
print(json.dumps(msg))
")
    
    # Send via ClawTalk API using temp file (avoid truncation)
    local tmpfile=$(mktemp)
    echo "$msg" > "$tmpfile"
    
    local response
    response=$(curl -sf -X POST "https://clawtalk.monkeymango.co/messages" \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$tmpfile" 2>&1) || true
    
    rm -f "$tmpfile"
    
    echo "[$(date -u +%H:%M:%S)] Signal sent: $(echo "$payload" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d[\"data\"][\"regime\"]} ({d[\"confidence\"]*100:.0f}%)')" 2>/dev/null || echo "sent")"
}

# Check for regime change vs previous state
check_regime_change() {
    local current_signal="$1"
    
    local current_regime
    current_regime=$(echo "$current_signal" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['regime'])")
    
    local previous_regime="unknown"
    local changed=false
    
    if [[ -f "$STATE_FILE" ]]; then
        previous_regime=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    print(json.load(f).get('regime', 'unknown'))
" 2>/dev/null || echo "unknown")
    fi
    
    if [[ "$current_regime" != "$previous_regime" ]]; then
        changed=true
    fi
    
    # Update signal with change info
    local py_changed="False"
    if $changed; then py_changed="True"; fi
    
    local updated
    updated=$(python3 -c "
import json, sys
signal = json.loads('''$current_signal''')
signal['data']['regime_change'] = $py_changed
signal['data']['previous_regime'] = '$previous_regime'
print(json.dumps(signal, indent=2))
")
    
    # Save state
    python3 -c "
import json
state = {'regime': '$current_regime', 'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f)
"
    
    echo "$updated"
    if $changed; then
        return 0  # Changed
    else
        return 1  # No change
    fi
}

# Single detection run
run_once() {
    local signal
    signal=$(detect_regime)
    
    if [[ -z "$signal" || "$signal" == "null" ]]; then
        echo "ERROR: Failed to detect regime" >&2
        return 1
    fi
    
    local updated
    local changed=false
    updated=$(check_regime_change "$signal") && changed=true || true
    
    if $changed || $JSON_ONLY; then
        send_signal "$updated"
        echo "[$(date -u +%H:%M:%S)] Regime CHANGE detected — signal pushed"
    else
        if $DRY_RUN; then
            echo "[$(date -u +%H:%M:%S)] No regime change ($(echo "$updated" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['regime'])"))"
        fi
    fi
    
    echo "$updated"
}

# Daemon mode
run_daemon() {
    echo "=== Regime Detector Daemon v1.0 ==="
    echo "Poll interval: ${POLL_INTERVAL_SECS}s"
    echo "Signal target: Lotbot via ClawTalk"
    echo ""
    
    local last_send=0
    
    while true; do
        local now
        now=$(date +%s)
        
        local signal
        signal=$(detect_regime 2>/dev/null) || { echo "[$(date -u +%H:%M:%S)] Detection failed, retrying in 60s"; sleep 60; continue; }
        
        local updated
        local changed=false
        updated=$(check_regime_change "$signal") && changed=true || true
        
        local time_since_last=$((now - last_send))
        
        if $changed; then
            echo "[$(date -u +%H:%M:%S)] ⚡ REGIME CHANGE — pushing immediately"
            send_signal "$updated"
            last_send=$now
        elif [[ $time_since_last -ge $POLL_INTERVAL_SECS ]]; then
            echo "[$(date -u +%H:%M:%S)] 📊 Heartbeat signal (${POLL_INTERVAL_SECS}s elapsed)"
            send_signal "$updated"
            last_send=$now
        else
            local remaining=$((POLL_INTERVAL_SECS - time_since_last))
            echo "[$(date -u +%H:%M:%S)] No change. Next heartbeat in ${remaining}s"
        fi
        
        sleep 60  # Check every 60s, but only push per interval
    done
}

# Main
if $DAEMON; then
    run_daemon
else
    run_once
fi
