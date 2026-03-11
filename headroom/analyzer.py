import sqlite3
from datetime import datetime
from .constants import DB_PATH
from .db import get_connection, get_system_info


def analyze(db_path=None):
    """Run full analysis and return a Markdown report."""
    conn = get_connection(db_path)
    conn.row_factory = sqlite3.Row

    sys_info = get_system_info(conn)
    stats = _compute_stats(conn)
    conn.close()

    if stats['sample_count'] == 0:
        return (
            "# Headroom Analysis\n\n"
            "No data collected yet. Let the collector run for a few hours before analyzing.\n"
            "Check status with: headroom status"
        )

    return _generate_report(sys_info, stats)


# ---------------------------------------------------------------------------
# Stats computation
# ---------------------------------------------------------------------------

def _compute_stats(conn):
    stats = {}

    row = conn.execute("""
        SELECT COUNT(*) as cnt, MIN(timestamp) as first_ts, MAX(timestamp) as last_ts
        FROM samples
    """).fetchone()

    stats['sample_count'] = row['cnt']
    if row['cnt'] == 0:
        return stats

    stats['first_sample'] = row['first_ts']
    stats['last_sample'] = row['last_ts']

    try:
        first = datetime.fromisoformat(row['first_ts'].replace('Z', '+00:00'))
        last = datetime.fromisoformat(row['last_ts'].replace('Z', '+00:00'))
        stats['duration_hours'] = (last - first).total_seconds() / 3600
    except Exception:
        stats['duration_hours'] = 0

    # CPU
    stats['cpu'] = _percentile_stats(conn, 'cpu_p_cluster_pct')
    stats['cpu_e'] = _percentile_stats(conn, 'cpu_e_cluster_pct')
    stats['cpu_p_above_80'] = _pct_above(conn, 'cpu_p_cluster_pct', 80)
    stats['cpu_p_above_90'] = _pct_above(conn, 'cpu_p_cluster_pct', 90)
    stats['cpu_power'] = _percentile_stats(conn, 'cpu_power_watts')

    # GPU
    stats['gpu'] = _percentile_stats(conn, 'gpu_utilization_pct')
    stats['gpu_above_80'] = _pct_above(conn, 'gpu_utilization_pct', 80)
    stats['gpu_above_90'] = _pct_above(conn, 'gpu_utilization_pct', 90)
    stats['gpu_power'] = _percentile_stats(conn, 'gpu_power_watts')

    # Memory / swap
    stats['swap'] = _percentile_stats(conn, 'memory_swap_used_bytes')
    stats['swap_mb'] = {k: v / (1024 ** 2) for k, v in stats['swap'].items()}

    # Memory pressure distribution
    pressure_rows = conn.execute("""
        SELECT memory_pressure, COUNT(*) as cnt
        FROM samples WHERE memory_pressure IS NOT NULL
        GROUP BY memory_pressure
    """).fetchall()
    total = sum(r['cnt'] for r in pressure_rows)
    stats['pressure_dist'] = (
        {r['memory_pressure']: r['cnt'] / total * 100 for r in pressure_rows}
        if total else {}
    )

    # Page-in deltas (consecutive sample differences)
    pageins = conn.execute("""
        SELECT memory_pageins FROM samples
        WHERE memory_pageins IS NOT NULL ORDER BY timestamp
    """).fetchall()
    if len(pageins) > 1:
        deltas = []
        for i in range(1, len(pageins)):
            d = pageins[i]['memory_pageins'] - pageins[i - 1]['memory_pageins']
            if d >= 0:
                deltas.append(d)
        if deltas:
            deltas.sort()
            n = len(deltas)
            stats['pagein_deltas'] = {
                'p50': deltas[n // 2],
                'p90': deltas[int(n * 0.9)],
                'p99': deltas[int(n * 0.99)],
                'max': deltas[-1],
                'avg': sum(deltas) / n,
            }

    # Thermal
    stats['cpu_temp'] = _percentile_stats(conn, 'cpu_temp_avg')
    thermal_rows = conn.execute("""
        SELECT thermal_pressure, COUNT(*) as cnt
        FROM samples WHERE thermal_pressure IS NOT NULL
        GROUP BY thermal_pressure
    """).fetchall()
    total = sum(r['cnt'] for r in thermal_rows)
    stats['thermal_dist'] = (
        {r['thermal_pressure']: r['cnt'] / total * 100 for r in thermal_rows}
        if total else {}
    )

    # Power
    stats['package_power'] = _percentile_stats(conn, 'package_power_watts')
    stats['sys_power'] = _percentile_stats(conn, 'sys_power_watts')

    # Top processes by memory
    stats['top_processes'] = [dict(r) for r in conn.execute("""
        SELECT process_name, AVG(cpu_pct) as avg_cpu,
               AVG(memory_bytes) as avg_mem, COUNT(*) as appearances
        FROM process_snapshots
        GROUP BY process_name ORDER BY avg_mem DESC LIMIT 15
    """).fetchall()]

    # Top processes by CPU
    stats['top_cpu_processes'] = [dict(r) for r in conn.execute("""
        SELECT process_name, AVG(cpu_pct) as avg_cpu,
               MAX(cpu_pct) as max_cpu, COUNT(*) as appearances
        FROM process_snapshots
        GROUP BY process_name HAVING avg_cpu > 1
        ORDER BY avg_cpu DESC LIMIT 10
    """).fetchall()]

    return stats


def _percentile_stats(conn, column):
    rows = conn.execute(
        f"SELECT {column} FROM samples WHERE {column} IS NOT NULL ORDER BY {column}"
    ).fetchall()
    if not rows:
        return {'p50': 0, 'p90': 0, 'p99': 0, 'min': 0, 'max': 0, 'avg': 0}
    values = [r[0] for r in rows]
    n = len(values)
    return {
        'p50': values[n // 2],
        'p90': values[int(n * 0.9)],
        'p99': values[int(n * 0.99)],
        'min': values[0],
        'max': values[-1],
        'avg': sum(values) / n,
    }


def _pct_above(conn, column, threshold):
    row = conn.execute(
        f"SELECT COUNT(CASE WHEN {column} > ? THEN 1 END) * 100.0 / COUNT(*) as pct "
        f"FROM samples WHERE {column} IS NOT NULL",
        (threshold,),
    ).fetchone()
    return row['pct'] if row['pct'] else 0


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def _score_memory(stats):
    swap_p90_mb = stats.get('swap_mb', {}).get('p90', 0)
    pressure_warn = stats.get('pressure_dist', {}).get('warn', 0)
    pressure_critical = stats.get('pressure_dist', {}).get('critical', 0)

    score = 0

    if swap_p90_mb > 8192:
        score += 5
    elif swap_p90_mb > 4096:
        score += 4
    elif swap_p90_mb > 1024:
        score += 3
    elif swap_p90_mb > 256:
        score += 2
    elif swap_p90_mb > 0:
        score += 1

    if pressure_critical > 5:
        score += 3
    elif pressure_critical > 1:
        score += 2
    elif pressure_warn > 20:
        score += 2
    elif pressure_warn > 5:
        score += 1

    pagein_p90 = stats.get('pagein_deltas', {}).get('p90', 0)
    if pagein_p90 > 10000:
        score += 2
    elif pagein_p90 > 1000:
        score += 1

    return min(score, 10)


def _score_gpu(stats):
    above_80 = stats.get('gpu_above_80', 0)
    above_90 = stats.get('gpu_above_90', 0)

    score = 0
    if above_90 > 20:
        score += 5
    elif above_90 > 10:
        score += 4
    elif above_80 > 20:
        score += 3
    elif above_80 > 10:
        score += 2
    elif stats.get('gpu', {}).get('p90', 0) > 50:
        score += 1

    gpu_power_p90 = stats.get('gpu_power', {}).get('p90', 0)
    if gpu_power_p90 > 15:
        score += 3
    elif gpu_power_p90 > 8:
        score += 2
    elif gpu_power_p90 > 3:
        score += 1

    return min(score, 10)


def _score_cpu(stats):
    p_above_80 = stats.get('cpu_p_above_80', 0)
    p_above_90 = stats.get('cpu_p_above_90', 0)

    score = 0
    if p_above_90 > 20:
        score += 5
    elif p_above_90 > 10:
        score += 4
    elif p_above_80 > 20:
        score += 3
    elif p_above_80 > 10:
        score += 2
    elif stats.get('cpu', {}).get('p90', 0) > 50:
        score += 1

    thermal_heavy = (stats.get('thermal_dist', {}).get('heavy', 0)
                     + stats.get('thermal_dist', {}).get('critical', 0))
    if thermal_heavy > 10:
        score += 3
    elif thermal_heavy > 5:
        score += 2
    elif thermal_heavy > 1:
        score += 1

    return min(score, 10)


def _score_thermal(stats):
    thermal_moderate = stats.get('thermal_dist', {}).get('moderate', 0)
    thermal_heavy = stats.get('thermal_dist', {}).get('heavy', 0)
    thermal_critical = stats.get('thermal_dist', {}).get('critical', 0)
    temp_p90 = stats.get('cpu_temp', {}).get('p90', 0)

    score = 0
    if thermal_critical > 5:
        score += 4
    elif thermal_heavy > 10:
        score += 3
    elif thermal_heavy > 5:
        score += 2
    elif thermal_moderate > 30:
        score += 2
    elif thermal_moderate > 10:
        score += 1

    if temp_p90 > 95:
        score += 4
    elif temp_p90 > 85:
        score += 3
    elif temp_p90 > 75:
        score += 1

    return min(score, 10)


# ---------------------------------------------------------------------------
# Recommendations
# ---------------------------------------------------------------------------

_RAM_TIERS = [8, 16, 24, 32, 48, 64, 96, 128]


def _memory_recommendation(score, current_ram_gb):
    ram = int(current_ram_gb) if current_ram_gb and current_ram_gb != 'unknown' else 16
    current_idx = 0
    for i, t in enumerate(_RAM_TIERS):
        if t >= ram:
            current_idx = i
            break

    if score <= 2:
        return f"{ram}GB (current RAM is sufficient)"
    elif score <= 4:
        bump = min(current_idx + 1, len(_RAM_TIERS) - 1)
        return f"{_RAM_TIERS[bump]}GB (+1 tier)"
    elif score <= 7:
        bump = min(current_idx + 2, len(_RAM_TIERS) - 1)
        return f"{_RAM_TIERS[bump]}GB (+2 tiers)"
    else:
        bump = min(current_idx + 3, len(_RAM_TIERS) - 1)
        return f"{_RAM_TIERS[bump]}GB+ (significant upgrade needed)"


def _gpu_recommendation(score):
    if score <= 2:
        return "Base GPU (your GPU workload is light)"
    elif score <= 4:
        return "Base or Pro tier (moderate GPU usage)"
    elif score <= 7:
        return "Pro tier (regular heavy GPU usage)"
    else:
        return "Max tier (sustained heavy GPU + bandwidth needs)"


def _cpu_recommendation(score):
    if score <= 2:
        return "Base CPU is fine (P-cores rarely saturated)"
    elif score <= 4:
        return "Current tier OK, newer generation would help"
    elif score <= 7:
        return "Pro tier (more performance cores needed)"
    else:
        return "Pro/Max tier (sustained heavy CPU demand)"


def _thermal_recommendation(score):
    if score <= 2:
        return "No thermal concerns (any form factor)"
    elif score <= 4:
        return "Mild throttling — MacBook Pro preferred over Air for sustained loads"
    elif score <= 7:
        return "Significant throttling — MacBook Pro or desktop Mac recommended"
    else:
        return "Severe throttling — desktop Mac (Mini/Studio/Pro) strongly recommended"


# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------

def _score_bar(score):
    return "[" + "#" * score + "." * (10 - score) + "]"


def _generate_report(sys_info, stats):
    ram_gb = sys_info.get('total_ram_gb', '?')
    chip = sys_info.get('chip', '?')
    model = sys_info.get('model_name', sys_info.get('model', '?'))

    mem_score = _score_memory(stats)
    gpu_score = _score_gpu(stats)
    cpu_score = _score_cpu(stats)
    thermal_score = _score_thermal(stats)

    scores = {
        'Memory': mem_score,
        'GPU': gpu_score,
        'CPU': cpu_score,
        'Thermal': thermal_score,
    }
    primary_bottleneck = max(scores, key=scores.get)
    max_score = scores[primary_bottleneck]

    hours = stats.get('duration_hours', 0)
    if hours < 1:
        duration_desc = f"{int(hours * 60)} minutes"
    elif hours < 48:
        duration_desc = f"{hours:.1f} hours"
    else:
        duration_desc = f"{hours / 24:.1f} days"

    confidence = "low" if hours < 4 else "moderate" if hours < 48 else "high"

    lines = []

    # Header
    lines.append("# Headroom Analysis Report")
    lines.append("")
    lines.append(f"**System**: {model} — {chip} — {ram_gb}GB RAM  ")
    lines.append(f"**Monitoring period**: {duration_desc} ({stats['sample_count']:,} samples)  ")
    lines.append(f"**Confidence**: {confidence}")
    lines.append("")

    # Executive Summary
    lines.append("## Executive Summary")
    lines.append("")
    if max_score <= 2:
        lines.append(
            f"Your {model} is well-matched to your workload. "
            "No immediate upgrade needed."
        )
    else:
        lines.append(
            f"Based on {duration_desc} of monitoring, your **primary bottleneck is "
            f"{primary_bottleneck}** (score: {max_score}/10)."
        )
    lines.append("")

    lines.append("| Dimension | Score | Status |")
    lines.append("|-----------|-------|--------|")
    for dim, sc in scores.items():
        bar = _score_bar(sc)
        if sc <= 2:
            status = "OK"
        elif sc <= 4:
            status = "Watch"
        elif sc <= 7:
            status = "Constrained"
        else:
            status = "Critical"
        lines.append(f"| {dim} | {sc}/10 {bar} | {status} |")
    lines.append("")

    # Memory
    lines.append("## Memory Analysis")
    lines.append("")
    swap = stats.get('swap_mb', {})
    lines.append(
        f"- **Swap usage**: p50={swap.get('p50', 0):.0f}MB, "
        f"p90={swap.get('p90', 0):.0f}MB, max={swap.get('max', 0):.0f}MB"
    )
    pressure = stats.get('pressure_dist', {})
    lines.append(
        "- **Pressure distribution**: "
        + ", ".join(f"{k}={v:.1f}%" for k, v in sorted(pressure.items()))
    )
    pagein = stats.get('pagein_deltas', {})
    if pagein:
        lines.append(
            f"- **Page-in rate** (per interval): p50={pagein.get('p50', 0):.0f}, "
            f"p90={pagein.get('p90', 0):.0f}, p99={pagein.get('p99', 0):.0f}"
        )
    lines.append(f"- **Recommendation**: {_memory_recommendation(mem_score, ram_gb)}")
    lines.append("")

    # GPU
    lines.append("## GPU Analysis")
    lines.append("")
    gpu = stats.get('gpu', {})
    lines.append(
        f"- **Utilization**: p50={gpu.get('p50', 0):.1f}%, "
        f"p90={gpu.get('p90', 0):.1f}%, max={gpu.get('max', 0):.1f}%"
    )
    lines.append(f"- **Time >80%**: {stats.get('gpu_above_80', 0):.1f}% of samples")
    lines.append(f"- **Time >90%**: {stats.get('gpu_above_90', 0):.1f}% of samples")
    lines.append(f"- **Recommendation**: {_gpu_recommendation(gpu_score)}")
    lines.append("")

    # CPU
    lines.append("## CPU Analysis")
    lines.append("")
    cpu = stats.get('cpu', {})
    cpu_e = stats.get('cpu_e', {})
    lines.append(
        f"- **P-cluster utilization**: p50={cpu.get('p50', 0):.1f}%, "
        f"p90={cpu.get('p90', 0):.1f}%, max={cpu.get('max', 0):.1f}%"
    )
    lines.append(
        f"- **E-cluster utilization**: p50={cpu_e.get('p50', 0):.1f}%, "
        f"p90={cpu_e.get('p90', 0):.1f}%"
    )
    lines.append(f"- **P-cores >80%**: {stats.get('cpu_p_above_80', 0):.1f}% of samples")
    lines.append(f"- **P-cores >90%**: {stats.get('cpu_p_above_90', 0):.1f}% of samples")
    lines.append(f"- **Recommendation**: {_cpu_recommendation(cpu_score)}")
    lines.append("")

    # Thermal
    lines.append("## Thermal Analysis")
    lines.append("")
    temp = stats.get('cpu_temp', {})
    lines.append(
        f"- **CPU temperature**: p50={temp.get('p50', 0):.1f}\u00b0C, "
        f"p90={temp.get('p90', 0):.1f}\u00b0C, max={temp.get('max', 0):.1f}\u00b0C"
    )
    thermal = stats.get('thermal_dist', {})
    lines.append(
        "- **Thermal state**: "
        + ", ".join(f"{k}={v:.1f}%" for k, v in sorted(thermal.items()))
    )
    lines.append(f"- **Recommendation**: {_thermal_recommendation(thermal_score)}")
    lines.append("")

    # Power
    lines.append("## Power")
    lines.append("")
    pkg = stats.get('package_power', {})
    sys_pwr = stats.get('sys_power', {})
    lines.append(
        f"- **Package power**: p50={pkg.get('p50', 0):.1f}W, "
        f"p90={pkg.get('p90', 0):.1f}W, max={pkg.get('max', 0):.1f}W"
    )
    lines.append(
        f"- **System power**: p50={sys_pwr.get('p50', 0):.1f}W, "
        f"p90={sys_pwr.get('p90', 0):.1f}W, max={sys_pwr.get('max', 0):.1f}W"
    )
    lines.append("")

    # Workload Fingerprint
    if stats.get('top_processes'):
        lines.append("## Workload Fingerprint")
        lines.append("")
        lines.append("**Top processes by memory:**")
        lines.append("")
        lines.append("| Process | Avg Memory | Avg CPU | Appearances |")
        lines.append("|---------|-----------|---------|-------------|")
        for p in stats['top_processes'][:10]:
            mem_mb = p['avg_mem'] / (1024 ** 2)
            lines.append(
                f"| {p['process_name']} | {mem_mb:.0f} MB | "
                f"{p['avg_cpu']:.1f}% | {p['appearances']} |"
            )
        lines.append("")

    if stats.get('top_cpu_processes'):
        lines.append("**Top processes by CPU:**")
        lines.append("")
        lines.append("| Process | Avg CPU | Max CPU |")
        lines.append("|---------|---------|---------|")
        for p in stats['top_cpu_processes'][:10]:
            lines.append(
                f"| {p['process_name']} | {p['avg_cpu']:.1f}% | {p['max_cpu']:.1f}% |"
            )
        lines.append("")

    # Raw Data
    lines.append("## Raw Data (Percentiles)")
    lines.append("")
    lines.append("| Metric | p50 | p90 | p99 | Max |")
    lines.append("|--------|-----|-----|-----|-----|")

    def _row(name, s, fmt=".1f", scale=1):
        return (
            f"| {name} "
            f"| {s.get('p50', 0) * scale:{fmt}} "
            f"| {s.get('p90', 0) * scale:{fmt}} "
            f"| {s.get('p99', 0) * scale:{fmt}} "
            f"| {s.get('max', 0) * scale:{fmt}} |"
        )

    lines.append(_row("CPU P-cluster (%)", stats.get('cpu', {})))
    lines.append(_row("CPU E-cluster (%)", stats.get('cpu_e', {})))
    lines.append(_row("GPU (%)", stats.get('gpu', {})))
    lines.append(_row("Swap (MB)", stats.get('swap', {}), ".0f", 1 / (1024 ** 2)))
    lines.append(_row("CPU Temp (\u00b0C)", stats.get('cpu_temp', {})))
    lines.append(_row("Package Power (W)", stats.get('package_power', {})))
    lines.append(_row("System Power (W)", stats.get('sys_power', {})))
    lines.append("")

    return "\n".join(lines)
