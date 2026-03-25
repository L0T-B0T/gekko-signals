#!/usr/bin/env bash
# News Sentiment Scorer v1.0 — Gekko Signal
# Scans financial news RSS for sentiment, pushes structured signals via ClawTalk
# Dependencies: bash, curl, python3 (stdlib only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAWTALK_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
CLAWTALK_API_KEY="${CLAWTALK_API_KEY:-}"
GEKKO_AGENT="${GEKKO_AGENT:-Lotbot}"
STATE_DIR="${STATE_DIR:-/tmp/news-sentiment-state}"
DAEMON_INTERVAL="${DAEMON_INTERVAL:-900}"  # 15 min default

# --- Argument parsing ---
MODE="single"
JSON_ONLY=false
SECTOR_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemon) MODE="daemon" ;;
        --json) JSON_ONLY=true ;;
        --sector) SECTOR_FILTER="$2"; shift ;;
        --help|-h) echo "Usage: $0 [--daemon] [--json] [--sector SECTOR]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

mkdir -p "$STATE_DIR"

# --- Financial Lexicon ---
# Bullish and bearish word lists for sentiment scoring
BULLISH_WORDS=(
    "surge" "surges" "surging" "rally" "rallies" "rallying" "soar" "soars" "soaring"
    "jump" "jumps" "jumping" "gain" "gains" "gaining" "rise" "rises" "rising"
    "boom" "booming" "bullish" "optimism" "optimistic" "recovery" "recover" "recovers"
    "upgrade" "upgrades" "outperform" "outperforms" "beat" "beats" "beating"
    "record" "high" "highs" "breakthrough" "breakout" "upside" "strong" "strength"
    "accelerate" "accelerates" "expand" "expands" "expansion" "growth" "growing"
    "profit" "profitable" "dividend" "buyback" "acquisition" "deal" "merger"
    "ceasefire" "peace" "agreement" "resolution" "de-escalation" "diplomatic"
    "innovation" "breakthrough" "approval" "approved" "positive" "confidence"
)

BEARISH_WORDS=(
    "crash" "crashes" "crashing" "plunge" "plunges" "plunging" "tumble" "tumbles"
    "drop" "drops" "dropping" "fall" "falls" "falling" "decline" "declines" "declining"
    "sink" "sinks" "sinking" "slump" "slumps" "sell" "selloff" "sell-off"
    "bearish" "pessimism" "pessimistic" "recession" "downturn" "contraction"
    "downgrade" "downgrades" "underperform" "miss" "misses" "missing"
    "low" "lows" "breakdown" "downside" "weak" "weakness" "slowdown"
    "loss" "losses" "deficit" "debt" "default" "bankruptcy" "layoff" "layoffs"
    "war" "conflict" "escalation" "sanctions" "tariff" "tariffs" "embargo"
    "attack" "missile" "strike" "blockade" "threat" "threatens" "crisis"
    "inflation" "overvalued" "bubble" "fraud" "investigation" "probe" "lawsuit"
    "volatility" "uncertainty" "fear" "panic" "collapse" "warning"
)

NEGATION_WORDS=("not" "no" "never" "neither" "nor" "barely" "hardly" "unlikely" "fail" "fails" "failed")

# --- Sector keyword mapping ---
ENERGY_KEYWORDS=("oil" "crude" "brent" "wti" "energy" "opec" "petroleum" "gas" "natural gas" "refinery" "pipeline" "exxon" "chevron" "shell" "bp" "devon" "eog" "oxy" "xlc" "xle" "iran" "hormuz" "saudi" "aramco")
TECH_KEYWORDS=("tech" "technology" "nvidia" "apple" "microsoft" "google" "amazon" "meta" "ai" "artificial intelligence" "semiconductor" "chip" "chips" "nasdaq" "qqq" "xlk" "software" "cloud" "data center")
MACRO_KEYWORDS=("fed" "federal reserve" "interest rate" "inflation" "gdp" "unemployment" "jobs" "payroll" "treasury" "bond" "yield" "dollar" "forex" "economic" "economy" "recession" "stimulus" "fiscal" "monetary" "s&p" "dow" "market")
CRYPTO_KEYWORDS=("bitcoin" "crypto" "ethereum" "btc" "eth" "blockchain" "defi" "stablecoin" "coinbase" "binance" "sec crypto" "digital asset" "nft" "web3")
DEFENSE_KEYWORDS=("defense" "military" "lockheed" "raytheon" "northrop" "boeing" "pentagon" "arms" "weapon" "missile" "drone" "nato" "deployment" "troops")

