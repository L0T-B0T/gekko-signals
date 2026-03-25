#!/usr/bin/env bash
# Correlation Monitor v1.0 — Cross-Asset Correlation Detection for Gekko
# Tracks pairwise correlations between instruments and detects regime shifts
# Zero external APIs beyond Yahoo Finance (free)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_FILE="${SCRIPT_DIR}/correlation-monitor.db"
LOOKBACK_DAYS=${LOOKBACK_DAYS:-30}
CORRELATION_THRESHOLD=${CORRELATION_THRESHOLD:-0.7}
DECORRELATION_ALERT=${DECORRELATION_ALERT:-0.3}

# Core instrument pairs for correlation tracking
declare -a PAIRS=(
  "SPY:TLT"    # Equity vs Bond (classic risk toggle)
  "SPY:VIX"    # Equity vs Vol (fear gauge)
  "XLE:SPY"    # Energy vs Broad (sector rotation)
  "GLD:TLT"    # Gold vs Bond (safe-haven competition)
  "XLE:GLD"    # Energy vs Gold (inflation hedge)
  "QQQ:XLF"    # Tech vs Financials (growth vs value)
  "SPY:GLD"    # Equity vs Gold (risk appetite)
  "XLE:VIX"    # Energy vs Vol (crisis correlation)
)

usage() {
  echo "Usage: $0 [options]"
  echo "  --scan           Full correlation scan (default)"
  echo "  --alerts         Show decorrelation alerts only"
  echo "  --history        Show correlation trend history"
  echo "  --pair A:B       Analyze specific pair"
  echo "  --json           JSON output format"
  echo "  --daemon [sec]   Continuous monitoring (default: 900s)"
  echo "  --push           Push alerts to Gekko via ClawTalk"
  echo "  --lookback N     Days of price history (default: 30)"
  exit 0
}

init_db() {
  sqlite3 "$DB_FILE" << 'SQL'
CREATE TABLE IF NOT EXISTS correlations (
  id INTEGER PRIMARY KEY,
  pair TEXT NOT NULL,
  timestamp TEXT NOT NULL DEFAULT (datetime('now')),
  correlation REAL NOT NULL,
  lookback_days INTEGER NOT NULL,
  sample_size INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY,
  pair TEXT NOT NULL,
  timestamp TEXT NOT NULL DEFAULT (datetime('now')),
  alert_type TEXT NOT NULL,
  old_corr REAL,
  new_corr REAL,
  delta REAL,
  message TEXT
);
CREATE INDEX IF NOT EXISTS idx_corr_pair_ts ON correlations(pair, timestamp);
CREATE INDEX IF NOT EXISTS idx_alert_ts ON alerts(timestamp);
SQL
}

fetch_prices() {
  local symbol="$1"
  local period="${2:-${LOOKBACK_DAYS}d}"
  local url="https://query1.finance.yahoo.com/v8/finance/chart/${symbol}?range=${period}&interval=1d"
  
  curl -sf "$url" \
    -H "User-Agent: Mozilla/5.0" \
    --connect-timeout 10 \
    --max-time 15 2>/dev/null || echo "{}"
}

compute_correlation() {
  local sym_a="$1" sym_b="$2"
  
  python3 << PYEOF
import json, sys, math

def get_returns(data):
    try:
        result = data.get("chart", {}).get("result", [{}])[0]
        closes = result.get("indicators", {}).get("quote", [{}])[0].get("close", [])
        closes = [c for c in closes if c is not None]
        if len(closes) < 5:
            return []
        return [(closes[i] - closes[i-1]) / closes[i-1] for i in range(1, len(closes))]
    except:
        return []

def pearson(x, y):
    n = min(len(x), len(y))
    if n < 5:
        return None, 0
    x, y = x[:n], y[:n]
    mx = sum(x) / n
    my = sum(y) / n
    cov = sum((x[i] - mx) * (y[i] - my) for i in range(n)) / n
    sx = math.sqrt(sum((xi - mx) ** 2 for xi in x) / n)
    sy = math.sqrt(sum((yi - my) ** 2 for yi in y) / n)
    if sx == 0 or sy == 0:
        return None, n
    return round(cov / (sx * sy), 4), n

try:
    data_a = json.loads("""$(fetch_prices "$sym_a")""")
    data_b = json.loads("""$(fetch_prices "$sym_b")""")
    
    ret_a = get_returns(data_a)
    ret_b = get_returns(data_b)
    
    corr, n = pearson(ret_a, ret_b)
    if corr is not None:
        print(f"{corr}|{n}")
    else:
        print("null|0")
except Exception as e:
    print(f"error|0", file=sys.stderr)
    print("null|0")
PYEOF
}

