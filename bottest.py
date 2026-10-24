import subprocess
import time
import requests
import re
import os
import uuid
import math
import base64
import sys

WEB_URL = "https://ruby.fool.jp/cgi-bin/mt4/tmpl/feeds/feed/rob/api.php"
FILE_DIR = "/storage/emulated/0/Delta/Autoexecute"

cached_packages = []
last_status = {
    "installed": [],
    "running": {},
    "username": {}
}

def get_device_id():
    if os.path.exists('.device_id'):
        with open('.device_id', 'r') as f: 
            return f.read().strip()
    did = "DEV-" + str(uuid.uuid4())[:6].upper()
    with open('.device_id', 'w') as f: 
        f.write(did)
    return did

def get_device_info():
    try:
        res_cpu = subprocess.run("grep -c ^processor /proc/cpuinfo", shell=True, capture_output=True, text=True)
        cpu_count = res_cpu.stdout.strip()
        cpu = f"{cpu_count} Cores" if cpu_count.isdigit() else "Unknown"

        res_ram = subprocess.run("awk '/MemTotal/ {print $2}' /proc/meminfo", shell=True, capture_output=True, text=True)
        ram_raw = res_ram.stdout.strip()
        ram = f"{int(ram_raw) // 1024} MB" if ram_raw.isdigit() else "Unknown"

        res_df = subprocess.run("df /data | tail -n 1 | awk '{print $2}'", shell=True, capture_output=True, text=True)
        df_raw = res_df.stdout.strip()
        if df_raw.isdigit():
            kb = int(df_raw)
            storage = f"{kb // (1024 * 1024)} GB" if kb > 1024 * 1024 else f"{kb // 1024} MB"
        else:
            storage = "Unknown"

        return f"CPU: {cpu} | RAM: {ram} | INT: {storage}"
    except Exception:
        return "Unknown Specs"

DEVICE_ID = get_device_id()
DEVICE_INFO = get_device_info()

def clear_screen(): os.system('clear')

def run_root(cmd, timeout=20):
    # Script dikirim lewat stdin ke root shell, jadi tidak ada masalah quoting
    # dan jalan di semua varian su (Magisk, KernelSU, SuperSU, dll).
    try:
        res = subprocess.run(["su", "-c", "sh"], input=cmd + "\n", capture_output=True,
                             text=True, timeout=timeout)
        return res.stdout.strip()
    except Exception:
        return ""

def get_all_packages():
    global cached_packages
    if not cached_packages:
        out = run_root("pm list packages | grep 'com.roblox'")
        if out: cached_packages = [line.replace("package:", "").strip() for line in out.splitlines() if line.strip()]
    return cached_packages

# ============================================================
#  KONFIGURASI DETEKSI STATUS & STABILITAS
# ============================================================
FG_ADJ_MAX = 100        # oom_score_adj <= 100 berarti app sedang tampil (foreground/visible)
GAME_PORT_MIN = 1024    # port remote UDP minimum yang dianggap koneksi server game
IGNORE_UDP_PORTS = {53, 80, 123, 443, 853, 5353}   # DNS, QUIC, NTP, mDNS, dll
GAME_MIN_UDP_SOCKETS = 2   # jumlah socket UDP (di luar QUIC/DNS) yang menandakan In-Game
                           # hasil observasi: Lobby = 1 socket, In-Game = 2 socket
UP_CONFIRM = 2          # butuh 2x pembacaan sama untuk NAIK status (OFF -> Lobby -> Game)
DOWN_CONFIRM = 3        # butuh 3x pembacaan sama untuk TURUN status (anti flapping)
MIN_FREE_RAM_MB = 500   # tunda START kalau RAM bebas di bawah ini
MAX_TEMP_C = 46.0       # tunda START kalau suhu baterai di atas ini
SAFE_PKG = re.compile(r'^[A-Za-z0-9_.]+$')

