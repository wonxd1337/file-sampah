import subprocess
import time
import requests
import re
import os
import curses
from datetime import datetime

WEB_URL = "http://ez.mn/tmpl/feeds/feed/rob/api.php"
FILE_DIR = "/storage/emulated/0/Delta/Autoexecute"

last_status = {
    "installed": [],
    "running": {},
    "username": {}
}

# ==================== FUNGSI UTAMA ====================
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

# ==================== SYNC & COMMANDS ====================
def sync_status():
    installed = get_all_packages()
    accounts_status = {}
    running_status = {}
    username_status = {}
    for pkg in installed:
        running = is_running(pkg)
        username = get_username(pkg)
        accounts_status[pkg] = {"running": running, "username": username}
        running_status[pkg] = running
        username_status[pkg] = username

    last_status["installed"] = installed
    last_status["running"] = running_status
    last_status["username"] = username_status

    payload = {"installed": installed, "accounts": accounts_status}
    try:
        requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=10)
        return True, len(installed)
    except Exception as e:
        return False, len(installed)

def get_pending_commands():
    try:
        res = requests.get(f"{WEB_URL}?action=get_commands", timeout=10)
        data = res.json()
        if isinstance(data, list):
            return {}
        return data
    except Exception as e:
        return {}

def ack_execution(pkg):
    try:
        requests.get(f"{WEB_URL}?action=ack_execution&pkg={pkg}", timeout=5)
        return True
    except Exception:
        return False

