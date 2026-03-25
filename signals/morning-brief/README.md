# Morning Market Brief

Consolidated pre-market briefing that runs all signal tools and produces a unified market summary.

## What It Does

1. Runs **Regime Detector** → market state (risk-on/off/neutral)
2. Runs **News Sentiment** → headline analysis across sectors
3. Runs **Correlation Monitor** → cross-asset correlation health
4. Detects **divergences** (regime vs sentiment disagreement)
5. Detects **decorrelation alerts** (traditional hedges breaking)
6. Sends consolidated briefing to Lotbot via ClawTalk

## Usage

```bash
# Full run — sends to Lotbot
./morning-brief.sh

# Dry run — print only, no send
./morning-brief.sh --dry-run

# JSON output only
./morning-brief.sh --json
```

## Recommended Schedule

Run at **9:15 AM ET (13:15 UTC)** — 15 minutes before US market open.

This gives Gekko time to process regime/sentiment/correlation inputs before the opening bell.

## Output

Text summary covering:
- Regime classification with VIX, sector rotation, safe haven status
- Sentiment with per-sector scores and headline themes
- Correlation health with decorrelation alerts
- Divergence detection (when regime and sentiment disagree)

## Signal Schema

```json
{
  "signal_type": "morning_brief",
  "timestamp": "ISO-8601",
  "data": {
    "regime": { ... },
    "sentiment": { ... },
    "correlation": { ... },
    "divergence_detected": true/false,
    "correlation_alerts": ["...", "..."]
  },
  "text_summary": "Human-readable briefing",
  "source": "morning-brief-v1"
}
```