# Satu panggilan root untuk semua package. Hanya butuh: cat, pidof/ps (fallback otomatis).
SNAPSHOT_TEMPLATE = r"""
echo "@@PKG __PKG__"
pids=$(pidof __PKG__ 2>/dev/null)
if [ -z "$pids" ]; then
  pids=$( (ps -A 2>/dev/null || ps 2>/dev/null) | while read -r l; do
    set -- $l
    [ $# -ge 2 ] || continue
    eval "last=\${$#}"
    if [ "$last" = "__PKG__" ]; then
      for f in "$1" "$2" "$3"; do
        case "$f" in ""|*[!0-9]*) ;; *) echo "$f"; break ;; esac
      done
    fi
  done )
fi
for p in $pids; do
  echo "@@PID $p"
  cat /proc/$p/status 2>/dev/null
  echo "@@ADJ"
  cat /proc/$p/oom_score_adj 2>/dev/null
  echo "@@CG"
  cat /proc/$p/cgroup 2>/dev/null
  echo "@@END"
done
"""

def _build_snapshot_script(pkgs):
    parts = [SNAPSHOT_TEMPLATE.replace("__PKG__", p) for p in pkgs if SAFE_PKG.match(p)]
    parts.append('echo "@@UDP4"; cat /proc/net/udp 2>/dev/null')
    parts.append('echo "@@UDP6"; cat /proc/net/udp6 2>/dev/null')
    return "\n".join(parts)

def _parse_snapshot(out):
    procs = {}   # pkg -> [ {pid, state, uid, adj, cg} ]
    udp = []     # [ {uid, port, connected, loopback} ]
    cur_pkg, cur, mode = None, None, None
    for line in out.splitlines():
        line = line.rstrip()
        if line.startswith("@@PKG "):
            cur_pkg = line[6:].strip()
            procs[cur_pkg] = []
            cur, mode = None, None
        elif line.startswith("@@PID ") and cur_pkg is not None:
            cur = {"pid": line[6:].strip(), "state": "", "uid": -1, "adj": None, "cg": "", "threads": None, "rss_mb": None}
            procs[cur_pkg].append(cur)
            mode = "status"
        elif line == "@@ADJ":
            mode = "adj"
        elif line == "@@CG":
            mode = "cg"
        elif line == "@@END":
            mode = None
        elif line in ("@@UDP4", "@@UDP6"):
            mode, cur = line, None
        elif mode == "status" and cur is not None:
            if line.startswith("State:"):
                parts = line.split()
                cur["state"] = parts[1] if len(parts) > 1 else ""
            elif line.startswith("Uid:"):
                parts = line.split()
                if len(parts) > 1 and parts[1].isdigit():
                    cur["uid"] = int(parts[1])
            elif line.startswith("Threads:"):
                parts = line.split()
                if len(parts) > 1 and parts[1].isdigit():
                    cur["threads"] = int(parts[1])
            elif line.startswith("VmRSS:"):
                parts = line.split()
                if len(parts) > 1 and parts[1].isdigit():
                    cur["rss_mb"] = int(parts[1]) // 1024
        elif mode == "adj" and cur is not None:
            try: cur["adj"] = int(line.strip())
            except ValueError: pass
        elif mode == "cg" and cur is not None:
            cur["cg"] += line + "\n"
        elif mode in ("@@UDP4", "@@UDP6"):
            parts = line.split()
            if len(parts) < 8 or parts[0] == "sl" or ":" not in parts[2]:
                continue
            try:
                rip, rport = parts[2].rsplit(":", 1)
                port = int(rport, 16)
                uid = int(parts[7])
                udp.append({
                    "uid": uid,
                    "lport": int(parts[1].rsplit(":", 1)[1], 16),
                    "port": port,
                    "connected": port != 0 and int(rip, 16) != 0,
                    "loopback": rip in ("0100007F", "00000000000000000000000001000000"),
                })
            except ValueError:
                continue
    return procs, udp

def _game_socket_uids(udp):
    """UID yang dianggap sedang In-Game berdasarkan socket UDP-nya."""
    strong, count = set(), {}
    for s in udp:
        if s["loopback"]:
            continue
        if s["connected"]:
            if s["port"] in IGNORE_UDP_PORTS or s["port"] < GAME_PORT_MIN:
                continue          # QUIC/DNS/NTP tidak dihitung
            strong.add(s["uid"])  # koneksi langsung ke port tinggi = server game
        count[s["uid"]] = count.get(s["uid"], 0) + 1
    return strong | {u for u, c in count.items() if c >= GAME_MIN_UDP_SOCKETS}

