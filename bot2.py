import subprocess
import time
import requests
import json
import re

# ==========================================
# KONFIGURASI URL WEBSITE
# ==========================================
WEB_API_GET = "http://ez.mn/tmpl/feeds/feed/control/api.php?action=get_commands"
WEB_API_POST = "http://ez.mn/tmpl/feeds/feed/control/api.php?action=update_status"

# ==========================================
# FUNGSI SISTEM ANDROID (ADB & ROOT)
# ==========================================
def run_root(cmd):
    """Mengeksekusi perintah shell Android dengan akses root[span_3](start_span)[span_3](end_span)."""
    try:
        result = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return result.stdout.strip()
    except:
        return ""

def get_roblox_packages():
    """Mencari semua package Roblox yang terinstal di perangkat[span_4](start_span)[span_4](end_span)."""
    out = run_root("pm list packages | grep 'com.roblox'")
    packages = []
    if out:
        for line in out.splitlines():
            pkg = line.replace("package:", "").strip()
            if pkg: 
                packages.append(pkg)
    return packages

def is_running(pkg):
    """Mengecek apakah aplikasi sedang berjalan di layar[span_5](start_span)[span_5](end_span)."""
    out = run_root(f"dumpsys window windows | grep {pkg}")
    return len(out) > 50

def force_stop(pkg):
    """Mematikan paksa aplikasi."""
    run_root(f"am force-stop {pkg}")
    
def start_game(pkg, place_id, private_code):
    """Membuka game dan langsung masuk ke server menggunakan Deep Link[span_6](start_span)[span_6](end_span)[span_7](start_span)[span_7](end_span)."""
    if private_code and private_code.strip() != "":
        # Menggunakan Private Server
        uri = f"https://www.roblox.com/share?code={private_code}&type=Server"
        print(f"[+] {pkg} -> Join Private Server: {private_code}")
    else:
        # Menggunakan Public Server (Place ID)
        uri = f"roblox://placeId={place_id}"
        print(f"[+] {pkg} -> Join Public Game: {place_id}")
        
    run_root(f"am start -a android.intent.action.VIEW -d '{uri}' {pkg}")

def get_username(pkg):
    """Membaca username akun yang sedang login dari file sistem secara diam-diam[span_8](start_span)[span_8](end_span)."""
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    if match: 
        return match.group(1)
    return "Unknown"

def format_playtime(seconds):
    """Mengonversi detik menjadi format Jam dan Menit."""
    hh = seconds // 3600
    mm = (seconds % 3600) // 60
    return f"{hh}jam {mm}mnt"

# ==========================================
# PROGRAM UTAMA (LOOPING KONTROL)
# ==========================================
def main():
    print("[*] Multi-Account Bot Started...")
    
    # Dictionary untuk menyimpan waktu mulai (uptime) masing-masing package
    uptime_tracker = {}
    
    while True:
        packages = get_roblox_packages()
        
        # 1. Ambil instruksi terbaru dari Website
        try:
            req = requests.get(WEB_API_GET, timeout=10)
            commands = req.json()
        except:
            commands = {}
            
        current_status = {}

        # 2. Proses eksekusi untuk setiap akun
        for pkg in packages:
            # Ambil instruksi spesifik untuk package ini (default: STOP)
            cmd_data = commands.get(pkg, {"command": "STOP", "place_id": "", "private_code": ""})
            cmd = cmd_data.get("command", "STOP")
            place_id = cmd_data.get("place_id", "")
            private_code = cmd_data.get("private_code", "")
            
            running = is_running(pkg)
            
            # --- LOGIKA EKSEKUSI ---
            if cmd == "START":
                if not running:
                    print(f"[!] {pkg} mati. Menyalakan...")
                    start_game(pkg, place_id, private_code)
                    uptime_tracker[pkg] = int(time.time())
                    time.sleep(3) # Jeda agar perangkat tidak freeze saat membuka banyak game
                    
            elif cmd == "STOP":
                if running:
                    print(f"[-] Menghentikan {pkg}...")
                    force_stop(pkg)
                    if pkg in uptime_tracker: 
                        del uptime_tracker[pkg]
                    
            elif cmd == "RERUN":
                print(f"[*] RERUN diminta untuk {pkg}...")
                force_stop(pkg)
                time.sleep(2)
                start_game(pkg, place_id, private_code)
                uptime_tracker[pkg] = int(time.time())
                
                # Ubah memori lokal agar tidak Rerun terus-menerus
                commands[pkg]["command"] = "START" 

            # --- PEMBARUAN STATUS & PLAYTIME ---
            running_now = is_running(pkg)
            status_text = "Online" if running_now else "Offline"
            playtime_text = "0jam 0mnt"
            
            if running_now and pkg in uptime_tracker:
                seconds_active = int(time.time()) - uptime_tracker[pkg]
                playtime_text = format_playtime(seconds_active)
            elif not running_now:
                if pkg in uptime_tracker: 
                    del uptime_tracker[pkg]

            uname = get_username(pkg)

            # Simpan data status akun ini untuk dilaporkan
            current_status[pkg] = {
                "username": uname,
                "status": status_text,
                "playtime": playtime_text
            }

        # 3. Kirim semua laporan status kembali ke Website
        try:
            requests.post(WEB_API_POST, json=current_status, timeout=10)
        except Exception as e:
            print(f"[-] Gagal mengirim laporan ke web: {e}")

        # 4. Jeda sistem sebelum siklus berikutnya (Hemat CPU)
        time.sleep(10)

if __name__ == "__main__":
    main()
