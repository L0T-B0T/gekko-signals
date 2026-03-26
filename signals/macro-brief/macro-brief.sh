#!/usr/bin/env bash
# Macro Regime Brief v1.0 — Consolidated Gekko Signal Summary
# Synthesizes market data into a single actionable brief
# Usage: ./macro-brief.sh [text|json]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FORMAT="${1:-text}"

echo "Fetching market data..." >&2

BRIEF=$(python3 << 'PYEOF'
import urllib.request, json, sys
from datetime import datetime, timedelta

def fetch_yahoo(sym):
    """Fetch latest price from Yahoo Finance"""
    try:
        url = f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}?range=5d&interval=1d"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            d = json.loads(resp.read())
        meta = d["chart"]["result"][0]["meta"]
        price = meta.get("regularMarketPrice", 0)
        prev = meta.get("chartPreviousClose", price)
        chg_pct = ((price - prev) / prev * 100) if prev else 0
        return {"price": round(price, 2), "change_pct": round(chg_pct, 2)}
    except Exception as e:
        return {"price": 0, "change_pct": 0, "error": str(e)}

# === 1. MARKET SNAPSHOT ===
core_tickers = {
    "SPY": "S&P 500", "QQQ": "Nasdaq 100", "^VIX": "VIX",
    "XLE": "Energy", "TLT": "20Y Bond", "GLD": "Gold",
    "CL=F": "WTI Crude", "BZ=F": "Brent Crude", "DX-Y.NYB": "USD Index"
}
snapshot = {}
for sym, name in core_tickers.items():
    data = fetch_yahoo(sym)
    data["name"] = name
    data["symbol"] = sym
    snapshot[sym] = data

# === 2. REGIME CLASSIFICATION ===
vix = snapshot.get("^VIX", {}).get("price", 20)
spy_chg = snapshot.get("SPY", {}).get("change_pct", 0)
xle_chg = snapshot.get("XLE", {}).get("change_pct", 0)
tlt_chg = snapshot.get("TLT", {}).get("change_pct", 0)
gld_chg = snapshot.get("GLD", {}).get("change_pct", 0)

score = 0
reasons = []

# VIX level
if vix > 30:
    score -= 3; reasons.append(f"VIX extreme ({vix:.1f})")
elif vix > 25:
    score -= 2; reasons.append(f"VIX elevated ({vix:.1f})")
elif vix > 20:
    score -= 1; reasons.append(f"VIX above avg ({vix:.1f})")
elif vix < 15:
    score += 2; reasons.append(f"VIX low ({vix:.1f})")
else:
    score += 1; reasons.append(f"VIX normal ({vix:.1f})")

# Equity momentum
if spy_chg > 1.5:
    score += 3; reasons.append(f"SPY strong rally ({spy_chg:+.2f}%)")
elif spy_chg > 0.5:
    score += 1; reasons.append(f"SPY up ({spy_chg:+.2f}%)")
elif spy_chg < -1.5:
    score -= 3; reasons.append(f"SPY selloff ({spy_chg:+.2f}%)")
elif spy_chg < -0.5:
    score -= 1; reasons.append(f"SPY down ({spy_chg:+.2f}%)")

# Safe haven bid (bearish)
if gld_chg > 1 and tlt_chg > 0.5:
    score -= 1; reasons.append("Safe haven bid (GLD+TLT)")
elif gld_chg < -0.5 and tlt_chg < -0.5:
    score += 1; reasons.append("Safe haven unwind")

# Energy shock
if abs(xle_chg) > 3:
    reasons.append(f"Energy shock (XLE {xle_chg:+.2f}%)")

if score >= 4: regime = "STRONG_RISK_ON"
elif score >= 2: regime = "RISK_ON"
elif score >= 0: regime = "NEUTRAL"
elif score >= -2: regime = "RISK_OFF"
else: regime = "STRONG_RISK_OFF"

confidence = min(95, 40 + abs(score) * 12)

regime_data = {
    "regime": regime,
    "score": score,
    "confidence": confidence,
    "vix": round(vix, 2),
    "reasons": reasons
}

# === 3. SECTOR ROTATION ===
sector_etfs = ["XLE","XLF","XLK","XLV","XLC","XLI","XLB","XLRE","XLU","XLP","XLY"]
sectors = []
for sym in sector_etfs:
    data = fetch_yahoo(sym)
    sectors.append({"symbol": sym, "change": data["change_pct"]})

sectors.sort(key=lambda x: x["change"], reverse=True)
leaders = sectors[:3]
laggards = sectors[-3:]
spread = (sectors[0]["change"] - sectors[-1]["change"]) if sectors else 0

# Rotation type
if leaders[0]["symbol"] in ["XLE","XLB","XLI"]:
    rotation = "CYCLICAL (value/commodity)"
