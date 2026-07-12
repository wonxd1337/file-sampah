# bot.py (modified)

import subprocess
import time
import requests
import re
import sys
from datetime import datetime

# ========== KONFIGURASI ==========
WEB_URL = "http://ez.mn/tmpl/feeds/feed/control/api.php"   # Ganti dengan domain Anda
INTERVAL = 5   # detik, bisa diubah
MAX_RETRY_START = 3
# =================================

def log(msg):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {msg}")
    # Opsional: tulis ke file
    # with open("bot.log", "a") as f:
    #     f.write(f"[{timestamp}] {msg}\n")

def run_root(cmd):
    try:
        res = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return res.stdout.strip()
    except Exception as e:
        log(f"run_root error: {e}")
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
    """Mengeksekusi game berdasarkan mode, dengan retry."""
    if mode == "private":
        if "http" not in target:
            uri = f"https://www.roblox.com/share?code={target}&type=Server"
        else:
            uri = target
        log(f"[+] {pkg} -> Join Private Server: {uri}")
    else:
        uri = f"roblox://placeId={target}"
        log(f"[+] {pkg} -> Join Public Game (Place ID: {target})")

    cmd = f"am start -a android.intent.action.VIEW -d '{uri}' {pkg}"
    for attempt in range(MAX_RETRY_START):
        out = run_root(cmd)
        # Cek apakah muncul error "Error type 3" atau "Activity not started"
        if "Error" not in out:
            log(f"[+] {pkg} start command sent (attempt {attempt+1})")
            # Tunggu sebentar dan cek running
            time.sleep(3)
            if is_running(pkg):
                return True
            else:
                log(f"[!] {pkg} not running after start, retrying...")
        else:
            log(f"[-] {pkg} start failed: {out}")
        time.sleep(2)
    log(f"[!] Gagal menjalankan {pkg} setelah {MAX_RETRY_START} percobaan.")
    return False

def get_username(pkg):
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    if match:
        return match.group(1)
    # fallback
    out2 = run_root(f"grep -r username /data/data/{pkg}/shared_prefs/ 2>/dev/null | head -1")
    match2 = re.search(r'<string name="username">([^<]+)</string>', out2)
    return match2.group(1) if match2 else "Unknown"

def main():
    log("Termux Executor Started. Sinkronisasi dengan Web...")
    
    while True:
        try:
            # 1. Scan packages & status
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

            # 2. Kirim status & minta perintah
            try:
                res = requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=10)
                if res.status_code == 200:
                    commands = res.json()
                    if not isinstance(commands, dict):
                        commands = {}
                else:
                    log(f"[-] Web response error: {res.status_code}")
                    commands = {}
            except requests.exceptions.RequestException as e:
                log(f"[-] Gagal terhubung ke web: {e}")
                commands = {}

            # 3. Eksekusi perintah
            for pkg, cmd_info in commands.items():
                cmd = cmd_info.get("cmd", "STOP")
                mode = cmd_info.get("mode", "public")
                target = cmd_info.get("target", "")

                # Validasi target untuk START
                if cmd in ("START", "RERUN") and not target:
                    log(f"[!] Perintah {cmd} untuk {pkg} tidak memiliki target, dilewati.")
                    continue

                running = accounts_status.get(pkg, {}).get("running", False)

                if cmd == "START":
                    if not running:
                        log(f"[!] {pkg} offline. Menjalankan START...")
                        success = start_game(pkg, mode, target)
                        if success:
                            log(f"[+] {pkg} berhasil di-start.")
                        else:
                            log(f"[-] {pkg} gagal di-start.")
                    else:
                        log(f"[i] {pkg} sudah online, START diabaikan.")

                elif cmd == "STOP":
                    if running:
                        log(f"[-] Menghentikan {pkg}...")
                        force_stop(pkg)
                        time.sleep(1)
                    else:
                        log(f"[i] {pkg} sudah offline, STOP diabaikan.")

                elif cmd == "RERUN":
                    log(f"[*] RERUN diminta untuk {pkg}...")
                    force_stop(pkg)
                    time.sleep(2)
                    success = start_game(pkg, mode, target)
                    if success:
                        log(f"[+] {pkg} RERUN sukses.")
                    else:
                        log(f"[-] {pkg} RERUN gagal.")
                    # Konfirmasi ke web bahwa RERUN selesai
                    try:
                        ack_url = f"{WEB_URL}?action=ack_rerun&pkg={pkg}"
                        requests.get(ack_url, timeout=5)
                        log(f"[*] RERUN dikonfirmasi ke web untuk {pkg}.")
                    except Exception as e:
                        log(f"[-] Gagal konfirmasi RERUN: {e}")

            # Jeda
            time.sleep(INTERVAL)

        except KeyboardInterrupt:
            log("Dihentikan oleh pengguna.")
            break
        except Exception as e:
            log(f"[-] Error utama: {e}")
            time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
