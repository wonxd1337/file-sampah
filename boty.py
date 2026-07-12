import subprocess
import time
import requests
import re

# ==========================================
# KONFIGURASI URL WEBSITE
# ==========================================
# Ganti dengan URL domain Anda
WEB_URL = "http://ez.mn/tmpl/feeds/feed/control/api.php"

def run_root(cmd):
    try:
        res = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return res.stdout.strip()
    except:
        return ""

def get_all_packages():
    """Scan semua package roblox yang terinstal."""
    out = run_root("pm list packages | grep 'com.roblox'")
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

def start_game(pkg, mode, target):
    """Mengeksekusi game berdasarkan pilihan Public/Private."""
    if mode == "private":
        # Jika user memasukkan kode mentah, tambahkan linknya. Jika sudah berupa link utuh, biarkan saja.
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

def main():
    print("[*] Termux Executor Started. Sinkronisasi dengan Web...")
    
    while True:
        # 1. SCAN PACKAGES & AMBIL STATUS
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

        # 2. KIRIM STATUS SEKALIGUS MINTA PERINTAH VIA 'POST' (100% BYPASS CACHE)
        try:
            res = requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=10)
            commands = res.json()
        except Exception as e:
            print(f"[-] Gagal terhubung ke web: {e}")
            commands = {}

        if isinstance(commands, list): 
            commands = {}

        # 3. EKSEKUSI PERINTAH DARI WEB
        for pkg, cmd_info in commands.items():
            cmd = cmd_info.get("cmd", "STOP")
            mode = cmd_info.get("mode", "public")
            target = cmd_info.get("target", "")
            
            # Cek status asli dari device
            running = accounts_status.get(pkg, {}).get("running", False)
            
            if cmd == "START":
                if not running and target != "":
                    print(f"[!] {pkg} offline. Membuka game...")
                    start_game(pkg, mode, target)
                    time.sleep(3)
                    
            elif cmd == "STOP":
                if running:
                    print(f"[-] Menghentikan {pkg}...")
                    force_stop(pkg)
                    
            elif cmd == "RERUN":
                print(f"[*] RERUN diminta untuk {pkg}...")
                force_stop(pkg)
                time.sleep(2)
                start_game(pkg, mode, target)
                time.sleep(3)
                
                # Konfirmasi ke web bahwa RERUN sudah selesai, ubah status web kembali ke START
                try:
                    requests.get(f"{WEB_URL}?action=ack_rerun&pkg={pkg}", timeout=5)
                except:
                    pass

        # Jeda 5 detik
        time.sleep(5)

if __name__ == "__main__":
    main()
