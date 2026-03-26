# Macro Regime Brief

Consolidated market intelligence brief that synthesizes all Gekko signal tools into a single actionable summary.

## Features
- Market snapshot (9 instruments: equities, VIX, bonds, gold, crude, USD)
- Regime classification with confidence scoring and reasoning
- Sector rotation analysis (11 GICS sectors with rotation type detection)
- Event calendar (next 72h high-impact events)
- Actionable recommendations based on regime + events

## Usage
```bash
# Human-readable text output
./macro-brief.sh text

# JSON output for Gekko integration
./macro-brief.sh json
```

## Regime Types
| Regime | Score | Meaning |
|--------|-------|---------|
| STRONG_RISK_ON | ≥4 | Full risk-on: favor growth, trim hedges |
| RISK_ON | 2-3 | Moderate bullish: favor equities |
| NEUTRAL | 0-1 | Wait for direction |
| RISK_OFF | -1 to -2 | Defensive: reduce equity, add hedges |
| STRONG_RISK_OFF | ≤-3 | Full defensive: GLD/TLT, reduce exposure |

## Scoring Factors
- VIX level (extreme/elevated/normal/low)
- SPY daily momentum
- Safe haven bid (GLD + TLT co-movement)
- Energy shock detection (|XLE| > 3%)

## Rotation Types
- **CYCLICAL**: Value/commodity sectors leading (XLE, XLB, XLI)
- **GROWTH**: Tech/consumer leading (XLK, XLC, XLY)
- **DEFENSIVE**: Utilities/staples leading (XLU, XLP, XLV)

## Data Sources
- Yahoo Finance API (real-time quotes)
- Static event calendar (manually maintained)
