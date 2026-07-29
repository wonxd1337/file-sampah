import subprocess
import time
import requests
import re
import os
import uuid

WEB_URL = "http://ez.mn/tmpl/feeds/feed/rob/api.php"
FILE_DIR = "/storage/emulated/0/Delta/Autoexecute"

cached_packages = []
cached_usernames = {}
last_status = {
    "installed": [],
    "running": {},
    "username": {}
}

def get_device_id():
    if os.path.exists('.device_id'):
        with open('.device_id', 'r') as f: 
            return f.read().strip()
    did = "DEV-" + str(uuid.uuid4())[:6].upper()
    with open('.device_id', 'w') as f: 
        f.write(did)
    return did

def get_device_info():
    try:
        res_cpu = subprocess.run("grep -c ^processor /proc/cpuinfo", shell=True, capture_output=True, text=True)
        cpu_count = res_cpu.stdout.strip()
        cpu = f"{cpu_count} Cores" if cpu_count.isdigit() else "Unknown"

        res_ram = subprocess.run("awk '/MemTotal/ {print $2}' /proc/meminfo", shell=True, capture_output=True, text=True)
        ram_raw = res_ram.stdout.strip()
        ram = f"{int(ram_raw) // 1024} MB" if ram_raw.isdigit() else "Unknown"

        res_df = subprocess.run("df /data | tail -n 1 | awk '{print $2}'", shell=True, capture_output=True, text=True)
        df_raw = res_df.stdout.strip()
        if df_raw.isdigit():
            kb = int(df_raw)
            storage = f"{kb // (1024 * 1024)} GB" if kb > 1024 * 1024 else f"{kb // 1024} MB"
        else:
            storage = "Unknown"

        return f"CPU: {cpu} | RAM: {ram} | INT: {storage}"
    except Exception:
        return "Unknown Specs"

DEVICE_ID = get_device_id()
DEVICE_INFO = get_device_info()

def clear_screen(): os.system('clear')

def run_root(cmd):
    try:
        res = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return res.stdout.strip()
    except: return ""

def get_all_packages():
    global cached_packages
    if not cached_packages:
        out = run_root("pm list packages | grep 'com.roblox'")
        if out: cached_packages = [line.replace("package:", "").strip() for line in out.splitlines() if line.strip()]
    return cached_packages

def get_running_packages():
    installed_packages = get_all_packages()
    running = []
    for pkg in installed_packages:
        pid_out = run_root(f"pidof {pkg}")
        if pid_out:
            first_pid = pid_out.split()[0]
            # Validasi mutlak menggunakan cgroup kernel Android
            cgroup_out = run_root(f"cat /proc/{first_pid}/cgroup 2>/dev/null")
            if "cpuset:/foreground" in cgroup_out or "cpuset:/top-app" in cgroup_out:
                running.append(pkg)
    return running

def force_stop(pkg): run_root(f"am force-stop {pkg}")

def start_game(pkg, mode, target):
    if mode == "private":
        uri = f"https://www.roblox.com/share?code={target}&type=Server" if "http" not in target else target
    else:
        uri = f"roblox://placeId={target}"
    run_root(f'am start -a android.intent.action.VIEW -d "{uri}" {pkg}')

def get_username(pkg):
    if pkg in cached_usernames and cached_usernames[pkg] != "Unknown": return cached_usernames[pkg]
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    username = match.group(1) if match else "Unknown"
    if username != "Unknown": cached_usernames[pkg] = username
    return username

# ================= FITUR FILE MANAGER =================
def sanitize_filename(filename): return os.path.basename(filename)

def list_files():
    try:
        if not os.path.exists(FILE_DIR): return {"success": True, "data": []}
        files = []
        for item in os.listdir(FILE_DIR):
            path = os.path.join(FILE_DIR, item)
            if os.path.isfile(path):
                stat = os.stat(path)
                files.append({"name": item, "size": stat.st_size, "mtime": stat.st_mtime})
        return {"success": True, "data": files}
    except Exception as e: return {"success": False, "message": str(e)}

def add_file(filename, content):
    try:
        filename = sanitize_filename(filename)
        os.makedirs(FILE_DIR, exist_ok=True)
        with open(os.path.join(FILE_DIR, filename), 'w', encoding='utf-8') as f:
            f.write(content)
        return {"success": True, "message": f"File {filename} created"}
    except Exception as e: return {"success": False, "message": str(e)}

def edit_file(filename, content): return add_file(filename, content)

