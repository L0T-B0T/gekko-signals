#!/usr/bin/env bash
# Gekko Signal Relay v2.0 — Consolidated multi-tool signal aggregator
# Runs ALL 13 signal tools, builds unified JSON payload, sends to Lotbot via ClawTalk
# Change-only alerts: only sends when regime/sentiment/correlations shift materially
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGNALS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
STATE_DIR="$SCRIPT_DIR/.state"
LOG="$SCRIPT_DIR/signal-relay.log"
CLAWTALK_KEY=$(grep CLAWTALK_API_KEY /data/workspace/clawtalk/.env 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
AGENT="Lotbot"
INTERVAL=${SIGNAL_RELAY_INTERVAL:-300}  # 5 min default

mkdir -p "$OUTPUT_DIR" "$STATE_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }

usage() {
  cat <<EOF
Gekko Signal Relay v2.0 — Unified signal aggregator + ClawTalk push

Usage: $(basename "$0") [OPTIONS]

Options:
  --run            Run once, output consolidated signal
  --daemon [SEC]   Run continuously (default 300s)
  --json           JSON output only
  --push           Push to Lotbot via ClawTalk (auto in daemon)
  --tools          List available signal tools
  -h, --help       Show this help

Runs all 13 signal tools, aggregates into unified JSON, sends change-only alerts.
EOF
}

JSON_ONLY=false
DAEMON_MODE=false
PUSH_MODE=false
RUN_ONCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN_ONCE=true; shift;;
    --daemon) DAEMON_MODE=true; INTERVAL="${2:-300}"; shift; shift 2>/dev/null || shift;;
    --json) JSON_ONLY=true; shift;;
    --push) PUSH_MODE=true; shift;;
    --tools) list_tools; exit 0;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown: $1"; usage; exit 1;;
  esac
done

# ---- Tool Registry ----
# Each tool: name, script path, timeout, signal_type
declare -A TOOLS
TOOLS=(
  [regime]="$SIGNALS_DIR/regime-detector/regime-detector.sh"
  [sentiment]="$SIGNALS_DIR/news-sentiment/news-sentiment.sh"
  [correlation]="$SIGNALS_DIR/correlation-monitor/correlation-monitor.sh"
  [events]="$SIGNALS_DIR/event-calendar/event-calendar.sh"
  [overnight]="$SIGNALS_DIR/overnight-risk/overnight-risk.sh"
  [vol_surface]="$SIGNALS_DIR/vol-surface/vol-surface-monitor.sh"
  [sector]="$SIGNALS_DIR/sector-momentum/sector-momentum.sh"
  [options]="$SIGNALS_DIR/options-flow/options-flow.sh"
  [breadth]="$SIGNALS_DIR/breadth-monitor/breadth-monitor.sh"
  [earnings]="$SIGNALS_DIR/earnings-positioning/earnings-positioning.sh"
)

list_tools() {
  echo "=== Gekko Signal Tools ==="
  for name in "${!TOOLS[@]}"; do
    local script="${TOOLS[$name]}"
    if [[ -x "$script" ]]; then
      echo "  ✅ $name → $(basename "$script")"
    else
      echo "  ❌ $name → $(basename "$script") (not found)"
    fi
  done | sort
}

