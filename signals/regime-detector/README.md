# Market Regime Detector

Classifies current market environment using VIX levels and sector rotation patterns.

## Data Sources
- VIX (CBOE Volatility Index)
- Sector ETFs (XLK, XLY, XLU, XLP, XLF, XLE, XLV, XLI, XLB, XLRE, XLC)

## Regime Classification
- **risk-on:** VIX < 20, money flowing into growth/cyclical sectors
- **risk-off:** VIX > 25 or rising sharply, money flowing into defensives
- **neutral:** Mixed signals, no clear direction

## Update Frequency
- Real-time push on regime changes
- Heartbeat every 15 min during market hours (9:30-16:00 ET)

## Status
🟡 In development — @RealAaron
