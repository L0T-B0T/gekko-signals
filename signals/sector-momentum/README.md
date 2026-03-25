# Sector Momentum Scanner v1.0

Tracks relative strength of 11 GICS sectors vs SPY benchmark. Identifies rotational momentum — where money is flowing between sectors.

## Metrics

| Metric | Description |
|--------|-------------|
| Alpha | Sector return minus SPY return (outperformance) |
| Momentum Score | Weighted: 60% 5-day alpha + 40% full-period alpha |
| Rotation Signal | risk-on (cyclicals lead) / risk-off (defensives lead) / mixed |
| Breadth | % of sectors outperforming SPY |
| Dispersion | Spread between best and worst sector returns |
| Win Rate | % of positive daily returns |
| Acceleration | accelerating/decelerating/reversing trend |
| Risk-Adjusted | Momentum normalized by volatility |

## Sectors Tracked

| ETF | Sector | Type |
|-----|--------|------|
| XLE | Energy | Cyclical |
| XLF | Financials | Cyclical |
| XLI | Industrials | Cyclical |
| XLB | Materials | Cyclical |
| XLY | Consumer Disc | Cyclical |
| XLK | Technology | Cyclical |
| XLC | Communication | Cyclical |
| XLU | Utilities | Defensive |
| XLP | Consumer Staples | Defensive |
| XLV | Healthcare | Defensive |
| XLRE | Real Estate | Defensive |

## Usage

```bash
# Human-readable dashboard
./sector-momentum.sh

# JSON output
./sector-momentum.sh --json

# Push signal to Gekko via ClawTalk
./sector-momentum.sh --json --push

# Daemon mode (every 15 min)
./sector-momentum.sh --daemon 900 --push

# Custom lookback period
./sector-momentum.sh --lookback 10
```

## Signal Schema

```json
{
  "signal_type": "sector-momentum",
  "rotation": { "signal": "risk-on|risk-off|mixed", "confidence": 0.0-1.0 },
  "leaders": [{ "sector": "XLE", "alpha": 14.7, "momentum": 7.3 }],
  "laggards": [{ "sector": "XLRE", "alpha": -3.0, "momentum": -3.3 }],
  "sectors": [/* full ranked list */]
}
```

## Data Source

Yahoo Finance (free, no API key required). 20-day default lookback.

## Trading Applications

- **Pair trades**: Long leaders, short laggards
- **Rotation**: Follow momentum into leading sectors
- **Risk management**: Defensive rotation = reduce equity exposure
- **Breadth confirmation**: Low breadth + high dispersion = concentrated risk
