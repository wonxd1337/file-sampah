import subprocess
import time
import re
import os
import asyncio
import websockets
import json

# URL WebSocket dari Cloudflare Anda
WS_URL = "wss://web-socket.abosok60.workers.dev/"
FILE_DIR = "/storage/emulated/0/Delta/Autoexecute"

cached_packages = []
cached_usernames = {}

def clear_screen():
    os.system('clear')

def run_root(cmd):
    try:
        res = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return res.stdout.strip()
    except:
        return ""

def get_all_packages():
    global cached_packages
    if not cached_packages:
        out = run_root("pm list packages | grep 'com.roblox'")
        if out:
            cached_packages = [line.replace("package:", "").strip() for line in out.splitlines() if line.strip()]
    return cached_packages

def get_running_packages():
    out = run_root("ps -A | grep com.roblox")
    running = []
    for line in out.splitlines():
        parts = line.split()
        if parts and 'com.roblox' in parts[-1]:
            running.append(parts[-1])
    return running

def force_stop(pkg):
    run_root(f"am force-stop {pkg}")

def start_game(pkg, mode, target):
    if mode == "private":
        uri = f"https://www.roblox.com/share?code={target}&type=Server" if "http" not in target else target
    else:
        uri = f"roblox://placeId={target}"
    run_root(f'am start -a android.intent.action.VIEW -d "{uri}" {pkg}')

def get_username(pkg):
    if pkg in cached_usernames and cached_usernames[pkg] != "Unknown":
        return cached_usernames[pkg]
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    username = match.group(1) if match else "Unknown"
    if username != "Unknown":
        cached_usernames[pkg] = username
    return username

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
                files.append({"name": item, "size": stat.st_size, "mtime": stat.st_mtime})
        return {"success": True, "data": files}
    except Exception as e:
        return {"success": False, "message": str(e)}

def edit_add_file(filename, content):
    try:
        filename = sanitize_filename(filename)
        os.makedirs(FILE_DIR, exist_ok=True)
        path = os.path.join(FILE_DIR, filename)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return {"success": True, "message": f"File {filename} disimpan"}
    except Exception as e:
        return {"success": False, "message": str(e)}

def delete_file(filename):
    try:
        filename = sanitize_filename(filename)
        path = os.path.join(FILE_DIR, filename)
        if os.path.exists(path):
            os.remove(path)
            return {"success": True, "message": f"File {filename} dihapus"}
        return {"success": False, "message": "File tidak ditemukan"}
    except Exception as e:
        return {"success": False, "message": str(e)}

async def connect_to_dashboard():
    clear_screen()
    print(f"Menyambungkan ke {WS_URL} ...")
    
    while True:
        try:
            async with websockets.connect(WS_URL) as ws:
                print("=======================================")
                print("[✓] TERHUBUNG KE DASHBOARD REAL-TIME!")
                print("Menunggu perintah...")
                print("=======================================\n")

                # Fungsi untuk mengirim status HP ke Dashboard
                async def send_status():
                    installed = get_all_packages()
                    running_pkgs = get_running_packages()
                    accounts_status = {}
                    
                    for pkg in installed:
                        accounts_status[pkg] = {
                            "running": pkg in running_pkgs,
                            "username": get_username(pkg)
                        }
                    
                    payload = {
                        "action": "sync_status",
                        "installed": installed,
                        "status_data": accounts_status
                    }
                    await ws.send(json.dumps(payload))

                # Kirim status pertama kali saat baru terkonek
                await send_status()

                # TUGAS BACKGROUND: Kirim status HP setiap 10 detik otomatis (sebagai Ping)
                async def ping_status():
                    while True:
                        await asyncio.sleep(10)
                        await send_status()
                
                ping_task = asyncio.create_task(ping_status())

                # TUGAS UTAMA: Mendengarkan perintah dari web
                async for message in ws:
                    try:
                        data = json.loads(message)
                        action = data.get("action")

                        if action == "command":
                            cmd = data.get("cmd")
                            pkg = data.get("pkg")
                            mode = data.get("mode", "public")
                            target = data.get("target", "")
                            content = data.get("content", "")

                            # ================= HANDLER AUTOEXECUTE =================
                            if pkg == '_file_manager':
                                res = {}
                                if cmd == "FILE_LIST":
                                    res = list_files()
                                elif cmd in ["FILE_ADD", "FILE_EDIT"]:
                                    res = edit_add_file(target, content)
                                elif cmd == "FILE_DELETE":
                                    res = delete_file(target)
                                
                                await ws.send(json.dumps({
                                    "action": "file_result",
                                    "operation": cmd,
                                    "success": res.get("success", False),
                                    "data": res.get("data", []),
                                    "message": res.get("message", "")
                                }))

                            # ================= HANDLER AKUN =================
                            else:
                                if cmd == "START":
                                    start_game(pkg, mode, target)
                                elif cmd == "STOP":
                                    force_stop(pkg)
                                elif cmd == "RERUN":
                                    force_stop(pkg)
                                    await asyncio.sleep(1.5) # Jeda agar Roblox tutup sempurna
                                    start_game(pkg, mode, target)
                                
                                # Broadcast notifikasi sukses dan update status
                                await ws.send(json.dumps({
                                    "action": "cmd_ack",
                                    "pkg": pkg,
                                    "cmd": cmd
                                }))
                                await asyncio.sleep(2)
                                await send_status()

                    except json.JSONDecodeError:
                        pass
                    except Exception as e:
                        print(f"Error proses perintah: {e}")

                ping_task.cancel() # Batalkan ping jika disconnect

        except Exception as e:
            print(f"[!] Terputus dari server. Mencoba ulang dalam 5 detik...")
            await asyncio.sleep(5)

if __name__ == "__main__":
    asyncio.run(connect_to_dashboard())
