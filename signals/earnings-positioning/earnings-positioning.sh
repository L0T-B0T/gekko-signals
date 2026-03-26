#!/usr/bin/env bash
# Gekko Signal: Pre-Earnings Positioning Scanner v1.0
# Analyzes options/technical positioning ahead of major earnings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
TMP_DIR=$(mktemp -d)
mkdir -p "$OUTPUT_DIR"
trap "rm -rf $TMP_DIR" EXIT

EARNINGS_TICKERS="${1:-NVDA,LULU}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "=== Pre-Earnings Positioning Scanner v1.0 ==="
log "Tickers: ${EARNINGS_TICKERS}"

IFS=',' read -ra TICKERS <<< "$EARNINGS_TICKERS"

for ticker in "${TICKERS[@]}"; do
    log "Analyzing ${ticker}..."
    
    # Fetch price data
    curl -sf -A "Mozilla/5.0" \
        "https://query1.finance.yahoo.com/v8/finance/chart/${ticker}?interval=1d&range=30d" \
        > "$TMP_DIR/${ticker}_price.json" 2>/dev/null || echo '{}' > "$TMP_DIR/${ticker}_price.json"
    
    # Fetch options
    curl -sf -A "Mozilla/5.0" \
        "https://query1.finance.yahoo.com/v7/finance/options/${ticker}" \
        > "$TMP_DIR/${ticker}_options.json" 2>/dev/null || echo '{}' > "$TMP_DIR/${ticker}_options.json"
    
    sleep 1
done

# Analyze everything in Python using temp files
python3 << 'PYEOF'
import json, math, os, sys
from datetime import datetime, timezone

tmp_dir = os.environ.get('TMP_DIR', '/tmp')
tickers_str = os.environ.get('TICKERS_STR', 'NVDA')
output_dir = os.environ.get('OUTPUT_DIR', '.')
tickers = tickers_str.split(',')

SECTOR_MAP = {
    "NVDA": "XLK", "LULU": "XLY", "AAPL": "XLK", "MSFT": "XLK",
    "AMZN": "XLY", "GOOGL": "XLC", "META": "XLC", "TSLA": "XLY"
}

all_results = []

