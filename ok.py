import subprocess
import time
import requests
import re
import os
import json
import base64
from datetime import datetime

# Ganti dengan URL domain Anda
WEB_URL = "http://ez.mn/tmpl/feeds/feed/rob/api.php"

# Untuk tracking status terakhir agar tidak spam
last_status = {
    "installed": [],
    "running": {},
    "username": {}
}

# Konfigurasi direktori file
AUTOEXEC_DIR = "/storage/emulated/0/Delta/Autoexecute"

def clear_screen():
    os.system('clear')

def print_status(message, type="info"):
    timestamp = datetime.now().strftime("%H:%M:%S")
    icons = {
        "info": "ℹ️",
        "success": "✅",
        "error": "❌",
        "warning": "⚠️",
        "action": "⚡",
        "sync": "🔄",
        "idle": "💤",
        "file": "📁",
        "download": "📥",
        "upload": "📤",
        "edit": "✏️",
        "delete": "🗑️"
    }
    icon = icons.get(type, "ℹ️")
    print(f"[{timestamp}] {icon} {message}")

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

# ==================== FILE MANAGEMENT FUNCTIONS ====================

def ensure_directory():
    """Pastikan direktori Autoexecute ada"""
    if not os.path.exists(AUTOEXEC_DIR):
        try:
            os.makedirs(AUTOEXEC_DIR, exist_ok=True)
            print_status(f"Created directory: {AUTOEXEC_DIR}", "file")
            return True
        except Exception as e:
            print_status(f"Failed to create directory: {str(e)}", "error")
            return False
    return True

def list_files():
    """Dapatkan daftar file di direktori Autoexecute"""
    if not ensure_directory():
        return []
    
    try:
        files = os.listdir(AUTOEXEC_DIR)
        result = []
        for f in files:
            full_path = os.path.join(AUTOEXEC_DIR, f)
            if os.path.isfile(full_path):
                result.append({
                    'name': f,
                    'size': os.path.getsize(full_path),
                    'type': 'file',
                    'modified': int(os.path.getmtime(full_path)),
                    'is_executable': os.access(full_path, os.X_OK)
                })
            elif os.path.isdir(full_path):
                result.append({
                    'name': f,
                    'size': 0,
                    'type': 'directory',
                    'modified': int(os.path.getmtime(full_path)),
                    'is_executable': False
                })
        return result
    except Exception as e:
        print_status(f"Error listing files: {str(e)}", "error")
        return []

def get_file_content(filename):
    """Baca isi file"""
    # Proteksi directory traversal
    if '..' in filename or filename.startswith('/'):
        return {'error': 'Invalid filename'}
    
    path = os.path.join(AUTOEXEC_DIR, filename)
    if not os.path.exists(path) or not os.path.isfile(path):
        return {'error': 'File not found'}
    
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        return {'content': content, 'size': len(content)}
    except Exception as e:
        return {'error': str(e)}

def save_file(filename, content, is_base64=False):
    """Simpan file"""
    # Proteksi directory traversal
    if '..' in filename or filename.startswith('/'):
        return {'error': 'Invalid filename'}
    
    if not ensure_directory():
        return {'error': 'Directory not accessible'}
    
    path = os.path.join(AUTOEXEC_DIR, filename)
    
    try:
        # Decode base64 jika perlu
        if is_base64:
            content = base64.b64decode(content)
            mode = 'wb'
        else:
            mode = 'w'
        
        with open(path, mode) as f:
            f.write(content)
        
        print_status(f"File saved: {filename}", "file")
        return {'success': True}
    except Exception as e:
        return {'error': str(e)}

def delete_file(filename):
    """Hapus file"""
    # Proteksi directory traversal
    if '..' in filename or filename.startswith('/'):
        return {'error': 'Invalid filename'}
    
    path = os.path.join(AUTOEXEC_DIR, filename)
    if not os.path.exists(path) or not os.path.isfile(path):
        return {'error': 'File not found'}
    
    try:
        os.remove(path)
        print_status(f"File deleted: {filename}", "delete")
        return {'success': True}
    except Exception as e:
        return {'error': str(e)}

