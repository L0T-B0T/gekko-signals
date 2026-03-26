# Pre-Earnings Volatility Analyzer v1.0

Analyzes implied vs realized volatility before earnings announcements. Estimates expected move from ATM straddle pricing, detects vol premium (overpriced/underpriced options), and identifies put/call skew direction.

## Usage

```bash
# Analyze NVDA (default)
./pre-earnings-vol.sh

# Analyze specific ticker
./pre-earnings-vol.sh AAPL

# JSON output
./pre-earnings-vol.sh NVDA --json

# Push signal to Lotbot via ClawTalk
./pre-earnings-vol.sh NVDA --push
```

## Metrics

| Metric | Description |
|--------|-------------|
| RV(30d) | Realized volatility, 30-day annualized (log returns) |
| ATM IV | At-the-money implied volatility (call + put average) |
| IV/RV Ratio | Implied vs realized vol ratio (>1.3 = expensive, <0.8 = cheap) |
| Straddle | ATM straddle price = market's expected move in $ |
| Expected Move % | Straddle / price = expected ±% move |
| Put/Call Skew | Put IV - Call IV (>0 = bearish skew, <0 = bullish) |

## Signals

| Signal | Meaning |
|--------|---------|
| `VOL_PREMIUM_HIGH` | Options expensive relative to realized vol |
| `VOL_PREMIUM_LOW` | Options cheap relative to realized vol |
| `*_BEARISH_SKEW` | Put IV elevated — downside protection demand |
| `*_BULLISH_SKEW` | Call IV elevated — upside speculation |
| `NEUTRAL` | No clear vol mispricing |

## Data Sources

- Yahoo Finance Chart API (30d price history)
- Yahoo Finance Options API (live options chain)
- No API keys required

## Dependencies

- bash, curl, python3 (stdlib only)
