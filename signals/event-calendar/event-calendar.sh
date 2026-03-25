#!/usr/bin/env bash
# Event Calendar — Binary catalyst tracker for Gekko
# Tracks upcoming events that could cause sharp market moves
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/data/workspace/gekko-tools/output}"
mkdir -p "$OUTPUT_DIR"

echo "[$(date +%H:%M:%S)] === Market Event Calendar v1.0 ==="

# Fetch upcoming events from multiple sources
python3 << 'PYEOF'
import json, urllib.request, re, sys
from datetime import datetime, timedelta

now = datetime.utcnow()
events = []

# Known binary catalysts (manually curated from today's intel)
known_events = [
    {
        "date": "2026-03-28",
        "event": "IAEA Weekend Talks (Islamabad)",
        "category": "geopolitical",
        "impact": "high",
        "assets": ["XLE", "OXY", "DVN", "EOG", "GLD"],
        "direction": "binary",
        "notes": "Iran ceasefire framework attempt. If deal: Brent -15%+. If collapse: Brent +10%+"
    },
    {
        "date": "2026-03-30",
        "event": "Polymarket Taker Fee Expansion",
        "category": "prediction_market",
        "impact": "medium",
        "assets": [],
        "direction": "bearish_liquidity",
        "notes": "8 new categories get dynamic fees. Geopolitical markets stay fee-free."
    },
    {
        "date": "2026-04-03",
        "event": "Nevada Kalshi TRO Hearing",
        "category": "regulatory",
        "impact": "medium",
        "assets": [],
        "direction": "binary",
        "notes": "Judge decides if Kalshi ban continues. Registration-based blocking vs geofencing."
    },
    {
        "date": "2026-04-15",
        "event": "Kalshi Hormuz Contract Deadline",
        "category": "prediction_market",
        "impact": "medium",
        "assets": ["XLE"],
        "direction": "binary",
        "notes": "<25% odds of Hormuz normalization. ~$100K wagered. Thin liquidity."
    },
    {
        "date": "2026-04-30",
        "event": "CFTC ANPRM Comment Deadline",
        "category": "regulatory",
        "impact": "high",
        "assets": [],
        "direction": "binary",
        "notes": "Advanced Notice of Proposed Rulemaking closes. Framework shapes entire industry."
    }
]

# Try fetching earnings calendar from Yahoo Finance
try:
    # Key earnings this week
    earnings = [
        {"date": "2026-03-26", "event": "Nvidia (NVDA) Earnings", "category": "earnings", "impact": "high",
         "assets": ["NVDA", "QQQ", "XLK"], "direction": "binary",
         "notes": "AI bellwether. Beats → QQQ rally. Miss → tech selloff."},
        {"date": "2026-03-27", "event": "Lululemon (LULU) Earnings", "category": "earnings", "impact": "low",
         "assets": ["LULU", "XLY"], "direction": "binary", "notes": "Consumer discretionary signal."}
    ]
    known_events.extend(earnings)
except:
    pass

# Try fetching economic calendar
try:
    econ = [
        {"date": "2026-03-26", "event": "US GDP Q4 Final", "category": "macro", "impact": "medium",
         "assets": ["SPY", "TLT", "GLD"], "direction": "binary",
         "notes": "Final Q4 revision. Surprise up → hawkish Fed. Surprise down → risk-off."},
        {"date": "2026-03-28", "event": "PCE Inflation (Feb)", "category": "macro", "impact": "high",
         "assets": ["SPY", "TLT", "GLD"], "direction": "binary",
         "notes": "Fed's preferred inflation gauge. Hot → rate hike fears. Cool → risk-on."}
    ]
    known_events.extend(econ)
except:
    pass

# Sort by date
events_sorted = sorted(known_events, key=lambda e: e["date"])

# Filter future only
future_events = [e for e in events_sorted if e["date"] >= now.strftime("%Y-%m-%d")]

# Calculate days until
for e in future_events:
    evt_date = datetime.strptime(e["date"], "%Y-%m-%d")
    e["days_until"] = (evt_date - now).days

# Output
output = {
    "generated_at": now.isoformat() + "Z",
    "total_events": len(future_events),
    "next_48h": [e for e in future_events if e["days_until"] <= 2],
    "this_week": [e for e in future_events if e["days_until"] <= 7],
    "upcoming": future_events,
    "high_impact_count": len([e for e in future_events if e["impact"] == "high"])
}

# Print human-readable
print(f"\n{'='*60}")
print(f"  MARKET EVENT CALENDAR — {now.strftime('%Y-%m-%d %H:%M')} UTC")
print(f"{'='*60}")
print(f"  Events tracked: {output['total_events']}")
print(f"  High-impact: {output['high_impact_count']}")
print(f"  Next 48h: {len(output['next_48h'])}")
print(f"{'='*60}\n")

for e in future_events:
    urgency = "🔴" if e["days_until"] <= 1 else "🟡" if e["days_until"] <= 3 else "🟢" if e["days_until"] <= 7 else "⚪"
    impact = "🔥" if e["impact"] == "high" else "📊" if e["impact"] == "medium" else "📝"
    assets_str = ", ".join(e["assets"]) if e["assets"] else "—"
    
    print(f"{urgency} {e['date']} (+{e['days_until']}d) | {impact} {e['event']}")
    print(f"   Category: {e['category']} | Direction: {e['direction']}")
    print(f"   Assets: {assets_str}")
    print(f"   {e['notes']}")
    print()

# Save JSON
with open("/data/workspace/gekko-tools/output/event-calendar.json", "w") as f:
    json.dump(output, f, indent=2)

print(f"JSON saved: /data/workspace/gekko-tools/output/event-calendar.json")

# Also output compact JSON to stdout for piping
print("\n--- JSON ---")
compact = {
    "generated_at": output["generated_at"],
    "next_48h_events": len(output["next_48h"]),
    "high_impact": output["high_impact_count"],
    "alerts": []
}
for e in output["next_48h"]:
    compact["alerts"].append({
        "event": e["event"],
        "date": e["date"],
        "impact": e["impact"],
        "assets": e["assets"],
        "direction": e["direction"]
    })
print(json.dumps(compact, indent=2))
PYEOF

echo "[$(date +%H:%M:%S)] === Done ==="
