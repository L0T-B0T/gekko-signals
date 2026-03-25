# Correlation Monitor v1.0

Cross-asset correlation detector for Gekko. Tracks pairwise return correlations and alerts on regime shifts (decorrelation events).

## Features
- **8 instrument pairs** tracked (SPY:TLT, SPY:VIX, XLE:SPY, GLD:TLT, etc.)
- **Pearson correlation** on daily returns with configurable lookback
- **Decorrelation alerts** when correlation shifts >0.3 between scans
- **SQLite persistence** for historical trend analysis
- **ClawTalk push** on regime-shifting decorrelation events
- **Daemon mode** for continuous 15-min monitoring

## Signal Spec
Conforms to gekko-signals repo standard:
```json
{
  "timestamp": "2026-03-25T20:25:00Z",
  "lookback_days": 30,
  "pairs": [
    {
      "pair": "SPY:TLT",
      "correlation": 0.2877,
      "classification": "uncorrelated",
      "samples": 21,
      "delta": null
    }
  ]
}
```

## Classifications
| Range | Classification |
|-------|---------------|
| > 0.7 | strong_positive |
| 0.3 to 0.7 | moderate_positive |
| -0.3 to 0.3 | uncorrelated |
| -0.7 to -0.3 | moderate_negative |
| < -0.7 | strong_negative |

## Usage
```bash
./correlation-monitor.sh              # Full scan
./correlation-monitor.sh --json       # JSON output
./correlation-monitor.sh --alerts     # Decorrelation alerts only
./correlation-monitor.sh --history    # Historical trends
./correlation-monitor.sh --pair XLE:SPY  # Specific pair
./correlation-monitor.sh --daemon 900 --push  # 15-min monitor + ClawTalk push
./correlation-monitor.sh --lookback 14  # 14-day window
```

## Dependencies
- bash 4+, curl, python3, sqlite3
- Yahoo Finance (free, no API key)

## Trading Relevance
- **SPY:TLT decorrelation** → bond market questioning equity narrative
- **XLE:SPY divergence** → energy decoupling from broad market (geopolitical)
- **GLD:TLT convergence** → flight-to-safety regime
- **QQQ:XLF rotation** → growth-to-value or vice versa
