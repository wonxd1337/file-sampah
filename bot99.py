import subprocess
import time
import requests
import re

# ==========================================
# KONFIGURASI URL WEBSITE (GANTI URL INI)
# ==========================================
WEB_API_GET = "http://ez.mn/tmpl/feeds/feed/control/api.php?action=get_data"
WEB_API_POST = "http://ez.mn/tmpl/feeds/feed/control/api.php?action=update_status"

def run_root(cmd):
    try:
        res = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return res.stdout.strip()
    except:
        return ""

def get_target_packages(config):
    mode = config.get("package_mode", "prefix")
    val = config.get("package_val", "com.roblox")
    
    if mode == "manual":
        return [p.strip() for p in val.split(",") if p.strip()]
        
    out = run_root(f"pm list packages | grep '{val}'")
    pkgs = []
    if out:
        for line in out.splitlines():
            p = line.replace("package:", "").strip()
            if p: pkgs.append(p)
    return pkgs

def is_running(pkg):
    out = run_root(f"dumpsys window windows | grep {pkg}")
    return len(out) > 50

def force_stop(pkg):
    run_root(f"am force-stop {pkg}")
    
def start_game(pkg, place_id, private_code):
    if private_code and private_code.strip() != "":
        uri = f"https://www.roblox.com/share?code={private_code}&type=Server"
        print(f"[+] {pkg} -> Join Private Server")
    else:
        uri = f"roblox://placeId={place_id}"
        print(f"[+] {pkg} -> Join Public Game ({place_id})")
    run_root(f"am start -a android.intent.action.VIEW -d '{uri}' {pkg}")

def get_username(pkg):
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    return match.group(1) if match else "Unknown"

def format_playtime(seconds):
    return f"{seconds // 3600}jam {(seconds % 3600) // 60}mnt"

def main():
    print("[*] Termux Executor Started. Sinkronisasi dengan Web...")
    uptime_tracker = {}
    
    while True:
        # PENGHANCUR CACHE: Tambahkan timestamp ke URL get data
        current_time = int(time.time())
        cache_buster_url = f"{WEB_API_GET}&t={current_time}"
        
        try:
            req = requests.get(cache_buster_url, timeout=10)
            data = req.json()
            if isinstance(data, list): data = {} 
        except Exception as e:
            data = {"config": {}, "commands": {}}
            
        # FIX ERROR ATTRIBUTE: Paksa menjadi dictionary jika membaca list kosong
        config = data.get("config", {})
        if isinstance(config, list): config = {}
            
        commands = data.get("commands", {})
        if isinstance(commands, list): commands = {}
        
        packages = get_target_packages(config)
        current_status = {}

        for pkg in packages:
            cmd_data = commands.get(pkg, {})
            cmd = cmd_data.get("command", "STOP")
            place_id = cmd_data.get("place_id", config.get("place_id", ""))
            private_code = cmd_data.get("private_code", config.get("private_code", ""))
            
            running = is_running(pkg)
            
            if cmd == "START":
                if not running:
                    print(f"[!] {pkg} offline. Membuka game...")
                    start_game(pkg, place_id, private_code)
                    uptime_tracker[pkg] = int(time.time())
                    time.sleep(3)
                    
            elif cmd == "STOP":
                if running:
                    print(f"[-] {pkg} dihentikan.")
                    force_stop(pkg)
                    if pkg in uptime_tracker: del uptime_tracker[pkg]
                    
            elif cmd == "RERUN":
                print(f"[*] RERUN diminta untuk {pkg}...")
                force_stop(pkg)
                time.sleep(2)
                start_game(pkg, place_id, private_code)
                uptime_tracker[pkg] = int(time.time())
                
                cmd_data["command"] = "START" 
                commands[pkg] = cmd_data

            # STATUS & PLAYTIME
            running_now = is_running(pkg)
            playtime_text = "0jam 0mnt"
            
            if running_now and pkg in uptime_tracker:
                playtime_text = format_playtime(int(time.time()) - uptime_tracker[pkg])
            elif not running_now and pkg in uptime_tracker:
                del uptime_tracker[pkg]

            current_status[pkg] = {
                "username": get_username(pkg),
                "status": "Online" if running_now else "Offline",
                "playtime": playtime_text
            }

        try:
            requests.post(WEB_API_POST, json=current_status, timeout=10)
        except:
            pass

        time.sleep(10)

if __name__ == "__main__":
    main()
