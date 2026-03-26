# Earnings Positioning Scanner v1.0

Pre-earnings positioning analysis combining technical + options signals.

## Usage
```bash
./earnings-positioning.sh "NVDA,LULU"    # specific tickers
./earnings-positioning.sh                 # defaults (NVDA,LULU)
```

## Signals
- **Technical**: SMA crossovers, volume buildup, momentum
- **Options**: P/C ratio, ATM straddle (expected move), IV skew
- **Overall**: Composite positioning score [-1, +1]

## Output
- Console: human-readable positioning summary
- JSON: `output/earnings-positioning.json`
