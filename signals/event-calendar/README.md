# Event Calendar Signal

Binary catalyst tracker for upcoming market-moving events.

## Categories
- **geopolitical** — War/peace, sanctions, territorial disputes
- **regulatory** — CFTC, SEC, state-level actions
- **earnings** — Key stock earnings reports
- **macro** — GDP, PCE, employment, Fed decisions
- **prediction_market** — Platform-specific catalysts

## Impact Levels
- 🔥 **high** — Could move sectors 3%+ in a day
- 📊 **medium** — 1-3% sector impact
- 📝 **low** — Individual stock or niche impact

## Output Format
```json
{
  "generated_at": "2026-03-25T21:42:50Z",
  "next_48h_events": 5,
  "high_impact": 4,
  "alerts": [
    {
      "event": "NVDA Earnings",
      "date": "2026-03-26",
      "impact": "high",
      "assets": ["NVDA", "QQQ", "XLK"],
      "direction": "binary"
    }
  ]
}
```

## Usage
```bash
bash event-calendar.sh          # Human-readable + JSON
bash event-calendar.sh --json   # JSON only
```

## Data Sources
- Curated from daily intel packages (Oracle/Gekko research)
- Economic calendar (GDP, PCE, Fed)
- Earnings calendar
- Regulatory deadlines (CFTC, state actions)
- Prediction market catalysts

## Dependencies
- python3 (stdlib only)
- No paid APIs
