import time
import sys
from adb_utils import is_running, get_username, is_foreground
from delta_control import full_process, get_status
from utils import (
    bold, green, red, yellow, blue, cyan, get_status_color,
    clear_screen, print_header, print_info, print_error, print_success, print_warning,
    load_config, Colors
)

last_status = {}
last_username = {}
table_dirty = True

def print_table(packages, status, username_map, start_time, force=False):
    global table_dirty
    if not force and not table_dirty:
        return
    clear_screen()
    print_header()
    # Header tabel
    print(f"\n{Colors.BOLD}{'#':<3} {'Username':<20} {'Time':<12} {'Status':<10}{Colors.END}")
    print("=" * 55)
    for i, pkg in enumerate(packages, 1):
        elapsed = int(time.time() - start_time)
        h = elapsed // 3600
        m = (elapsed % 3600) // 60
        s = elapsed % 60
        time_str = f"{h}h{m:02d}m{s:02d}s"
        username = username_map.get(pkg, f"Account {i}")
        stat = status.get(pkg, "Unknown")
        colored_status = get_status_color(stat)
        # potong username jika terlalu panjang
        display_username = username[:20] if len(username) > 20 else username
        print(f"{i:<3} {display_username:<20} {bold(time_str):<12} {colored_status}")
    print("=" * 55)
    print_info(f"Monitoring {len(packages)} instances...")
    print_info(f"Last update: {time.strftime('%H:%M:%S')}")
    table_dirty = False

def monitor(packages, place_id, bot_token, channel_id, private_code=None, interval=10):
    global last_status, last_username, table_dirty
    start_time = time.time()
    status = {}
    username_map = {}

    print_info("Initializing monitoring...")
    for i, pkg in enumerate(packages):
        status[pkg] = "Unknown"
        uname = get_username(pkg)
        if uname:
            username_map[pkg] = uname
        else:
            username_map[pkg] = f"Account {i+1}"

    last_status = status.copy()
    last_username = username_map.copy()
    table_dirty = True
    print_table(packages, status, username_map, start_time, force=True)

    while True:
        changed = False
        for pkg in packages:
            new_status = get_status(pkg)
            if new_status != status.get(pkg):
                status[pkg] = new_status
                changed = True
                if new_status == "Offline":
                    print_warning(f"{pkg} offline, restarting...")
                    # restart
                    uname = full_process(pkg, place_id, bot_token, channel_id, private_code)
                    if uname and uname != "Unknown":
                        username_map[pkg] = uname
                    status[pkg] = get_status(pkg)
                    changed = True
            # cek username berubah
            new_uname = get_username(pkg)
            if new_uname and new_uname != username_map.get(pkg):
                username_map[pkg] = new_uname
                changed = True

        if changed:
            table_dirty = True
            print_table(packages, status, username_map, start_time, force=True)
        time.sleep(interval)