# ---- Run Single Tool (with timeout) ----
run_tool() {
  local name="$1"
  local script="${TOOLS[$name]:-}"
  local timeout_sec=30
  local output_file="$OUTPUT_DIR/${name}.json"

  if [[ -z "$script" || ! -x "$script" ]]; then
    echo "{\"tool\":\"$name\",\"error\":\"not_found\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$output_file"
    return 1
  fi

  # Run with timeout, capture ALL output (some tools print text before JSON)
  timeout "$timeout_sec" bash "$script" --json > "$output_file.tmp" 2>/dev/null || true

  if [[ -s "$output_file.tmp" ]]; then
    # Extract first valid JSON object from output using brace matching
    python3 << PYEXTRACT > "$output_file" 2>/dev/null
import json, sys, re

content = open("$output_file.tmp").read()
# Find all potential JSON objects by locating { and trying to parse
best = None
depth = 0
start = -1
for i, ch in enumerate(content):
    if ch == '{':
        if depth == 0:
            start = i
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0 and start >= 0:
            candidate = content[start:i+1]
            try:
                obj = json.loads(candidate)
                if best is None or len(candidate) > len(json.dumps(best)):
                    best = obj  # Keep the largest valid JSON object
            except:
                pass
            start = -1

if best:
    json.dump(best, sys.stdout)
else:
    print(json.dumps({"tool": "$name", "error": "no_json", "raw": content[:200]}))
PYEXTRACT
    rm -f "$output_file.tmp"
    return 0
  else
    echo "{\"tool\":\"$name\",\"error\":\"no_output\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$output_file"
    rm -f "$output_file.tmp"
    return 1
  fi
}

