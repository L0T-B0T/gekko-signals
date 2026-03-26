#!/usr/bin/env bash
# Signal Relay Service v1.0 — Bridge Gekko Signals to ClawTalk
# Runs regime detector + news sentiment periodically, pushes CHANGES to agents
# Usage: ./signal-relay.sh [--interval 300] [--agents Lotbot,Motya] [--once]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GEKKO_DIR="/data/workspace/gekko-tools"
DB_FILE="${SCRIPT_DIR}/signal-relay.db"
INTERVAL=300  # 5 minutes default
AGENTS="Lotbot"
ONCE=false
CLAWTALK_API_KEY=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2;;
        --agents) AGENTS="$2"; shift 2;;
        --once) ONCE=true; shift;;
        --help) echo "Usage: $0 [--interval SEC] [--agents A,B] [--once]"; exit 0;;
        *) shift;;
    esac
done

# Load API key
if [ -f "${SCRIPT_DIR}/.env" ]; then
    CLAWTALK_API_KEY=$(grep -oP 'API_KEY=\K.*' "${SCRIPT_DIR}/.env" 2>/dev/null | tr -d '"' | tr -d "'")
fi
if [ -z "$CLAWTALK_API_KEY" ]; then
    echo "ERROR: No ClawTalk API key found in ${SCRIPT_DIR}/.env"
    exit 1
fi

# Initialize SQLite DB
sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS signal_state (
    signal_name TEXT PRIMARY KEY,
    last_value TEXT,
    last_change TEXT,
    updated_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS relay_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT DEFAULT (datetime('now')),
    signal_name TEXT,
    old_value TEXT,
    new_value TEXT,
    agents_notified TEXT,
    delivery_status TEXT
);
SQL

log() { echo "$(date -u +%H:%M:%S) [relay] $*"; }

# Send ClawTalk message
send_ct() {
    local agent="$1" topic="$2" text="$3"
    local tmpfile=$(mktemp)
    cat > "$tmpfile" <<EOJSON
{"to":"${agent}","type":"notification","topic":"${topic}","encrypted":false,"payload":{"text":"${text}"}}
EOJSON
    local resp
    resp=$(curl -s -X POST "https://clawtalk.monkeymango.co/messages" \
        -H "Authorization: Bearer ${CLAWTALK_API_KEY}" \
        -H "Content-Type: application/json" \
        --data-binary "@${tmpfile}" 2>&1)
    rm -f "$tmpfile"
    if echo "$resp" | grep -qE '"id"|"ok"'; then
        echo "delivered"
    else
        echo "failed: $(echo "$resp" | head -c 100)"
    fi
}

# Run regime detector and extract regime
get_regime() {
    local json_file="${GEKKO_DIR}/output/regime.json"
    # Run detector if output is stale (>10 min) or missing
    if [ -f "${GEKKO_DIR}/market-regime-detector.sh" ]; then
        local stale=true
        if [ -f "$json_file" ]; then
            local age=$(( $(date +%s) - $(stat -c %Y "$json_file" 2>/dev/null || echo 0) ))
            [ "$age" -lt 600 ] && stale=false
        fi
        if [ "$stale" = true ]; then
            bash "${GEKKO_DIR}/market-regime-detector.sh" >/dev/null 2>&1 || true
        fi
    fi
    # Read cached JSON
    if [ -f "$json_file" ]; then
        python3 -c "
import json
with open('${json_file}') as f:
    d = json.load(f)
    regime = d.get('regime', 'unknown')
    conf = d.get('confidence', 0)
    if isinstance(conf, float) and conf < 1:
        conf = int(conf * 100)
    vix = d.get('vix', 0)
    print(f'{regime}|{conf}|{vix}')
" 2>/dev/null || echo "unknown|0|0"
    else
        echo "unavailable|0|0"
    fi
}

# Run news sentiment scanner
get_sentiment() {
    if [ -f "${GEKKO_DIR}/news-sentiment.sh" ] || [ -f "/data/workspace/gekko-tools/output/sentiment-latest.json" ]; then
        # Try cached output first (faster)
        if [ -f "/data/workspace/gekko-tools/output/sentiment-latest.json" ]; then
            python3 -c "
import json
with open('/data/workspace/gekko-tools/output/sentiment-latest.json') as f:
    d = json.load(f)
    score = d.get('overall_sentiment', d.get('score', 0))
    label = d.get('label', 'neutral')
    count = d.get('headline_count', d.get('count', 0))
    print(f'{label}|{score}|{count}')
" 2>/dev/null || echo "neutral|0|0"
        else
            echo "neutral|0|0"
        fi
    else
        echo "unavailable|0|0"
    fi
}

