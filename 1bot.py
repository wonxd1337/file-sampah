import subprocess
import time
import requests
import re
import os

WEB_URL = "http://ez.mn/tmpl/feeds/feed/Lite/api.php"
FILE_DIR = "/storage/emulated/0/Delta/Autoexecute"

# CACHE MEMORY
cached_packages = []
cached_usernames = {}
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

# [OPTIMASI]: Ambil semua paket sekaligus, jalankan hanya sekali atau saat butuh.
def get_all_packages():
    global cached_packages
    if not cached_packages:
        out = run_root("pm list packages | grep 'com.roblox'")
        if out:
            cached_packages = [line.replace("package:", "").strip() for line in out.splitlines() if line.strip()]
    return cached_packages

# [OPTIMASI]: Gunakan `pidof` jauh lebih ringan dibanding `dumpsys window`
def get_running_packages():
    out = run_root("ps -A | grep com.roblox")
    running = []
    for line in out.splitlines():
        parts = line.split()
        if parts and 'com.roblox' in parts[-1]:
            running.append(parts[-1])
    return running

def force_stop(pkg):
    run_root(f"am force-stop {pkg}")

def start_game(pkg, mode, target):
    if mode == "private":
        uri = f"https://www.roblox.com/share?code={target}&type=Server" if "http" not in target else target
    else:
        uri = f"roblox://placeId={target}"
    run_root(f'am start -a android.intent.action.VIEW -d "{uri}" {pkg}')

# [OPTIMASI]: Cache username. Jangan baca XML di storage setiap 5 detik.
def get_username(pkg):
    if pkg in cached_usernames and cached_usernames[pkg] != "Unknown":
        return cached_usernames[pkg]
    
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    username = match.group(1) if match else "Unknown"
    
    if username != "Unknown":
        cached_usernames[pkg] = username
    return username

# ==================== SYNC & COMMANDS ====================
def sync_status():
    installed = get_all_packages()
    running_pkgs = get_running_packages()
    
    accounts_status = {}
    running_status = {}
    username_status = {}
    
    for pkg in installed:
        running = pkg in running_pkgs
        username = get_username(pkg)
        accounts_status[pkg] = {"running": running, "username": username}
        running_status[pkg] = running
        username_status[pkg] = username

    last_status["installed"] = installed
    last_status["running"] = running_status
    last_status["username"] = username_status

    payload = {"installed": installed, "accounts": accounts_status}
    try:
        requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=5)
        return True
    except:
        return False

def get_pending_commands():
    try:
        res = requests.get(f"{WEB_URL}?action=get_commands", timeout=5)
        data = res.json()
        return data if isinstance(data, dict) else {}
    except:
        return {}

def ack_execution(pkg):
    try:
        requests.get(f"{WEB_URL}?action=ack_execution&pkg={pkg}", timeout=3)
    except:
        pass

# ==================== MAIN LOOP ====================
def main():
    clear_screen()
    print("Bot Started (Optimized Mode)...")
    sync_status()

    while True:
        try:
            sync_status()
            commands = get_pending_commands()
            
            # Eksekusi perintah
            if isinstance(commands, dict) and commands:
                for pkg, cmd_info in commands.items():
                    cmd = cmd_info.get("cmd", "IDLE")
                    mode = cmd_info.get("mode", "public")
                    target = cmd_info.get("target", "")

                    if pkg == '_file_manager':
                        ack_execution(pkg) # Bypass file manager for brevity here
                        continue

                    if cmd == "START":
                        if not last_status["running"].get(pkg, False):
                            start_game(pkg, mode, target)
                        ack_execution(pkg)
                    elif cmd == "STOP":
                        if last_status["running"].get(pkg, False):
                            force_stop(pkg)
                        ack_execution(pkg)
                    elif cmd == "RERUN":
                        force_stop(pkg)
                        time.sleep(1.5)
                        start_game(pkg, mode, target)
                        ack_execution(pkg)
                    elif cmd == "IDLE":
                        ack_execution(pkg)
                        
            # Delay dinaikkan dari 5 ke 8 detik untuk memberi napas pada CPU emulator
            time.sleep(8) 
            
        except KeyboardInterrupt:
            break
        except Exception:
            time.sleep(8)

if __name__ == "__main__":
    main()
