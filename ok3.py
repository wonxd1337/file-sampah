# bot.py - Versi dengan tampilan tabel bersih seperti monitor.py
import subprocess
import time
import requests
import re
import os
import curses
from datetime import datetime

WEB_URL = "http://ez.mn/tmpl/feeds/feed/rob/api.php"
FILE_DIR = "/storage/emulated/0/Delta/Autoexecute"

last_status = {
    "installed": [],
    "running": {},
    "username": {}
}

def clear_screen():
    os.system('clear')

def run_root(cmd):
    try:
        res = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return res.stdout.strip()
    except:
        return ""

def get_all_packages():
    out = run_root("pm list packages | grep 'com.roblox'")
    pkgs = []
    if out:
        for line in out.splitlines():
            p = line.replace("package:", "").strip()
            if p:
                pkgs.append(p)
    return pkgs

def is_running(pkg):
    out = run_root(f"dumpsys window windows | grep {pkg}")
    return len(out) > 50

def force_stop(pkg):
    run_root(f"am force-stop {pkg}")

def start_game(pkg, mode, target):
    if mode == "private":
        if "http" not in target:
            uri = f"https://www.roblox.com/share?code={target}&type=Server"
        else:
            uri = target
    else:
        uri = f"roblox://placeId={target}"
    run_root(f"am start -a android.intent.action.VIEW -d '{uri}' {pkg}")

def get_username(pkg):
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    return match.group(1) if match else "Unknown"

# ==================== FILE OPERATIONS ====================
def sanitize_filename(filename):
    return os.path.basename(filename)

def list_files():
    try:
        if not os.path.exists(FILE_DIR):
            return {"success": True, "data": []}
        files = []
        for item in os.listdir(FILE_DIR):
            path = os.path.join(FILE_DIR, item)
            if os.path.isfile(path):
                stat = os.stat(path)
                files.append({
                    "name": item,
                    "size": stat.st_size,
                    "mtime": stat.st_mtime
                })
        return {"success": True, "data": files}
    except Exception as e:
        return {"success": False, "message": str(e)}

def add_file(filename, content):
    try:
        filename = sanitize_filename(filename)
        if not os.path.exists(FILE_DIR):
            os.makedirs(FILE_DIR, exist_ok=True)
        path = os.path.join(FILE_DIR, filename)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return {"success": True, "message": f"File {filename} created"}
    except Exception as e:
        return {"success": False, "message": str(e)}

def edit_file(filename, content):
    return add_file(filename, content)

def delete_file(filename):
    try:
        filename = sanitize_filename(filename)
        path = os.path.join(FILE_DIR, filename)
        if os.path.exists(path):
            os.remove(path)
            return {"success": True, "message": f"File {filename} deleted"}
        else:
            return {"success": False, "message": "File not found"}
    except Exception as e:
        return {"success": False, "message": str(e)}

# ==================== SYNC & COMMANDS ====================
def sync_status():
    installed = get_all_packages()
    accounts_status = {}
    running_status = {}
    username_status = {}
    for pkg in installed:
        running = is_running(pkg)
        username = get_username(pkg)
        accounts_status[pkg] = {"running": running, "username": username}
        running_status[pkg] = running
        username_status[pkg] = username

    last_status["installed"] = installed
    last_status["running"] = running_status
    last_status["username"] = username_status

    payload = {"installed": installed, "accounts": accounts_status}
    try:
        requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=10)
        return True
    except Exception:
        return False

def get_pending_commands():
    try:
        res = requests.get(f"{WEB_URL}?action=get_commands", timeout=10)
        data = res.json()
        if isinstance(data, list):
            return {}
        return data
    except Exception:
        return {}

def ack_execution(pkg):
    try:
        requests.get(f"{WEB_URL}?action=ack_execution&pkg={pkg}", timeout=5)
        return True
    except Exception:
        return False

def send_file_result(operation, success, data=None, message=""):
    try:
        requests.post(f"{WEB_URL}?action=file_result", json={
            "operation": operation,
            "success": success,
            "data": data or [],
            "message": message
        }, timeout=10)
    except Exception:
        pass

