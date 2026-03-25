# News Sentiment Scorer

Real-time news sentiment analysis for energy, tech, and macro markets.

## Signal Type: `sentiment`

Scans financial news headlines for market-moving keywords and phrases, assigns directional sentiment scores per sector, and pushes structured signals to Gekko via ClawTalk.

## Data Sources

- **Yahoo Finance RSS** — real-time market headlines (free, no API key)
- **Google News RSS** — sector-specific news feeds (free, no API key)
- **Keyword-based scoring** — rule-based NLP using financial lexicon

## Output Schema

```json
{
  "signal_type": "sentiment",
  "timestamp": "2026-03-25T20:00:00Z",
  "data": {
    "overall_sentiment": -0.35,
    "overall_label": "bearish",
    "sectors": {
      "energy": { "score": -0.72, "label": "very_bearish", "headlines": 8, "top_headline": "..." },
      "tech": { "score": 0.25, "label": "mildly_bullish", "headlines": 12, "top_headline": "..." },
      "macro": { "score": -0.15, "label": "neutral", "headlines": 6, "top_headline": "..." },
      "crypto": { "score": 0.10, "label": "neutral", "headlines": 4, "top_headline": "..." },
      "defense": { "score": 0.45, "label": "bullish", "headlines": 3, "top_headline": "..." }
    },
    "momentum": "deteriorating",
    "headline_count": 33,
    "signal_strength": "strong",
    "key_themes": ["iran-ceasefire", "oil-crash", "tech-rotation"]
  },
  "confidence": 0.78,
  "source": "news-sentiment-v1"
}
```

## Scoring Method

1. **Headline extraction** — RSS feeds parsed for fresh headlines (<6h old)
2. **Sector classification** — keywords map headlines to sectors (energy, tech, macro, crypto, defense)
3. **Sentiment scoring** — financial lexicon with bullish/bearish word lists, negation handling
4. **Momentum** — compare current score to 1h-ago score (improving/stable/deteriorating)
5. **Confidence** — based on headline volume (more headlines = higher confidence)

## Sentiment Scale

| Range | Label |
|-------|-------|
| +0.5 to +1.0 | very_bullish |
| +0.2 to +0.5 | bullish |
| +0.05 to +0.2 | mildly_bullish |
| -0.05 to +0.05 | neutral |
| -0.2 to -0.05 | mildly_bearish |
| -0.5 to -0.2 | bearish |
| -1.0 to -0.5 | very_bearish |

## Update Frequency

- Every **15 minutes** during US market hours (9:30 AM - 4 PM ET)
- Every **30 minutes** during extended hours (4 AM - 9:30 AM, 4 PM - 8 PM ET)
- Every **60 minutes** overnight
- **Immediate** push on sentiment shift >0.3 in any sector

## Dependencies

- `bash` + `curl` + `python3` (stdlib only, no pip packages)
- ClawTalk API key for signal delivery
- No paid APIs required

## Usage

```bash
# Single scan
./news-sentiment.sh

# Daemon mode (auto-pushes to Gekko)
./news-sentiment.sh --daemon

# JSON output only (no ClawTalk push)
./news-sentiment.sh --json

# Specific sector focus
./news-sentiment.sh --sector energy
```
