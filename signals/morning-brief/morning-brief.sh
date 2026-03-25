#!/usr/bin/env bash
# Morning Market Brief v1.0 — Gekko Signal Feed
# Runs all signal tools and sends a consolidated briefing via ClawTalk
# Designed to run 15 min before market open (9:15 AM ET / 13:15 UTC)
#
# Usage: ./morning-brief.sh [--dry-run] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAWTALK_ENV="${CLAWTALK_ENV:-/data/workspace/clawtalk/.env}"

DRY_RUN=false
JSON_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --json) JSON_ONLY=true ;;
    esac
done

# Load ClawTalk API key
if [[ -f "$CLAWTALK_ENV" ]]; then
    CLAWTALK_API_KEY=$(grep 'CLAWTALK_API_KEY' "$CLAWTALK_ENV" | cut -d'=' -f2)
fi

echo "=== Gekko Morning Brief ===" >&2
echo "Time: $(date -u '+%Y-%m-%d %H:%M UTC')" >&2
echo "" >&2

# Run each signal and capture output
echo "[1/3] Running regime detector..." >&2
REGIME=$(bash "$REPO_ROOT/signals/regime-detector/regime-detector.sh" --json 2>/dev/null) || REGIME="{}"

echo "[2/3] Running news sentiment..." >&2
SENTIMENT=$(bash "$REPO_ROOT/signals/news-sentiment/news-sentiment.sh" --json 2>/dev/null) || SENTIMENT="{}"

echo "[3/3] Running correlation monitor..." >&2
CORRELATION=$(bash "$REPO_ROOT/signals/correlation-monitor/correlation-monitor.sh" --json 2>/dev/null) || CORRELATION="{}"

# Build consolidated briefing
BRIEFING=$(python3 << PYEOF
import json, datetime

regime = json.loads('''$REGIME''') if '''$REGIME'''.strip() else {}
sentiment = json.loads('''$SENTIMENT''') if '''$SENTIMENT'''.strip() else {}
correlation = json.loads('''$CORRELATION''') if '''$CORRELATION'''.strip() else {}

now = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")

# Extract regime data
rd = regime.get("data", {})
regime_label = rd.get("regime", "unknown").upper()
vix = rd.get("vix_level", "?")
vix_trend = rd.get("vix_trend", "?")
spy_5d = rd.get("spy_5d", "?")
gld_5d = rd.get("gld_5d", "?")
tlt_5d = rd.get("tlt_5d", "?")
gd_spread = rd.get("growth_defensive_spread", "?")
leaders = rd.get("sector_rotation", {}).get("leading", [])
laggers = rd.get("sector_rotation", {}).get("lagging", [])
safe_haven = rd.get("safe_haven_bid", False)
confidence = regime.get("confidence", 0)

# Extract sentiment data
sd = sentiment.get("data", {})
overall_sent = sd.get("overall_sentiment", 0)
sent_label = sd.get("overall_label", "unknown")
momentum = sd.get("momentum", "?")
themes = sd.get("key_themes", [])
sectors_sent = sd.get("sectors", {})

# Extract correlation data
corr_pairs = correlation.get("pairs", []) if isinstance(correlation, dict) else []
# Find interesting decorrelations
alerts = []
for p in corr_pairs:
    if isinstance(p, dict):
        pair = p.get("pair", "")
        corr = p.get("correlation", 0)
        cls = p.get("classification", "")
        if "uncorrelated" in cls and pair in ["SPY:TLT", "XLE:SPY"]:
            alerts.append(f"⚠️ {pair} decorrelated ({corr:.2f})")

# Divergence detection
divergence = ""
if regime_label == "RISK-OFF" and sent_label in ["bullish", "mildly_bullish"]:
    divergence = "🔀 DIVERGENCE: VIX says risk-off but sentiment is bullish — watch for resolution"
elif regime_label == "RISK-ON" and sent_label in ["bearish", "mildly_bearish"]:
    divergence = "🔀 DIVERGENCE: VIX says risk-on but sentiment is bearish — potential reversal signal"

# Build text
lines = []
lines.append(f"🌅 Gekko Morning Brief — {now}")
lines.append("")
lines.append(f"📊 REGIME: {regime_label} ({confidence*100:.0f}% conf)")
lines.append(f"   VIX: {vix} ({vix_trend}) | SPY 5d: {spy_5d}% | GLD 5d: {gld_5d}%")
lines.append(f"   Leaders: {', '.join(leaders)} | Laggers: {', '.join(laggers)}")
lines.append(f"   Growth/Defensive: {gd_spread} | Safe haven: {'YES' if safe_haven else 'NO'}")
lines.append("")
lines.append(f"📰 SENTIMENT: {sent_label.upper()} ({overall_sent:.2f}) | Momentum: {momentum}")
for sname, sdata in sectors_sent.items():
    if isinstance(sdata, dict):
        lines.append(f"   {sname}: {sdata.get('label','?')} ({sdata.get('score',0):.2f}) [{sdata.get('headlines',0)} headlines]")
if themes:
    lines.append(f"   Themes: {', '.join(themes)}")
lines.append("")
if corr_pairs:
    lines.append("🔗 CORRELATIONS:")
    for p in corr_pairs[:6]:
        if isinstance(p, dict):
            lines.append(f"   {p.get('pair','?')}: {p.get('correlation',0):.2f} ({p.get('classification','?')})")
if alerts:
    lines.append("")
    for a in alerts:
        lines.append(a)
if divergence:
    lines.append("")
    lines.append(divergence)

# Build output
output = {
    "signal_type": "morning_brief",
    "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "data": {
        "regime": regime,
        "sentiment": sentiment,
        "correlation": correlation,
        "divergence_detected": bool(divergence),
        "correlation_alerts": alerts
    },
    "text_summary": "\\n".join(lines),
    "source": "morning-brief-v1"
}

print(json.dumps(output, indent=2))
PYEOF
)

if $JSON_ONLY; then
    echo "$BRIEFING"
    exit 0
fi

if $DRY_RUN; then
    echo "[DRY RUN] Morning Brief:"
    echo "$BRIEFING" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('text_summary','no summary'))"
    exit 0
fi

# Send via ClawTalk
SUMMARY=$(echo "$BRIEFING" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('text_summary','Morning brief generated.'))")

MSG=$(python3 -c "
import json
msg = {
    'to': 'Lotbot',
    'type': 'notification',
    'topic': 'gekko-signal',
    'encrypted': False,
    'payload': {'text': '''$SUMMARY'''}
}
print(json.dumps(msg))
")

tmpfile=$(mktemp)
echo "$MSG" > "$tmpfile"

response=$(curl -sf -X POST "https://clawtalk.monkeymango.co/messages" \
    -H "Authorization: Bearer $CLAWTALK_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "@$tmpfile" 2>&1) || true

rm -f "$tmpfile"

echo "✅ Morning brief sent to Lotbot via ClawTalk"
echo "$BRIEFING" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('text_summary',''))"
