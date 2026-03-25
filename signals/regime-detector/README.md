# Market Regime Detector v1.0

Classifies current market environment using VIX levels, sector rotation patterns, and safe-haven flows. Pushes structured signals to Gekko via ClawTalk.

## Signal Output

Conforms to the [gekko-signals spec](../../README.md):

```json
{
  "signal_type": "regime",
  "timestamp": "2026-03-25T19:20:00Z",
  "data": {
    "regime": "risk-off",
    "vix_level": 25.19,
    "vix_trend": "rising",
    "vix_5d_change": 12.3,
    "sector_rotation": {
      "leading": ["XLE", "XLU", "XLP"],
      "lagging": ["XLK", "XLY", "XLC"]
    },
    "regime_change": true,
    "previous_regime": "neutral",
    "growth_defensive_spread": -3.42,
    "safe_haven_bid": true,
    "spy_5d": -2.1,
    "tlt_5d": 3.4,
    "gld_5d": 4.1
  },
  "confidence": 0.86,
  "source": "regime-detector-v1"
}
```

## Regime Classification

| Regime | VIX Range | Sector Signal | Confidence |
|--------|-----------|---------------|------------|
| **risk-on** | < 20 | Growth > Defensive | 0.65–0.95 |
| **risk-off** | > 25 | Defensive > Growth | 0.75–0.95 |
| **neutral** | 20–25 | Mixed signals | 0.40–0.65 |

### Confidence Boosters
- VIX extreme (< 15 or > 30): +0.10–0.15
- Sector rotation confirms regime: +0.10
- Safe-haven bid (TLT/GLD rising) confirms risk-off: +0.05
- Contradictory signals: -0.10–0.15

## Data Sources

| Instrument | Symbol | Purpose |
|-----------|--------|---------|
| VIX | ^VIX | Primary regime indicator |
| SPY | SPY | Broad market direction |
| QQQ | QQQ | Tech/growth sentiment |
| Sector ETFs | XLE, XLK, XLY, XLU, XLP, XLF, XLV, XLI, XLB, XLRE, XLC | Rotation analysis |
| TLT | TLT | Bond market (flight to safety) |
| GLD | GLD | Gold (safe haven demand) |

All data via Yahoo Finance API (free, no key required).

## Usage

### Single Run
```bash
# Detect current regime and send to Gekko
./regime-detector.sh

# Output JSON only (don't send)
./regime-detector.sh --json

# Detect but don't send
./regime-detector.sh --dry-run
```

### Daemon Mode
```bash
# Run continuously — push on regime changes + every 15 min
./regime-detector.sh --daemon

# Background daemon
nohup ./regime-detector.sh --daemon >> /tmp/regime-detector.log 2>&1 &
```

### Daemon Behavior
- Checks market every 60 seconds
- Pushes immediately on regime changes
- Heartbeat signal every 15 minutes (configurable via `POLL_INTERVAL_SECS`)
- State persisted in `/tmp/regime-detector-state.json`
- Auto-retries on detection failure (60s backoff)

## Environment

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLAWTALK_ENV` | No | `/data/workspace/clawtalk/.env` | Path to ClawTalk credentials |
| `STATE_FILE` | No | `/tmp/regime-detector-state.json` | Regime state persistence |

## Dependencies

- `bash` 4+
- `python3` (stdlib only — `json`, `urllib`)
- `curl`
- ClawTalk API key (in `.env` file)

## Author

**RealAaron** — built as first Gekko signal feed contribution.

## Changelog

- **v1.0** (2026-03-25): Initial release. VIX + 11-sector rotation + bond/gold safe-haven analysis.
