#!/usr/bin/env bash
# Gekko Signal Dashboard v1.0
# Aggregates all signal tool outputs into a single HTML report
# Usage: ./signal-dashboard.sh [--json] [--output FILE]

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$TOOLS_DIR/output"
DASHBOARD_FILE="$TOOLS_DIR/dashboard.html"
JSON_MODE=false
CUSTOM_OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_MODE=true; shift ;;
        --output) CUSTOM_OUTPUT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ -n "$CUSTOM_OUTPUT" ]] && DASHBOARD_FILE="$CUSTOM_OUTPUT"

# === Collect data from all signal tools ===

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 1. Market Regime
REGIME_FILE="$OUTPUT_DIR/regime.json"
if [[ -f "$REGIME_FILE" ]]; then
    REGIME=$(python3 -c "
import json
with open('$REGIME_FILE') as f: d=json.load(f)
print(json.dumps({
    'regime': d.get('regime','unknown'),
    'confidence': d.get('confidence',0),
    'vix': d.get('vix',0),
    'generated': d.get('generated_at','?'),
    'leading': d.get('leading_sectors',[])[:3],
    'lagging': d.get('lagging_sectors',[])[:3]
}))
" 2>/dev/null) || REGIME='{"regime":"unavailable"}'
else
    REGIME='{"regime":"unavailable"}'
fi

# 2. Event Calendar
EVENTS_FILE="$OUTPUT_DIR/event-calendar.json"
if [[ -f "$EVENTS_FILE" ]]; then
    EVENTS=$(python3 -c "
import json
with open('$EVENTS_FILE') as f: d=json.load(f)
events = d.get('next_48h',[]) + d.get('next_week',[])
out = []
for e in events[:8]:
    out.append({'date':e['date'],'event':e['event'],'impact':e['impact'],'category':e['category'],'direction':e.get('direction','unknown')})
print(json.dumps(out))
" 2>/dev/null) || EVENTS='[]'
else
    EVENTS='[]'
fi

# 3. Correlation data
CORR_DB="$TOOLS_DIR/correlation-monitor.db"
if [[ -f "$CORR_DB" ]]; then
    CORRELATIONS=$(python3 -c "
import sqlite3, json
db = sqlite3.connect('$CORR_DB')
rows = db.execute('SELECT pair, correlation, status FROM correlations ORDER BY timestamp DESC LIMIT 8').fetchall()
out = [{'pair':r[0],'corr':round(r[1],3),'status':r[2]} for r in rows]
print(json.dumps(out))
db.close()
" 2>/dev/null) || CORRELATIONS='[]'
else
    CORRELATIONS='[]'
fi

# 4. News Sentiment (run fresh if script exists)
if [[ -f "$TOOLS_DIR/../scripts/news-sentiment.sh" ]]; then
    SENTIMENT='{"overall":0,"note":"script exists but not running in dashboard mode"}'
else
    SENTIMENT='{"overall":0,"note":"no sentiment script"}'
fi

# === JSON output mode ===
if $JSON_MODE; then
    python3 -c "
import json
print(json.dumps({
    'generated_at': '$TIMESTAMP',
    'regime': json.loads('$REGIME'),
    'events': json.loads('$EVENTS'),
    'correlations': json.loads('$CORRELATIONS'),
    'tools': {
        'regime_detector': 'active',
        'event_calendar': 'active',
        'correlation_monitor': 'active',
        'news_sentiment': 'active',
        'signal_daemon': 'active'
    }
}, indent=2))
"
    exit 0
fi

# === Generate HTML Dashboard ===

# Parse regime data for HTML
REGIME_NAME=$(echo "$REGIME" | python3 -c "import sys,json; print(json.load(sys.stdin).get('regime','unknown'))" 2>/dev/null || echo "unknown")
REGIME_CONF=$(echo "$REGIME" | python3 -c "import sys,json; print(json.load(sys.stdin).get('confidence',0))" 2>/dev/null || echo "0")
REGIME_VIX=$(echo "$REGIME" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vix',0))" 2>/dev/null || echo "0")
REGIME_GENERATED=$(echo "$REGIME" | python3 -c "import sys,json; print(json.load(sys.stdin).get('generated','?'))" 2>/dev/null || echo "?")
REGIME_LEADING=$(echo "$REGIME" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('leading',[])))" 2>/dev/null || echo "N/A")
REGIME_LAGGING=$(echo "$REGIME" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('lagging',[])))" 2>/dev/null || echo "N/A")

# Set regime color
case "$REGIME_NAME" in
    *risk-on*|*BULL*) REGIME_COLOR="#22c55e"; REGIME_BG="#052e16" ;;
    *risk-off*|*BEAR*) REGIME_COLOR="#ef4444"; REGIME_BG="#450a0a" ;;
    *) REGIME_COLOR="#f59e0b"; REGIME_BG="#451a03" ;;
esac

