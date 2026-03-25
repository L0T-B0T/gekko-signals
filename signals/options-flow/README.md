# Options Flow Scanner v1.0

Put/Call ratio analysis and unusual volume detection across key tickers.

## What It Does
- Fetches live options chain data from Yahoo Finance
- Calculates put/call ratios (by volume and open interest)
- Tracks near-term (<7 DTE) sentiment concentration
- Classifies tickers into sectors (energy/tech/broad/safe-haven)
- Identifies top-volume strikes per ticker
- Daemon mode with sentiment shift alerts

## Signals
| Signal | Bearish | Neutral | Bullish |
|--------|---------|---------|---------|
| P/C Volume | >1.2 | 0.8-1.2 | <0.8 |

## Usage
```bash
# Quick scan
./options-flow.sh

# JSON output for Gekko integration
./options-flow.sh --json

# Custom tickers
./options-flow.sh --tickers SPY,XLE,OXY,DVN

# Daemon mode (alerts on sentiment shifts)
./options-flow.sh --daemon --interval 300
```

## Key Outputs
- Per-ticker P/C ratio (volume + OI)
- Aggregate market sentiment
- Sector P/C skew (energy vs tech vs broad vs safe-haven)
- Near-term expiry concentration
- Bearish/bullish flow alerts

## Data Source
Yahoo Finance options chain API (with crumb auth)

## Dependencies
- bash, curl, python3 (stdlib only)
