import json
import os
import re
import subprocess
from datetime import datetime, timezone


def parse_macmon_line(line):
    """Parse a single JSON line from macmon pipe."""
    data = json.loads(line)

    ecpu_freq, ecpu_util = data.get('ecpu_usage', [0, 0])
    pcpu_freq, pcpu_util = data.get('pcpu_usage', [0, 0])
    gpu_freq, gpu_util = data.get('gpu_usage', [0, 0])
    memory = data.get('memory', {})
    temp = data.get('temp', {})

    return {
        'timestamp': data.get('timestamp', datetime.now(timezone.utc).isoformat()),
        'cpu_e_cluster_pct': ecpu_util * 100,
        'cpu_p_cluster_pct': pcpu_util * 100,
        'cpu_freq_mhz_e': int(ecpu_freq),
        'cpu_freq_mhz_p': int(pcpu_freq),
        'cpu_power_watts': data.get('cpu_power', 0),
        'gpu_utilization_pct': gpu_util * 100,
        'gpu_freq_mhz': int(gpu_freq),
        'gpu_power_watts': data.get('gpu_power', 0),
        'ane_power_watts': data.get('ane_power', 0),
        'memory_swap_used_bytes': memory.get('swap_usage', 0),
        'cpu_temp_avg': temp.get('cpu_temp_avg', 0),
        'gpu_temp_avg': temp.get('gpu_temp_avg', 0),
        'package_power_watts': data.get('all_power', 0),
        'sys_power_watts': data.get('sys_power', 0),
    }


def read_vm_stat():
    """Read vm_stat for memory compression and paging metrics."""
    try:
        output = subprocess.check_output(['vm_stat'], text=True)
        stats = {}

        page_size_match = re.search(r'page size of (\d+) bytes', output)
        page_size = int(page_size_match.group(1)) if page_size_match else 16384

        for line in output.strip().split('\n'):
            match = re.match(r'^(.+?):\s+([\d.]+)', line)
            if match:
                key = match.group(1).strip().strip('"').lower()
                value = int(match.group(2).rstrip('.'))
                stats[key] = value

        compressed_pages = stats.get('pages stored in compressor', 0)

        return {
            'memory_compressed_bytes': compressed_pages * page_size,
            'memory_pageins': stats.get('pageins', 0),
            'memory_pageouts': stats.get('pageouts', 0),
        }
    except Exception:
        return {}


def read_memory_pressure():
    """Read memory pressure level via memory_pressure -Q."""
    try:
        output = subprocess.check_output(
            ['/usr/bin/memory_pressure', '-Q'],
            text=True, stderr=subprocess.DEVNULL
        )
        match = re.search(r'free percentage:\s*(\d+)%', output)
        if match:
            pct = int(match.group(1))
            if pct >= 50:
                return 'normal'
            elif pct >= 25:
                return 'warn'
            else:
                return 'critical'
    except Exception:
        pass
    return 'unknown'


def get_thermal_pressure(cpu_temp):
    """Derive thermal pressure category from CPU temperature."""
    if cpu_temp < 70:
        return 'nominal'
    elif cpu_temp < 85:
        return 'moderate'
    elif cpu_temp < 95:
        return 'heavy'
    else:
        return 'critical'


def get_process_snapshot(top_n=15):
    """Get top processes by CPU and memory usage."""
    try:
        output = subprocess.check_output(
            ['ps', '-eo', 'pid,rss,pcpu,comm', '-r'],
            text=True, stderr=subprocess.DEVNULL
        )
        processes = []
        for line in output.strip().split('\n')[1:]:  # skip header
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            try:
                pid = int(parts[0])
                rss_kb = int(parts[1])
                cpu_pct = float(parts[2])
            except ValueError:
                continue
            name = os.path.basename(parts[3])

            if cpu_pct < 0.1 and rss_kb < 10240:
                continue

            processes.append({
                'pid': pid,
                'name': name,
                'cpu_pct': cpu_pct,
                'memory_bytes': rss_kb * 1024,
            })

        # Sort by combined CPU + memory weight
        processes.sort(
            key=lambda p: p['cpu_pct'] + p['memory_bytes'] / (1024 ** 2),
            reverse=True
        )
        return processes[:top_n]
    except Exception:
        return []


def collect_system_info():
    """Collect static system information (run once at install)."""
    info = {}

    for key, cmd in [
        ('chip', ['sysctl', '-n', 'machdep.cpu.brand_string']),
        ('model', ['sysctl', '-n', 'hw.model']),
        ('ncpu', ['sysctl', '-n', 'hw.ncpu']),
    ]:
        try:
            info[key] = subprocess.check_output(cmd, text=True).strip()
        except Exception:
            info[key] = 'unknown'

    try:
        mem_bytes = int(subprocess.check_output(
            ['sysctl', '-n', 'hw.memsize'], text=True
        ).strip())
        info['total_ram_gb'] = str(round(mem_bytes / (1024 ** 3)))
    except Exception:
        info['total_ram_gb'] = 'unknown'

    try:
        profiler = subprocess.check_output(
            ['system_profiler', 'SPHardwareDataType'],
            text=True, stderr=subprocess.DEVNULL
        )
        for line in profiler.split('\n'):
            line = line.strip()
            if 'Model Name' in line:
                info['model_name'] = line.split(':', 1)[1].strip()
            elif 'Total Number of Cores' in line:
                info['core_details'] = line.split(':', 1)[1].strip()
            elif 'GPU' in line and 'Core' in line:
                match = re.search(r'(\d+)-Core GPU', line)
                if match:
                    info['gpu_cores'] = match.group(1)
    except Exception:
        pass

    try:
        info['macos_version'] = subprocess.check_output(
            ['sw_vers', '-productVersion'], text=True
        ).strip()
    except Exception:
        info['macos_version'] = 'unknown'

    return info
