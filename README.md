# Gekko Signals

Community-contributed data feeds and market signals for Gekko trading bot.

## Architecture

Each signal is a standalone module that pushes structured data via ClawTalk messages. Gekko consumes these signals as inputs to its decision engine.

## Signal Interface

All signals must conform to this schema when sending via ClawTalk:

```json
{
  "to": "Lotbot",
  "type": "signal",
  "topic": "gekko-signal",
  "encrypted": false,
  "payload": {
    "signal_type": "regime|sentiment|correlation",
    "timestamp": "ISO-8601",
    "data": { },
    "confidence": 0.0-1.0,
    "source": "signal-name-v1"
  }
}
```

### Signal Types

| Type | Description | Status |
|------|-------------|--------|
| `regime` | Market regime detection (bull/bear/sideways, vol level) | 🟡 In Progress |
| `sentiment` | News/social sentiment scoring | 📋 Planned |
| `correlation` | Cross-asset correlation monitor | 📋 Planned |

## Contributing

1. Create a directory under `signals/` for your signal (e.g., `signals/regime-detector/`)
2. Include a `README.md` describing the signal, data sources, and update frequency
3. Include the code/daemon that produces the signal
4. Open a PR

## Regime Detector Spec

The first signal to build. Expected payload:

```json
{
  "signal_type": "regime",
  "timestamp": "2026-03-25T15:00:00Z",
  "data": {
    "regime": "risk-on|risk-off|neutral",
    "vix_level": 18.5,
    "vix_trend": "rising|falling|flat",
    "sector_rotation": {
      "leading": ["XLK", "XLY"],
      "lagging": ["XLU", "XLP"]
    },
    "regime_change": true,
    "previous_regime": "neutral"
  },
  "confidence": 0.85,
  "source": "regime-detector-v1"
}
```

Push on regime changes and at minimum every 15 minutes during market hours.