# ==================== CURSES UI ====================
def draw_table(stdscr, accounts, commands, status_msg, log_msgs):
    stdscr.clear()
    height, width = stdscr.getmaxyx()
    
    # Header
    title = " ROBLOX REMOTE CONTROLLER - TERMUX BOT "
    stdscr.attron(curses.A_BOLD | curses.A_REVERSE)
    stdscr.addstr(0, (width - len(title)) // 2, title[:width-1])
    stdscr.attroff(curses.A_BOLD | curses.A_REVERSE)
    
    # Status bar
    status_line = f" {status_msg} "
    stdscr.attron(curses.A_REVERSE)
    stdscr.addstr(1, 0, status_line[:width-1].ljust(width-1))
    stdscr.attroff(curses.A_REVERSE)
    
    # Header tabel
    headers = ["#", "Username", "Package", "Status", "Cmd"]
    col_widths = [4, 20, 30, 10, 10]
    total_width = sum(col_widths) + len(col_widths) - 1
    
    y = 3
    stdscr.attron(curses.A_BOLD)
    x = 0
    for i, header in enumerate(headers):
        stdscr.addstr(y, x, header.ljust(col_widths[i]))
        x += col_widths[i] + 1
    stdscr.attroff(curses.A_BOLD)
    
    # Garis pemisah
    stdscr.addstr(y + 1, 0, "─" * min(total_width, width-1))
    
    # Data akun
    y += 2
    if not accounts:
        stdscr.addstr(y, 2, "Tidak ada akun terdeteksi. Tunggu sync...")
    else:
        for idx, (pkg, data) in enumerate(accounts.items(), 1):
            if y >= height - 5:  # Sisakan space untuk log
                break
                
            username = data.get('username', 'Unknown')[:20]
            running = data.get('running', False)
            cmd_info = commands.get(pkg, {})
            cmd = cmd_info.get('cmd', 'IDLE')[:10]
            
            # Status dengan warna
            status_text = "ON" if running else "OFF"
            if running:
                stdscr.attron(curses.color_pair(2))  # Hijau
            else:
                stdscr.attron(curses.color_pair(1))  # Merah
            
            # Cmd dengan warna
            if cmd == "IDLE":
                cmd_color = curses.color_pair(3)  # Kuning
            elif cmd == "START" or cmd == "RERUN":
                cmd_color = curses.color_pair(2)  # Hijau
            elif cmd == "STOP":
                cmd_color = curses.color_pair(1)  # Merah
            else:
                cmd_color = curses.A_NORMAL
            
            row_data = [
                str(idx),
                username[:20],
                pkg[:30],
                status_text,
                cmd
            ]
            
            x = 0
            for i, val in enumerate(row_data):
                if i == 3:  # Kolom Status
                    stdscr.attron(curses.color_pair(2 if running else 1))
                    stdscr.addstr(y, x, val.ljust(col_widths[i]))
                    stdscr.attroff(curses.color_pair(2 if running else 1))
                elif i == 4:  # Kolom Cmd
                    stdscr.attron(cmd_color)
                    stdscr.addstr(y, x, val.ljust(col_widths[i]))
                    stdscr.attroff(cmd_color)
                else:
                    stdscr.addstr(y, x, val.ljust(col_widths[i]))
                x += col_widths[i] + 1
            
            y += 1
    
    # Log messages
    if log_msgs:
        y = height - len(log_msgs) - 1
        if y < 5:
            y = 5
        stdscr.attron(curses.A_REVERSE)
        stdscr.addstr(y, 0, " LOG ".ljust(width-1))
        stdscr.attroff(curses.A_REVERSE)
        y += 1
        for msg in log_msgs[-3:]:  # Tampilkan 3 log terakhir
            if y < height:
                if "✅" in msg or "success" in msg.lower():
                    stdscr.attron(curses.color_pair(2))
                elif "❌" in msg or "error" in msg.lower():
                    stdscr.attron(curses.color_pair(1))
                elif "⚠️" in msg or "warning" in msg.lower():
                    stdscr.attron(curses.color_pair(3))
                stdscr.addstr(y, 2, msg[:width-4])
                stdscr.attroff(curses.color_pair(1) | curses.color_pair(2) | curses.color_pair(3))
                y += 1
    
    stdscr.refresh()

def main(stdscr):
    # Inisialisasi warna
    curses.start_color()
    curses.init_pair(1, curses.COLOR_RED, curses.COLOR_BLACK)      # Offline
    curses.init_pair(2, curses.COLOR_GREEN, curses.COLOR_BLACK)    # Online
    curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLACK)   # Warning/Idle
    
    curses.curs_set(0)  # Sembunyikan cursor
    stdscr.nodelay(1)   # Non-blocking input
    stdscr.timeout(100) # 100ms timeout
    
    log_msgs = ["Bot started..."]
    status_msg = "Initializing..."
    
    loop_count = 0
    accounts = {}
    commands = {}
    
    while True:
        try:
            # Ambil status
            sync_success, total = sync_status()
            accounts = {pkg: {"username": last_status["username"].get(pkg, "Unknown"), 
                             "running": last_status["running"].get(pkg, False)} 
                       for pkg in last_status["installed"]}
            
            # Ambil commands
            commands = get_pending_commands()
            
            # Proses commands
            if commands:
                for pkg, cmd_info in commands.items():
                    cmd = cmd_info.get("cmd", "IDLE")
                    mode = cmd_info.get("mode", "public")
                    target = cmd_info.get("target", "")
                    username = last_status["username"].get(pkg, pkg)
                    
                    if cmd == "START":
                        if not is_running(pkg):
                            start_game(pkg, mode, target)
                            log_msgs.append(f"✅ {username} started")
                        else:
                            log_msgs.append(f"⚠️ {username} already running")
                        ack_execution(pkg)
                    elif cmd == "STOP":
                        if is_running(pkg):
                            force_stop(pkg)
                            log_msgs.append(f"✅ {username} stopped")
                        else:
                            log_msgs.append(f"⚠️ {username} not running")
                        ack_execution(pkg)
                    elif cmd == "RERUN":
                        force_stop(pkg)
                        time.sleep(2)
                        start_game(pkg, mode, target)
                        log_msgs.append(f"🔄 {username} restarted")
                        ack_execution(pkg)
                    elif cmd == "IDLE":
                        log_msgs.append(f"💤 {username} idle")
                        ack_execution(pkg)
                    
                    # Update status setelah eksekusi
                    sync_success, total = sync_status()
                    accounts = {pkg: {"username": last_status["username"].get(pkg, "Unknown"), 
                                     "running": last_status["running"].get(pkg, False)} 
                               for pkg in last_status["installed"]}
            
            # Update status message
            online_count = sum(1 for a in accounts.values() if a.get('running', False))
            status_msg = f"🔄 Sync: {'OK' if sync_success else 'FAIL'} | 📊 {total} accounts | 🟢 {online_count} online | ⏱️ {datetime.now().strftime('%H:%M:%S')}"
            
            # Log periodic status
            loop_count += 1
            if loop_count % 10 == 0:
                log_msgs.append(f"💤 Idle - {online_count}/{total} online")
                if len(log_msgs) > 20:
                    log_msgs = log_msgs[-15:]
                loop_count = 0
            
            # Draw UI
            draw_table(stdscr, accounts, commands, status_msg, log_msgs[-5:])
            
            # Check keyboard
            key = stdscr.getch()
            if key == ord('q') or key == ord('Q'):
                break
            
            time.sleep(3)  # Polling interval
            
        except KeyboardInterrupt:
            break
        except Exception as e:
            log_msgs.append(f"❌ Error: {str(e)[:50]}")
            time.sleep(2)

def run_curses():
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        print("\nBot stopped by user")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    print("Starting Roblox Remote Controller...")
    time.sleep(1)
    run_curses()