def _classify(plist, game_uids):
    """Return (status, alasan). 0 = OFF, 1 = In-Lobby, 2 = In-Game."""
    alive = [p for p in plist if p["state"] not in ("Z", "X")]
    if not alive:
        return 0, "tidak ada proses"
    visible = False
    for p in alive:
        if p["adj"] is not None:
            vis = p["adj"] <= FG_ADJ_MAX
        else:   # fallback kalau oom_score_adj tidak terbaca
            vis = "top-app" in p["cg"] or "foreground" in p["cg"]
        if vis:
            visible = True
            break
    if not visible:
        return 0, "proses jalan tapi tidak tampil (background)"
    if any(p["uid"] in game_uids for p in alive):
        return 2, "ada socket UDP ke server game"
    return 1, "tampil, tapi belum ada socket UDP game"

_confirmed = {}   # pkg -> status yang sudah terkonfirmasi
_pending = {}     # pkg -> (kandidat, jumlah pembacaan berturut-turut)

def reset_debounce(pkg):
    _confirmed.pop(pkg, None)
    _pending.pop(pkg, None)

def debounced_status(raw):
    out = {}
    for pkg, new in raw.items():
        cur = _confirmed.get(pkg)
        if cur is None or new == cur:
            _confirmed[pkg] = new
            _pending.pop(pkg, None)
        else:
            cand, cnt = _pending.get(pkg, (None, 0))
            cnt = cnt + 1 if cand == new else 1
            need = UP_CONFIRM if new > cur else DOWN_CONFIRM
            if cnt >= need:
                _confirmed[pkg] = new
                _pending.pop(pkg, None)
            else:
                _pending[pkg] = (new, cnt)
        out[pkg] = _confirmed[pkg]
    return out

def get_running_packages():
    """Status mentah per package: 0 = OFF, 1 = In-Lobby, 2 = In-Game."""
    pkgs = get_all_packages()
    if not pkgs:
        return {}
    out = run_root(_build_snapshot_script(pkgs), timeout=30)
    if "@@PKG" not in out:   # root call gagal/timeout: pakai status terakhir, jangan dianggap OFF
        return {p: _confirmed.get(p, 0) for p in pkgs}
    procs, udp = _parse_snapshot(out)
    game_uids = _game_socket_uids(udp)
    return {p: _classify(procs.get(p, []), game_uids)[0] for p in pkgs}

def debug_dump():
    """python bot_source.py --debug  -> lihat apa yang terdeteksi, untuk verifikasi di device."""
    pkgs = get_all_packages()
    out = run_root(_build_snapshot_script(pkgs), timeout=30)
    procs, udp = _parse_snapshot(out)
    game_uids = _game_socket_uids(udp)
    print(f"Android SDK: {get_sdk()} | RAM bebas: {get_free_ram_mb()} MB | Suhu: {get_battery_temp_c()} C")
    for pkg in pkgs:
        plist = procs.get(pkg, [])
        status, why = _classify(plist, game_uids)
        print(f"\n== {pkg} -> status {status} ({why})")
        for p in plist:
            print(f"   pid={p['pid']} state={p['state']} uid={p['uid']} adj={p['adj']} threads={p['threads']} rss={p['rss_mb']}MB")
            for s in udp:
                if s["uid"] == p["uid"]:
                    print(f"     udp local_port={s['lport']} remote_port={s['port']} connected={s['connected']} loopback={s['loopback']}")

# ============================================================
#  STABILITAS (semua command diberi gate versi Android)
# ============================================================
_sdk = None

def get_sdk():
    global _sdk
    if _sdk is None:
        try:
            r = subprocess.run(["getprop", "ro.build.version.sdk"], capture_output=True, text=True, timeout=5)
            _sdk = int(r.stdout.strip())
        except Exception:
            _sdk = 0
    return _sdk

