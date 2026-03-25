# Volatility Surface Monitor

Tracks historical vs implied volatility across 7 key assets to detect vol compression/expansion regimes.

## Assets Tracked
SPY, QQQ, XLE, VIX, GLD, TLT, IWM

## Metrics
- **HV30d**: 30-day historical volatility (annualized)
- **RV5d**: 5-day recent volatility (annualized) 
- **Vol Ratio**: RV5d / HV30d — measures vol regime
- **Max Drawdown**: Peak-to-trough in lookback period

## Signals
| Signal | Vol Ratio | Meaning |
|--------|-----------|---------|
| VOL_SPIKE | >2.0 | Extreme expansion — crisis/dislocation |
| EXPANDING | >1.5 | Vol rising — protective positioning |
| NORMAL | 0.7-1.5 | Balanced — no extreme signal |
| CONTRACTING | 0.5-0.7 | Vol declining — pre-breakout |
| COMPRESSED | <0.5 | Vol floor — breakout imminent |

## Cross-Asset Divergence
Detects XLE/SPY vol divergence — leading indicator for sector rotation timing.

## Usage
```bash
# One-shot scan
./vol-surface-monitor.sh

# JSON output only  
./vol-surface-monitor.sh 2>/dev/null | sed -n '/^--- JSON OUTPUT ---$/,$ p' | tail -n +2
```

## Output
Human-readable dashboard + JSON object conforming to Gekko signal spec.
