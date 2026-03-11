# Headroom

## What This Is

A macOS tool that monitors your actual hardware usage over time (days/weeks/months) and produces a concrete, data-driven recommendation for what Mac you should buy next. Instead of guessing based on persona ("I'm a developer, so I probably need 32GB"), it tells you exactly where you're constrained based on your real workload patterns.

**Nothing like this exists today.** The monitoring primitives are all there in macOS. The benchmarking tools (Geekbench, etc.) measure what a machine *can* do. But nobody has built the thing that measures what your machine *is asked* to do, where it falls short, and maps that to a purchase recommendation.

## The Core Insight

When you buy a Mac, you're making decisions along several independent axes that Apple charges significant premiums for:

- **Unified Memory (RAM)**: 16 → 24 → 32 → 48 → 64 → 96 → 128 GB
- **GPU Cores**: Base → Pro → Max → Ultra tier (or within a tier, e.g., M4 Pro 16-core vs 20-core GPU)
- **CPU Cores**: Performance vs Efficiency cluster sizing
- **SSD Size & Speed**: Varies by tier (base configs sometimes have slower single-NAND SSDs)
- **Neural Engine**: Same across tiers but utilization matters for understanding workload character
- **Memory Bandwidth**: Dramatically different between tiers (M4: 120 GB/s vs M4 Max: 546 GB/s)

Most people overspend on one axis and underspend on another because they're guessing. This tool removes the guesswork.

## Architecture

### Component 1: The Collector Daemon

A lightweight background process that samples system metrics at regular intervals and stores them in a local SQLite database.

#### Data Sources (prioritized)

**Primary — `macmon pipe` (sudoless, Apple Silicon only)**
- Uses private IOReport API (same data as `powermetrics` but no root required)
- Outputs JSON with: CPU utilization per cluster (E/P), GPU utilization %, ANE power, memory bandwidth (CPU/GPU/total), package power draw, thermal state
- Install: `brew install vladkens/tap/macmon`
- Invoke: `macmon pipe` — emits one JSON object per sample interval

**Secondary — `powermetrics` (requires sudo, richer data)**
- Apple's built-in tool, extremely comprehensive
- Additional data beyond macmon: per-core residency states, detailed frequency stepping, disk I/O power, thermal pressure level, individual sensor temps
- Invoke: `sudo powermetrics --samplers cpu_power,gpu_power,thermal,disk,network -i 30000 -f json`
- The sudo requirement makes this less ideal for always-on daemon use unless you set up a dedicated launchd plist running as root

**Tertiary — `vm_stat` / `sysctl` / `memory_pressure` (no sudo, critical for memory analysis)**
- These are the most important data sources for the memory dimension — more so than raw "memory used" from macmon, which is essentially meaningless. macOS is designed to use all available RAM via aggressive caching and compression, so a machine with 64GB will "use" 60GB just as happily as a 16GB machine uses 15GB. That's not a problem, that's the OS doing its job. The real signals are about what happens when the OS runs out of room:
- `sysctl vm.swapusage`: Current swap allocation — **this is the single most important memory metric**. How many GB are paged out to SSD, and how consistently? Sustained multi-GB swap means your working set genuinely doesn't fit in RAM.
- `vm_stat`: Page-in rate from swap (the metric that actually correlates with "my Mac feels slow" — page-outs happen in the background, page-ins stall your app while it waits for data from disk), page-out rate, compression stats
- `memory_pressure`: Returns categorical pressure level (normal/warn/critical) — but the interesting thing is the *transitions*: how often you enter pressure and how long you stay there
- `sysctl hw.memsize`: Total physical RAM (for context)
- Compression ratio (derived from vm_stat): macOS compresses inactive pages before swapping. High compressor activity with a climbing ratio is the "yellow light before red" — the system postponing swap as long as it can

**Quaternary — Process-level context (optional but very useful)**
- `ps aux` or `top -l 1 -stats pid,command,cpu,mem,time` sampled periodically
- Maps resource consumption to specific apps, so the analysis can say "Xcode + Simulator is what drives your memory pressure" rather than just "you need more RAM"
- This is what makes the recommendation *actionable* — it connects hardware bottlenecks to workflow patterns

#### Sampling Strategy

- **Metrics sample**: Every 30 seconds (macmon pipe + vm_stat)
- **Process snapshot**: Every 5 minutes (top N processes by CPU and memory)
- **Estimated storage**: ~50-100 MB/month in SQLite at these intervals
- **Power impact**: Negligible — macmon itself uses <1% CPU

#### SQLite Schema (starting point)

