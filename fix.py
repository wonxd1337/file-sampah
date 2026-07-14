import subprocess
import time
import requests
import re
import os
from datetime import datetime

# Ganti dengan URL domain Anda
WEB_URL = "http://ez.mn/tmpl/feeds/feed/rob/api.php"

# Untuk tracking status terakhir agar tidak spam
last_status = {
    "installed": [],
    "running": {},
    "username": {}
}

def clear_screen():
    os.system('clear')

def print_status(message, type="info"):
    timestamp = datetime.now().strftime("%H:%M:%S")
    icons = {
        "info": "ℹ️",
        "success": "✅",
        "error": "❌",
        "warning": "⚠️",
        "action": "⚡",
        "sync": "🔄",
        "idle": "💤"
    }
    icon = icons.get(type, "ℹ️")
    print(f"[{timestamp}] {icon} {message}")

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

def sync_status():
    installed = get_all_packages()
    accounts_status = {}
    running_status = {}
    username_status = {}
    
    for pkg in installed:
        running = is_running(pkg)
        username = get_username(pkg)
        accounts_status[pkg] = {
            "running": running,
            "username": username
        }
        running_status[pkg] = running
        username_status[pkg] = username
    
    # Cek apakah ada perubahan status
    status_changed = False
    
    # Cek perubahan installed packages
    if set(installed) != set(last_status["installed"]):
        status_changed = True
        if len(installed) > len(last_status["installed"]):
            new_pkgs = set(installed) - set(last_status["installed"])
            for pkg in new_pkgs:
                print_status(f"Detected new account: {username_status.get(pkg, pkg)} ({pkg})", "success")
        elif len(installed) < len(last_status["installed"]):
            removed_pkgs = set(last_status["installed"]) - set(installed)
            for pkg in removed_pkgs:
                print_status(f"Account removed: {last_status['username'].get(pkg, pkg)} ({pkg})", "warning")
    
    # Cek perubahan running status
    for pkg in installed:
        current_running = running_status.get(pkg, False)
        last_running = last_status["running"].get(pkg, False)
        if current_running != last_running:
            status_changed = True
            username = username_status.get(pkg, "Unknown")
            status_text = "ONLINE" if current_running else "OFFLINE"
            print_status(f"{username} ({pkg}) is now {status_text}", "info")
    
    # Update last_status
    last_status["installed"] = installed
    last_status["running"] = running_status
    last_status["username"] = username_status
    
    # Kirim ke web
    payload = {
        "installed": installed,
        "accounts": accounts_status
    }
    try:
        requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=10)
        if status_changed:
            print_status(f"Status synced to server ({len(installed)} accounts)", "sync")
        return True
    except Exception as e:
        print_status(f"Sync failed: {str(e)}", "error")
        return False

def get_pending_commands():
    try:
        res = requests.get(f"{WEB_URL}?action=get_commands", timeout=10)
        data = res.json()
        if isinstance(data, list):
            return {}
        return data
    except Exception as e:
        print_status(f"Failed to get commands: {str(e)}", "error")
        return {}

def ack_execution(pkg):
    try:
        requests.get(f"{WEB_URL}?action=ack_execution&pkg={pkg}", timeout=5)
        return True
    except Exception:
        return False

def main():
    clear_screen()
    print("=" * 60)
    print("  🤖 ROBLOX REMOTE CONTROLLER - TERMUX BOT")
    print("=" * 60)
    print_status(f"Connected to: {WEB_URL}", "info")
    print_status("Bot started. Waiting for commands...", "info")
    print("=" * 60)
    print()
    
    # Initial sync
    print_status("Initial sync...", "sync")
    sync_status()
    print()
    
    loop_count = 0
    
    while True:
        try:
            loop_count += 1
            
            # 1. Kirim status terbaru ke web (hanya jika ada perubahan)
            sync_status()

            # 2. Ambil perintah yang pending
            commands = get_pending_commands()
            
            if not isinstance(commands, dict):
                time.sleep(5)
                continue
                
            # 3. Eksekusi setiap perintah
            if commands:
                print_status(f"📨 Received {len(commands)} command(s)", "action")
                for pkg, cmd_info in commands.items():
                    cmd = cmd_info.get("cmd", "IDLE")
                    mode = cmd_info.get("mode", "public")
                    target = cmd_info.get("target", "")
                    username = last_status["username"].get(pkg, pkg)
                    
                    print_status(f"▶ Executing {cmd} on {username}", "action")
                    
                    if cmd == "START":
                        if not is_running(pkg):
                            start_game(pkg, mode, target)
                            print_status(f"✓ {username} started successfully", "success")
                            ack_execution(pkg)
                        else:
                            print_status(f"⚠ {username} already running, skipping START", "warning")
                            ack_execution(pkg)

                    elif cmd == "STOP":
                        if is_running(pkg):
                            force_stop(pkg)
                            print_status(f"✓ {username} stopped", "success")
                            ack_execution(pkg)
                        else:
                            print_status(f"⚠ {username} not running, skipping STOP", "warning")
                            ack_execution(pkg)

                    elif cmd == "RERUN":
                        print_status(f"⟳ Restarting {username}...", "action")
                        force_stop(pkg)
                        time.sleep(2)
                        start_game(pkg, mode, target)
                        print_status(f"✓ {username} restarted", "success")
                        ack_execution(pkg)
                    
                    elif cmd == "IDLE":
                        print_status(f"💤 {username} set to IDLE (no action)", "idle")
                        ack_execution(pkg)

                    else:
                        print_status(f"⚠ Unknown command {cmd} for {username}", "warning")
                        ack_execution(pkg)
                    
                    # Update status setelah eksekusi
                    time.sleep(1)
                    sync_status()
            else:
                # Hanya tampilkan status idle setiap 30 loop (sekitar 2.5 menit)
                if loop_count % 30 == 0:
                    running_count = sum(1 for r in last_status["running"].values() if r)
                    total_count = len(last_status["installed"])
                    print_status(f"💤 IDLE - {running_count}/{total_count} accounts online", "idle")
                    loop_count = 0

            # 4. Tunggu 5 detik sebelum loop berikutnya
            time.sleep(5)
            
        except KeyboardInterrupt:
            print()
            print_status("Bot stopped by user", "warning")
            break
        except Exception as e:
            print_status(f"Error in main loop: {str(e)}", "error")
            time.sleep(5)
            continue

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        print_status("Bot stopped", "warning")
