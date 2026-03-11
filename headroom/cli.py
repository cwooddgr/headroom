import argparse
import sqlite3
import subprocess
import sys

from .constants import DB_PATH, DATA_DIR, LAUNCHAGENT_PATH


def main():
    parser = argparse.ArgumentParser(
        prog='headroom',
        description='Monitor your Mac hardware usage and get upgrade recommendations.',
    )
    sub = parser.add_subparsers(dest='command')

    sub.add_parser('install', help='Set up headroom and start collecting data')

    p_uninstall = sub.add_parser('uninstall', help='Stop collecting and remove headroom')
    p_uninstall.add_argument(
        '--keep-data', action='store_true',
        help='Keep collected data after uninstalling',
    )

    p_analyze = sub.add_parser('analyze', help='Generate analysis report')
    p_analyze.add_argument(
        '-o', '--output', type=str, default=None,
        help='Write report to file instead of stdout',
    )

    sub.add_parser('status', help='Show collection status')
    sub.add_parser('collect', help=argparse.SUPPRESS)  # internal: used by LaunchAgent

    args = parser.parse_args()

    if args.command == 'install':
        from .installer import install
        install()

    elif args.command == 'uninstall':
        from .installer import uninstall
        uninstall(keep_data=args.keep_data)

    elif args.command == 'analyze':
        from .analyzer import analyze
        report = analyze()
        if args.output:
            with open(args.output, 'w') as f:
                f.write(report)
            print(f"Report written to {args.output}")
        else:
            print(report)

    elif args.command == 'collect':
        from .db import init_db
        from .collector import run_collector
        init_db()
        run_collector()

    elif args.command == 'status':
        _show_status()

    else:
        parser.print_help()


def _show_status():
    print("Headroom Status")
    print("=" * 40)

    if DB_PATH.exists():
        conn = sqlite3.connect(str(DB_PATH))
        conn.row_factory = sqlite3.Row

        row = conn.execute(
            "SELECT COUNT(*) as cnt, MIN(timestamp) as first_ts, "
            "MAX(timestamp) as last_ts FROM samples"
        ).fetchone()
        print(f"Database: {DB_PATH}")
        print(f"Samples:  {row['cnt']:,}")
        if row['cnt'] > 0:
            print(f"First:    {row['first_ts']}")
            print(f"Latest:   {row['last_ts']}")

        proc_count = conn.execute(
            "SELECT COUNT(DISTINCT timestamp) FROM process_snapshots"
        ).fetchone()[0]
        print(f"Process snapshots: {proc_count:,}")

        db_size = DB_PATH.stat().st_size
        print(f"DB size:  {db_size / (1024 * 1024):.1f} MB")
        conn.close()
    else:
        print("Database: not found (run 'headroom install' first)")

    if LAUNCHAGENT_PATH.exists():
        result = subprocess.run(
            ['launchctl', 'list', 'com.dgrlabs.headroom'],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            print("Daemon:   running")
        else:
            print("Daemon:   installed but not running")
    else:
        print("Daemon:   not installed")
