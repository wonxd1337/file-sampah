import subprocess
import time
import requests
import json
import re

WEB_API_GET = "http://ez.mn/tmpl/feeds/feed/control/api.php?action=get_commands"
WEB_API_POST = "http://ez.mn/tmpl/feeds/feed/control/api.php?action=update_status"

def run_root(cmd):
    """Eksekusi perintah root[span_1](start_span)[span_1](end_span)"""
    try:
        result = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return result.stdout.strip()
    except:
        return ""

def get_roblox_packages():
    """Mencari semua package roblox otomatis[span_2](start_span)[span_2](end_span)[span_3](start_span)[span_3](end_span)"""
    out = run_root("pm list packages | grep 'com.roblox'")
    packages = []
    if out:
        for line in out.splitlines():
            pkg = line.replace("package:", "").strip()
            if pkg: packages.append(pkg)
    return packages

def is_running(pkg):
    """Cek apakah game jalan[span_4](start_span)[span_4](end_span)"""
    out = run_root(f"dumpsys window windows | grep {pkg}")
    return len(out) > 50

def force_stop(pkg):
    run_root(f"am force-stop {pkg}")
    
def start_game(pkg, place_id, private_code):
    """Membuka game menggunakan Place ID atau Private Server Code."""
    if private_code and private_code.strip() != "":
        # Jika private_code diisi, gunakan link private server
        uri = f"https://www.roblox.com/share?code={private_code}&type=Server"
        print(f"[+] {pkg} -> Join Private Server: {private_code}")
    else:
        # Jika private_code kosong, gunakan Place ID biasa
        uri = f"roblox://placeId={place_id}"
        print(f"[+] {pkg} -> Join Public Game (Place ID): {place_id}")
        
    # Eksekusi URL
    run_root(f"am start -a android.intent.action.VIEW -d '{uri}' {pkg}")

def get_username(pkg):
    """Ambil username dari file XML android diam-diam[span_5](start_span)[span_5](end_span)"""
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    if match: return match.group(1)
    return "Unknown"

def format_playtime(seconds):
    hh = seconds // 3600
    mm = (seconds % 3600) // 60
    return f"{hh}jam {mm}mnt"

def main():
    print("[*] Multi-Account Bot Started...")
    uptime_tracker = {}
    
    while True:
        packages = get_roblox_packages()
        
        try:
            req = requests.get(WEB_API_GET, timeout=10)
            commands = req.json()
        except:
            commands = {}
            
        current_status = {}

        for pkg in packages:
            # Ambil data perintah dari web, berikan nilai default jika kosong
            cmd_data = commands.get(pkg, {"command": "STOP", "place_id": "", "private_code": ""})
            cmd = cmd_data.get("command", "STOP")
            place_id = cmd_data.get("place_id", "")
            private_code = cmd_data.get("private_code", "") # Ambil Private Code
            
            running = is_running(pkg)
            
            if cmd == "START":
                if not running:
                    print(f"[!] {pkg} mati. Menyalakan...")
                    # Masukkan argumen private_code
                    start_game(pkg, place_id, private_code) 
                    uptime_tracker[pkg] = int(time.time())
                    time.sleep(3)
                    
            elif cmd == "STOP":
                if running:
                    force_stop(pkg)
                    if pkg in uptime_tracker: del uptime_tracker[pkg]
                    
            elif cmd == "RERUN":
                print(f"[*] RERUN diminta untuk {pkg}...")
                force_stop(pkg)
                time.sleep(2)
                # Masukkan argumen private_code
                start_game(pkg, place_id, private_code)
                uptime_tracker[pkg] = int(time.time())
                commands[pkg]["command"] = "START" 

            # ... (bagian menghitung playtime dan lapor status ke web tetap sama seperti sebelumnya) ...
            
            running_now = is_running(pkg)
            status_text = "Online" if running_now else "Offline"
            playtime_text = "0jam 0mnt"
            
            if running_now and pkg in uptime_tracker:
                seconds_active = int(time.time()) - uptime_tracker[pkg]
                playtime_text = format_playtime(seconds_active)
            elif not running_now:
                if pkg in uptime_tracker: del uptime_tracker[pkg]

            uname = get_username(pkg)

            current_status[pkg] = {
                "username": uname,
                "status": status_text,
                "playtime": playtime_text
            }

        try:
            requests.post(WEB_API_POST, json=current_status, timeout=10)
        except Exception as e:
            pass

        time.sleep(10)

if __name__ == "__main__":
    main()
