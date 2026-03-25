#!/usr/bin/env bash
# Options Flow Scanner v1.0 — Put/Call Ratios & Unusual Volume for Gekko
# Uses Yahoo Finance options chain data (with crumb auth)
set -euo pipefail

VERSION="1.0"
TICKERS=("SPY" "QQQ" "XLE" "TLT" "GLD" "OXY" "DVN" "EOG" "NVDA" "COIN")
OUTPUT_FORMAT="text"
DAEMON_MODE=false
DAEMON_INTERVAL=300
COOKIE_FILE="/tmp/yf_options_cookies"

usage() {
    cat <<EOF
Options Flow Scanner v1.0 — Put/Call Ratios & Volume Analysis

Usage: $(basename "$0") [OPTIONS]

Options:
  --tickers T1,T2   Override default tickers (comma-separated)
  --json            Output JSON format
  --daemon          Run continuously, alert on shifts
  --interval SECS   Daemon interval (default: 300)
  --help            Show this help

Signals:
  • Per-ticker put/call ratio (vol + OI)
  • Aggregate market P/C ratio
  • Sector P/C skew (energy/tech/broad/safe-haven)
  • Near-term (<7 DTE) sentiment concentration
  • Top volume strikes per ticker

Default tickers: ${TICKERS[*]}
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tickers) IFS=',' read -ra TICKERS <<< "$2"; shift 2 ;;
        --json) OUTPUT_FORMAT="json"; shift ;;
        --daemon) DAEMON_MODE=true; shift ;;
        --interval) DAEMON_INTERVAL="$2"; shift 2 ;;
        --help) usage ;;
        *) shift ;;
    esac
done

# Get Yahoo Finance crumb + cookies
get_crumb() {
    curl -s -c "$COOKIE_FILE" "https://fc.yahoo.com" -H "User-Agent: Mozilla/5.0" >/dev/null 2>&1
    curl -s -b "$COOKIE_FILE" "https://query2.finance.yahoo.com/v1/test/getcrumb" \
        -H "User-Agent: Mozilla/5.0" 2>/dev/null
}

# Fetch options chain for ticker
fetch_options() {
    local ticker="$1" crumb="$2"
    curl -s -m 15 -b "$COOKIE_FILE" \
        "https://query2.finance.yahoo.com/v7/finance/options/${ticker}?crumb=${crumb}" \
        -H "User-Agent: Mozilla/5.0" 2>/dev/null
}

