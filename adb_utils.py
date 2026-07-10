import subprocess
import time
import re
import os

def run(cmd):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if result.stdout.strip():
            return result.stdout.strip()
        
        result2 = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return result2.stdout.strip()
    except:
        return ""

def run_root(cmd):
    try:
        result = subprocess.run(f"su -c '{cmd}'", shell=True, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return result.stdout.strip()
    except:
        return ""

def tap(x, y):
    run(f"input tap {x} {y}")

def input_text(text):
    text = text.replace(" ", "%s")
    run(f"input text '{text}'")

def press_keycode(keycode):
    run(f"input keyevent {keycode}")

def get_clipboard():
    out = run("service call clipboard 1")
    match = re.search(r"'(.*?)'", out)
    if match:
        return match.group(1)
    return ""

def set_clipboard(text):
    text_escaped = text.replace("'", "\\'")
    run(f"service call clipboard 2 i32 0 s16 '{text_escaped}'")

def dump_ui():
    run_root("rm -f /data/local/tmp/ui.xml")
    run_root("uiautomator dump /data/local/tmp/ui.xml")
    time.sleep(0.5)
    xml = run("cat /data/local/tmp/ui.xml")
    if not xml:
        xml = run_root("cat /data/local/tmp/ui.xml")
    return xml

def is_running(pkg):
    out = run_root(f"ps -A | grep {pkg}")
    if pkg in out:
        return True
    out2 = run_root(f"pidof {pkg}")
    if out2:
        return True
    return False

def is_foreground(pkg):
    # gunakan perintah yang lebih komprehensif
    out = run_root("dumpsys activity activities | grep -iE 'mResumedActivity|topResumedActivity|mCurrentFocus'")
    return pkg in out

def get_foreground_app():
    out = run_root("dumpsys activity activities | grep -iE 'mResumedActivity|topResumedActivity|mCurrentFocus'")
    # coba ekstrak package name
    match = re.search(r'([a-zA-Z0-9._]+)/', out)
    if match:
        return match.group(1)
    return None

def start_app(pkg):
    run(f"am start -n {pkg}/.RobloxActivity")  # coba langsung ke activity tertentu
    # fallback
    run(f"am start -p {pkg}")

def wait_app(pkg, timeout=10):
    for i in range(timeout):
        if is_running(pkg):
            return True
        time.sleep(1)
    return False

def get_username(pkg):
    """
    Mendapatkan username dari shared_prefs dengan mencari file prefs.xml atau xml lain.
    """
    # 1. Cukup grep kata "username" saja (jauh lebih aman dari bentrok kutip)
    out = run_root(f"cat /data/data/{pkg}/shared_prefs/prefs.xml 2>/dev/null | grep username")
    
    # Biarkan regex Python yang menyeleksi dan mengambil namanya
    match = re.search(r'<string name="username">([^<]+)</string>', out)
    if match:
        return match.group(1)
        
    # 2. Fallback jika tidak ada di prefs.xml, cari di file xml lainnya
    out2 = run_root(f"grep -r username /data/data/{pkg}/shared_prefs/ 2>/dev/null | head -1")
    match2 = re.search(r'<string name="username">([^<]+)</string>', out2)
    if match2:
        return match2.group(1)
        
    return None


def get_packages_by_prefix(prefix):
    """
    Mengembalikan daftar package yang terinstal dengan prefix tertentu.
    """
    out = run_root(f"pm list packages | grep '{prefix}'")
    packages = []
    if out:
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("package:"):
                pkg = line.replace("package:", "").strip()
                pkg = pkg.replace('\r', '').replace('\n', '')
                if pkg:
                    packages.append(pkg)
    return packages