# Check if signal changed
check_and_relay() {
    local signal_name="$1" new_value="$2" summary="$3"
    
    local old_value
    old_value=$(sqlite3 "$DB_FILE" "SELECT last_value FROM signal_state WHERE signal_name='${signal_name}'" 2>/dev/null || echo "")
    
    if [ "$old_value" = "$new_value" ]; then
        log "${signal_name}: unchanged (${new_value})"
        return 0
    fi
    
    log "${signal_name}: CHANGED ${old_value:-none} → ${new_value}"
    
    # Update state
    sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO signal_state (signal_name, last_value, last_change, updated_at) 
        VALUES ('${signal_name}', '${new_value}', '${old_value:-none}', datetime('now'))"
    
    # Send to agents
    IFS=',' read -ra AGENT_LIST <<< "$AGENTS"
    local notified=""
    for agent in "${AGENT_LIST[@]}"; do
        agent=$(echo "$agent" | xargs) # trim
        local escaped_summary
        escaped_summary=$(echo "$summary" | sed 's/"/\\"/g' | sed "s/'/\\\\'/g" | tr '\n' ' ')
        local status
        status=$(send_ct "$agent" "signal-relay" "$escaped_summary")
        log "  → ${agent}: ${status}"
        notified="${notified}${agent}:${status},"
    done
    
    # Log relay
    sqlite3 "$DB_FILE" "INSERT INTO relay_log (signal_name, old_value, new_value, agents_notified, delivery_status)
        VALUES ('${signal_name}', '${old_value:-none}', '${new_value}', '${notified}', 'sent')"
    
    return 1  # signal changed
}

# Main relay cycle
relay_cycle() {
    local changes=0
    
    # 1. Market Regime
    local regime_data
    regime_data=$(get_regime)
    local regime=$(echo "$regime_data" | cut -d'|' -f1)
    local conf=$(echo "$regime_data" | cut -d'|' -f2)
    local vix=$(echo "$regime_data" | cut -d'|' -f3)
    
    if [ "$regime" != "unavailable" ] && [ "$regime" != "unknown" ]; then
        local regime_summary="[Signal Relay] Market Regime: ${regime} (${conf}% conf, VIX ${vix})"
        check_and_relay "regime" "$regime" "$regime_summary" && true || changes=$((changes+1))
    fi
    
    # 2. News Sentiment
    local sent_data
    sent_data=$(get_sentiment)
    local sent_label=$(echo "$sent_data" | cut -d'|' -f1)
    local sent_score=$(echo "$sent_data" | cut -d'|' -f2)
    local sent_count=$(echo "$sent_data" | cut -d'|' -f3)
    
    if [ "$sent_label" != "unavailable" ]; then
        local sent_summary="[Signal Relay] News Sentiment: ${sent_label} (score ${sent_score}, ${sent_count} headlines)"
        check_and_relay "sentiment" "$sent_label" "$sent_summary" && true || changes=$((changes+1))
    fi
    
    log "Cycle complete: ${changes} signal change(s) relayed"
    return 0
}

# Stats command
show_stats() {
    echo "=== Signal Relay Stats ==="
    echo ""
    echo "Current State:"
    sqlite3 -header -column "$DB_FILE" "SELECT signal_name, last_value, last_change, updated_at FROM signal_state ORDER BY signal_name" 2>/dev/null
    echo ""
    echo "Recent Relays (last 10):"
    sqlite3 -header -column "$DB_FILE" "SELECT timestamp, signal_name, old_value, new_value, agents_notified FROM relay_log ORDER BY id DESC LIMIT 10" 2>/dev/null
    echo ""
    local total
    total=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM relay_log" 2>/dev/null || echo 0)
    echo "Total relays: ${total}"
}

# Main
log "Signal Relay v1.0 starting (interval=${INTERVAL}s, agents=${AGENTS})"

if [ "$ONCE" = true ]; then
    relay_cycle
    show_stats
    exit 0
fi

while true; do
    relay_cycle
    sleep "$INTERVAL"
done
