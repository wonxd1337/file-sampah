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
    pass  # no-op

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

def get_dashboard_data():
    try:
        res = requests.get(f"{WEB_URL}?action=get_dashboard_data", timeout=5)
        return res.json()
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

# ==================== TABLE DISPLAY ====================
def print_table(commands):
    installed = last_status["installed"]
    if not installed:
        print("No Roblox accounts found.")
        return

    headers = ["Username", "Package", "Status", "Command"]
    rows = []
    for pkg in installed:
        username = last_status["username"].get(pkg, "Unknown")
        running = last_status["running"].get(pkg, False)
        status_str = "Online" if running else "Offline"
        cmd_info = commands.get(pkg)
        cmd = cmd_info.get("cmd", "IDLE") if cmd_info else "IDLE"
        rows.append((username, pkg, status_str, cmd))

    col_widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            col_widths[i] = max(col_widths[i], len(cell))

    border = "+" + "+".join("-" * (w + 2) for w in col_widths) + "+"
    header_line = "| " + " | ".join(f"{h:<{col_widths[i]}}" for i, h in enumerate(headers)) + " |"
    row_lines = []
    for row in rows:
        row_lines.append("| " + " | ".join(f"{cell:<{col_widths[i]}}" for i, cell in enumerate(row)) + " |")

    clear_screen()
    print(border)
    print(header_line)
    print(border)
    for line in row_lines:
        print(line)
    print(border)

# ==================== MAIN LOOP ====================
def main():
    clear_screen()
    sync_status()

    while True:
        try:
            sync_status()
            commands = get_pending_commands()
            print_table(commands)

            # ---- AUTO REJOIN ----
            dashboard = get_dashboard_data()
            if dashboard.get('auto_rejoin', False):
                all_commands = dashboard.get('commands', {})
                for pkg in last_status["installed"]:
                    # Jika offline dan memiliki target tersimpan
                    if not last_status["running"].get(pkg, False):
                        cmd_info = all_commands.get(pkg, {})
                        target = cmd_info.get('target', '')
                        if target:
                            mode = cmd_info.get('mode', 'public')
                            print(f"[AutoRejoin] Starting {pkg} with target {target}")
                            start_game(pkg, mode, target)
                            time.sleep(1)

            # ---- PROSES PERINTAH DARI DASHBOARD ----
            if isinstance(commands, dict) and commands:
                for pkg, cmd_info in commands.items():
                    cmd = cmd_info.get("cmd", "IDLE")
                    mode = cmd_info.get("mode", "public")
                    target = cmd_info.get("target", "")
                    content = cmd_info.get("content", "")
                    username = last_status["username"].get(pkg, pkg)

                    # FILE MANAGER
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

                    # GAME COMMANDS
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
                    else:
                        ack_execution(pkg)

                    time.sleep(1)

            time.sleep(5)

        except KeyboardInterrupt:
            print()
            break
        except Exception:
            time.sleep(5)
            continue

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
