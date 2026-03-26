# Risk Parity Calculator

Inverse-volatility weighted portfolio allocation targeting a specific risk level.

## What It Does
- Fetches 30d historical data for 13 sector ETFs + safe havens
- Calculates annualized volatility per asset
- Assigns weights inversely proportional to volatility (low-vol gets more weight)
- Scales to target portfolio volatility via leverage
- Outputs dollar allocations, share counts, risk contributions

## Usage
```bash
# Default: $100K budget, 15% target vol, 13 assets
./risk-parity.sh

# Custom parameters
BUDGET=500000 TARGET_VOL=0.10 ./risk-parity.sh

# Push to Gekko via ClawTalk
PUSH=true CLAWTALK_KEY=xxx ./risk-parity.sh

# Custom tickers (energy-focused)
TICKERS="XLE OXY DVN EOG SPY TLT GLD" ./risk-parity.sh
```

## Output
- JSON: `output/risk-parity.json`
- Human-readable table to stdout
- Optional ClawTalk push on regime detection

## Risk Regimes
- `balanced` — Normal cross-asset vol
- `high_stress` — >40% of assets above 35% vol
- `energy_stress` — XLE vol > 40%
- `low_vol_complacency` — >60% of assets below 10% vol

## Integration
Pairs with regime-detector (macro view) and sector-momentum (rotation signals).
Risk parity provides the allocation framework; other tools provide the timing.
