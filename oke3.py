import subprocess
import time
import requests
import re
import os
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

def print_status(message, type="info"):
    timestamp = datetime.now().strftime("%H:%M:%S")
    icons = {
        "info": "ℹ️", "success": "✅", "error": "❌",
        "warning": "⚠️", "action": "⚡", "sync": "🔄", "idle": "💤"
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
    return add_file(filename, content)  # sama, overwrite

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

    status_changed = False
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

    for pkg in installed:
        current_running = running_status.get(pkg, False)
        last_running = last_status["running"].get(pkg, False)
        if current_running != last_running:
            status_changed = True
            username = username_status.get(pkg, "Unknown")
            status_text = "ONLINE" if current_running else "OFFLINE"
            print_status(f"{username} ({pkg}) is now {status_text}", "info")

    last_status["installed"] = installed
    last_status["running"] = running_status
    last_status["username"] = username_status

    payload = {"installed": installed, "accounts": accounts_status}
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

def send_file_result(operation, success, data=None, message=""):
    try:
        requests.post(f"{WEB_URL}?action=file_result", json={
            "operation": operation,
            "success": success,
            "data": data or [],
            "message": message
        }, timeout=10)
    except Exception as e:
        print_status(f"Failed to send file result: {str(e)}", "error")

# ==================== MAIN LOOP ====================
def main():
    clear_screen()
    print("=" * 60)
    print("  🤖 ROBLOX REMOTE CONTROLLER - TERMUX BOT")
    print("=" * 60)
    print_status(f"Connected to: {WEB_URL}", "info")
    print_status("Bot started. Waiting for commands...", "info")
    print("=" * 60)
    print()

    sync_status()
    loop_count = 0

    while True:
        try:
            loop_count += 1
            sync_status()
            commands = get_pending_commands()

            if not isinstance(commands, dict):
                time.sleep(5)
                continue

            if commands:
                print_status(f"📨 Received {len(commands)} command(s)", "action")
                for pkg, cmd_info in commands.items():
                    cmd = cmd_info.get("cmd", "IDLE")
                    mode = cmd_info.get("mode", "public")
                    target = cmd_info.get("target", "")
                    content = cmd_info.get("content", "")
                    username = last_status["username"].get(pkg, pkg)

                    # ----- FILE MANAGER COMMANDS -----
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

                    # ----- GAME COMMANDS -----
                    print_status(f"▶ Executing {cmd} on {username}", "action")
                    if cmd == "START":
                        if not is_running(pkg):
                            start_game(pkg, mode, target)
                            print_status(f"✓ {username} started successfully", "success")
                        else:
                            print_status(f"⚠ {username} already running, skipping START", "warning")
                        ack_execution(pkg)

                    elif cmd == "STOP":
                        if is_running(pkg):
                            force_stop(pkg)
                            print_status(f"✓ {username} stopped", "success")
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

                    time.sleep(1)
                    sync_status()
            else:
                if loop_count % 30 == 0:
                    running_count = sum(1 for r in last_status["running"].values() if r)
                    total_count = len(last_status["installed"])
                    print_status(f"💤 IDLE - {running_count}/{total_count} accounts online", "idle")
                    loop_count = 0

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