def get_free_ram_mb():
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                info[k] = int(v.split()[0])
        kb = info.get("MemAvailable") or (info.get("MemFree", 0) + info.get("Cached", 0) + info.get("Buffers", 0))
        return kb // 1024
    except Exception:
        return None

def get_battery_temp_c():
    m = re.search(r'temperature:\s*(-?\d+)', run_root("dumpsys battery"))
    return int(m.group(1)) / 10.0 if m else None

def wait_until_safe(timeout=90):
    """Tunda launch kalau RAM hampir habis atau device terlalu panas."""
    start, last_print = time.time(), 0
    while True:
        ram, temp = get_free_ram_mb(), get_battery_temp_c()
        if (ram is None or ram >= MIN_FREE_RAM_MB) and (temp is None or temp <= MAX_TEMP_C):
            return True
        if time.time() - start >= timeout:
            print(f"[{time.strftime('%H:%M:%S')}] Batas tunggu habis (RAM {ram} MB, suhu {temp} C), lanjut launch.")
            return False
        if time.time() - last_print >= 10:
            print(f"[{time.strftime('%H:%M:%S')}] Menunggu kondisi aman (RAM {ram} MB, suhu {temp} C)...")
            last_print = time.time()
        time.sleep(5)

def apply_stability_tweaks():
    sdk = get_sdk()
    cmds = [
        "svc power stayon true",   # layar tetap menyala selama dicas
        "settings put global window_animation_scale 0",
        "settings put global transition_animation_scale 0",
        "settings put global animator_duration_scale 0",
    ]
    if sdk >= 31:   # Android 12+: phantom process killer
        cmds += [
            "device_config set_sync_disabled_for_tests persistent",
            "device_config put activity_manager max_phantom_processes 2147483647",
            "settings put global settings_enable_monitor_phantom_procs false",
        ]
    run_root("\n".join(c + " >/dev/null 2>&1" for c in cmds))

def protect_package(pkg):
    if not SAFE_PKG.match(pkg):
        return
    sdk = get_sdk()
    cmds = []
    if sdk >= 23:   # Doze whitelist (Android 6+)
        cmds.append(f"dumpsys deviceidle whitelist +{pkg}")
    ops = []
    if sdk >= 24: ops.append("RUN_IN_BACKGROUND")
    if sdk >= 28: ops.append("RUN_ANY_IN_BACKGROUND")
    for op in ops:
        cmds.append(f"cmd appops set {pkg} {op} allow || appops set {pkg} {op} allow")
    if cmds:
        run_root("\n".join(c + " >/dev/null 2>&1" for c in cmds))

def setup_stability():
    apply_stability_tweaks()
    for pkg in get_all_packages():
        protect_package(pkg)


def force_stop(pkg):
    run_root(f"am force-stop {pkg}")
    reset_debounce(pkg)

window_index = 0

def get_screen_size():
    try:
        out = run_root("dumpsys window displays | grep 'cur='")
        match = re.search(r'cur=(\d+)x(\d+)', out)
        if match: return int(match.group(1)), int(match.group(2))
        
        out_wm = run_root("wm size")
        for line in out_wm.splitlines():
            if "Override size:" in line or "Physical size:" in line:
                size_str = line.split(":")[1].strip()
                if "x" in size_str:
                    w, h = size_str.split("x")
                    return int(w), int(h)
    except Exception:
        pass
    return 1280, 720 # Fallback darurat

def get_dynamic_offset():
    try:
        # Cek kerapatan pixel (DPI) layar via shell
        out = run_root("wm density")
        import re
        # Cari angka dari output (misal: "Physical density: 240")
        match = re.findall(r'\d+', out)
        if match:
            dpi = int(match[-1])
        else:
            dpi = 240 # Fallback jika gagal
    except:
        dpi = 240
        
    target_dp = 50 
    
    pixel_offset = int(target_dp * (dpi / 160))
    return pixel_offset