for ticker in tickers:
    result = {"ticker": ticker, "timestamp": datetime.now(timezone.utc).isoformat()}
    
    # === PRICE ANALYSIS ===
    try:
        with open(f"{tmp_dir}/{ticker}_price.json") as f:
            pdata = json.load(f)
        chart = pdata['chart']['result'][0]
        closes = [c for c in chart['indicators']['quote'][0]['close'] if c is not None]
        volumes = [v for v in chart['indicators']['quote'][0]['volume'] if v is not None]
    except:
        result["error"] = "price_fetch_fail"
        all_results.append(result)
        continue
    
    if len(closes) < 5:
        result["error"] = "insufficient_data"
        all_results.append(result)
        continue
    
    current = closes[-1]
    sma5 = sum(closes[-5:]) / 5
    sma20 = sum(closes[-20:]) / min(20, len(closes))
    pct_5d = ((closes[-1] / closes[-6]) - 1) * 100 if len(closes) >= 6 else 0
    pct_20d = ((closes[-1] / closes[-21]) - 1) * 100 if len(closes) >= 21 else 0
    
    # Realized vol
    if len(closes) >= 21:
        rets = [math.log(closes[i]/closes[i-1]) for i in range(len(closes)-20, len(closes)) if closes[i-1] > 0]
        rv20 = (sum(r**2 for r in rets) / len(rets)) ** 0.5 * (252**0.5) * 100 if rets else 0
    else:
        rv20 = 0
    
    avg_vol_10 = sum(volumes[-10:]) / min(10, len(volumes)) if volumes else 0
    latest_vol = volumes[-1] if volumes else 0
    vol_ratio = latest_vol / avg_vol_10 if avg_vol_10 > 0 else 1
    
    # Technical signals
    tech_signals = []
    if current > sma20: tech_signals.append("above_20sma")
    else: tech_signals.append("below_20sma")
    if current > sma5: tech_signals.append("above_5sma")
    else: tech_signals.append("below_5sma")
    if sma5 > sma20: tech_signals.append("bullish_cross")
    else: tech_signals.append("bearish_cross")
    if vol_ratio > 1.5: tech_signals.append("high_volume")
    elif vol_ratio < 0.7: tech_signals.append("low_volume")
    
    bull = sum(1 for s in tech_signals if s in ['above_20sma','above_5sma','bullish_cross','high_volume'])
    bear = sum(1 for s in tech_signals if s in ['below_20sma','below_5sma','bearish_cross'])
    tech_bias = "bullish" if bull > bear else "bearish" if bear > bull else "neutral"
    
    result.update({
        "price": round(current, 2),
        "sma5": round(sma5, 2),
        "sma20": round(sma20, 2),
        "pct_5d": round(pct_5d, 2),
        "pct_20d": round(pct_20d, 2),
        "realized_vol_20d": round(rv20, 1),
        "volume_ratio": round(vol_ratio, 2),
        "technical_signals": tech_signals,
        "technical_bias": tech_bias,
        "sector_etf": SECTOR_MAP.get(ticker, "SPY")
    })
    
    # === OPTIONS ANALYSIS ===
    try:
        with open(f"{tmp_dir}/{ticker}_options.json") as f:
            odata = json.load(f)
        chain = odata['optionChain']['result'][0]
        quote = chain.get('quote', {})
        opts = chain.get('options', [{}])[0]
        calls = opts.get('calls', [])
        puts = opts.get('puts', [])
        
        cp = quote.get('regularMarketPrice', current)
        
        total_call_vol = sum(c.get('volume', 0) or 0 for c in calls)
        total_put_vol = sum(p.get('volume', 0) or 0 for p in puts)
        pc_vol = total_put_vol / total_call_vol if total_call_vol > 0 else 999
        
        total_call_oi = sum(c.get('openInterest', 0) or 0 for c in calls)
        total_put_oi = sum(p.get('openInterest', 0) or 0 for p in puts)
        pc_oi = total_put_oi / total_call_oi if total_call_oi > 0 else 999
        
        # ATM straddle
        atm_call = min(calls, key=lambda c: abs(c.get('strike',0) - cp)) if calls else None
        atm_put = min(puts, key=lambda p: abs(p.get('strike',0) - cp)) if puts else None
        
        if atm_call and atm_put:
            straddle = (atm_call.get('lastPrice',0) or 0) + (atm_put.get('lastPrice',0) or 0)
            exp_move = (straddle / cp * 100) if cp > 0 else 0
            atm_strike = atm_call.get('strike', 0)
            call_iv = (atm_call.get('impliedVolatility', 0) or 0) * 100
            put_iv = (atm_put.get('impliedVolatility', 0) or 0) * 100
            iv_skew = put_iv - call_iv
        else:
            straddle = exp_move = atm_strike = call_iv = put_iv = iv_skew = 0
        
        # Top strikes
        top_calls = sorted(calls, key=lambda c: c.get('volume',0) or 0, reverse=True)[:3]
        top_puts = sorted(puts, key=lambda p: p.get('volume',0) or 0, reverse=True)[:3]
        
        skew_signal = "put_premium" if iv_skew > 5 else "call_premium" if iv_skew < -5 else "balanced"
        pc_sentiment = "bullish" if pc_vol < 0.7 else "bearish" if pc_vol > 1.3 else "neutral"
        
        result["options"] = {
            "pc_ratio_volume": round(pc_vol, 3),
            "pc_ratio_oi": round(pc_oi, 3),
            "pc_sentiment": pc_sentiment,
            "atm_strike": atm_strike,
            "straddle_price": round(straddle, 2),
            "expected_move_pct": round(exp_move, 2),
            "call_iv": round(call_iv, 1),
            "put_iv": round(put_iv, 1),
            "iv_skew": round(iv_skew, 1),
            "skew_signal": skew_signal,
            "total_call_volume": total_call_vol,
            "total_put_volume": total_put_vol,
            "total_call_oi": total_call_oi,
            "total_put_oi": total_put_oi,
            "top_call_strikes": [{"strike": c.get('strike'), "vol": c.get('volume',0)} for c in top_calls],
            "top_put_strikes": [{"strike": p.get('strike'), "vol": p.get('volume',0)} for p in top_puts]
        }
    except Exception as e:
        result["options"] = {"error": str(e)}
    
    # === OVERALL POSITIONING ===
    signals = []
    if tech_bias == 'bullish': signals.append(1)
    elif tech_bias == 'bearish': signals.append(-1)
    else: signals.append(0)
    
    opts_data = result.get("options", {})
    pc_sent = opts_data.get("pc_sentiment", "neutral")
    if pc_sent == 'bullish': signals.append(1)
    elif pc_sent == 'bearish': signals.append(-1)
    else: signals.append(0)
    
    sk = opts_data.get("skew_signal", "balanced")
    if sk == 'call_premium': signals.append(1)
    elif sk == 'put_premium': signals.append(-1)
    else: signals.append(0)
    
    if vol_ratio > 1.5:
        signals.append(1 if tech_bias == 'bullish' else -1)
    
    avg_sig = sum(signals) / len(signals) if signals else 0
    positioning = 'bullish' if avg_sig > 0.3 else 'bearish' if avg_sig < -0.3 else 'mixed'
    result["overall_positioning"] = positioning
    result["signal_score"] = round(avg_sig, 2)
    
    all_results.append(result)

