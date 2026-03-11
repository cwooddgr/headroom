import sqlite3
from .constants import DB_PATH, DATA_DIR


def get_connection(db_path=None):
    path = db_path or DB_PATH
    conn = sqlite3.connect(str(path), isolation_level=None)
    return conn


def init_db(db_path=None):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = get_connection(db_path)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS samples (
            id INTEGER PRIMARY KEY,
            timestamp TEXT NOT NULL,

            -- CPU
            cpu_e_cluster_pct REAL,
            cpu_p_cluster_pct REAL,
            cpu_freq_mhz_e INTEGER,
            cpu_freq_mhz_p INTEGER,
            cpu_power_watts REAL,

            -- GPU
            gpu_utilization_pct REAL,
            gpu_freq_mhz INTEGER,
            gpu_power_watts REAL,

            -- Neural Engine
            ane_power_watts REAL,

            -- Memory (swap/pressure/compression — NOT raw "memory used")
            memory_swap_used_bytes INTEGER,
            memory_pressure TEXT,
            memory_compressed_bytes INTEGER,
            memory_pageins INTEGER,
            memory_pageouts INTEGER,

            -- Thermal
            thermal_pressure TEXT,
            cpu_temp_avg REAL,
            gpu_temp_avg REAL,
            package_power_watts REAL,
            sys_power_watts REAL
        );

        CREATE TABLE IF NOT EXISTS process_snapshots (
            id INTEGER PRIMARY KEY,
            timestamp TEXT NOT NULL,
            pid INTEGER,
            process_name TEXT,
            cpu_pct REAL,
            memory_bytes INTEGER
        );

        CREATE TABLE IF NOT EXISTS system_info (
            key TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_samples_timestamp ON samples(timestamp);
        CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON process_snapshots(timestamp);
    """)
    conn.close()


def insert_sample(conn, data):
    conn.execute("""
        INSERT INTO samples (
            timestamp, cpu_e_cluster_pct, cpu_p_cluster_pct,
            cpu_freq_mhz_e, cpu_freq_mhz_p, cpu_power_watts,
            gpu_utilization_pct, gpu_freq_mhz, gpu_power_watts,
            ane_power_watts, memory_swap_used_bytes, memory_pressure,
            memory_compressed_bytes, memory_pageins, memory_pageouts,
            thermal_pressure, cpu_temp_avg, gpu_temp_avg,
            package_power_watts, sys_power_watts
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        data.get('timestamp'),
        data.get('cpu_e_cluster_pct'),
        data.get('cpu_p_cluster_pct'),
        data.get('cpu_freq_mhz_e'),
        data.get('cpu_freq_mhz_p'),
        data.get('cpu_power_watts'),
        data.get('gpu_utilization_pct'),
        data.get('gpu_freq_mhz'),
        data.get('gpu_power_watts'),
        data.get('ane_power_watts'),
        data.get('memory_swap_used_bytes'),
        data.get('memory_pressure'),
        data.get('memory_compressed_bytes'),
        data.get('memory_pageins'),
        data.get('memory_pageouts'),
        data.get('thermal_pressure'),
        data.get('cpu_temp_avg'),
        data.get('gpu_temp_avg'),
        data.get('package_power_watts'),
        data.get('sys_power_watts'),
    ))


def insert_process_snapshot(conn, timestamp, processes):
    conn.executemany(
        """INSERT INTO process_snapshots
           (timestamp, pid, process_name, cpu_pct, memory_bytes)
           VALUES (?, ?, ?, ?, ?)""",
        [(timestamp, p['pid'], p['name'], p['cpu_pct'], p['memory_bytes'])
         for p in processes]
    )


def set_system_info(conn, key, value):
    conn.execute(
        "INSERT OR REPLACE INTO system_info (key, value) VALUES (?, ?)",
        (key, str(value))
    )


def get_system_info(conn):
    rows = conn.execute("SELECT key, value FROM system_info").fetchall()
    return dict(rows)