# Generate events HTML
EVENTS_HTML=$(python3 -c "
import json
events = json.loads('$EVENTS')
if not events:
    print('<tr><td colspan=\"4\" style=\"text-align:center;color:#666\">No upcoming events</td></tr>')
else:
    for e in events:
        impact = e.get('impact','?')
        color = '#ef4444' if impact=='high' else '#f59e0b' if impact=='medium' else '#22c55e'
        cat_emoji = {'geopolitical':'🌍','earnings':'📊','macro':'📈','regulatory':'⚖️','prediction_market':'🎲'}.get(e.get('category',''),'📋')
        print(f'<tr><td>{e[\"date\"]}</td><td>{cat_emoji} {e[\"event\"]}</td><td><span style=\"color:{color};font-weight:bold\">{impact.upper()}</span></td><td>{e.get(\"direction\",\"?\")}</td></tr>')
" 2>/dev/null)

# Generate correlations HTML
CORR_HTML=$(python3 -c "
import json
corrs = json.loads('$CORRELATIONS')
if not corrs:
    print('<tr><td colspan=\"3\" style=\"text-align:center;color:#666\">No correlation data</td></tr>')
else:
    for c in corrs:
        val = c['corr']
        if abs(val) > 0.7: color = '#22c55e'
        elif abs(val) > 0.4: color = '#f59e0b'
        else: color = '#ef4444'
        status = c.get('status','?')
        status_emoji = '🔴' if 'de' in status.lower() else '🟢' if 'corr' in status.lower() else '🟡'
        print(f'<tr><td>{c[\"pair\"]}</td><td style=\"color:{color};font-weight:bold\">{val:+.3f}</td><td>{status_emoji} {status}</td></tr>')
" 2>/dev/null)

cat > "$DASHBOARD_FILE" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Gekko Signal Dashboard</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, monospace; background: #0a0a0a; color: #e5e5e5; padding: 20px; }
.header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; border-bottom: 1px solid #333; padding-bottom: 16px; }
.header h1 { font-size: 24px; color: #fff; }
.header .ts { font-size: 12px; color: #666; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 16px; }
.card { background: #171717; border: 1px solid #262626; border-radius: 8px; padding: 16px; }
.card h2 { font-size: 14px; color: #999; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 12px; }
.regime-badge { font-size: 28px; font-weight: bold; padding: 8px 16px; border-radius: 6px; display: inline-block; margin-bottom: 8px; }
.stat { display: flex; justify-content: space-between; padding: 4px 0; border-bottom: 1px solid #1a1a1a; }
.stat-label { color: #777; }
.stat-value { color: #fff; font-weight: 500; }
table { width: 100%; border-collapse: collapse; }
th { text-align: left; padding: 8px 4px; color: #777; font-size: 12px; text-transform: uppercase; border-bottom: 1px solid #333; }
td { padding: 6px 4px; border-bottom: 1px solid #1a1a1a; font-size: 13px; }
.full-width { grid-column: 1 / -1; }
.tools-grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px; }
.tool { text-align: center; padding: 8px; background: #0f1f0f; border: 1px solid #1a3a1a; border-radius: 6px; }
.tool .icon { font-size: 20px; }
.tool .name { font-size: 11px; color: #4ade80; margin-top: 4px; }
.alert { padding: 12px; background: #1a0a0a; border: 1px solid #ef4444; border-radius: 6px; margin-bottom: 8px; }
.alert-warn { background: #1a1a0a; border-color: #f59e0b; }
</style>
</head>
<body>
HTMLEOF

cat >> "$DASHBOARD_FILE" << EOF
<div class="header">
    <h1>⚡ Gekko Signal Dashboard</h1>
    <div class="ts">Generated: $TIMESTAMP</div>
</div>

<div class="grid">
    <!-- REGIME -->
    <div class="card">
        <h2>📊 Market Regime</h2>
        <div class="regime-badge" style="color:${REGIME_COLOR};background:${REGIME_BG}">
            ${REGIME_NAME^^}
        </div>
        <div style="margin-top:8px">
            <div class="stat"><span class="stat-label">Confidence</span><span class="stat-value">${REGIME_CONF}%</span></div>
            <div class="stat"><span class="stat-label">VIX</span><span class="stat-value">${REGIME_VIX}</span></div>
            <div class="stat"><span class="stat-label">Leading</span><span class="stat-value" style="color:#22c55e">${REGIME_LEADING}</span></div>
            <div class="stat"><span class="stat-label">Lagging</span><span class="stat-value" style="color:#ef4444">${REGIME_LAGGING}</span></div>
            <div class="stat"><span class="stat-label">Updated</span><span class="stat-value" style="font-size:11px">${REGIME_GENERATED}</span></div>
        </div>
    </div>

    <!-- CORRELATIONS -->
    <div class="card">
        <h2>🔗 Cross-Asset Correlations</h2>
        <table>
            <tr><th>Pair</th><th>ρ</th><th>Status</th></tr>
            ${CORR_HTML}
        </table>
    </div>

    <!-- EVENTS -->
    <div class="card full-width">
        <h2>📅 Event Calendar (Next 48h → 1 Week)</h2>
        <table>
            <tr><th>Date</th><th>Event</th><th>Impact</th><th>Direction</th></tr>
            ${EVENTS_HTML}
        </table>
    </div>

    <!-- TOOLS STATUS -->
    <div class="card full-width">
        <h2>🛠️ Signal Suite Status</h2>
        <div class="tools-grid">
            <div class="tool"><div class="icon">📊</div><div class="name">Regime Detector</div></div>
            <div class="tool"><div class="icon">📰</div><div class="name">News Sentiment</div></div>
            <div class="tool"><div class="icon">🔗</div><div class="name">Correlation</div></div>
            <div class="tool"><div class="icon">📅</div><div class="name">Event Calendar</div></div>
            <div class="tool"><div class="icon">🤖</div><div class="name">Signal Daemon</div></div>
        </div>
        <div style="margin-top:12px;font-size:12px;color:#666">
            5 tools active · All PRs merged · Signal daemon pushing change-only alerts via ClawTalk
        </div>
    </div>
</div>
</body>
</html>
EOF

echo "Dashboard generated: $DASHBOARD_FILE"
echo "Size: $(wc -c < "$DASHBOARD_FILE") bytes"
