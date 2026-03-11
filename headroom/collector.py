import json
import logging
import signal
import subprocess
import sys
import time

from .constants import DATA_DIR, METRICS_INTERVAL, PROCESS_INTERVAL, LOG_PATH
from .db import get_connection, insert_sample, insert_process_snapshot
from .sources import (
    parse_macmon_line, read_vm_stat, read_memory_pressure,
    get_thermal_pressure, get_process_snapshot,
)

logger = logging.getLogger('headroom')


def setup_logging():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    handler = logging.FileHandler(LOG_PATH)
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.addHandler(logging.StreamHandler())


def run_collector():
    """Main collector loop — reads macmon pipe and enriches with vm_stat / memory_pressure."""
    setup_logging()
    logger.info("Headroom collector starting")

    running = True

    def handle_signal(signum, _frame):
        nonlocal running
        logger.info("Received signal %s, shutting down", signum)
        running = False

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    conn = get_connection()
    conn.execute("PRAGMA journal_mode=WAL")

    last_process_time = 0

    # Start macmon pipe
    try:
        macmon_proc = subprocess.Popen(
            ['macmon', 'pipe', '-i', str(METRICS_INTERVAL * 1000)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        logger.error("macmon not found. Install with: brew install vladkens/tap/macmon")
        sys.exit(1)

    logger.info("macmon pipe started (pid=%d, interval=%ds)", macmon_proc.pid, METRICS_INTERVAL)

    try:
        for line in macmon_proc.stdout:
            if not running:
                break

            line = line.strip()
            if not line:
                continue

            try:
                sample = parse_macmon_line(line)

                # Enrich with vm_stat data
                vm_data = read_vm_stat()
                sample.update(vm_data)

                # Memory pressure level
                sample['memory_pressure'] = read_memory_pressure()

                # Derive thermal pressure from CPU temp
                sample['thermal_pressure'] = get_thermal_pressure(
                    sample.get('cpu_temp_avg', 0)
                )

                insert_sample(conn, sample)

                # Process snapshot every PROCESS_INTERVAL seconds
                now = time.time()
                if now - last_process_time >= PROCESS_INTERVAL:
                    processes = get_process_snapshot()
                    if processes:
                        insert_process_snapshot(conn, sample['timestamp'], processes)
                    last_process_time = now
                    logger.info(
                        "Sample: CPU E=%.1f%% P=%.1f%% GPU=%.1f%% "
                        "Swap=%.0fMB Pressure=%s Temp=%.1f°C",
                        sample['cpu_e_cluster_pct'],
                        sample['cpu_p_cluster_pct'],
                        sample['gpu_utilization_pct'],
                        sample['memory_swap_used_bytes'] / (1024 ** 2),
                        sample['memory_pressure'],
                        sample['cpu_temp_avg'],
                    )

            except (json.JSONDecodeError, KeyError, ValueError) as e:
                logger.warning("Failed to parse sample: %s", e)
                continue
    finally:
        macmon_proc.terminate()
        try:
            macmon_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            macmon_proc.kill()
        conn.close()
        logger.info("Headroom collector stopped")