def resize_task(pkg, l, t, r, b):
    pref_dir = f"/data/data/{pkg}/shared_prefs"
    pref_file = f"{pref_dir}/{pkg}_preferences.xml"
    
    run_root(f"mkdir -p {pref_dir}")
    
    check_file = run_root(f"[ -f {pref_file} ] && echo 'EXISTS'")
    if "EXISTS" not in check_file:
        init_xml = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>"
        import base64
        encoded_init = base64.b64encode(init_xml.encode('utf-8')).decode('utf-8')
        run_root(f"echo '{encoded_init}' | base64 -d > {pref_file}")
        
    content = run_root(f"cat {pref_file}")
    if not content or "<map>" not in content:
        content = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>"

    def update_xml_value(xml_str, key, val):
        pattern = f'(<int name="{key}" value=")[^"]*(" />)'
        if re.search(pattern, xml_str):
            return re.sub(pattern, f'\\g<1>{val}\\g<2>', xml_str)
        else:
            new_tag = f'    <int name="{key}" value="{val}" />\n'
            return xml_str.replace('</map>', f'{new_tag}</map>')

    content = update_xml_value(content, "app_cloner_current_window_left", l)
    content = update_xml_value(content, "app_cloner_current_window_top", t)
    content = update_xml_value(content, "app_cloner_current_window_right", r)
    content = update_xml_value(content, "app_cloner_current_window_bottom", b)

    import base64
    encoded_content = base64.b64encode(content.encode('utf-8')).decode('utf-8')
    run_root(f"echo '{encoded_content}' | base64 -d > {pref_file}")
    
    run_root(f"chmod 660 {pref_file}")
    run_root(f"chown $(stat -c '%U:%G' /data/data/{pkg}) {pref_file}")

def maximize_window(pkg):
    SCREEN_W, SCREEN_H = get_screen_size()
    
    TOP_OFFSET = get_dynamic_offset()
    
    print(f"[{time.strftime('%H:%M:%S')}] Memperbesar layar untuk {pkg} (Restarting...)")
    force_stop(pkg)
    time.sleep(1.0)
    
    resize_task(pkg, 0, TOP_OFFSET, SCREEN_W, SCREEN_H)
    
    run_root(f"monkey -p {pkg} -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1")

def get_grid_layout(item_index, total_items):
    if total_items <= 0:
        return 0, 0, 0, 0
        
    import math
    cols = math.ceil(math.sqrt(total_items))
    rows = math.ceil(total_items / cols)
    
    if cols > 2 and (cols - 1) * rows >= total_items:
        cols -= 1
        
    SCREEN_W, SCREEN_H = get_screen_size()
    
    TOP_OFFSET = get_dynamic_offset() 
    available_h = SCREEN_H - TOP_OFFSET
    
    win_w = SCREEN_W // cols
    win_h = available_h // rows
    
    col = item_index % cols
    row = item_index // cols 
    
    left = col * win_w
    top = (row * win_h) + TOP_OFFSET
    right = left + win_w
    bottom = top + win_h
    
    return left, top, right, bottom

def grid_all_windows():
    running = [p for p, state in get_running_packages().items() if state > 0]
    if not running: 
        print(f"[{time.strftime('%H:%M:%S')}] Tidak ada game yang berjalan untuk di-grid.")
        return
    
    installed = get_all_packages()
    total_installed = len(installed)
    
    for pkg in running:
        try:
            current_index = installed.index(pkg)
        except ValueError:
            current_index = 0
            
        left_pos, top_pos, right_pos, bottom_pos = get_grid_layout(current_index, total_installed)
        
        print(f"[{time.strftime('%H:%M:%S')}] Merapikan Grid untuk {pkg} (Restarting...)")
        
        force_stop(pkg)
        time.sleep(1.0)
        resize_task(pkg, left_pos, top_pos, right_pos, bottom_pos)
        
        run_root(f"monkey -p {pkg} -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1")
        time.sleep(2.5)

def start_game(pkg, mode, target):
    wait_until_safe()
    if mode == "private":
        uri = f"https://www.roblox.com/share?code={target}&type=Server" if "http" not in target else target
    else:
        uri = f"roblox://placeId={target}"
        
    installed = get_all_packages()
    total_installed = len(installed)
    
    try:
        current_index = installed.index(pkg)
    except ValueError:
        current_index = 0
        
    left, top, right, bottom = get_grid_layout(current_index, total_installed)
    
    force_stop(pkg)
    time.sleep(1.0)
    
    resize_task(pkg, left, top, right, bottom)
    
    run_root(f'am start -a android.intent.action.VIEW -d "{uri}" {pkg}')
    reset_debounce(pkg)

