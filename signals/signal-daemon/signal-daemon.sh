#!/usr/bin/env bash
# Gekko Signal Daemon v1.0
# Runs all 3 signal tools on schedule, pushes changes to Lotbot via ClawTalk
# Only sends on regime/sentiment CHANGES — no spam
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGNALS_DIR="/data/workspace/gekko-signals/signals"
STATE_DIR="$SCRIPT_DIR/.signal-state"
LOG="$SCRIPT_DIR/signal-daemon.log"
CLAWTALK_KEY=$(grep CLAWTALK_API_KEY /data/workspace/clawtalk/.env 2>/dev/null | cut -d= -f2 || true)
AGENT="Lotbot"
INTERVAL=${SIGNAL_INTERVAL:-300}  # 5 min default

mkdir -p "$STATE_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG"; }
log "Signal daemon v1.0 starting (interval=${INTERVAL}s)"

send_clawtalk() {
    local topic="$1" text="$2"
    [ -z "$CLAWTALK_KEY" ] && { log "SKIP: no ClawTalk key"; return 1; }
    local tmpfile=$(mktemp)
    cat > "$tmpfile" <<EOJSON
{"to":"$AGENT","type":"notification","topic":"$topic","encrypted":false,"payload":{"text":"$text","metadata":{"source":"signal-daemon","timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}}}
EOJSON
    local resp
    resp=$(curl -s -w "\n%{http_code}" -X POST "https://clawtalk.monkeymango.co/messages" \
        -H "Authorization: Bearer $CLAWTALK_KEY" \
        -H "Content-Type: application/json" \
        --data-binary @"$tmpfile" 2>/dev/null)
    local code=$(echo "$resp" | tail -1)
    rm -f "$tmpfile"
    if [ "$code" = "200" ] || [ "$code" = "201" ]; then
        log "SENT($topic): $code"
        return 0
    else
        log "FAIL($topic): $code"
        return 1
    fi
}

parse_first_json() {
    # Extract first complete JSON object from output (scripts may emit multiple)
    python3 -c "
import sys
raw = sys.stdin.read()
brace = 0; start = -1; end = -1
for i, c in enumerate(raw):
    if c == '{':
        if start == -1: start = i
        brace += 1
    elif c == '}':
        brace -= 1
        if brace == 0 and start >= 0:
            end = i + 1
            break
if start >= 0 and end > start:
    print(raw[start:end])
else:
    print('{}')
" 2>/dev/null
}

run_regime_detector() {
    log "Running regime detector..."
    local output
    output=$(bash "$SIGNALS_DIR/regime-detector/regime-detector.sh" --json 2>/dev/null | parse_first_json) || { log "regime: FAILED"; return 1; }
    
    local regime confidence
    regime=$(echo "$output" | python3 -c "
import sys,json
d=json.load(sys.stdin)
# Handle both flat and nested formats
if 'data' in d: d = d['data']
print(d.get('regime','unknown'))
" 2>/dev/null || echo "unknown")
    confidence=$(echo "$output" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('confidence',0))
" 2>/dev/null || echo "0")
    
    local prev_regime=""
    [ -f "$STATE_DIR/regime.txt" ] && prev_regime=$(cat "$STATE_DIR/regime.txt")
    
    echo "$regime" > "$STATE_DIR/regime.txt"
    echo "$output" > "$STATE_DIR/regime.json"
    
    if [ "$regime" != "$prev_regime" ] && [ -n "$prev_regime" ]; then
        log "REGIME CHANGE: $prev_regime -> $regime (confidence=$confidence)"
        local vix sectors
        vix=$(echo "$output" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data = d.get('data', d)
print(data.get('vix_level', data.get('vix','?')))
" 2>/dev/null || echo "?")
        sectors=$(echo "$output" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data = d.get('data', d)
rot = data.get('sector_rotation', {})
lead = rot.get('leading', data.get('leading_sectors',['?']))[:3]
lag = rot.get('lagging', data.get('lagging_sectors',['?']))[:3]
print(f'Leading: {\", \".join(lead)} | Lagging: {\", \".join(lag)}')
" 2>/dev/null || echo "?")
        send_clawtalk "gekko-regime-alert" \
            "🔄 REGIME CHANGE: ${prev_regime} → ${regime} (${confidence}% confidence). VIX: ${vix}. ${sectors}. Source: signal-daemon auto-push."
        return 0
    else
        log "regime: $regime (unchanged from $prev_regime)"
        return 1
    fi
}

run_sentiment_scorer() {
    log "Running sentiment scorer..."
    local output
    output=$(bash "$SIGNALS_DIR/news-sentiment/news-sentiment.sh" --json 2>/dev/null | parse_first_json) || { log "sentiment: FAILED"; return 1; }
    
    local overall
    overall=$(echo "$output" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data = d.get('data', d)
print(data.get('overall_sentiment', data.get('sentiment', 0)))
" 2>/dev/null || echo "0")
    
    local prev_sentiment="0"
    [ -f "$STATE_DIR/sentiment.txt" ] && prev_sentiment=$(cat "$STATE_DIR/sentiment.txt")
    
    echo "$overall" > "$STATE_DIR/sentiment.txt"
    echo "$output" > "$STATE_DIR/sentiment.json"
    
    # Alert on >0.15 shift
    local shift
    shift=$(python3 -c "print(abs(float('$overall') - float('$prev_sentiment')))" 2>/dev/null || echo "0")
    local significant
    significant=$(python3 -c "print('yes' if float('$shift') > 0.15 else 'no')" 2>/dev/null || echo "no")
    
    if [ "$significant" = "yes" ]; then
        local label
        label=$(python3 -c "
s=float('$overall')
if s > 0.1: print('BULLISH')
elif s < -0.1: print('BEARISH')
else: print('NEUTRAL')
" 2>/dev/null || echo "?")
        log "SENTIMENT SHIFT: $prev_sentiment -> $overall (shift=$shift)"
        
        local sectors
        sectors=$(echo "$output" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data = d.get('data', d)
secs = data.get('sectors', data.get('sector_sentiment', {}))
if isinstance(secs, dict):
    # Handle both {sector: score} and {sector: {score: X}} formats
    items = []
    for k, v in secs.items():
        if isinstance(v, dict):
            items.append((k, v.get('score', 0)))
        elif isinstance(v, (int, float)):
            items.append((k, v))
    items.sort(key=lambda x: abs(x[1]), reverse=True)
    parts = [f'{k}: {v:+.2f}' for k, v in items[:4]]
    print(' | '.join(parts))
else:
    print('?')
" 2>/dev/null || echo "?")
        send_clawtalk "gekko-sentiment-alert" \
            "📊 SENTIMENT SHIFT: ${prev_sentiment} → ${overall} ($label, Δ${shift}). Sectors: ${sectors}. Source: signal-daemon auto-push."
        return 0
    else
        log "sentiment: $overall (shift=$shift, below threshold)"
        return 1
    fi
}

run_correlation_monitor() {
    log "Running correlation monitor..."
    local output
    output=$(bash "$SIGNALS_DIR/correlation-monitor/correlation-monitor.sh" --json 2>/dev/null | parse_first_json) || { log "correlation: FAILED"; return 1; }
    
    # Check for decorrelation events
    local alerts
    alerts=$(echo "$output" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data = d.get('data', d)
pairs = data.get('pairs', data.get('correlations', []))
decorr = [p for p in pairs if abs(p.get('correlation', p.get('corr', 0))) < 0.2 and p.get('expected','') in ['positive','negative']]
if decorr:
    for p in decorr[:3]:
        c = p.get('correlation', p.get('corr', 0))
        print(f\"{p.get('pair','?')}: {c:.2f} (expected {p.get('expected','?')})\")
" 2>/dev/null || echo "")
    
    echo "$output" > "$STATE_DIR/correlation.json"
    
    if [ -n "$alerts" ]; then
        local prev_alert=""
        [ -f "$STATE_DIR/corr_alert.txt" ] && prev_alert=$(cat "$STATE_DIR/corr_alert.txt")
        
        local alert_hash
        alert_hash=$(echo "$alerts" | md5sum | cut -d' ' -f1)
        
        if [ "$alert_hash" != "$prev_alert" ]; then
            echo "$alert_hash" > "$STATE_DIR/corr_alert.txt"
            log "DECORRELATION: $alerts"
            send_clawtalk "gekko-correlation-alert" \
                "⚡ DECORRELATION DETECTED: ${alerts}. Trading signal: pairs diverging from historical norm. Source: signal-daemon auto-push."
            return 0
        fi
    fi
    
    log "correlation: no new alerts"
    return 1
}

# Main loop
cycle=0
while true; do
    cycle=$((cycle + 1))
    log "=== Cycle $cycle ==="
    
    alerts_sent=0
    
    run_regime_detector && alerts_sent=$((alerts_sent + 1)) || true
    run_sentiment_scorer && alerts_sent=$((alerts_sent + 1)) || true
    run_correlation_monitor && alerts_sent=$((alerts_sent + 1)) || true
    
    # Heartbeat every 3 cycles (15 min) even if no changes
    if [ $((cycle % 3)) -eq 0 ]; then
        hb_regime="?"
        hb_sentiment="?"
        [ -f "$STATE_DIR/regime.txt" ] && hb_regime=$(cat "$STATE_DIR/regime.txt")
        [ -f "$STATE_DIR/sentiment.txt" ] && hb_sentiment=$(cat "$STATE_DIR/sentiment.txt")
        hb_ts=$(date -u +%H:%M)
        send_clawtalk "gekko-heartbeat" \
            "💓 Signal daemon heartbeat ($hb_ts UTC). Regime: $hb_regime | Sentiment: $hb_sentiment | Alerts sent this cycle: $alerts_sent. Running normally." || true
    fi
    
    log "Cycle $cycle done. Alerts: $alerts_sent. Sleeping ${INTERVAL}s..."
    sleep "$INTERVAL"
done
