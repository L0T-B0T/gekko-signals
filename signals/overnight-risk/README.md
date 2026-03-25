# Overnight Risk Monitor

Pre-market risk assessment tool for Gekko. Scans overnight/pre-market data to generate risk levels and position management recommendations before US market open.

## What It Does

Collects and analyzes 5 data categories:
1. **US Futures** (ES, NQ, YM, RTY, CL, GC, SI, ZB) — gap analysis
2. **VIX** — fear gauge level + overnight change
3. **Global Indices** (FTSE, DAX, CAC, Nikkei, Hang Seng, ASX, TSX) — overnight sentiment
4. **Energy** (Crude, Brent, NatGas) — commodity shock detection
5. **Safe Haven** (Gold, Silver, Bonds) — flight-to-quality signals

## Risk Scoring (0-100)

| Component | Max Points | Trigger |
|-----------|-----------|---------|
| VIX Level | 30 | ≥35 panic, ≥28 high, ≥22 elevated |
| VIX Overnight | 15 | ≥10% spike, ≥5% move |
| Futures Gap | 20 | ≥2% large, ≥1% notable |
| Global Divergence | 15 | ≥3% range, ≥1.5% avg selloff |
| Energy Shock | 10 | ≥5% crude move |
| Safe Haven Bid | 10 | Gold >1.5% + bonds >0.5% |

## Risk Levels

| Level | Score | Action |
|-------|-------|--------|
| EXTREME | ≥60 | REDUCE_EXPOSURE |
| HIGH | ≥40 | TIGHTEN_STOPS |
| ELEVATED | ≥20 | MONITOR |
| LOW | <20 | NORMAL |

## Output Format

```json
{
  "timestamp": "2026-03-26T06:00:00Z",
  "risk_level": "ELEVATED",
  "risk_score": 25,
  "action": "MONITOR",
  "direction": "BEARISH_OPEN",
  "vix": { "level": 25.19, "overnight_change": -2.1 },
  "futures": { "es_gap": -0.45, "nq_gap": -0.72, "avg_gap": -0.38, "max_gap": 0.72 },
  "energy": { "crude_gap": -3.2 },
  "gold_gap": 0.8,
  "risk_factors": ["VIX ELEVATED: 25.2", "ENERGY MOVE: crude -3.2%"],
  "recommendation": "ELEVATED risk (25/100). MONITOR. BEARISH_OPEN."
}
```

## Usage

```bash
# One-shot scan
./overnight-risk.sh scan

# Daemon mode (5-min intervals, alerts on level changes)
./overnight-risk.sh daemon 300

# With ClawTalk alerts
CLAWTALK_API_KEY=xxx ./overnight-risk.sh daemon
```

## Best Run Times

- **Pre-market**: 4:00-6:00 AM ET (futures open, global indices closed/closing)
- **Asian open**: 7:00-8:00 PM ET (first overnight data point)
- **European open**: 3:00-4:00 AM ET (full global picture)

## Dependencies

- bash, python3, curl (stdlib only)
- No paid APIs — uses Yahoo Finance public endpoints
- Rate limiting: 1 request/sec between symbols
