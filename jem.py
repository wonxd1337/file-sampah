import subprocess
import time
import requests
import re

# Ganti dengan URL domain Anda
WEB_URL = "http://ez.mn/tmpl/feeds/feed/control/api.php"

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
        print(f"[+] {pkg} -> Join Private Server")
    else:
        uri = f"roblox://placeId={target}"
        print(f"[+] {pkg} -> Join Public Game (Place ID: {target})")
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
        res = requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=10)
        return res.json()
    except Exception as e:
        print(f"[-] Sync error: {e}")
        return None

def get_pending_commands():
    """Ambil perintah yang belum dieksekusi dari web"""
    try:
        res = requests.get(f"{WEB_URL}?action=get_commands", timeout=10)
        data = res.json()
        # Jika response berupa list kosong, ubah ke dict kosong
        if isinstance(data, list):
            return {}
        return data
    except Exception as e:
        print(f"[-] Get commands error: {e}")
        return {}

def ack_execution(pkg):
    """Kirim konfirmasi ke web bahwa perintah sudah dieksekusi (akan dihapus)"""
    try:
        requests.get(f"{WEB_URL}?action=ack_execution&pkg={pkg}", timeout=5)
        print(f"[+] Acknowledged execution for {pkg}")
    except Exception as e:
        print(f"[-] Ack error: {e}")

def main():
    print("[*] Termux Executor Started (loop mode).")
    print(f"[*] Web URL: {WEB_URL}")
    
    while True:
        try:
            # 1. Kirim status terbaru ke web
            print("[*] Syncing status...")
            sync_status()

            # 2. Ambil perintah yang pending (belum dieksekusi)
            commands = get_pending_commands()
            
            # 3. Pastikan commands adalah dict
            if not isinstance(commands, dict):
                print(f"[!] Warning: commands is {type(commands)}, not dict. Skipping...")
                time.sleep(5)
                continue
                
            if commands:
                print(f"[*] Found {len(commands)} pending command(s): {list(commands.keys())}")

            # 4. Eksekusi setiap perintah SEKALI lalu konfirmasi
            for pkg, cmd_info in commands.items():
                cmd = cmd_info.get("cmd", "STOP")
                mode = cmd_info.get("mode", "public")
                target = cmd_info.get("target", "")
                
                print(f"[*] Processing {pkg}: {cmd}")

                if cmd == "START":
                    if not is_running(pkg):
                        print(f"[!] {pkg} -> START")
                        start_game(pkg, mode, target)
                        ack_execution(pkg)
                    else:
                        print(f"[!] {pkg} already running, skipping START")
                        ack_execution(pkg)  # tetap hapus agar tidak diulang

                elif cmd == "STOP":
                    if is_running(pkg):
                        print(f"[-] {pkg} -> STOP")
                        force_stop(pkg)
                        ack_execution(pkg)
                    else:
                        print(f"[-] {pkg} not running, skipping STOP")
                        ack_execution(pkg)

                elif cmd == "RERUN":
                    print(f"[*] {pkg} -> RERUN")
                    force_stop(pkg)
                    time.sleep(2)
                    start_game(pkg, mode, target)
                    ack_execution(pkg)

                else:
                    print(f"[?] Unknown command {cmd} for {pkg}, acknowledging anyway")
                    ack_execution(pkg)

            # 5. Tunggu 5 detik sebelum loop berikutnya
            time.sleep(5)
            
        except Exception as e:
            print(f"[-] Error in main loop: {e}")
            import traceback
            traceback.print_exc()
            time.sleep(5)
            continue

if __name__ == "__main__":
    main()
