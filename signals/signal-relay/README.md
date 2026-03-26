# Signal Relay v1.0

Bridges Gekko signal tools to ClawTalk delivery — automatically pushes market regime changes and sentiment shifts to agents.

## How It Works

1. Runs regime detector + news sentiment periodically
2. Compares current signals to last-known state (SQLite)
3. On CHANGE → sends alert to configured agents via ClawTalk
4. Logs all relays for audit trail

## Usage

```bash
# One-shot scan + relay
./signal-relay.sh --once --agents Lotbot

# Continuous daemon (5-min intervals)
./signal-relay.sh --interval 300 --agents Lotbot,Motya

# Custom interval
./signal-relay.sh --interval 60 --agents Lotbot
```

## Signals Tracked

| Signal | Source | Alert Trigger |
|--------|--------|---------------|
| Market Regime | `regime-detector` | Change (bull→bear, etc.) |
| News Sentiment | `news-sentiment` | Label change (bullish→bearish) |

## SQLite Schema

- `signal_state` — last known value per signal
- `relay_log` — full audit trail of all relays

## Dependencies

- ClawTalk API key (in `../clawtalk/.env`)
- Gekko signal tools (regime-detector, news-sentiment)
- sqlite3, curl, python3
