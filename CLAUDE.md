# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Headroom is a macOS CLI tool that monitors hardware resource usage over time and produces data-driven Mac purchase recommendations. It answers "what Mac should I buy next?" based on real workload patterns rather than guesswork.

**Target**: macOS 13+ (Ventura+), Apple Silicon only.

## Build & Run

```bash
pip3 install -e .              # Install in dev mode
python3 -m headroom --help     # CLI usage
python3 -m headroom install    # Set up DB + LaunchAgent + start collecting
python3 -m headroom status     # Check collection status
python3 -m headroom analyze    # Generate report (after collecting data)
python3 -m headroom uninstall  # Stop daemon + clean up
```

## Architecture

Three components, all in the `headroom/` Python package:

1. **Collector** (`collector.py`) — Long-running daemon that reads `macmon pipe` (JSON stream), enriches with `vm_stat` and `memory_pressure`, writes to SQLite every 30s. Process snapshots every 5 min. Started via LaunchAgent.

2. **Analyzer** (`analyzer.py`) — Reads SQLite, computes percentile stats, scores four dimensions (Memory, GPU, CPU, Thermal) on 0-10 scale, maps scores to upgrade recommendations, generates Markdown report.

3. **CLI** (`cli.py`) — Argparse entrypoint dispatching to installer/collector/analyzer.

Supporting modules:
- `sources.py` — Wrappers for macmon JSON parsing, `vm_stat`, `memory_pressure -Q`, `ps` process snapshots, system info collection
- `db.py` — SQLite schema, insert/query helpers
- `installer.py` — LaunchAgent plist generation, load/unload, macmon dependency check
- `constants.py` — Paths (`~/.headroom/`), intervals, LaunchAgent label

## Key Design Decisions

- **macmon** (`brew install vladkens/tap/macmon`) is the primary data source — sudoless, JSON via `macmon pipe`. Output format: `ecpu_usage`/`pcpu_usage`/`gpu_usage` are `[freq_mhz, utilization_fraction]` tuples.
- **Swap usage is the primary memory metric**, not raw RAM usage. macOS uses all available RAM by design; swap volume/frequency and memory pressure transitions indicate real constraints.
- **Page-in rate** (not page-out) correlates with perceived slowness.
- Thermal pressure is derived from CPU temperature thresholds (nominal <70°C, moderate <85°C, heavy <95°C, critical ≥95°C).
- Memory pressure mapped from `memory_pressure -Q` percentage (normal ≥50%, warn ≥25%, critical <25%).

## Dependencies

- macmon: `brew install vladkens/tap/macmon`
- Python 3.9+ with sqlite3 (ships with macOS)
- macOS system utilities: `vm_stat`, `sysctl`, `memory_pressure`, `ps`
