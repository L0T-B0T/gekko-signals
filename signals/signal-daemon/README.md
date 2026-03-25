# Signal Daemon v1.0

Automated orchestrator that runs all 3 Gekko signal tools on schedule and pushes **change-only** alerts to Lotbot via ClawTalk.

## How It Works

1. **Every 5 min** (configurable): runs regime-detector, news-sentiment, correlation-monitor
2. **Compares** each output against previous state (SQLite-free, file-based)
3. **Pushes via ClawTalk** ONLY when:
   - Regime changes (e.g., risk-on → risk-off)
   - Sentiment shifts >0.15 (significant move)
   - New decorrelation events detected
4. **Heartbeat** every 15 min with current state summary

## Signal Types Pushed

| Signal | ClawTalk Topic | Trigger |
|--------|---------------|---------|
| 🔄 Regime change | `gekko-regime-alert` | Regime classification changes |
| 📊 Sentiment shift | `gekko-sentiment-alert` | Overall sentiment moves >0.15 |
| ⚡ Decorrelation | `gekko-correlation-alert` | Cross-asset pairs break expected correlation |
| 💓 Heartbeat | `gekko-heartbeat` | Every 3 cycles (~15 min) |

## Usage

```bash
# Run as daemon (background)
nohup bash signal-daemon.sh &

# Custom interval (10 min)
SIGNAL_INTERVAL=600 bash signal-daemon.sh

# Check state
cat .signal-state/regime.txt
cat .signal-state/sentiment.txt
```

## Dependencies

- `regime-detector.sh` (in `signals/regime-detector/`)
- `news-sentiment.sh` (in `signals/news-sentiment/`)
- `correlation-monitor.sh` (in `signals/correlation-monitor/`)
- ClawTalk API key in `/data/workspace/clawtalk/.env`

## Design Decisions

- **Change-only push**: Avoids noise — Lotbot only gets actionable alerts
- **File-based state**: No SQLite dependency, survives restarts
- **First-JSON parser**: Handles scripts that emit multiple JSON objects
- **Graceful degradation**: Each tool runs independently — if one fails, others continue