elif leaders[0]["symbol"] in ["XLK","XLC","XLY"]:
    rotation = "GROWTH (tech/consumer)"
elif leaders[0]["symbol"] in ["XLU","XLP","XLV"]:
    rotation = "DEFENSIVE (utilities/staples)"
else:
    rotation = "MIXED"

sector_data = {
    "leaders": leaders,
    "laggards": laggards,
    "spread": round(spread, 2),
    "rotation_type": rotation
}

# === 4. KEY EVENTS (next 72h) ===
now = datetime.utcnow()
upcoming = [
    {"name": "US GDP Q4 Final", "dt": "2026-03-27T12:30:00", "cat": "macro", "impact": "high"},
    {"name": "US PCE Inflation", "dt": "2026-03-28T12:30:00", "cat": "macro", "impact": "critical"},
    {"name": "IAEA Iran Talks (Islamabad)", "dt": "2026-03-28T09:00:00", "cat": "geopolitical", "impact": "critical"},
    {"name": "Edward Laws CFO Interview", "dt": "2026-03-27T15:00:00", "cat": "business", "impact": "medium"},
]
events = []
for e in upcoming:
    try:
        evt = datetime.strptime(e["dt"], "%Y-%m-%dT%H:%M:%S")
        hrs = (evt - now).total_seconds() / 3600
        if 0 < hrs < 72:
            events.append({
                "name": e["name"],
                "hours_away": round(hrs, 1),
                "category": e["cat"],
                "impact": e["impact"]
            })
    except:
        pass

# === 5. ACTIONABLE SUMMARY ===
actions = []
if "RISK_OFF" in regime:
    actions.append("Reduce equity exposure, favor GLD/TLT")
    if vix > 28: actions.append("Consider VIX put spreads for mean reversion")
elif "RISK_ON" in regime:
    actions.append("Favor growth sectors (XLK/XLC), trim safe havens")
    if spread > 3: actions.append(f"Wide sector spread ({spread:.1f}%) = rotation trade")
else:
    actions.append("Neutral stance — watch VIX and sector breadth for direction")

if any(e["impact"] == "critical" for e in events):
    actions.append("⚠️ Critical event(s) within 72h — size positions accordingly")

# === OUTPUT ===
brief = {
    "generated": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "regime": regime_data,
    "snapshot": {sym: {"name": v["name"], "price": v["price"], "change_pct": v["change_pct"]}
                 for sym, v in snapshot.items()},
    "sectors": sector_data,
    "events": events,
    "actions": actions,
    "tool_count": 17,
    "version": "1.0"
}

fmt = sys.argv[1] if len(sys.argv) > 1 else "text"

if fmt == "json":
    print(json.dumps(brief, indent=2))
else:
    r = regime_data
    print(f"╔═══════════════════════════════════════════╗")
    print(f"║        MACRO REGIME BRIEF v1.0            ║")
    print(f"║        {now.strftime('%Y-%m-%d %H:%M UTC'):^35}║")
    print(f"╚═══════════════════════════════════════════╝")
    print()
    icon = {"STRONG_RISK_ON":"🟢🟢","RISK_ON":"🟢","NEUTRAL":"⚪","RISK_OFF":"🔴","STRONG_RISK_OFF":"🔴🔴"}
    print(f"  REGIME: {icon.get(r['regime'],'?')} {r['regime']} ({r['confidence']}% conf)")
    print(f"  VIX: {r['vix']:.2f}")
    for reason in r["reasons"]:
        print(f"    • {reason}")
    print()
    
    print("── MARKET SNAPSHOT ──────────────────────────")
    for sym, data in snapshot.items():
        arrow = "▲" if data["change_pct"] > 0 else "▼" if data["change_pct"] < 0 else "━"
        print(f"  {data['name']:14} {data['price']:>10.2f}  {arrow} {data['change_pct']:+.2f}%")
    print()
    
    print(f"── SECTOR ROTATION ({sector_data['rotation_type']}) ──")
    print(f"  Spread: {sector_data['spread']:.1f}% | Leaders vs Laggards")
    print("  ▲ " + " | ".join(f"{s['symbol']} {s['change']:+.2f}%" for s in leaders))
    print("  ▼ " + " | ".join(f"{s['symbol']} {s['change']:+.2f}%" for s in laggards))
    print()
    
    if events:
        print("── EVENTS (next 72h) ───────────────────────")
        for e in events:
            ic = "🔴" if e["impact"] == "critical" else "🟡" if e["impact"] == "high" else "⚪"
            print(f"  {ic} {e['hours_away']:>5.1f}h — {e['name']}")
        print()
    
    print("── ACTIONS ─────────────────────────────────")
    for a in actions:
        print(f"  ⚡ {a}")
    print()
    print(f"[{len(snapshot)} instruments | {len(sectors)} sectors | {len(events)} events]")

PYEOF
)

echo "$BRIEF"
