# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Headroom is a native macOS app that monitors hardware resource usage over time and produces data-driven Mac purchase recommendations. It answers "what Mac should I buy next?" based on real workload patterns rather than guesswork.

**Target**: macOS 14+ (Sonoma+), Apple Silicon only.

## Build & Run

```bash
# Build via Xcode
xcodebuild -project HeadroomApp/HeadroomApp.xcodeproj -scheme Headroom build

# Or open in Xcode
open HeadroomApp/HeadroomApp.xcodeproj
```

The legacy Python CLI (`headroom/`) is retained for reference but is no longer the primary interface.

## Architecture

Single-process non-sandboxed macOS app. Collection runs in-process on a background dispatch queue.

```
Headroom.app (non-sandboxed, SwiftUI GUI)
    ├── CollectorManager → owns CollectionEngine (background queue)
    │   ├── MetricsCollector — IOReport, Mach APIs, sysctl
    │   ├── SMCReader — IOKit AppleSMC temperatures
    │   └── ProcessSnapshot — libproc enumeration
    │   └── Writes to SQLite in ~/Library/Application Support/Headroom/
    └── HeadroomDatabase — reads SQLite, computes analysis, feeds UI
```

### Main App (`HeadroomApp/Headroom/`)
- **HeadroomApp.swift** — App entry point, auto-starts collection for returning users
- **ContentView.swift** — Sidebar navigation + collector status
- **Models/CollectorManager.swift** — In-process collection manager with background engine
- **Models/HeadroomDatabase.swift** — SQLite reader + scoring/analysis engine
- **Models/Models.swift** — Data structures (Sample, SystemInfoData, DimensionScore, etc.)
- **Views/** — DashboardView, TimelineView, RecommendationView, ProcessesView, etc.

### Collectors (`HeadroomApp/HeadroomHelper/`)
- **MetricsCollector.swift** — IOReport (via dlsym), host_statistics64, sysctl
- **SMCReader.swift** — IOKit AppleSMC temperature reading
- **ProcessSnapshot.swift** — proc_listpids/proc_pidinfo enumeration

### Shared (`HeadroomApp/Shared/`)
- **DatabaseSchema.swift** — SQLite schema, insert helpers

## Data Flow

1. **CollectionEngine** (background dispatch queue) collects metrics every 30s, process snapshots every 5min
2. Writes to SQLite in `~/Library/Application Support/Headroom/headroom.db` (WAL mode)
3. **HeadroomDatabase** reads the DB (read-only), computes analysis, renders UI
4. Auto-starts on launch if DB exists (returning user); first-time users click "Start Monitoring"

## Key Design Decisions

- **IOReport** private API (loaded via dlsym) for CPU/GPU utilization, frequency, and power metrics. Fallback to `host_processor_info()` if unavailable.
- **SMC** (AppleSMC IOKit service) for CPU/GPU temperatures. Fallback to `Foundation.ProcessInfo.thermalState`.
- **Swap usage is the primary memory metric**, not raw RAM usage. macOS uses all available RAM by design.
- **Page-in rate** (not page-out) correlates with perceived slowness.
- Thermal pressure derived from CPU temperature thresholds (nominal <70°C, moderate <85°C, heavy <95°C, critical ≥95°C).
- Memory pressure from `kern.memorystatus_vm_pressure_level` sysctl.
- **SQLite with WAL mode** for concurrent reader+writer access.
- macOS 26+ APIs (MeshGradient, glassEffect) wrapped with `#available` checks for backward compatibility.
- **Non-sandboxed** for now — required for IOReport/SMC access. Two-process sandboxed architecture planned for App Store submission.

## Dependencies

- No external dependencies. Fully self-contained native Swift.
- macOS system frameworks: IOKit, SQLite3
- Development team: 2CTUXD4C44
