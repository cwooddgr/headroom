from pathlib import Path

DATA_DIR = Path.home() / ".headroom"
DB_PATH = DATA_DIR / "headroom.db"
LOG_PATH = DATA_DIR / "headroom.log"

LAUNCHAGENT_LABEL = "com.dgrlabs.headroom"
LAUNCHAGENT_DIR = Path.home() / "Library" / "LaunchAgents"
LAUNCHAGENT_PATH = LAUNCHAGENT_DIR / f"{LAUNCHAGENT_LABEL}.plist"

METRICS_INTERVAL = 30      # seconds between macmon samples
PROCESS_INTERVAL = 300     # seconds between process snapshots