classify_correlation() {
  local corr="$1"
  python3 -c "
c = float('$corr') if '$corr' != 'null' else 0
if c > 0.7: print('strong_positive')
elif c > 0.3: print('moderate_positive')
elif c > -0.3: print('uncorrelated')
elif c > -0.7: print('moderate_negative')
else: print('strong_negative')
"
}

run_scan() {
  local json_mode="${1:-false}"
  local push_mode="${2:-false}"
  local results=()
  local alerts=()
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  if [[ "$json_mode" != "true" ]]; then
    echo "╔══════════════════════════════════════════════════╗"
    echo "║       CROSS-ASSET CORRELATION MONITOR v1.0      ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║  Lookback: ${LOOKBACK_DAYS}d  |  Threshold: ±${CORRELATION_THRESHOLD}  |  Alert: Δ>${DECORRELATION_ALERT}  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    printf "%-12s  %8s  %-20s  %s\n" "PAIR" "CORR" "CLASSIFICATION" "SIGNAL"
    printf "%-12s  %8s  %-20s  %s\n" "────────────" "────────" "────────────────────" "──────"
  fi
  
  for pair in "${PAIRS[@]}"; do
    local sym_a="${pair%%:*}"
    local sym_b="${pair##*:}"
    
    local result
    result=$(compute_correlation "$sym_a" "$sym_b")
    local corr="${result%%|*}"
    local n="${result##*|}"
    
    if [[ "$corr" == "null" ]]; then
      [[ "$json_mode" != "true" ]] && printf "%-12s  %8s  %-20s  %s\n" "$pair" "N/A" "insufficient_data" "⚠️"
      continue
    fi
    
    local classification
    classification=$(classify_correlation "$corr")
    
    # Check for decorrelation vs historical
    local prev_corr
    prev_corr=$(sqlite3 "$DB_FILE" "SELECT correlation FROM correlations WHERE pair='$pair' ORDER BY timestamp DESC LIMIT 1" 2>/dev/null || echo "")
    
    local signal="—"
    local delta=""
    if [[ -n "$prev_corr" ]]; then
      delta=$(python3 -c "print(round(float('$corr') - float('$prev_corr'), 4))")
      local abs_delta
      abs_delta=$(python3 -c "print(abs(float('$delta')))")
      
      if python3 -c "exit(0 if float('$abs_delta') > float('$DECORRELATION_ALERT') else 1)"; then
        if python3 -c "exit(0 if float('$delta') > 0 else 1)"; then
          signal="🔺 CONVERGING (+${delta})"
        else
          signal="🔻 DIVERGING (${delta})"
        fi
        
        # Store alert
        sqlite3 "$DB_FILE" "INSERT INTO alerts (pair, alert_type, old_corr, new_corr, delta, message) VALUES ('$pair', 'decorrelation', $prev_corr, $corr, $delta, 'Correlation shift: $prev_corr → $corr')"
        alerts+=("$pair:$corr:$delta:$classification")
      fi
    fi
    
    # Store measurement
    sqlite3 "$DB_FILE" "INSERT INTO correlations (pair, correlation, lookback_days, sample_size) VALUES ('$pair', $corr, $LOOKBACK_DAYS, $n)"
    
    if [[ "$json_mode" != "true" ]]; then
      printf "%-12s  %8s  %-20s  %s\n" "$pair" "$corr" "$classification" "$signal"
    fi
    
    results+=("{\"pair\":\"$pair\",\"correlation\":$corr,\"classification\":\"$classification\",\"samples\":$n,\"delta\":\"${delta:-null}\"}")
    
    sleep 1  # Rate limit Yahoo Finance
  done
  
  if [[ "$json_mode" == "true" ]]; then
    echo "{\"timestamp\":\"$ts\",\"lookback_days\":$LOOKBACK_DAYS,\"pairs\":[$(IFS=,; echo "${results[*]}")]}"
  else
    echo ""
    echo "───────────────────────────────────────────────────"
    
    # Summary
    local strong_pos=0 strong_neg=0 uncorr=0 alerts_count=${#alerts[@]}
    for pair in "${PAIRS[@]}"; do
      local sym_a="${pair%%:*}" sym_b="${pair##*:}"
      local last
      last=$(sqlite3 "$DB_FILE" "SELECT correlation FROM correlations WHERE pair='$pair' ORDER BY timestamp DESC LIMIT 1" 2>/dev/null || echo "0")
      [[ -z "$last" ]] && continue
      local cls
      cls=$(classify_correlation "$last")
      case "$cls" in
        strong_positive) ((strong_pos++)) || true ;;
        strong_negative) ((strong_neg++)) || true ;;
        uncorrelated) ((uncorr++)) || true ;;
      esac
    done
    
    echo "SUMMARY: ${#PAIRS[@]} pairs tracked"
    echo "  Strong correlations: $((strong_pos + strong_neg))"
    echo "  Uncorrelated: $uncorr"
    echo "  Decorrelation alerts: $alerts_count"
    echo ""
    
    if [[ $alerts_count -gt 0 ]]; then
      echo "⚠️  DECORRELATION ALERTS:"
      for alert in "${alerts[@]}"; do
        IFS=: read -r a_pair a_corr a_delta a_class <<< "$alert"
        echo "  $a_pair: correlation=$a_corr (Δ${a_delta}) — $a_class"
      done
    fi
  fi
  
  # Push to Gekko via ClawTalk if alerts exist
  if [[ "$push_mode" == "true" && ${#alerts[@]} -gt 0 ]]; then
    push_to_gekko "$ts" "${alerts[@]}"
  fi
}

push_to_gekko() {
  local ts="$1"; shift
  local alerts=("$@")
  local env_file="${SCRIPT_DIR}/../clawtalk/.env"
  
  if [[ ! -f "$env_file" ]]; then
    echo "⚠️  No ClawTalk .env found, skipping push"
    return
  fi
  
  local api_key
  api_key=$(grep CLAWTALK_API_KEY "$env_file" | cut -d= -f2)
  
  local alert_text="🔗 CORRELATION MONITOR ALERT ($ts)\n\n"
  for alert in "${alerts[@]}"; do
    IFS=: read -r a_pair a_corr a_delta a_class <<< "$alert"
    alert_text+="$a_pair: r=$a_corr (Δ${a_delta}) — $a_class\n"
  done
  alert_text+="\nSignal type: correlation_shift"
  
  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
    'to': 'Lotbot',
    'type': 'notification',
    'topic': 'gekko-correlation-alert',
    'encrypted': False,
    'payload': {
        'text': '''$(echo -e "$alert_text")''',
        'metadata': {
            'signal': 'correlation_shift',
            'timestamp': '$ts',
            'alert_count': ${#alerts[@]}
        }
    }
}))
")
  
  local tmpfile
  tmpfile=$(mktemp)
  echo "$payload" > "$tmpfile"
  
  curl -sf -X POST "https://clawtalk.monkeymango.co/messages" \
    -H "Authorization: Bearer $api_key" \
    -H "Content-Type: application/json" \
    --data-binary "@$tmpfile" \
    --connect-timeout 10 \
    --max-time 15 > /dev/null 2>&1 && echo "✅ Alert pushed to Gekko via ClawTalk" || echo "⚠️ Push failed"
  
  rm -f "$tmpfile"
}