# --- RSS Feed URLs ---
FEEDS=(
    "https://feeds.finance.yahoo.com/rss/2.0/headline?s=^GSPC&region=US&lang=en-US"
    "https://feeds.finance.yahoo.com/rss/2.0/headline?s=CL=F&region=US&lang=en-US"
    "https://feeds.finance.yahoo.com/rss/2.0/headline?s=^VIX&region=US&lang=en-US"
    "https://news.google.com/rss/search?q=stock+market+today&hl=en-US&gl=US&ceid=US:en"
    "https://news.google.com/rss/search?q=oil+price+energy+market&hl=en-US&gl=US&ceid=US:en"
    "https://news.google.com/rss/search?q=federal+reserve+economy&hl=en-US&gl=US&ceid=US:en"
)

# --- Core Functions ---

fetch_headlines() {
    local output_file="$STATE_DIR/raw_headlines.txt"
    > "$output_file"
    
    for feed in "${FEEDS[@]}"; do
        curl -s --max-time 10 "$feed" 2>/dev/null | python3 -c "
import sys, re, html
from datetime import datetime, timezone, timedelta

content = sys.stdin.read()
# Extract titles and pubDates from RSS XML
items = re.findall(r'<item>.*?</item>', content, re.DOTALL)
cutoff = datetime.now(timezone.utc) - timedelta(hours=6)

for item in items:
    title_m = re.search(r'<title>(.*?)</title>', item, re.DOTALL)
    date_m = re.search(r'<pubDate>(.*?)</pubDate>', item, re.DOTALL)
    if title_m:
        title = html.unescape(re.sub(r'<!\[CDATA\[(.*?)\]\]>', r'\1', title_m.group(1))).strip()
        # Filter by date if available
        if date_m:
            try:
                from email.utils import parsedate_to_datetime
                pub_date = parsedate_to_datetime(date_m.group(1).strip())
                if pub_date.tzinfo is None:
                    pub_date = pub_date.replace(tzinfo=timezone.utc)
                if pub_date < cutoff:
                    continue
            except:
                pass
        if len(title) > 10:
            print(title)
" >> "$output_file" 2>/dev/null
        sleep 1  # Rate limit
    done
    
    # Deduplicate
    sort -u "$output_file" -o "$output_file"
    echo "$output_file"
}