```sql
CREATE TABLE samples (
    id INTEGER PRIMARY KEY,
    timestamp TEXT NOT NULL,       -- ISO 8601
    
    -- CPU
    cpu_e_cluster_pct REAL,        -- Efficiency cluster utilization %
    cpu_p_cluster_pct REAL,        -- Performance cluster utilization %
    cpu_freq_mhz_e INTEGER,        -- E-cluster frequency
    cpu_freq_mhz_p INTEGER,        -- P-cluster frequency
    cpu_power_watts REAL,
    
    -- GPU
    gpu_utilization_pct REAL,
    gpu_freq_mhz INTEGER,
    gpu_power_watts REAL,
    
    -- Neural Engine
    ane_power_watts REAL,
    
    -- Memory (NOTE: raw "memory used" is intentionally excluded — it's meaningless
    -- on macOS because the OS uses all available RAM by design. The real constraint
    -- signals are swap, pressure transitions, compression, and page-in rate.)
    memory_swap_used_bytes INTEGER,  -- THE key metric: how much is paged to SSD
    memory_pressure TEXT,            -- 'normal', 'warn', 'critical'
    memory_pressure_changed BOOLEAN, -- flag transitions for duration analysis
    memory_compressed_bytes INTEGER,  -- compressor working hard = yellow light
    memory_compressor_ratio REAL,     -- ratio trending up = running out of room
    memory_pageins INTEGER,          -- cumulative; delta = "felt slowness" from swap reads
    memory_pageouts INTEGER,         -- cumulative; delta = system pushing pages to disk
    memory_bandwidth_gbps REAL,
    
    -- Thermal
    thermal_pressure TEXT,         -- 'nominal', 'moderate', 'heavy', 'critical'  
    package_power_watts REAL,
    
    -- Disk
    disk_read_ops INTEGER,
    disk_write_ops INTEGER,
    disk_read_bytes INTEGER,
    disk_write_bytes INTEGER
);

CREATE TABLE process_snapshots (
    id INTEGER PRIMARY KEY,
    timestamp TEXT NOT NULL,
    pid INTEGER,
    process_name TEXT,
    cpu_pct REAL,
    memory_bytes INTEGER,
    -- Top 10-20 processes per snapshot
    FOREIGN KEY (timestamp) REFERENCES samples(timestamp)
);

CREATE TABLE system_info (
    key TEXT PRIMARY KEY,
    value TEXT
);
-- Populated once at install: chip model, total RAM, GPU core count,
-- macOS version, machine model identifier
```

### Component 2: The Analyzer

A script (Python or Swift) that reads the SQLite database and produces a structured analysis report. This is where the intelligence lives.

#### Analysis Dimensions

**Memory Constraint Score**
- NOTE: Raw "memory used vs total" is deliberately NOT a factor here. macOS uses all available RAM by design (caching, compression, speculative prefetch). Almost everyone looks "constrained" by that metric. The real signals are:
- **Swap volume and frequency**: How many GB are paged to SSD? How consistently? Occasional light swap (<1GB, intermittent) is normal. Sustained multi-GB swap means your working set genuinely doesn't fit in RAM and you're burning SSD write cycles.
- **Memory pressure state transitions**: Not just "are you in pressure" but how often do you *enter* warn/critical and how long do you stay? Someone who spikes once a day for 10 minutes has a different problem than someone who lives there for 4 hours.
- **Compression ratio trend**: macOS compresses inactive pages before resorting to swap. A steadily climbing compression ratio means the system is working harder to avoid swap — the yellow light before red.
- **Page-in rate from swap**: This is what correlates with the subjective "my Mac feels slow" experience. Page-outs happen in the background. Page-ins are what stall your app while it waits for data to come back from disk. High page-in deltas during active hours = you're feeling it.
- Which processes correlated with pressure/swap events? (From process snapshots)
- Recommendation mapping:
  - Minimal swap (<1GB), pressure transitions rare → current RAM is fine
  - Moderate swap (1-4GB), enters pressure daily → +1 RAM tier (e.g., 16→24 or 24→32)
  - Heavy swap (4-8GB+), sustained pressure episodes → +2 RAM tiers
  - Chronic critical pressure, high page-in rates → significantly more RAM, and also flag which apps are responsible (maybe the answer is "close some Safari tabs" not "buy a new Mac")

**GPU Constraint Score**
- What % of active hours was GPU utilization >80%?
- Did GPU frequency hit max sustained? For how long?
- Was GPU power draw near the chip's TDP limit?
- Correlation with specific apps (Final Cut, Blender, games, etc.)
- Recommendation mapping:
  - GPU rarely >50% → base chip GPU is fine, save your money
  - GPU regularly >80% with specific pro apps → Pro tier
  - GPU sustained >90% with rendering/ML workloads → Max tier
  - Memory bandwidth saturation alongside GPU load → Max tier (bandwidth doubles)

**CPU Constraint Score**
- P-cluster utilization distribution — how often are all performance cores pegged?
- E-cluster vs P-cluster balance — are efficiency cores handling most work? (Good, means P-cores are available for bursts)
- Thermal throttling frequency and duration
- Recommendation mapping:
  - P-cores rarely saturated → base core count is fine
  - P-cores frequently saturated, short bursts → current tier OK, just needs newer gen
  - P-cores sustained >90% for extended periods → more cores (Pro/Max)

**Thermal Constraint Score**
- How often does the system thermally throttle?
- Duration of throttle events?
- This distinguishes "I need a more powerful chip" from "I need a machine with better cooling" (e.g., MacBook Air vs MacBook Pro with the same chip)

