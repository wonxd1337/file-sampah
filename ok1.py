import subprocess
import time
import requests
import re
import os
from datetime import datetime

WEB_URL = "http://ez.mn/tmpl/feeds/feed/rob/api.php"

last_status = {
    "installed": [],
    "running": {},
    "username": {}
}

# ==================== FUNGSI UTAMA ====================
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
        return True, len(installed)
    except Exception:
        return False, len(installed)

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

# ==================== DRAW TABLE ====================
def draw_table(accounts, commands):
    clear_screen()
    
    # Lebar kolom
    col_num = 4
    col_user = 22
    col_pkg = 30
    col_status = 10
    col_cmd = 10
    
    # Total lebar
    total_width = col_num + col_user + col_pkg + col_status + col_cmd + 9
    
    # Header
    print("┌" + "─" * total_width + "┐")
    print("│" + " ROBLOX REMOTE CONTROLLER ".center(total_width) + "│")
    print("├" + "─" * total_width + "┤")
    
    # Header kolom
    header = f"│ # │ {'Username':<{col_user}}│ {'Package':<{col_pkg}}│ {'Status':<{col_status}}│ {'Cmd':<{col_cmd}}│"
    print(header)
    print("├" + "─" * total_width + "┤")
    
    # Data
    if not accounts:
        print("│" + " No accounts detected ".center(total_width) + "│")
    else:
        for idx, (pkg, data) in enumerate(accounts.items(), 1):
            username = data.get('username', 'Unknown')[:col_user-1]
            running = data.get('running', False)
            cmd_info = commands.get(pkg, {})
            cmd = cmd_info.get('cmd', 'IDLE')[:col_cmd-1]
            
            status_text = "🟢 ON" if running else "🔴 OFF"
            
            row = f"│ {idx:<2}│ {username:<{col_user}}│ {pkg:<{col_pkg}}│ {status_text:<{col_status}}│ {cmd:<{col_cmd}}│"
            print(row)
    
    print("└" + "─" * total_width + "┘")

# ==================== MAIN LOOP ====================
def main():
    # First sync
    sync_status()
    accounts = {pkg: {"username": last_status["username"].get(pkg, "Unknown"), 
                     "running": last_status["running"].get(pkg, False)} 
               for pkg in last_status["installed"]}
    
    loop_count = 0
    
    while True:
        try:
            # Ambil dan eksekusi perintah
            commands = get_pending_commands()
            
            if commands:
                for pkg, cmd_info in commands.items():
                    cmd = cmd_info.get("cmd", "IDLE")
                    mode = cmd_info.get("mode", "public")
                    target = cmd_info.get("target", "")
                    
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
                        time.sleep(2)
                        start_game(pkg, mode, target)
                        ack_execution(pkg)
                    elif cmd == "IDLE":
                        ack_execution(pkg)
                
                # Update status setelah eksekusi
                sync_status()
                accounts = {pkg: {"username": last_status["username"].get(pkg, "Unknown"), 
                                 "running": last_status["running"].get(pkg, False)} 
                           for pkg in last_status["installed"]}
            
            # Sync periodik setiap 2 loop
            loop_count += 1
            if loop_count % 2 == 0:
                sync_status()
                accounts = {pkg: {"username": last_status["username"].get(pkg, "Unknown"), 
                                 "running": last_status["running"].get(pkg, False)} 
                           for pkg in last_status["installed"]}
                loop_count = 0
            
            # Tampilkan tabel
            commands = get_pending_commands()
            draw_table(accounts, commands)
            
            time.sleep(3)
            
        except KeyboardInterrupt:
            print("\nBot stopped")
            break
        except Exception:
            time.sleep(3)

if __name__ == "__main__":
    main()
