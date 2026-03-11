# Headroom

A macOS CLI tool that monitors your Mac's hardware resource usage over time and produces data-driven upgrade recommendations. Instead of guessing what Mac to buy next, Headroom uses your real workload patterns to tell you.

**Requirements**: macOS 13+ (Ventura or later), Apple Silicon, Python 3.9+

## Install

```bash
# Install macmon (the data source)
brew install vladkens/tap/macmon

# Install headroom
pip3 install -e .
```

## Usage

```bash
# Set up the background collector daemon
headroom install

# Check collection status
headroom status

# Let it run for a day or more, then generate your report
headroom analyze

# Save report to a file
headroom analyze -o report.md

# Stop collecting and clean up
headroom uninstall

# Uninstall but keep your data
headroom uninstall --keep-data
```

## How It Works

1. **Collect** — A background daemon (managed via LaunchAgent) reads system metrics from `macmon pipe` every 30 seconds, enriched with `vm_stat` and `memory_pressure` data. Process snapshots are captured every 5 minutes. Everything is stored in a local SQLite database at `~/.headroom/headroom.db`.

2. **Analyze** — Reads the collected data, computes percentile statistics, and scores four dimensions on a 0–10 scale:

   | Dimension | What it measures |
   |-----------|-----------------|
   | Memory | Swap usage, memory pressure transitions, page-in rate |
   | GPU | Utilization percentage, time spent above 80%/90%, GPU power draw |
   | CPU | P-cluster and E-cluster utilization, time above 80%/90%, thermal impact |
   | Thermal | CPU temperature distribution, thermal throttling frequency |

3. **Recommend** — Maps scores to specific upgrade guidance: RAM tier, GPU tier (Base/Pro/Max), CPU tier, and form factor (Air vs Pro vs desktop).

## Example Output

```
# Headroom Analysis Report

**System**: MacBook Pro — Apple M1 Pro — 16GB RAM
**Monitoring period**: 3.2 days (9,216 samples)
**Confidence**: high

## Executive Summary

Based on 3.2 days of monitoring, your **primary bottleneck is Memory** (score: 6/10).

| Dimension | Score | Status |
|-----------|-------|--------|
| Memory | 6/10 [######....] | Constrained |
| GPU | 2/10 [##........] | OK |
| CPU | 3/10 [###.......] | Watch |
| Thermal | 1/10 [#.........] | OK |
```

## Data Storage

All data is stored locally in `~/.headroom/`:
- `headroom.db` — SQLite database with metrics and process snapshots
- `headroom.log` — Collector daemon log

## License

MIT
