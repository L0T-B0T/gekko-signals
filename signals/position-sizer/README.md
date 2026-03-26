# Position Sizer v1.0

Risk-adjusted position sizing using the Gekko Signal Suite.

## What It Does
Combines regime detection, volatility surface, momentum, and correlation data to recommend per-ticker position sizes as a percentage of portfolio.

## Methodology
1. **Vol-Adjusted Base**: Uses Kelly-inspired sizing — higher vol → smaller position (normalized to 20% baseline HV)
2. **Regime Multiplier**: risk-on=1.0x, neutral=0.75x, risk-off=0.5x (reads from regime detector state)
3. **Trend Signal**: 5d + 20d momentum → strong_up(1.2x), up(1.0x), mixed(0.9x), down(0.8x), strong_down(0.6x)
4. **Position Caps**: Max 10% single position, 25% sector

## Signals
- **LONG**: Positive momentum + regime ≥0.7
- **SHORT**: Negative momentum + regime ≤0.6
- **NEUTRAL**: Mixed signals or low conviction

## Output Format
```json
{
  "ticker": "XLE",
  "price": 95.23,
  "hv20": 0.3841,
  "mom5_pct": 3.2,
  "mom20_pct": 8.7,
  "trend": "strong_up",
  "vol_factor": 0.52,
  "regime_mult": 0.75,
  "final_pct": 1.86,
  "dollars": 1859,
  "shares": 19,
  "signal": "LONG",
  "sector": "energy"
}
```

## Usage
```bash
# Standard run (prints table + saves JSON)
./position-sizer.sh

# Environment variables
PORTFOLIO_SIZE=100000 MAX_SINGLE=0.10 BASE_RISK=0.02 ./position-sizer.sh
```

## Dependencies
- bash, python3, curl
- Yahoo Finance API (rate limited: 1 req/sec)
- Reads `$SIGNAL_STATE/regime.json` from regime detector (optional, defaults to neutral)

## Integration
- Designed to run AFTER regime-detector and vol-surface-monitor
- Signal daemon can invoke periodically and push changes to Gekko via ClawTalk
