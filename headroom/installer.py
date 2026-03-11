import os
import subprocess
import sys
from pathlib import Path

from .constants import (
    DATA_DIR, DB_PATH, LAUNCHAGENT_LABEL, LAUNCHAGENT_DIR, LAUNCHAGENT_PATH,
)
from .db import init_db, get_connection, set_system_info
from .sources import collect_system_info


PLIST_TEMPLATE = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{python}</string>
        <string>-m</string>
        <string>headroom</string>
        <string>collect</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{log_dir}/headroom-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>{log_dir}/headroom-launchd.err</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityBackgroundIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
    <key>WorkingDirectory</key>
    <string>{working_dir}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{path}</string>
    </dict>
</dict>
</plist>
"""


def install():
    """Set up headroom: check deps, create database, record system info, install LaunchAgent."""
    print("Installing headroom...")

    # Check for macmon
    if not _command_exists('macmon'):
        print("macmon not found. Installing via Homebrew...")
        try:
            subprocess.run(['brew', 'install', 'vladkens/tap/macmon'], check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print("ERROR: Could not install macmon. Install manually:")
            print("  brew install vladkens/tap/macmon")
            sys.exit(1)

    # Create database
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    init_db()
    print(f"  Database: {DB_PATH}")

    # Record system info
    conn = get_connection()
    info = collect_system_info()
    for key, value in info.items():
        set_system_info(conn, key, value)
    conn.close()

    print(f"  System: {info.get('chip', '?')} / {info.get('total_ram_gb', '?')}GB / "
          f"{info.get('model_name', info.get('model', '?'))}")

    # Install and start LaunchAgent
    _install_launchagent()

    print()
    print("Headroom is now collecting data in the background.")
    print("Run 'headroom status' to verify, 'headroom analyze' after a few hours of usage.")


def _install_launchagent():
    """Create and load the LaunchAgent plist."""
    python_path = sys.executable

    import headroom
    pkg_dir = str(Path(headroom.__file__).parent.parent)

    # Include current PATH so LaunchAgent can find Homebrew binaries (macmon)
    env_path = os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin')
    # Ensure common Homebrew paths are included
    for brew_path in ['/opt/homebrew/bin', '/usr/local/bin']:
        if brew_path not in env_path:
            env_path = brew_path + ':' + env_path

    plist_content = PLIST_TEMPLATE.format(
        label=LAUNCHAGENT_LABEL,
        python=python_path,
        log_dir=str(DATA_DIR),
        working_dir=pkg_dir,
        path=env_path,
    )

    LAUNCHAGENT_DIR.mkdir(parents=True, exist_ok=True)

    # Unload existing if present
    _unload_launchagent()

    LAUNCHAGENT_PATH.write_text(plist_content)
    print(f"  LaunchAgent: {LAUNCHAGENT_PATH}")

    subprocess.run(['launchctl', 'load', str(LAUNCHAGENT_PATH)], check=False)
    print("  Daemon started.")


def uninstall(keep_data=False):
    """Remove LaunchAgent and optionally delete collected data."""
    print("Uninstalling headroom...")

    _unload_launchagent()

    if LAUNCHAGENT_PATH.exists():
        LAUNCHAGENT_PATH.unlink()
        print(f"  Removed {LAUNCHAGENT_PATH}")

    if not keep_data:
        for f in DATA_DIR.glob('*'):
            f.unlink()
        if DATA_DIR.exists():
            DATA_DIR.rmdir()
            print(f"  Removed {DATA_DIR}")
    else:
        print(f"  Data preserved at {DATA_DIR}")

    print("Headroom uninstalled.")


def _unload_launchagent():
    if LAUNCHAGENT_PATH.exists():
        subprocess.run(
            ['launchctl', 'unload', str(LAUNCHAGENT_PATH)],
            check=False, capture_output=True,
        )


def _command_exists(cmd):
    try:
        subprocess.run(['which', cmd], check=True, capture_output=True)
        return True
    except subprocess.CalledProcessError:
        return False