# ==================== UI dengan CURSES ====================
def draw_table(stdscr, packages, status_map, username_map, elapsed_time, commands_pending=0):
    curses.curs_set(0)
    stdscr.clear()
    h, w = stdscr.getmaxyx()
    
    if commands_pending > 0:
        info += f" | 📨 {commands_pending} commands"
    stdscr.addstr(1, 0, info[:w-1])
    stdscr.addstr(2, 0, "=" * min(w-1, 60))
    
    # Table header
    header = f"{'#':<3} {'Username':<20} {'Package':<25} {'Status':<8}"
    stdscr.addstr(3, 0, header[:w-1], curses.A_BOLD)
    stdscr.addstr(4, 0, "-" * min(w-1, 60))
    
    # Table content
    max_rows = min(len(packages), h - 8)
    if curses.has_colors():
        curses.start_color()
        curses.init_pair(1, curses.COLOR_GREEN, curses.COLOR_BLACK)
        curses.init_pair(2, curses.COLOR_RED, curses.COLOR_BLACK)
        curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLACK)
    
    for i in range(max_rows):
        pkg = packages[i]
        uname = username_map.get(pkg, "Unknown")
        stat = status_map.get(pkg, "Offline")
        is_online = stat == "Online"
        color = curses.color_pair(1) if is_online else curses.color_pair(2)
        
        # Shorten package name
        pkg_short = pkg[:24] + "..." if len(pkg) > 24 else pkg
        
        line = f"{i+1:<3} {uname[:18]:<20} {pkg_short:<25}"
        stdscr.addstr(i+5, 0, line[:w-1])
        status_text = " ON" if is_online else " OFF"
        stdscr.addstr(i+5, len(line), f" {status_text}", color)
    
    # Footer
    footer_y = max_rows + 6
    if footer_y < h - 2:
        stdscr.addstr(footer_y, 0, "-" * min(w-1, 60))
        stdscr.addstr(footer_y + 1, 0, footer[:w-1])
        stdscr.addstr(footer_y + 2, 0, "Press 'q' or ESC to exit")
    
    stdscr.refresh()

def monitor_curses(stdscr, interval=3):
    start_time = time.time()
    last_update = 0
    commands_processed = 0
    
    # Status tracking
    status_map = {}
    username_map = {}
    
    while True:
        key = stdscr.getch()
        if key in (ord('q'), ord('Q'), 27):
            break
        
        now = time.time()
        if now - last_update >= interval:
            last_update = now
            
            # Update status
            sync_status()
            packages = last_status["installed"]
            
            # Build status map
            for pkg in packages:
                running = last_status["running"].get(pkg, False)
                status_map[pkg] = "Online" if running else "Offline"
                username_map[pkg] = last_status["username"].get(pkg, "Unknown")
            
            # Check for commands
            commands = get_pending_commands()
            commands_pending = len(commands) if isinstance(commands, dict) else 0
            
            # Process commands (limited to prevent flooding)
            if commands_pending > 0 and commands_processed < 3:
                process_commands(commands)
                commands_processed += 1
                # Re-sync after processing
                sync_status()
                for pkg in packages:
                    running = last_status["running"].get(pkg, False)
                    status_map[pkg] = "Online" if running else "Offline"
                    username_map[pkg] = last_status["username"].get(pkg, "Unknown")
            else:
                commands_processed = 0
            
            # Calculate uptime
            elapsed = int(now - start_time)
            time_str = f"{elapsed//3600}h{elapsed%3600//60:02d}m{elapsed%60:02d}s"
            
            # Draw table
            draw_table(stdscr, packages, status_map, username_map, time_str, commands_pending)
        
        time.sleep(0.1)

def process_commands(commands):
    """Process commands with minimal logging"""
    if not isinstance(commands, dict):
        return
    
    for pkg, cmd_info in commands.items():
        cmd = cmd_info.get("cmd", "IDLE")
        mode = cmd_info.get("mode", "public")
        target = cmd_info.get("target", "")
        content = cmd_info.get("content", "")
        
        # File manager commands
        if pkg == '_file_manager':
            if cmd == "FILE_LIST":
                result = list_files()
                send_file_result("FILE_LIST", result["success"], result.get("data", []), result.get("message", ""))
            elif cmd == "FILE_ADD":
                result = add_file(target, content)
                send_file_result("FILE_ADD", result["success"], [], result.get("message", ""))
            elif cmd == "FILE_EDIT":
                result = edit_file(target, content)
                send_file_result("FILE_EDIT", result["success"], [], result.get("message", ""))
            elif cmd == "FILE_DELETE":
                result = delete_file(target)
                send_file_result("FILE_DELETE", result["success"], [], result.get("message", ""))
            else:
                send_file_result(cmd, False, [], "Unknown file command")
            ack_execution(pkg)
            continue
        
        # Game commands
        if cmd == "START":
            if not is_running(pkg):
                start_game(pkg, mode, target)
            ack_execution(pkg)
        elif cmd == "STOP":
            if is_running(pkg):
                force_stop(pkg)
            ack_execution(pkg)
        elif cmd == "RERUN":
            force_stop(pkg)
            time.sleep(1)
            start_game(pkg, mode, target)
            ack_execution(pkg)
        elif cmd == "IDLE":
            ack_execution(pkg)
        else:
            ack_execution(pkg)

# ==================== MAIN ====================
def main():
    clear_screen()
    print("Starting ROBLOX Remote Controller...")
    print("Loading...")
    time.sleep(1)
    
    # Initial sync
    sync_status()
    
    try:
        curses.wrapper(monitor_curses)
    except KeyboardInterrupt:
        pass
    except Exception as e:
        print(f"Error: {e}")
        time.sleep(2)
    finally:
        print("\nBot stopped.")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nBot stopped by user")