run_scan() {
    local crumb
    crumb=$(get_crumb)
    if [[ -z "$crumb" ]] || [[ "$crumb" == "null" ]]; then
        echo '{"error":"Failed to get Yahoo Finance crumb"}'; return 1
    fi

    python3 -c "
import json, sys, time, subprocess, datetime

tickers = '${TICKERS[*]}'.split()
crumb = '''${crumb}'''
cookie_file = '${COOKIE_FILE}'
results = []
total_cv = 0
total_pv = 0
sector_data = {'energy': [], 'tech': [], 'broad': [], 'safe_haven': []}
sector_map = {
    'XLE': 'energy', 'OXY': 'energy', 'DVN': 'energy', 'EOG': 'energy',
    'QQQ': 'tech', 'NVDA': 'tech', 'AAPL': 'tech',
    'SPY': 'broad', 'COIN': 'broad',
    'TLT': 'safe_haven', 'GLD': 'safe_haven', 'VIX': 'safe_haven'
}

for ticker in tickers:
    try:
        import urllib.request, http.cookiejar
        cj = http.cookiejar.MozillaCookieJar(cookie_file)
        cj.load(ignore_discard=True, ignore_expires=True)
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
        req = urllib.request.Request(
            f'https://query2.finance.yahoo.com/v7/finance/options/{ticker}?crumb={crumb}',
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        resp = opener.open(req, timeout=15)
        data = json.loads(resp.read())
        
        chain = data.get('optionChain', {}).get('result', [])
        if not chain:
            continue
        
        c = chain[0]
        quote = c.get('quote', {})
        opts = c.get('options', [{}])[0]
        calls = opts.get('calls', [])
        puts = opts.get('puts', [])
        
        cv = sum(x.get('volume', 0) or 0 for x in calls)
        pv = sum(x.get('volume', 0) or 0 for x in puts)
        coi = sum(x.get('openInterest', 0) or 0 for x in calls)
        poi = sum(x.get('openInterest', 0) or 0 for x in puts)
        
        pc_vol = round(pv / cv, 3) if cv > 0 else 0
        pc_oi = round(poi / coi, 3) if coi > 0 else 0
        
        # Near-term (<7 DTE)
        now = time.time()
        near_cv = sum(x.get('volume', 0) or 0 for x in calls if (x.get('expiration', 0) - now) < 7*86400)
        near_pv = sum(x.get('volume', 0) or 0 for x in puts if (x.get('expiration', 0) - now) < 7*86400)
        near_pc = round(near_pv / near_cv, 3) if near_cv > 0 else 0
        
        # Top strikes
        all_opts = [(x.get('strike',0), x.get('volume',0) or 0, 'call') for x in calls] + \
                   [(x.get('strike',0), x.get('volume',0) or 0, 'put') for x in puts]
        all_opts.sort(key=lambda x: x[1], reverse=True)
        top = [{'strike': s, 'volume': v, 'type': t} for s,v,t in all_opts[:3]]
        
        price = round(quote.get('regularMarketPrice', 0), 2)
        sent = 'bearish' if pc_vol > 1.2 else 'bullish' if pc_vol < 0.8 else 'neutral'
        
        entry = {
            'ticker': ticker, 'price': price,
            'call_vol': cv, 'put_vol': pv, 'pc_vol': pc_vol,
            'call_oi': coi, 'put_oi': poi, 'pc_oi': pc_oi,
            'near_pc': near_pc, 'sentiment': sent, 'top_strikes': top
        }
        results.append(entry)
        total_cv += cv
        total_pv += pv
        
        sec = sector_map.get(ticker, 'broad')
        sector_data[sec].append(pc_vol)
        
        time.sleep(0.5)
    except Exception as e:
        continue

agg_pc = round(total_pv / total_cv, 3) if total_cv > 0 else 0
mkt_sent = 'bearish' if agg_pc > 1.2 else 'bullish' if agg_pc < 0.8 else 'neutral'

sector_avg = {}
for sec, vals in sector_data.items():
    sector_avg[sec] = round(sum(vals)/len(vals), 3) if vals else 0

output_format = '${OUTPUT_FORMAT}'
if output_format == 'json':
    signal = {
        'signal': 'options-flow', 'version': '${VERSION}',
        'timestamp': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
        'summary': {
            'market_sentiment': mkt_sent,
            'aggregate_pc': agg_pc,
            'total_call_vol': total_cv,
            'total_put_vol': total_pv,
            'sector_pc': sector_avg,
            'tickers_scanned': len(results)
        },
        'tickers': results
    }
    print(json.dumps(signal, indent=2))
else:
    print('═' * 50)
    print('  OPTIONS FLOW SCANNER v${VERSION}')
    print(f'  {datetime.datetime.utcnow().strftime(\"%Y-%m-%d %H:%M UTC\")}')
    print('═' * 50)
    print()
    print(f'MARKET SENTIMENT: {mkt_sent.upper()}')
    print(f'Aggregate P/C: {agg_pc}  ({total_cv:,} calls / {total_pv:,} puts)')
    print()
    print('SECTOR P/C RATIOS:')
    for sec in ['energy', 'tech', 'broad', 'safe_haven']:
        label = sec.replace('_', ' ').title()
        print(f'  {label:12s}: {sector_avg.get(sec, 0):.3f}')
    print()
    print('PER-TICKER:')
    print(f'{\"Ticker\":>8s} {\"Price\":>10s} {\"P/C Vol\":>8s} {\"P/C OI\":>8s} {\"Near PC\":>8s} {\"Sent\":>10s}')
    print('-' * 58)
    for r in results:
        print(f'{r[\"ticker\"]:>8s} {r[\"price\"]:>10.2f} {r[\"pc_vol\"]:>8.3f} {r[\"pc_oi\"]:>8.3f} {r[\"near_pc\"]:>8.3f} {r[\"sentiment\"]:>10s}')
    print()
    # Flag unusual
    bearish_tickers = [r['ticker'] for r in results if r['sentiment'] == 'bearish']
    bullish_tickers = [r['ticker'] for r in results if r['sentiment'] == 'bullish']
    if bearish_tickers:
        print(f'⚠️  BEARISH FLOW: {\", \".join(bearish_tickers)}')
    if bullish_tickers:
        print(f'🟢 BULLISH FLOW: {\", \".join(bullish_tickers)}')
    print('═' * 50)
"
}

if $DAEMON_MODE; then
    echo "Options Flow daemon started (interval: ${DAEMON_INTERVAL}s)"
    PREV_SENT=""
    while true; do
        CURRENT=$(run_scan 2>/dev/null)
        echo "$CURRENT"
        NEW_SENT=$(echo "$CURRENT" | python3 -c "
import sys,json
try:
    for line in sys.stdin:
        if 'MARKET SENTIMENT' in line:
            print(line.split(':')[1].strip())
            break
except: pass
" 2>/dev/null)
        if [[ -n "$PREV_SENT" ]] && [[ "$NEW_SENT" != "$PREV_SENT" ]]; then
            echo "🚨 SENTIMENT SHIFT: $PREV_SENT → $NEW_SENT"
        fi
        PREV_SENT="$NEW_SENT"
        sleep "$DAEMON_INTERVAL"
    done
else
    run_scan
fi