def download_file(filename):
    """Download file dari URL (untuk import file)"""
    # Implementasi jika diperlukan
    pass

# ==================== SYNC FUNCTIONS ====================

def sync_status():
    installed = get_all_packages()
    accounts_status = {}
    running_status = {}
    username_status = {}
    
    for pkg in installed:
        running = is_running(pkg)
        username = get_username(pkg)
        accounts_status[pkg] = {
            "running": running,
            "username": username
        }
        running_status[pkg] = running
        username_status[pkg] = username
    
    # Cek apakah ada perubahan status
    status_changed = False
    
    # Cek perubahan installed packages
    if set(installed) != set(last_status["installed"]):
        status_changed = True
        if len(installed) > len(last_status["installed"]):
            new_pkgs = set(installed) - set(last_status["installed"])
            for pkg in new_pkgs:
                print_status(f"Detected new account: {username_status.get(pkg, pkg)} ({pkg})", "success")
        elif len(installed) < len(last_status["installed"]):
            removed_pkgs = set(last_status["installed"]) - set(installed)
            for pkg in removed_pkgs:
                print_status(f"Account removed: {last_status['username'].get(pkg, pkg)} ({pkg})", "warning")
    
    # Cek perubahan running status
    for pkg in installed:
        current_running = running_status.get(pkg, False)
        last_running = last_status["running"].get(pkg, False)
        if current_running != last_running:
            status_changed = True
            username = username_status.get(pkg, "Unknown")
            status_text = "ONLINE" if current_running else "OFFLINE"
            print_status(f"{username} ({pkg}) is now {status_text}", "info")
    
    # Update last_status
    last_status["installed"] = installed
    last_status["running"] = running_status
    last_status["username"] = username_status
    
    # Kirim ke web
    payload = {
        "installed": installed,
        "accounts": accounts_status
    }
    try:
        requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=10)
        if status_changed:
            print_status(f"Status synced to server ({len(installed)} accounts)", "sync")
        return True
    except Exception as e:
        print_status(f"Sync failed: {str(e)}", "error")
        return False

def get_pending_commands():
    try:
        res = requests.get(f"{WEB_URL}?action=get_commands", timeout=10)
        data = res.json()
        if isinstance(data, list):
            return {}
        return data
    except Exception as e:
        print_status(f"Failed to get commands: {str(e)}", "error")
        return {}

def ack_execution(pkg):
    try:
        requests.get(f"{WEB_URL}?action=ack_execution&pkg={pkg}", timeout=5)
        return True
    except Exception:
        return False

# ==================== MAIN LOOP ====================