analyze_sentiment() {
    local headlines_file="$1"
    
    python3 << 'PYEOF'
import json, sys, os, re
from datetime import datetime, timezone

headlines_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/news-sentiment-state/raw_headlines.txt"
state_dir = os.environ.get("STATE_DIR", "/tmp/news-sentiment-state")
sector_filter = os.environ.get("SECTOR_FILTER", "")

# Load headlines
with open(headlines_file, 'r') as f:
    headlines = [h.strip() for h in f.readlines() if h.strip()]

if not headlines:
    print(json.dumps({"error": "no_headlines", "headline_count": 0}))
    sys.exit(0)

# Word lists
bullish = set("""surge surges surging rally rallies rallying soar soars soaring
jump jumps jumping gain gains gaining rise rises rising boom booming bullish
optimism optimistic recovery recover recovers upgrade upgrades outperform
outperforms beat beats beating record high highs breakthrough breakout upside
strong strength accelerate accelerates expand expands expansion growth growing
profit profitable dividend buyback acquisition deal merger ceasefire peace
agreement resolution de-escalation diplomatic innovation approval approved
positive confidence""".split())

bearish = set("""crash crashes crashing plunge plunges plunging tumble tumbles
drop drops dropping fall falls falling decline declines declining sink sinks
sinking slump slumps sell selloff sell-off bearish pessimism pessimistic
recession downturn contraction downgrade downgrades underperform miss misses
missing low lows breakdown downside weak weakness slowdown loss losses deficit
debt default bankruptcy layoff layoffs war conflict escalation sanctions tariff
tariffs embargo attack missile strike blockade threat threatens crisis inflation
overvalued bubble fraud investigation probe lawsuit volatility uncertainty fear
panic collapse warning""".split())

negation = set("not no never neither nor barely hardly unlikely fail fails failed".split())

# Sector keywords
sectors_kw = {
    "energy": set("oil crude brent wti energy opec petroleum gas refinery pipeline exxon chevron shell bp devon eog oxy xle iran hormuz saudi aramco".split()),
    "tech": set("tech technology nvidia apple microsoft google amazon meta ai semiconductor chip chips nasdaq qqq xlk software cloud".split()),
    "macro": set("fed reserve interest inflation gdp unemployment jobs payroll treasury bond yield dollar forex economic economy recession stimulus fiscal monetary".split()),
    "crypto": set("bitcoin crypto ethereum btc eth blockchain defi stablecoin coinbase binance digital nft web3".split()),
    "defense": set("defense military lockheed raytheon northrop boeing pentagon arms weapon missile drone nato deployment troops".split()),
}

def score_headline(headline):
    """Score a single headline. Returns -1.0 to +1.0"""
    words = re.findall(r'\b[a-z]+\b', headline.lower())
    bull_count = 0
    bear_count = 0
    negate = False
    
    for i, w in enumerate(words):
        if w in negation:
            negate = True
            continue
        if w in bullish:
            if negate:
                bear_count += 1
                negate = False
            else:
                bull_count += 1
        elif w in bearish:
            if negate:
                bull_count += 1
                negate = False
            else:
                bear_count += 1
        else:
            negate = False
    
    total = bull_count + bear_count
    if total == 0:
        return 0.0
    return (bull_count - bear_count) / total

def classify_sector(headline):
    """Classify headline into sectors (can be multi-sector)"""
    hl_lower = headline.lower()
    matched = []
    for sector, kws in sectors_kw.items():
        for kw in kws:
            if kw in hl_lower:
                matched.append(sector)
                break
    if not matched:
        matched.append("macro")  # default to macro
    return matched

def label_score(score):
    if score >= 0.5: return "very_bullish"
    if score >= 0.2: return "bullish"
    if score >= 0.05: return "mildly_bullish"
    if score > -0.05: return "neutral"
    if score > -0.2: return "mildly_bearish"
    if score > -0.5: return "bearish"
    return "very_bearish"

# Analyze each headline
sector_scores = {s: {"scores": [], "headlines": [], "best": ("", 0)} for s in sectors_kw}

for hl in headlines:
    score = score_headline(hl)
    sectors = classify_sector(hl)
    
    for sector in sectors:
        if sector_filter and sector != sector_filter:
            continue
        sector_scores[sector]["scores"].append(score)
        sector_scores[sector]["headlines"].append(hl)
        if abs(score) > abs(sector_scores[sector]["best"][1]):
            sector_scores[sector]["best"] = (hl, score)

# Compute sector averages
sector_data = {}
all_scores = []
themes = set()

for sector, data in sector_scores.items():
    scores = data["scores"]
    if not scores:
        continue
    avg = sum(scores) / len(scores)
    all_scores.extend(scores)
    sector_data[sector] = {
        "score": round(avg, 3),
        "label": label_score(avg),
        "headlines": len(scores),
        "top_headline": data["best"][0][:120] if data["best"][0] else ""
    }
    
    # Extract themes
    for hl in data["headlines"][:5]:
        hl_lower = hl.lower()
        if any(w in hl_lower for w in ["iran", "ceasefire", "hormuz"]): themes.add("iran-conflict")
        if any(w in hl_lower for w in ["oil", "crude", "brent", "wti"]): themes.add("oil-volatility")
        if any(w in hl_lower for w in ["tech", "rotation", "nasdaq"]): themes.add("tech-rotation")
        if any(w in hl_lower for w in ["fed", "rate", "inflation"]): themes.add("fed-policy")
        if any(w in hl_lower for w in ["ai", "artificial"]): themes.add("ai-momentum")
        if any(w in hl_lower for w in ["tariff", "trade war"]): themes.add("trade-war")

# Overall
overall = sum(all_scores) / len(all_scores) if all_scores else 0.0

# Momentum — compare to previous scan
prev_file = os.path.join(state_dir, "prev_sentiment.json")
momentum = "stable"
if os.path.exists(prev_file):
    try:
        with open(prev_file) as f:
            prev = json.load(f)
        prev_overall = prev.get("overall_sentiment", 0)
        diff = overall - prev_overall
        if diff > 0.1: momentum = "improving"
        elif diff < -0.1: momentum = "deteriorating"
    except: pass

# Confidence based on headline volume
confidence = min(0.95, 0.3 + (len(headlines) * 0.015))

# Signal strength
if abs(overall) > 0.4 and len(headlines) > 20:
    signal_strength = "strong"
elif abs(overall) > 0.2 and len(headlines) > 10:
    signal_strength = "moderate"
else:
    signal_strength = "weak"

result = {
    "signal_type": "sentiment",
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "data": {
        "overall_sentiment": round(overall, 3),
        "overall_label": label_score(overall),
        "sectors": sector_data,
        "momentum": momentum,
        "headline_count": len(headlines),
        "signal_strength": signal_strength,
        "key_themes": sorted(list(themes))[:5]
    },
    "confidence": round(confidence, 2),
    "source": "news-sentiment-v1"
}

# Save current as previous for momentum tracking
with open(prev_file, 'w') as f:
    json.dump({"overall_sentiment": overall, "timestamp": result["timestamp"]}, f)

# Save full result
out_file = os.path.join(state_dir, "latest_sentiment.json")
with open(out_file, 'w') as f:
    json.dump(result, f, indent=2)

print(json.dumps(result, indent=2))
PYEOF
}

