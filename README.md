# Headroom

A native macOS app that monitors your Mac's hardware resource usage over time and produces data-driven upgrade recommendations. Instead of guessing what Mac to buy next, Headroom uses your real workload patterns to tell you.

**Requirements**: macOS 14+ (Sonoma or later), Apple Silicon

## Install

Download the latest release from [Releases](../../releases), or build from source:

```bash
xcodebuild -project HeadroomApp/HeadroomApp.xcodeproj -scheme Headroom build
```

The app is signed and notarized for direct distribution. No App Store or sandbox restrictions — Headroom needs low-level system access for accurate hardware monitoring.

## How It Works

1. **Launch Headroom** and click "Start Monitoring." The app collects system metrics every 30 seconds and process snapshots every 5 minutes, all in the background.

2. **Use your Mac normally.** Let it run for at least a few hours (a full day or more gives the best results). Headroom tracks CPU, GPU, memory, and thermal behavior across your real workloads.

3. **Check the Dashboard.** Headroom scores four dimensions on a 0–10 pressure scale:

   | Dimension | What it measures |
   |-----------|-----------------|
   | Memory | Swap usage, memory pressure transitions, page-in rate |
   | GPU | Utilization percentage, time spent above 80%/90%, GPU power draw |
   | CPU | P-core and E-core utilization, time above 80%/90%, thermal impact |
   | Thermal | CPU temperature distribution, thermal throttling frequency |

4. **Get a Recommendation.** Headroom maps your scores to specific upgrade guidance: RAM tier, GPU tier (Base/Pro/Max), CPU tier, and form factor (Air vs Pro).

## Key Design Decisions

- **Swap is the primary memory metric**, not raw RAM usage. macOS uses all available RAM by design — high memory usage alone isn't a problem. Swap usage and page-in rate are what actually correlate with "my Mac feels slow."
- **All data stays local.** No telemetry, no network calls. Everything is stored in a SQLite database at `~/Library/Application Support/Headroom/`.
- **Low overhead.** Collection runs on a background dispatch queue with minimal CPU and power impact.

## Architecture

Single-process SwiftUI app. Collection runs in-process on a background dispatch queue.

```
Headroom.app
    ├── CollectorManager → CollectionEngine (background queue)
    │   ├── MetricsCollector — IOReport, Mach APIs, sysctl
    │   ├── SMCReader — IOKit AppleSMC temperatures
    │   └── ProcessSnapshot — libproc enumeration
    │   └── SQLite (~/Library/Application Support/Headroom/)
    └── HeadroomDatabase — reads SQLite, computes analysis, feeds UI
```

## Building from Source

```bash
# Clone and build
git clone https://github.com/yourusername/headroom.git
cd headroom
open HeadroomApp/HeadroomApp.xcodeproj
```

Select the "Headroom" scheme and build (Cmd+B). You'll need to update the development team in Xcode's Signing & Capabilities to your own.

## License

MIT — see [LICENSE](LICENSE) for details.
