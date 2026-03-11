# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Headroom is a macOS CLI tool that monitors hardware resource usage over time and produces data-driven Mac purchase recommendations. It answers "what Mac should I buy next?" based on real workload patterns rather than guesswork.

**Status**: Design / Pre-development. The design spec lives in `headroom-project.md`.

**Target**: macOS 13+ (Ventura+), Apple Silicon only.

## Architecture

Three-component design:

1. **Collector Daemon** — Background process sampling system metrics every 30 seconds (macmon + vm_stat) with process snapshots every 5 minutes. Stores to SQLite. Managed via LaunchAgent (`com.dgrlabs.headroom`).

2. **Analyzer** — Reads SQLite DB, scores six dimensions (Memory, GPU, CPU, Thermal, Bandwidth, Storage), produces Markdown report with specific Mac SKU recommendations. Optional Claude API integration for natural-language analysis.

3. **CLI Wrapper** — `headroom install|analyze|uninstall` entrypoint for lifecycle management.

## Key Design Decisions

- **Python first** (rapid prototyping), potential Swift rewrite for distribution
- **SQLite** for local data storage (~50-100 MB/month)
- **macmon** (`brew install vladkens/tap/macmon`) is the primary data source — sudoless, JSON output via `macmon pipe`
- **Swap usage is the primary memory metric**, not raw RAM usage. macOS uses all available RAM by design; swap volume/frequency and memory pressure transitions are what indicate real constraints.
- **Page-in rate** (not page-out) correlates with perceived slowness

## Dependencies

- macmon: `brew install vladkens/tap/macmon`
- Python 3.9+ with sqlite3 (ships with macOS)
- macOS system utilities: `vm_stat`, `sysctl`, `memory_pressure`, `ps`