**Memory Bandwidth Score**
- Are you saturating the memory bus?
- This is the subtle one — it's the difference between needing M4 Pro (200 GB/s) vs M4 Max (546 GB/s) even if you don't need more GPU cores
- Relevant for: large LLM inference, heavy video editing, scientific computing

**Storage Score**
- Sustained vs burst I/O patterns
- Whether disk I/O is ever the bottleneck (rare on modern SSDs but possible with very large file operations)

#### Output Format

The analyzer produces a Markdown report with:

1. **Executive Summary**: "Based on 23 days of monitoring, your primary bottleneck is memory. You regularly exceed your 16GB with Xcode + Simulator + Claude Code running simultaneously. Your GPU is underutilized. Recommendation: M4 Pro with 24GB or 36GB RAM, base GPU configuration."

2. **Per-Dimension Detail**: Charts/tables showing the distribution of utilization over time for each axis, with the key thresholds highlighted.

3. **Workload Fingerprint**: "Your typical heavy workload consists of: Xcode (avg 3.2GB RSS), Simulator (avg 2.1GB), Claude Code / Node.js (avg 1.8GB), Safari (avg 2.5GB across tabs), plus system overhead. Total working set: ~14GB against 16GB physical."

4. **Specific Purchase Recommendation**: Maps the analysis to current Apple Silicon configurations with pricing context. "The M4 Pro 24GB ($2,399) covers your needs with headroom. The M4 Pro 48GB ($2,799) gives you substantial future-proofing. The M4 Max is overkill for your GPU and bandwidth usage patterns."

5. **Raw Data Summary**: Key percentiles (p50, p90, p99) for each metric, for anyone who wants to sanity-check the recommendation.

### Component 3: Installation & Lifecycle

#### Install

- A shell script that:
  - Installs macmon via Homebrew (if not present)
  - Creates the SQLite database
  - Installs a LaunchAgent plist (`~/Library/LaunchAgents/com.dgrlabs.headroom.plist`)
  - Records system info (chip, RAM, GPU cores, model)
  - Starts the collector

#### LaunchAgent Plist (sketch)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dgrlabs.headroom</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/headroom-collector</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/headroom.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/headroom.err</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityBackgroundIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
```

#### Analyze

- `headroom analyze` reads the database and emits the report
- Could optionally pipe the report + raw stats summary to Claude API for the natural-language recommendation layer (this is where LLM insertion adds real value — translating percentile data into "buy this specific SKU")

#### Uninstall

- `headroom uninstall` removes the LaunchAgent, stops the daemon, optionally deletes the database

## Technology Choices

**Language: Python or Swift?**

- **Python** is faster to prototype, has great SQLite support, easy to parse JSON from macmon pipe. Downside: requires Python runtime on the user's machine (though macOS ships with it).
- **Swift** produces a native binary, fits the Mac ecosystem better, and Swift's Foundation framework has good process management. Downside: more boilerplate for JSON parsing and SQLite.
- **Recommendation**: Start with Python for the collector + analyzer. If this becomes a real product, rewrite the collector in Swift for a cleaner install story. The analyzer could stay Python or become a Claude API call.

**Database: SQLite**
- No question. Local, zero-config, handles the write volume easily, and the analysis queries are straightforward aggregations.

**Visualization (optional/later)**
- The analyzer could generate charts using matplotlib (Python) or output data suitable for a simple web dashboard
- Or just produce clean Markdown tables — the LLM analysis layer makes charts less critical

## Open Questions & Future Ideas

- **Could this run as a macOS menu bar app?** Yes, using SwiftUI + a background collector. Would make it more approachable than a CLI tool. The menu bar icon could show a simple health indicator (green/yellow/red per dimension).
- **Privacy**: All data stays local. No telemetry. The only network call would be the optional Claude API analysis step, and even that could be opt-in with the raw data visible before sending.
- **Apple Silicon only?** For v1, yes — macmon and the relevant powermetrics samplers are Apple Silicon specific. Intel Macs have different monitoring APIs and the purchase recommendation mapping is moot (Intel Macs are no longer sold).
- **How much data is enough?** A week of typical usage gives a reasonable picture. A month captures more variance (travel days, crunch periods, etc.). The analyzer should note confidence level based on data duration.
- **Could you compare against a known database of Mac configs?** Yes — if you maintain a table of current Mac SKUs with their specs (RAM, GPU cores, bandwidth, price), the analyzer can directly recommend specific models and flag the price/performance tradeoff.
- **Integration with Apple's existing data**: macOS collects some historical performance data in `/var/db/` and via `spindump`, `sysdiagnose`, etc. It might be possible to bootstrap the analysis from existing system logs without needing the daemon to run for weeks first. Worth investigating.
- **Name**: Headroom.

## Project Metadata

- **Author**: DGR Labs
- **Status**: Design / Pre-development
- **Target Platform**: macOS 13+ (Ventura and later), Apple Silicon only
- **License**: TBD (likely MIT for open source release)
- **Dependencies**: macmon (Homebrew), Python 3.9+, SQLite3 (ships with macOS)
