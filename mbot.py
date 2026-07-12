import subprocess
import time
import requests
import re
import sys
import os

# Ganti dengan URL domain Anda
WEB_URL = "http://ez.mn/tmpl/feeds/feed/control/api.php"

# Redirect stdout/stderr ke null untuk silent mode
if not os.isatty(sys.stdout.fileno()):
    sys.stdout = open(os.devnull, 'w')
    sys.stderr = open(os.devnull, 'w')

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
    for pkg in installed:
        accounts_status[pkg] = {
            "running": is_running(pkg),
            "username": get_username(pkg)
        }
    payload = {
        "installed": installed,
        "accounts": accounts_status
    }
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
    except Exception:
        pass

def main():
    # Silent loop - no output at all
    while True:
        try:
            # 1. Kirim status terbaru ke web
            sync_status()

            # 2. Ambil perintah yang pending
            commands = get_pending_commands()
            
            if not isinstance(commands, dict):
                time.sleep(5)
                continue
                
            # 3. Eksekusi setiap perintah
            for pkg, cmd_info in commands.items():
                cmd = cmd_info.get("cmd", "IDLE")
                mode = cmd_info.get("mode", "public")
                target = cmd_info.get("target", "")
                
                if cmd == "START":
                    if not is_running(pkg):
                        start_game(pkg, mode, target)
                        ack_execution(pkg)
                    else:
                        ack_execution(pkg)

                elif cmd == "STOP":
                    if is_running(pkg):
                        force_stop(pkg)
                        ack_execution(pkg)
                    else:
                        ack_execution(pkg)

                elif cmd == "RERUN":
                    force_stop(pkg)
                    time.sleep(2)
                    start_game(pkg, mode, target)
                    ack_execution(pkg)
                
                elif cmd == "IDLE":
                    # Hanya acknowledge tanpa melakukan apapun
                    ack_execution(pkg)

                else:
                    ack_execution(pkg)

            # 4. Tunggu 5 detik sebelum loop berikutnya
            time.sleep(5)
            
        except Exception:
            time.sleep(5)
            continue

if __name__ == "__main__":
    main()