_username_cache = {}   # pkg -> (username, waktu)

def get_username(pkg):
    cached = _username_cache.get(pkg)
    if cached and cached[0] != "Unknown" and time.time() - cached[1] < 120:
        return cached[0]
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    name = match.group(1) if match else "Unknown"
    _username_cache[pkg] = (name, time.time())
    return name

def sanitize_filename(filename): return os.path.basename(filename)

def list_files():
    try:
        if not os.path.exists(FILE_DIR): return {"success": True, "data": []}
        files = []
        for item in os.listdir(FILE_DIR):
            path = os.path.join(FILE_DIR, item)
            if os.path.isfile(path):
                stat = os.stat(path)
                files.append({"name": item, "size": stat.st_size, "mtime": stat.st_mtime})
        return {"success": True, "data": files}
    except Exception as e: return {"success": False, "message": str(e)}

def add_file(filename, content):
    try:
        filename = sanitize_filename(filename)
        os.makedirs(FILE_DIR, exist_ok=True)
        with open(os.path.join(FILE_DIR, filename), 'w', encoding='utf-8') as f:
            f.write(content)
        return {"success": True, "message": f"File {filename} created"}
    except Exception as e: return {"success": False, "message": str(e)}

def edit_file(filename, content): return add_file(filename, content)

def delete_file(filename):
    try:
        path = os.path.join(FILE_DIR, sanitize_filename(filename))
        if os.path.exists(path):
            os.remove(path)
            return {"success": True, "message": f"File deleted"}
        return {"success": False, "message": "File not found"}
    except Exception as e: return {"success": False, "message": str(e)}

def send_file_result(operation, success, data=None, message=""):
    try:
        requests.post(f"{WEB_URL}?action=file_result", json={
            "device_id": DEVICE_ID,
            "operation": operation, 
            "success": success, 
            "data": data or [], 
            "message": message
        }, timeout=10)
    except: pass
    
last_running_state = {}
last_sync_time = 0
command_poll_timer = 0

def sync_status():
    global last_running_state, last_sync_time
    
    installed = get_all_packages()
    running_info = debounced_status(get_running_packages())
    
    current_time = time.time()
    time_since_last_sync = current_time - last_sync_time
    
    if running_info == last_running_state and time_since_last_sync < 7:
        return False 
        
    accounts_status = {}
    
    for pkg in installed:
        status_code = running_info.get(pkg, 0)
        accounts_status[pkg] = {"running": status_code, "username": get_username(pkg)}

    payload = {
        "device_id": DEVICE_ID,
        "device_info": DEVICE_INFO,
        "installed": installed, 
        "accounts": accounts_status
    }
    try:
        requests.post(f"{WEB_URL}?action=sync", json=payload, timeout=5)
        
        last_running_state = running_info.copy()
        last_sync_time = current_time # Update Time
        return True
    except: 
        return False


def get_pending_commands():
    try:
        res = requests.get(f"{WEB_URL}?action=get_commands&device_id={DEVICE_ID}", timeout=5)
        return res.json() if isinstance(res.json(), dict) else {}
    except: return {}
    
def read_file(filename):
    try:
        path = os.path.join(FILE_DIR, sanitize_filename(filename))
        if os.path.exists(path):
            with open(path, 'r', encoding='utf-8') as f:
                content = f.read()
            return {"success": True, "data": content}
        return {"success": False, "message": "File not found"}
    except Exception as e: 
        return {"success": False, "message": str(e)}       

def ack_execution(pkg):
    try: requests.get(f"{WEB_URL}?action=ack_execution&device_id={DEVICE_ID}&pkg={pkg}", timeout=3)
    except: pass

