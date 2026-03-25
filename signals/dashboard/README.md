# Gekko Signal Dashboard

Aggregates all signal tool outputs into a single unified view.

## Usage

```bash
# Generate HTML dashboard
./signal-dashboard.sh

# JSON output (for API/programmatic use)
./signal-dashboard.sh --json

# Custom output file
./signal-dashboard.sh --output /path/to/report.html
```

## What It Shows

| Section | Source | Data |
|---------|--------|------|
| Market Regime | `regime-detector` | Current regime, confidence, VIX, sector rotation |
| Correlations | `correlation-monitor` | Cross-asset pair correlations, decorrelation alerts |
| Event Calendar | `event-calendar` | Next 48h + 1 week binary catalysts |
| Tools Status | All | 5-tool suite health check |

## Output Formats

- **HTML**: Dark-theme dashboard with responsive grid layout
- **JSON**: Machine-readable aggregation of all signal data

## Dependencies

- bash, python3 (stdlib only)
- Signal tool output files in `../output/` directory
- SQLite3 (for correlation data)

## Integration

The dashboard reads from the same output directory used by `signal-daemon`. Run the daemon first to populate data, then generate dashboard on demand or on a schedule.

```bash
# Daemon populates data every 5 min
./signal-daemon/signal-daemon.sh &

# Dashboard reads latest data
./dashboard/signal-dashboard.sh --json
```