show_history() {
  echo "CORRELATION HISTORY (last 10 per pair)"
  echo ""
  for pair in "${PAIRS[@]}"; do
    echo "📊 $pair:"
    sqlite3 -column "$DB_FILE" "SELECT timestamp, correlation, sample_size FROM correlations WHERE pair='$pair' ORDER BY timestamp DESC LIMIT 10" 2>/dev/null || echo "  No data"
    echo ""
  done
}

show_alerts_only() {
  echo "DECORRELATION ALERTS (last 20)"
  echo ""
  sqlite3 -column "$DB_FILE" "SELECT timestamp, pair, alert_type, old_corr, new_corr, delta FROM alerts ORDER BY timestamp DESC LIMIT 20" 2>/dev/null || echo "No alerts"
}

# Parse args
MODE="scan"
JSON_MODE="false"
PUSH_MODE="false"
SPECIFIC_PAIR=""
DAEMON_INTERVAL=900

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan) MODE="scan" ;;
    --alerts) MODE="alerts" ;;
    --history) MODE="history" ;;
    --pair) SPECIFIC_PAIR="$2"; shift ;;
    --json) JSON_MODE="true" ;;
    --daemon) MODE="daemon"; [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] && { DAEMON_INTERVAL="$2"; shift; } ;;
    --push) PUSH_MODE="true" ;;
    --lookback) LOOKBACK_DAYS="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

init_db

case "$MODE" in
  scan) run_scan "$JSON_MODE" "$PUSH_MODE" ;;
  alerts) show_alerts_only ;;
  history) show_history ;;
  daemon)
    echo "Starting correlation daemon (interval: ${DAEMON_INTERVAL}s, push: ${PUSH_MODE})"
    while true; do
      run_scan "$JSON_MODE" "$PUSH_MODE"
      echo ""
      echo "Next scan in ${DAEMON_INTERVAL}s ($(date -u -d "+${DAEMON_INTERVAL} seconds" +%H:%M:%S 2>/dev/null || date -u +%H:%M:%S) UTC)"
      sleep "$DAEMON_INTERVAL"
    done
    ;;
esac
