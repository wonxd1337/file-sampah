import subprocess
import time
import json
import re
import os
import threading
import websocket

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
        uri = f"[https://www.roblox.com/share?code=](https://www.roblox.com/share?code=){target}&type=Server" if "http" not in target else target
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

# ==================== FILE MANAGER ====================
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
        return {"success": True, "message": f"File {filename} saved"}
    except Exception as e:
        return {"success": False, "message": str(e)}

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

def send_file_result(ws, operation, success, data=None, message=""):
    payload = {
        "type": "FILE_RESULT",
        "operation": operation,
        "success": success,
        "data": data or [],
        "message": message
    }
    ws.send(json.dumps(payload))

# ==================== WEBSOCKET HANDLERS ====================
def sync_status(ws):
    while True:
        try:
            installed = get_all_packages()
            running_pkgs = get_running_packages()
            
            accounts_status = {}
            for pkg in installed:
                accounts_status[pkg] = {
                    "running": pkg in running_pkgs,
                    "username": get_username(pkg)
                }

            payload = {
                "type": "SYNC",
                "installed": installed,
                "accounts": accounts_status,
                "timestamp": int(time.time())
            }
            ws.send(json.dumps(payload))
        except Exception:
            pass
        time.sleep(3) # Broadcast status setiap 3 detik ke UI

def on_message(ws, message):
    try:
        data = json.loads(message)
        msg_type = data.get("type")
        
        if msg_type == "COMMAND":
            pkg = data.get("pkg")
            cmd = data.get("cmd")
            mode = data.get("mode", "public")
            target = data.get("target", "")
            content = data.get("content", "")
            
            # --- TANGANI FILE MANAGER ---
            if pkg == '_file_manager':
                if cmd == "FILE_LIST":
                    res = list_files()
                    send_file_result(ws, "FILE_LIST", res["success"], res.get("data"), res.get("message"))
                elif cmd in ["FILE_ADD", "FILE_EDIT"]:
                    res = add_file(target, content)
                    send_file_result(ws, cmd, res["success"], [], res.get("message"))
                elif cmd == "FILE_DELETE":
                    res = delete_file(target)
                    send_file_result(ws, "FILE_DELETE", res["success"], [], res.get("message"))
                return

            # --- TANGANI ROBLOX ACCOUNT ---
            if cmd == "START":
                start_game(pkg, mode, target)
            elif cmd == "STOP":
                force_stop(pkg)
            elif cmd == "RERUN":
                force_stop(pkg)
                time.sleep(1.5)
                start_game(pkg, mode, target)
                
            # Berikan sinyal ACK ke UI bahwa perintah selesai
            ws.send(json.dumps({"type": "ACK", "pkg": pkg, "cmd": "IDLE"}))
            
    except Exception as e:
        print(f"Error handling message: {e}")

def on_open(ws):
    print("Berhasil terhubung ke WebSocket Cloudflare!")
    threading.Thread(target=sync_status, args=(ws,), daemon=True).start()

def main():
    clear_screen()
    print("Menghubungkan ke WebSocket Server...")
    
    while True:
        try:
            ws = websocket.WebSocketApp(WS_URL,
                                      on_open=on_open,
                                      on_message=on_message)
            ws.run_forever()
        except Exception:
            pass
        print("Koneksi terputus. Mencoba ulang dalam 5 detik...")
        time.sleep(5)

if __name__ == "__main__":
    main()