def delete_file(filename):
    try:
        path = os.path.join(FILE_DIR, sanitize_filename(filename))
        if os.path.exists(path):
            os.remove(path)
            return {"success": True, "message": f"File deleted"}
        return {"success": False, "message": "File not found"}
    except Exception as e: return {"success": False, "message": str(e)}

def send_file_result(operation, success, data=None, message=""):
    try:
        requests.post(f"{WEB_URL}?action=file_result", json={
            "device_id": DEVICE_ID,
            "operation": operation, 
            "success": success, 
            "data": data or [], 
            "message": message
        }, timeout=10)
    except: pass
# =======================================================

def sync_status():
    installed = get_all_packages()
    running_info = get_running_packages()
    accounts_status = {}
    
    for pkg in installed:
        status_code = running_info.get(pkg, 0)
        accounts_status[pkg] = {"running": status_code, "username": get_username(pkg)}

    payload = {
        "device_id": DEVICE_ID,
        "device_info": DEVICE_INFO,
        "installed": installed, 
        "accounts": accounts_status
    }
    try:
        requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=5)
        return True
    except: return False

def get_pending_commands():
    try:
        res = requests.get(f"{WEB_URL}?action=get_commands&device_id={DEVICE_ID}", timeout=5)
        return res.json() if isinstance(res.json(), dict) else {}
    except: return {}
    
def read_file(filename):
    try:
        path = os.path.join(FILE_DIR, sanitize_filename(filename))
        if os.path.exists(path):
            with open(path, 'r', encoding='utf-8') as f:
                content = f.read()
            return {"success": True, "data": content}
        return {"success": False, "message": "File not found"}
    except Exception as e: 
        return {"success": False, "message": str(e)}       

def ack_execution(pkg):
    try: requests.get(f"{WEB_URL}?action=ack_execution&device_id={DEVICE_ID}&pkg={pkg}", timeout=3)
    except: pass

def main():
    clear_screen()
    print(f"READY! ID: {DEVICE_ID} | {DEVICE_INFO}")
    sync_status()

    while True:
        try:
            sync_status()
            data = get_pending_commands()
            
            if isinstance(data, dict):
                commands = data.get("commands", {})
                is_auto_rejoin = data.get("auto_rejoin", False)
            else:
                commands = {}
                is_auto_rejoin = False
            
            if isinstance(commands, dict) and commands:
                for pkg, cmd_info in commands.items():
                    cmd = cmd_info.get("cmd", "IDLE")
                    mode = cmd_info.get("mode", "public")
                    target = cmd_info.get("target", "")
                    content = cmd_info.get("content", "")

                    if pkg == '_file_manager':
                        if cmd == "FILE_LIST":
                            res = list_files()
                            send_file_result("FILE_LIST", res["success"], res.get("data", []), res.get("message", ""))
                        elif cmd == "FILE_ADD":
                            res = add_file(target, content)
                            send_file_result("FILE_ADD", res["success"], [], res.get("message", ""))
                        elif cmd == "FILE_EDIT":
                            res = edit_file(target, content)
                            send_file_result("FILE_EDIT", res["success"], [], res.get("message", ""))
                        elif cmd == "FILE_DELETE":
                            res = delete_file(target)
                            send_file_result("FILE_DELETE", res["success"], [], res.get("message", ""))
                        elif cmd == "FILE_READ":
                            res = read_file(target)
                            send_file_result("FILE_READ", res["success"], res.get("data", ""), res.get("message", ""))
                        
                        ack_execution(pkg)
                        continue

                    if cmd in ["START", "STOP", "RERUN"]:
                        print(f"[{time.strftime('%H:%M:%S')}] Executing {cmd} for {pkg} on {DEVICE_ID}...")

                    if cmd == "START":
                        start_game(pkg, mode, target)
                        ack_execution(pkg)
                        
                        if is_auto_rejoin:
                            print(f"⏳ Auto Rejoin ON: Jeda 15 detik sebelum eksekusi akun berikutnya...")
                            time.sleep(15.0)

                    elif cmd == "STOP":
                        force_stop(pkg)
                        ack_execution(pkg)
                        time.sleep(1.0)

                    elif cmd == "RERUN":
                        force_stop(pkg)
                        time.sleep(2.0)
                        start_game(pkg, mode, target)
                        ack_execution(pkg)
                        
                        if is_auto_rejoin:
                            print(f"⏳ Auto Rejoin ON: Jeda 15 detik setelah RERUN...")
                            time.sleep(15.0)

                    elif cmd == "IDLE":
                        ack_execution(pkg)
                        
            time.sleep(8) 
        except KeyboardInterrupt: break
        except Exception as e: 
            time.sleep(8)

if __name__ == "__main__": main()