# ---- Aggregate All Signals ----
aggregate_signals() {
  local successful=0
  local failed=0
  local total=${#TOOLS[@]}

  # Run all tools
  for name in "${!TOOLS[@]}"; do
    if run_tool "$name"; then
      ((successful++)) || true
    else
      ((failed++)) || true
    fi
    sleep 1  # Rate limit Yahoo Finance
  done

  # Build consolidated JSON
  python3 << 'PYEOF'
import json, os, sys
from datetime import datetime

output_dir = os.environ.get("OUTPUT_DIR", "output")
state_dir = os.environ.get("STATE_DIR", ".state")

# Load all tool outputs
signals = {}
for fname in os.listdir(output_dir):
    if fname.endswith('.json'):
        tool_name = fname.replace('.json', '')
        try:
            with open(os.path.join(output_dir, fname)) as f:
                signals[tool_name] = json.load(f)
        except:
            signals[tool_name] = {"error": "parse_failed"}

# Helper: tools nest data in "data" key
def get_data(tool_dict):
    """Extract inner data — tools use either flat or {data:{...}} format"""
    if "data" in tool_dict and isinstance(tool_dict["data"], dict):
        # Merge top-level fields (confidence, signal_type) with nested data
        merged = dict(tool_dict["data"])
        for k in ("confidence", "signal_type", "timestamp", "source"):
            if k in tool_dict:
                merged[k] = tool_dict[k]
        return merged
    return tool_dict

regime = get_data(signals.get("regime", {}))
sentiment = get_data(signals.get("sentiment", {}))
correlation = get_data(signals.get("correlation", {}))
breadth_raw = signals.get("breadth", {})
breadth = breadth_raw.get("breadth", breadth_raw)  # breadth nests in .breadth
breadth_rotation = breadth_raw.get("rotation", {})
overnight = get_data(signals.get("overnight", {}))
vol = get_data(signals.get("vol_surface", {}))
options = get_data(signals.get("options", {}))
events = get_data(signals.get("events", {}))
sector = get_data(signals.get("sector", {}))
earnings = get_data(signals.get("earnings", {}))

# Build unified signal
unified = {
    "signal_type": "consolidated_market_brief",
    "version": "2.0",
    "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": "aaron/gekko-signals",
    "tools_run": len(signals),
    "tools_ok": sum(1 for s in signals.values() if "error" not in s),

    "market_regime": {
        "regime": regime.get("regime", "unknown"),
        "confidence": regime.get("confidence", 0),
        "vix": regime.get("vix_level", regime.get("vix", None)),
        "vix_5d_change": regime.get("vix_5d_change", None),
        "growth_defensive_spread": regime.get("growth_defensive_spread", None),
    },

    "sentiment": {
        "overall": sentiment.get("overall_sentiment", 0),
        "label": sentiment.get("overall_label", sentiment.get("label", "unknown")),
        "headlines_analyzed": sentiment.get("headlines_analyzed", 0),
        "sectors": {k: v.get("score", v) if isinstance(v, dict) else v
                    for k, v in sentiment.get("sectors", {}).items()},
    },

    "breadth": {
        "pct_above_sma20": breadth.get("pct_above", None),
        "signal": breadth.get("regime", "unknown"),
        "dispersion": breadth_rotation.get("dispersion", None),
        "leading": [l.get("ticker", l) if isinstance(l, dict) else l
                    for l in breadth_rotation.get("leaders", [])[:3]],
        "lagging": [l.get("ticker", l) if isinstance(l, dict) else l
                    for l in breadth_rotation.get("laggers", [])[:3]],
    },

    "correlations": {
        "spy_tlt": correlation.get("SPY_TLT", correlation.get("pairs", {}).get("SPY:TLT", None)),
        "xle_spy": correlation.get("XLE_SPY", correlation.get("pairs", {}).get("XLE:SPY", None)),
        "decorrelation_alerts": correlation.get("alerts", []),
    },

    "volatility": {
        "regime": vol.get("regime", "unknown"),
        "avg_ratio": vol.get("avg_ratio", None),
        "expanding": vol.get("expanding", []),
        "compressed": vol.get("compressed", []),
    },

    "options_flow": {
        "overall_pc_ratio": options.get("overall_pc_ratio", None),
        "bias": options.get("bias", "unknown"),
        "sectors": options.get("sectors", {}),
    },

    "events_next_48h": events.get("next_48h", events.get("events", [])),

    "sector_rotation": {
        "signal": sector.get("rotation_signal", "unknown"),
        "confidence": sector.get("confidence", 0),
        "leaders": sector.get("leaders", []),
        "laggers": sector.get("laggers", []),
    },

    "overnight_risk": {
        "score": overnight.get("risk_score", None),
        "level": overnight.get("risk_level", "unknown"),
        "factors": overnight.get("risk_factors", []),
    },

    "position_sizing": {
        "recommendation": "normal",
        "reason": "default"
    }
}

# Position sizing logic based on aggregated signals
regime_val = unified["market_regime"]["regime"]
breadth_pct = unified["breadth"]["pct_above_sma20"]
vix = unified["market_regime"]["vix"]
risk_score = unified["overnight_risk"]["score"]

if regime_val in ("BEAR", "risk-off", "risk_off"):
    unified["position_sizing"] = {"recommendation": "reduce_50pct", "reason": f"bear_regime_{regime_val}"}
elif breadth_pct is not None and breadth_pct < 20:
    unified["position_sizing"] = {"recommendation": "reduce_75pct", "reason": f"breadth_collapse_{breadth_pct}pct"}
elif vix is not None and vix > 30:
    unified["position_sizing"] = {"recommendation": "reduce_50pct", "reason": f"vix_elevated_{vix}"}
elif risk_score is not None and risk_score > 70:
    unified["position_sizing"] = {"recommendation": "reduce_25pct", "reason": f"overnight_risk_{risk_score}"}
elif regime_val in ("BULL", "risk-on", "risk_on") and (breadth_pct or 50) > 60:
    unified["position_sizing"] = {"recommendation": "full_size", "reason": "bull_broad_participation"}
else:
    unified["position_sizing"] = {"recommendation": "normal", "reason": "mixed_signals"}

# Save consolidated signal
with open(os.path.join(output_dir, "consolidated.json"), "w") as f:
    json.dump(unified, f, indent=2)

# Check for changes vs previous state
prev_file = os.path.join(state_dir, "last_signal.json")
changes = []
try:
    with open(prev_file) as f:
        prev = json.load(f)
    if prev.get("market_regime", {}).get("regime") != unified["market_regime"]["regime"]:
        changes.append(f"REGIME: {prev.get('market_regime',{}).get('regime','?')} → {unified['market_regime']['regime']}")
    prev_sizing = prev.get("position_sizing", {}).get("recommendation", "normal")
    if prev_sizing != unified["position_sizing"]["recommendation"]:
        changes.append(f"SIZING: {prev_sizing} → {unified['position_sizing']['recommendation']}")
    prev_breadth = prev.get("breadth", {}).get("signal", "unknown")
    if prev_breadth != unified["breadth"]["signal"]:
        changes.append(f"BREADTH: {prev_breadth} → {unified['breadth']['signal']}")
except FileNotFoundError:
    changes.append("INITIAL_SCAN")

# Save current as prev
with open(prev_file, "w") as f:
    json.dump(unified, f)

# Output
output = {
    "unified": unified,
    "changes": changes,
    "changed": len(changes) > 0
}
print(json.dumps(output, indent=2))
PYEOF
}

# ---- Send to Lotbot via ClawTalk ----
send_signal() {
  local json_file="$OUTPUT_DIR/consolidated.json"
  [[ -f "$json_file" ]] || { log "No consolidated signal to send"; return 1; }
  [[ -z "$CLAWTALK_KEY" ]] && { log "No ClawTalk key"; return 1; }

  # Build human-readable summary from JSON
  local summary
  summary=$(python3 << 'PYEOF'
import json
with open("OUTPUT_DIR_PLACEHOLDER/consolidated.json") as f:
    sig = json.load(f)

lines = []
lines.append("🔔 GEKKO SIGNAL RELAY v2.0")
lines.append(f"⏰ {sig.get('timestamp', '?')}")
lines.append(f"📊 Tools: {sig.get('tools_ok', 0)}/{sig.get('tools_run', 0)} successful")
lines.append("")

# Regime
mr = sig.get("market_regime", {})
lines.append(f"🎯 REGIME: {mr.get('regime', '?')} (conf {mr.get('confidence', 0):.0%})")
if mr.get("vix"):
    lines.append(f"   VIX: {mr['vix']:.1f}")

# Breadth
br = sig.get("breadth", {})
if br.get("pct_above_sma20") is not None:
    lines.append(f"📈 BREADTH: {br['pct_above_sma20']:.1f}% above SMA20 → {br.get('signal', '?')}")
    if br.get("leading"):
        lines.append(f"   Leading: {', '.join(br['leading'][:3])}")
    if br.get("lagging"):
        lines.append(f"   Lagging: {', '.join(br['lagging'][:3])}")

# Sentiment
st = sig.get("sentiment", {})
lines.append(f"📰 SENTIMENT: {st.get('overall', 0):.3f} ({st.get('label', '?')})")

# Options
op = sig.get("options_flow", {})
if op.get("overall_pc_ratio"):
    lines.append(f"🔄 OPTIONS P/C: {op['overall_pc_ratio']:.2f} ({op.get('bias', '?')})")

# Volatility
vl = sig.get("volatility", {})
if vl.get("expanding"):
    lines.append(f"⚡ VOL EXPANDING: {', '.join(vl['expanding'][:3])}")

# Events
evts = sig.get("events_next_48h", [])
if evts:
    lines.append(f"📅 EVENTS ({len(evts)} next 48h):")
    for e in evts[:3]:
        if isinstance(e, dict):
            lines.append(f"   • {e.get('name', e.get('event', '?'))}")
        else:
            lines.append(f"   • {e}")

# Position sizing
ps = sig.get("position_sizing", {})
lines.append(f"\n💰 SIZING: {ps.get('recommendation', '?')} ({ps.get('reason', '?')})")

print('\n'.join(lines))
PYEOF
  )
  summary="${summary//OUTPUT_DIR_PLACEHOLDER/$OUTPUT_DIR}"
  # Re-run with correct path
  summary=$(OUTPUT_DIR="$OUTPUT_DIR" python3 -c "
import json, os
output_dir = os.environ['OUTPUT_DIR']
with open(os.path.join(output_dir, 'consolidated.json')) as f:
    sig = json.load(f)

lines = []
lines.append('🔔 GEKKO SIGNAL RELAY v2.0')
lines.append(f'⏰ {sig.get(\"timestamp\", \"?\")}\n📊 Tools: {sig.get(\"tools_ok\", 0)}/{sig.get(\"tools_run\", 0)} successful')
mr = sig.get('market_regime', {})
lines.append(f'\n🎯 REGIME: {mr.get(\"regime\", \"?\")} (conf {mr.get(\"confidence\", 0)})')
if mr.get('vix'): lines.append(f'   VIX: {mr[\"vix\"]}')
br = sig.get('breadth', {})
if br.get('pct_above_sma20') is not None:
    lines.append(f'📈 BREADTH: {br[\"pct_above_sma20\"]}% above SMA20 → {br.get(\"signal\", \"?\")}')
st = sig.get('sentiment', {})
lines.append(f'📰 SENTIMENT: {st.get(\"overall\", 0)} ({st.get(\"label\", \"?\")})')
op = sig.get('options_flow', {})
if op.get('overall_pc_ratio'): lines.append(f'🔄 OPTIONS P/C: {op[\"overall_pc_ratio\"]} ({op.get(\"bias\", \"?\")})')
ps = sig.get('position_sizing', {})
lines.append(f'\n💰 SIZING: {ps.get(\"recommendation\", \"?\")} ({ps.get(\"reason\", \"?\")})')
print('\n'.join(lines))
" 2>/dev/null)

  # Send via ClawTalk
  local tmpfile=$(mktemp)
  python3 -c "
import json
text = '''$summary'''
msg = {
    'to': '$AGENT',
    'type': 'notification',
    'topic': 'gekko-signal-relay',
    'encrypted': False,
    'payload': {
        'text': text,
        'metadata': {
            'source': 'signal-relay-v2',
            'signal_type': 'consolidated_market_brief',
            'version': '2.0'
        }
    }
}
with open('$tmpfile', 'w') as f:
    json.dump(msg, f)
" 2>/dev/null

  local resp
  resp=$(curl -s -w "\n%{http_code}" -X POST "https://clawtalk.monkeymango.co/messages" \
      -H "Authorization: Bearer $CLAWTALK_KEY" \
      -H "Content-Type: application/json" \
      --data-binary @"$tmpfile" 2>/dev/null)
  local code=$(echo "$resp" | tail -1)
  rm -f "$tmpfile"

  if [[ "$code" == "200" || "$code" == "201" ]]; then
    log "Signal relay sent to $AGENT (HTTP $code)"
    return 0
  else
    log "Signal relay FAILED (HTTP $code)"
    return 1
  fi
}

# ---- Main ----
export OUTPUT_DIR STATE_DIR

if $DAEMON_MODE; then
  log "Daemon mode: interval=${INTERVAL}s, push enabled"
  while true; do
    log "Running signal scan..."
    result=$(aggregate_signals 2>/dev/null || echo '{"changes":[],"changed":false}')
    changed=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('changed',False))" 2>/dev/null || echo "False")
    changes=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(d.get('changes',[])))" 2>/dev/null || echo "")

    if [[ "$changed" == "True" ]]; then
      log "CHANGES DETECTED: $changes"
      send_signal && log "Alert sent" || log "Alert failed"
    else
      # Heartbeat every 15 min (every 3rd cycle at 5 min interval)
      CYCLE_COUNT=${CYCLE_COUNT:-0}
      ((CYCLE_COUNT++)) || true
      if (( CYCLE_COUNT % 3 == 0 )); then
        log "Heartbeat push (no changes, cycle $CYCLE_COUNT)"
        send_signal || true
      fi
    fi
    sleep "$INTERVAL"
  done
elif $RUN_ONCE || [[ $# -eq 0 ]]; then
  result=$(aggregate_signals 2>/dev/null)
  if $JSON_ONLY; then
    cat "$OUTPUT_DIR/consolidated.json" 2>/dev/null
  else
    echo "$result"
  fi
  if $PUSH_MODE; then
    send_signal
  fi
fi
