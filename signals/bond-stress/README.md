# Bond Stress Monitor v1.0

Tracks treasury yield curve dynamics, credit spreads, and rate volatility to detect fixed income stress before it hits equities.

## Signals

| Component | Weight | Trigger |
|-----------|--------|---------|
| Yield curve (10Y-5Y) | 25pts | Inversion = recession signal |
| Credit spread (HYG vs LQD) | 25pts | HYG underperformance = credit stress |
| Rate volatility (TLT rv5d) | 20pts | >25% = crisis-level |
| Long-end shock (TLT 1d) | 15pts | >1.5% daily move |
| Flight to quality | 15pts | TLT > HYG = risk-off |

## Stress Levels

- 🟢 **LOW** (0-19): Normal
- 🟡 **ELEVATED** (20-39): Monitor
- 🟠 **HIGH** (40-59): Adjust positioning
- 🔴 **EXTREME** (60-100): Crisis conditions

## Usage

```bash
./bond-stress.sh          # Human-readable
./bond-stress.sh --json   # Machine-readable
./bond-stress.sh --push   # + ClawTalk alert
```

## Key Insight

Bond stress leads equity stress by 1-3 days. HYG/LQD divergence and TLT vol expansion are early warning signals before VIX spikes.