push_to_clawtalk() {
    local signal_json="$1"
    
    if [[ -z "$CLAWTALK_API_KEY" ]]; then
        echo "WARNING: No CLAWTALK_API_KEY set, skipping push"
        return 1
    fi
    
    local payload
    payload=$(python3 -c "
import json, sys
signal = json.loads(sys.stdin.read())
msg = {
    'to': '$GEKKO_AGENT',
    'type': 'notification',
    'topic': 'gekko-signal',
    'encrypted': False,
    'payload': signal
}
print(json.dumps(msg))
" <<< "$signal_json")
    
    local tmpfile
    tmpfile=$(mktemp)
    echo "$payload" > "$tmpfile"
    
    local resp
    resp=$(curl -s -w "\n%{http_code}" -X POST "$CLAWTALK_URL/messages" \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$tmpfile" 2>/dev/null)
    
    rm -f "$tmpfile"
    
    local http_code
    http_code=$(echo "$resp" | tail -1)
    
    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        echo "PUSH_OK: Signal delivered to $GEKKO_AGENT"
        return 0
    else
        echo "PUSH_FAIL: HTTP $http_code"
        return 1
    fi
}

display_human() {
    local signal_json="$1"
    
    python3 -c "
import json, sys
s = json.loads(sys.stdin.read())
d = s['data']
print(f'=== NEWS SENTIMENT SCANNER v1.0 ===')
print(f'Time: {s[\"timestamp\"]}')
print(f'Headlines analyzed: {d[\"headline_count\"]}')
print(f'Confidence: {s[\"confidence\"]:.0%}')
print(f'Signal strength: {d[\"signal_strength\"]}')
print()
print(f'OVERALL: {d[\"overall_sentiment\"]:+.3f} ({d[\"overall_label\"]})')
print(f'Momentum: {d[\"momentum\"]}')
print()
print('--- SECTOR BREAKDOWN ---')
for sector, info in sorted(d['sectors'].items(), key=lambda x: abs(x[1]['score']), reverse=True):
    bar_len = int(abs(info['score']) * 20)
    bar = ('▓' if info['score'] >= 0 else '░') * bar_len
    print(f'  {sector:>8}: {info[\"score\"]:+.3f} [{info[\"label\"]:>14}] {bar} ({info[\"headlines\"]} headlines)')
    if info.get('top_headline'):
        print(f'           └─ {info[\"top_headline\"][:100]}')
print()
if d.get('key_themes'):
    print(f'Key themes: {\" | \".join(d[\"key_themes\"])}')
print()
" <<< "$signal_json"
}

run_scan() {
    echo "Fetching headlines from RSS feeds..."
    local headlines_file
    headlines_file=$(fetch_headlines)
    
    local count
    count=$(wc -l < "$headlines_file")
    echo "Found $count unique headlines"
    
    if [[ "$count" -eq 0 ]]; then
        echo "No headlines found. Check feed connectivity."
        return 1
    fi
    
    echo "Analyzing sentiment..."
    local result
    result=$(SECTOR_FILTER="$SECTOR_FILTER" analyze_sentiment "$headlines_file")
    
    if [[ "$JSON_ONLY" == "true" ]]; then
        echo "$result"
        return 0
    fi
    
    display_human "$result"
    
    if [[ -n "$CLAWTALK_API_KEY" ]] && [[ "$JSON_ONLY" != "true" ]]; then
        # Check for significant sentiment shift before pushing
        local should_push=false
        local overall
        overall=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['overall_sentiment'])")
        
        if [[ -f "$STATE_DIR/last_push.json" ]]; then
            local last_overall
            last_overall=$(python3 -c "import json; print(json.load(open('$STATE_DIR/last_push.json'))['overall_sentiment'])" 2>/dev/null || echo "0")
            local diff
            diff=$(python3 -c "print(abs($overall - $last_overall))")
            if python3 -c "exit(0 if $diff > 0.15 else 1)"; then
                should_push=true
                echo "Sentiment shift detected (Δ${diff}), pushing signal..."
            fi
        else
            should_push=true
            echo "First scan, pushing signal..."
        fi
        
        if [[ "$should_push" == "true" ]] || [[ "$MODE" == "single" ]]; then
            push_to_clawtalk "$result"
            echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
with open('$STATE_DIR/last_push.json', 'w') as f:
    json.dump({'overall_sentiment': d['data']['overall_sentiment'], 'timestamp': d['timestamp']}, f)
"
        else
            echo "No significant shift, skipping push (use --force to override)"
        fi
    fi
}

# --- Main ---
if [[ "$MODE" == "daemon" ]]; then
    echo "Starting news sentiment daemon (interval: ${DAEMON_INTERVAL}s)..."
    while true; do
        echo "--- Scan $(date -u +%Y-%m-%dT%H:%M:%SZ) ---"
        run_scan || echo "Scan failed, retrying next cycle"
        sleep "$DAEMON_INTERVAL"
    done
else
    run_scan
fi