def main():
    clear_screen()
    print("=" * 60)
    print("  🤖 ROBLOX REMOTE CONTROLLER - TERMUX BOT")
    print("=" * 60)
    print_status(f"Connected to: {WEB_URL}", "info")
    print_status(f"File directory: {AUTOEXEC_DIR}", "file")
    print_status("Bot started. Waiting for commands...", "info")
    print("=" * 60)
    print()
    
    # Pastikan direktori file ada
    ensure_directory()
    
    # Initial sync
    print_status("Initial sync...", "sync")
    sync_status()
    print()
    
    loop_count = 0
    
    while True:
        try:
            loop_count += 1
            
            # 1. Kirim status terbaru ke web (hanya jika ada perubahan)
            sync_status()

            # 2. Ambil perintah yang pending
            commands = get_pending_commands()
            
            if not isinstance(commands, dict):
                time.sleep(5)
                continue
                
            # 3. Eksekusi setiap perintah
            if commands:
                print_status(f"📨 Received {len(commands)} command(s)", "action")
                for pkg, cmd_info in commands.items():
                    cmd = cmd_info.get("cmd", "IDLE")
                    mode = cmd_info.get("mode", "public")
                    target = cmd_info.get("target", "")
                    username = last_status["username"].get(pkg, pkg)
                    
                    # ============ FILE MANAGEMENT COMMANDS ============
                    if cmd == "FILE_LIST":
                        print_status(f"📁 Listing files in {AUTOEXEC_DIR}", "file")
                        files = list_files()
                        # Kirim daftar file ke server
                        try:
                            requests.post(f"{WEB_URL}?action=sync_files", 
                                        json={"files": files}, 
                                        timeout=10)
                            print_status(f"✓ Sent {len(files)} files to server", "file")
                        except Exception as e:
                            print_status(f"Failed to send file list: {str(e)}", "error")
                        ack_execution(pkg)
                    
                    elif cmd == "FILE_READ":
                        print_status(f"📖 Reading file: {target}", "file")
                        result = get_file_content(target)
                        if 'error' in result:
                            print_status(f"❌ {result['error']}", "error")
                            # Kirim error ke server
                            try:
                                requests.post(f"{WEB_URL}?action=file_content", 
                                            json={"filename": target, "error": result['error']},
                                            timeout=10)
                            except:
                                pass
                        else:
                            # Kirim konten file ke server (base64 encode untuk binary)
                            try:
                                content_b64 = base64.b64encode(result['content'].encode('utf-8')).decode('utf-8')
                                requests.post(f"{WEB_URL}?action=file_content", 
                                            json={
                                                "filename": target, 
                                                "content": content_b64,
                                                "is_base64": True
                                            },
                                            timeout=10)
                                print_status(f"✓ File content sent to server", "file")
                            except Exception as e:
                                print_status(f"Failed to send file content: {str(e)}", "error")
                        ack_execution(pkg)
                    
                    elif cmd == "FILE_WRITE":
                        print_status(f"✏️ Writing file: {target}", "file")
                        content = cmd_info.get("content", "")
                        is_base64 = cmd_info.get("is_base64", False)
                        result = save_file(target, content, is_base64)
                        if 'error' in result:
                            print_status(f"❌ {result['error']}", "error")
                        else:
                            print_status(f"✓ File saved: {target}", "file")
                        ack_execution(pkg)
                    
                    elif cmd == "FILE_DELETE":
                        print_status(f"🗑️ Deleting file: {target}", "delete")
                        result = delete_file(target)
                        if 'error' in result:
                            print_status(f"❌ {result['error']}", "error")
                        else:
                            print_status(f"✓ File deleted: {target}", "delete")
                        ack_execution(pkg)
                    
                    # ============ GAME COMMANDS ============
                    elif cmd == "START":
                        if not is_running(pkg):
                            start_game(pkg, mode, target)
                            print_status(f"✓ {username} started successfully", "success")
                            ack_execution(pkg)
                        else:
                            print_status(f"⚠ {username} already running, skipping START", "warning")
                            ack_execution(pkg)

                    elif cmd == "STOP":
                        if is_running(pkg):
                            force_stop(pkg)
                            print_status(f"✓ {username} stopped", "success")
                            ack_execution(pkg)
                        else:
                            print_status(f"⚠ {username} not running, skipping STOP", "warning")
                            ack_execution(pkg)

                    elif cmd == "RERUN":
                        print_status(f"⟳ Restarting {username}...", "action")
                        force_stop(pkg)
                        time.sleep(2)
                        start_game(pkg, mode, target)
                        print_status(f"✓ {username} restarted", "success")
                        ack_execution(pkg)
                    
                    elif cmd == "IDLE":
                        print_status(f"💤 {username} set to IDLE (no action)", "idle")
                        ack_execution(pkg)

                    else:
                        print_status(f"⚠ Unknown command {cmd} for {username}", "warning")
                        ack_execution(pkg)
                    
                    # Update status setelah eksekusi
                    time.sleep(1)
                    sync_status()
            else:
                # Hanya tampilkan status idle setiap 30 loop (sekitar 2.5 menit)
                if loop_count % 30 == 0:
                    running_count = sum(1 for r in last_status["running"].values() if r)
                    total_count = len(last_status["installed"])
                    print_status(f"💤 IDLE - {running_count}/{total_count} accounts online", "idle")
                    loop_count = 0

            # 4. Tunggu 5 detik sebelum loop berikutnya
            time.sleep(5)
            
        except KeyboardInterrupt:
            print()
            print_status("Bot stopped by user", "warning")
            break
        except Exception as e:
            print_status(f"Error in main loop: {str(e)}", "error")
            time.sleep(5)
            continue

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        print_status("Bot stopped", "warning")