def main():
    global command_poll_timer
    clear_screen()
    print(f"READY! ID: {DEVICE_ID} | {DEVICE_INFO}")
    setup_stability()
    
    last_running_state.clear()
    sync_status()

    while True:
        try:
            sync_status()
            
            if command_poll_timer >= 8:
                data = get_pending_commands()
                command_poll_timer = 0 # Reset
                
                if isinstance(data, dict):
                    commands = data.get("commands", {})
                    is_auto_rejoin = data.get("auto_rejoin", False)
                else:
                    commands = {}
                    is_auto_rejoin = False
                
                if isinstance(commands, dict) and commands:
                    for pkg, cmd_info in commands.items():
                        cmd = cmd_info.get("cmd", "IDLE")
                        mode = cmd_info.get("mode", "public")
                        target = cmd_info.get("target", "")
                        content = cmd_info.get("content", "")
                        if cmd != "IDLE":
                            last_sync_time = 0

                        if pkg == '_file_manager':
                            if cmd == "FILE_LIST":
                                res = list_files()
                                send_file_result("FILE_LIST", res["success"], res.get("data", []), res.get("message", ""))
                            elif cmd == "FILE_ADD":
                                res = add_file(target, content)
                                send_file_result("FILE_ADD", res["success"], [], res.get("message", ""))
                            elif cmd == "FILE_EDIT":
                                res = edit_file(target, content)
                                send_file_result("FILE_EDIT", res["success"], [], res.get("message", ""))
                            elif cmd == "FILE_DELETE":
                                res = delete_file(target)
                                send_file_result("FILE_DELETE", res["success"], [], res.get("message", ""))
                            elif cmd == "FILE_READ":
                                res = read_file(target)
                                send_file_result("FILE_READ", res["success"], res.get("data", ""), res.get("message", ""))
                            
                            ack_execution(pkg)
                            continue

                        if pkg == '_system':
                            if cmd == 'GRID_ALL':
                                print(f"[{time.strftime('%H:%M:%S')}] Merapikan semua window ke Grid...")
                                grid_all_windows()
                            elif cmd == 'MAXIMIZE':
                                print(f"[{time.strftime('%H:%M:%S')}] Memperbesar (Maximize) semua window aktif...")
                                running_pkgs = [p for p, state in get_running_packages().items() if state > 0]
                                for active_pkg in running_pkgs:
                                    maximize_window(active_pkg)
                                    time.sleep(0.5)
                            elif cmd == 'STOP_ALL':
                                print(f"[{time.strftime('%H:%M:%S')}] Menghentikan (Stop) semua window aktif...")
                                running_pkgs = [p for p, state in get_running_packages().items() if state > 0]
                                for active_pkg in running_pkgs:
                                    force_stop(active_pkg)
                                    time.sleep(0.5)
                            ack_execution(pkg)
                            continue

                        if cmd in ["START", "STOP", "RERUN", "MAXIMIZE"]:
                            print(f"[{time.strftime('%H:%M:%S')}] Executing {cmd} for {pkg} on {DEVICE_ID}...")

                        if cmd == "MAXIMIZE":
                            maximize_window(pkg)
                            ack_execution(pkg)

                        elif cmd == "START":
                            start_game(pkg, mode, target)
                            ack_execution(pkg)
                            
                            if is_auto_rejoin:
                                print(f"⏳ Auto Rejoin ON: Jeda 15 detik sebelum eksekusi akun berikutnya...")
                                time.sleep(15.0)

                        elif cmd == "STOP":
                            force_stop(pkg)
                            ack_execution(pkg)
                            time.sleep(1.0)

                        elif cmd == "RERUN":
                            force_stop(pkg)
                            time.sleep(2.0)
                            start_game(pkg, mode, target)
                            ack_execution(pkg)
                            
                            if is_auto_rejoin:
                                print(f"⏳ Auto Rejoin ON: Jeda 15 detik setelah RERUN...")
                                time.sleep(15.0)
            
            time.sleep(2)
            command_poll_timer += 2 
            
        except KeyboardInterrupt: 
            break
        except Exception as e: 
            print(f"[{time.strftime('%H:%M:%S')}] ERROR: {e}")
            time.sleep(2)
            command_poll_timer += 2

if __name__ == "__main__":
    if "--debug" in sys.argv:
        debug_dump()
    else:
        main()