# === DISPLAY ===
print()
for r in all_results:
    if r.get("error"):
        print(f"  {r['ticker']}: ERROR — {r['error']}")
        continue
    
    t = r['ticker']
    p = r['price']
    pos = r['overall_positioning'].upper()
    score = r['signal_score']
    bias = r['technical_bias']
    chg5 = r['pct_5d']
    rv = r['realized_vol_20d']
    vr = r['volume_ratio']
    
    opts = r.get('options', {})
    em = opts.get('expected_move_pct', 0)
    pc = opts.get('pc_ratio_volume', 0)
    skew = opts.get('skew_signal', '?')
    iv_c = opts.get('call_iv', 0)
    iv_p = opts.get('put_iv', 0)
    
    emoji = '🟢' if pos == 'BULLISH' else '🔴' if pos == 'BEARISH' else '🟡'
    
    print(f"{'='*60}")
    print(f"  {emoji} {t} — {pos} positioning (score: {score:+.2f})")
    print(f"{'='*60}")
    print(f"  Price: ${p:.2f} | 5d: {chg5:+.1f}% | Vol ratio: {vr:.1f}x")
    print(f"  Technical: {bias} | {', '.join(r.get('technical_signals',[]))}")
    print(f"  Options P/C (vol): {pc:.2f} | Skew: {skew}")
    print(f"  Expected Move: ±{em:.1f}% | Call IV: {iv_c:.0f}% | Put IV: {iv_p:.0f}%")
    print(f"  Realized Vol 20d: {rv:.0f}% | IV Premium: {max(iv_c,iv_p)-rv:.0f}%")
    
    top_c = opts.get('top_call_strikes', [])
    top_p = opts.get('top_put_strikes', [])
    if top_c:
        strikes_str = ', '.join(str(s.get("strike","?")) + "(" + str(s.get("vol",0)) + "v)" for s in top_c[:3])
        print(f"  Top call strikes: {strikes_str}")
    if top_p:
        strikes_str = ', '.join(str(s.get("strike","?")) + "(" + str(s.get("vol",0)) + "v)" for s in top_p[:3])
        print(f"  Top put strikes: {strikes_str}")
    print()

# === SAVE ===
output = {
    "scan_time": datetime.now(timezone.utc).isoformat(),
    "tickers": [r.get('ticker') for r in all_results],
    "results": all_results,
    "summary": {
        "bullish": sum(1 for r in all_results if r.get('overall_positioning') == 'bullish'),
        "bearish": sum(1 for r in all_results if r.get('overall_positioning') == 'bearish'),
        "mixed": sum(1 for r in all_results if r.get('overall_positioning') == 'mixed')
    }
}
out_path = f"{output_dir}/earnings-positioning.json"
with open(out_path, 'w') as f:
    json.dump(output, f, indent=2)
print(f"JSON output: {out_path}")
PYEOF

log "=== Done ==="
