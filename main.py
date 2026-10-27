# main.py - ALL OPTIONS FIXED & SYNCHRONIZED WITH CHECKPOINT LOGIC
import os
import sys
import signal
import atexit
import time
from config import Config
from proxy_manager import ProxyManager
from cache_manager import CacheManager
from scanner import MovableTypeScanner
from ip_generator import IPGenerator
from concurrent.futures import ThreadPoolExecutor, as_completed

class MovableTypeMassScanner:
    def __init__(self):
        self.proxy_manager = None
        self.cache_manager = None
        self.scanner = None
        self.ip_generator = None
        self.running = True
        
        # Counter & Metrics
        self.skip_counter = 0
        self.total_ips_processed = 0
        self.total_mt = 0
        self.total_mtv4 = 0
        self.total_timeouts = 0
        self.total_fails = 0
        
        self.scan_level = 1
        self.scan_phase = None
        self.current_base_three_octets = None
        
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        atexit.register(self.cleanup)
    
    def signal_handler(self, signum, frame):
        print("\n\n[!] Interupsi diterima. Menghentikan program secara aman...")
        self.running = False
        self.cleanup()
        sys.exit(0)
    
    def cleanup(self):
        print("\n[*] Membersihkan resource sistem...")
        if self.cache_manager:
            stats = self.cache_manager.get_stats()
            print(f"[*] Cache stats: {stats}")
        if self.proxy_manager:
            self.proxy_manager.print_stats()
        print("[✓] Selesai.")
    
    def print_header(self):
        os.system('cls' if os.name == 'nt' else 'clear')
        print("""
    ╔════════════════════════════════════════════════════════════╗
    ║        Movable Type Mass Scanner v2.1 (Enterprise)         ║
    ║        - Optimized Network & Fail-Fast Architecture        ║
    ║        - Real-time Timeout & Fail Debug Tracking           ║
    ╚════════════════════════════════════════════════════════════╝
        """)
    
    def update_status_bar(self):
        t = time.strftime("%H:%M:%S")
        
        if self.scan_level == 1:
            mode = "L1-FULL"
        elif self.scan_phase == 'explore':
            mode = "L2-EXP"
        elif self.scan_phase == 'sampling':
            mode = "L2-SMP"
        elif self.scan_phase == 'exploit':
            mode = "L2-EPT"
        else:
            mode = "MANUAL"
        
        status = (f"\r[{t}] Mode: {mode} | "
                  f"IP: {self.total_ips_processed} | "
                  f"MT: {self.total_mt} | "
                  f"v4: {self.total_mtv4} | "
                  f"Timeout: {self.total_timeouts} | "
                  f"Fail: {self.total_fails} | "
                  f"Skip: {self.skip_counter}")
        sys.stdout.write(status.ljust(110))
        sys.stdout.flush()
    
    def increment_mt(self):
        self.total_mt += 1
        self.update_status_bar()
    
    def increment_mtv4(self):
        self.total_mtv4 += 1
        self.update_status_bar()

    def increment_timeout(self):
        self.total_timeouts += 1
        self.update_status_bar()

    def increment_fail(self):
        self.total_fails += 1
        self.update_status_bar()
    
    def sample_base_quality(self, base_three_octets):
        print(f"\n" + "─"*60)
        print(f" [SAMPLING] Base: {base_three_octets}x | Target Sample: {Config.SAMPLE_SIZE} IP")
        print(f" Threshold Minimal: {Config.MIN_DOMAINS_PER_IP} domain per IP (Cukup 1 IP valid)")
        print(f"─"*60)
        
        valid_ips = self.ip_generator.get_valid_ips_from_base(
            base_three_octets, 
            max_ips=Config.SAMPLE_SIZE,
            max_attempts=500
        )
        
        if len(valid_ips) < 1:
            print(f"\n[SAMPLING] ✗ Base Ditolak: Tidak ada IP valid ditemukan.")
            return False, [], {}, None
        
        sampled_ips = []
        domain_counts = {}
        good_ip = None
        good_count = 0
        
        for idx, ip in enumerate(valid_ips[:Config.SAMPLE_SIZE], 1):
            sampled_ips.append(ip)
            
            print(f"  [{idx:2d}] {ip} → memeriksa reverse IP...", end=" ", flush=True)
            domains_tnt, status_tnt = self.scanner.reverse_ip_tntcode(ip)
            domains_ht, status_ht = self.scanner.reverse_ip_hackertarget(ip)
            
            all_domains = set(domains_tnt + domains_ht)
            count = len(all_domains)
            domain_counts[ip] = count
            
            if count >= Config.MIN_DOMAINS_PER_IP:
                print(f"✓ {count} domain (GOOD)")
                good_count += 1
                if not good_ip:
                    good_ip = ip
            else:
                print(f"✗ {count} domain (BAD)")
        
        print("─"*60)
        if good_count >= 1:
            print(f"[SAMPLING] ✓ Base Diloloskan ({good_count} sample bagus ditemukan).")
            if good_ip:
                print(f"[SAMPLING] Contoh IP: {good_ip} ({domain_counts[good_ip]} domain)")
            return True, sampled_ips, domain_counts, good_ip
        else:
            print(f"[SAMPLING] ✗ Base Ditolak: Tidak ada sample memenuhi ambang batas.")
            return False, sampled_ips, domain_counts, None
    
    def run(self):
        self.print_header()
        
        print("[*] Menginisialisasi komponen sistem...")
        self.proxy_manager = ProxyManager()
        self.cache_manager = CacheManager()
        self.scanner = MovableTypeScanner(self.proxy_manager, self.cache_manager, self)
        self.ip_generator = IPGenerator(self.cache_manager)
        
        print("\n" + "═"*50)
        print(" MENU UTAMA SCANNER")
        print("═"*50)
        print(" 1. Scan dari file daftar IP")
        print(" 2. Scan dengan RNG IP (Single Batch)")
        print(" 3. True Continuous Scan Mode (Jalan Terus / Selamanya)")
        print(" 4. Tampilkan Statistik Sistem")
        print("═"*50)
        
        choice = input("\nPilih menu (1-4): ").strip()
        
        if choice == '1':
            self.scan_from_file()
        elif choice == '2':
            self.scan_with_rng()
        elif choice == '3':
            self.continuous_scan()
        elif choice == '4':
            self.show_stats()
        else:
            print("[!] Pilihan tidak valid!")
    
    def scan_from_file(self):
        filename = input("Nama file daftar IP: ").strip()
        try:
            with open(filename, 'r') as f:
                ips = [line.strip() for line in f if line.strip()]
            
            print(f"[*] Dimuat {len(ips)} IP dari file. Memulai pemindaian...")
            self.update_status_bar()
            print()
            
            with ThreadPoolExecutor(max_workers=Config.MAX_THREADS_REVERSE) as executor:
                futures = [executor.submit(self.scanner.process_ip, ip) for ip in ips]
                for future in as_completed(futures):
                    if not self.running:
                        break
                    try:
                        future.result()
                    except Exception as e:
                        print(f"[-] Error worker: {e}")
                        self.increment_fail()
            
            print(f"\n[✓] Selesai memindai dari file {filename}.")
            self.show_stats()
            
        except Exception as e:
            print(f"[!] Error membaca file: {e}")
    
    def scan_with_rng(self):
        """OPSI 2: Scan dengan RNG IP (Single Batch) + Checkpoint & Resume"""
        base_input = input("Base IP 3 oktet (contoh: 157.7.44): ").strip()
        if base_input.count('.') != 2:
            print("[!] Format harus 3 oktet (contoh: 157.7.44)")
            return
        
        base_three_octets = base_input + '.'
        
        # --- CEK CHECKPOINT BASE IP ---
        progress = self.cache_manager.get_base_progress(base_input)
        start_octet = 1
        
        if progress:
            last_occ, status = progress
            print(f"\n[!] Riwayat ditemukan: Base IP '{base_input}' terakhir berjalan sampai IP oktet ke-**{last_occ}** dari 254.")
            choice_resume = input(f"[?] Apakah ingin dilanjutkan dari oktet .{last_occ + 1}? (y/n): ").strip().lower()
            if choice_resume == 'y':
                start_octet = min(last_occ + 1, 254)
                print(f"[*] Melanjutkan pemindaian dari oktet .{start_octet} ...")
            else:
                print("[*] Memulai ulang pemindaian dari oktet .1 ...")

        print(f"\n[*] Memindai penuh base {base_three_octets}x (mulai oktet .{start_octet})...")
        self.update_status_bar()
        print()
        
        for ip, current_octet in self.ip_generator.generate_ips_level2_exploit_full(base_three_octets, start_octet):
            if not self.running:
                break
            
            # Simpan progres oktet terakhir ke database checkpoint
            self.cache_manager.save_base_progress(base_input, current_octet)
            
            if ip and not self.cache_manager.is_ip_processed(ip):
                self.scanner.process_ip(ip)
        
        print(f"\n[✓] Scan RNG Single Batch selesai.")
        self.show_stats()
    
    def continuous_scan(self):
        """OPSI 3: True Continuous Scan Mode + Checkpoint Integration[span_1](start_span)[span_1](end_span)"""
        print("\n" + "═"*60)
        print(" TRUE CONTINUOUS SCAN MODE (OPTIMIZED WITH CHECKPOINT)")
        print("═"*60)
        print("[*] Tekan Ctrl+C untuk berhenti kapan saja.")
        print("[*] Kombinasi L1, L2-Explore, Sampling, & Exploit aktif.\n")
        
        base_input = input("Base IP Level 1 (3 oktet, cth: 157.7.44): ").strip()
        if base_input.count('.') != 2:
            print("[!] Format harus 3 oktet (cth: 157.7.44)")
            return
        
        base_level1 = base_input + '.1'
        base_two_octets = base_input[:base_input.rfind('.')] + '.'
        
        self.total_ips_processed = 0
        self.total_mt = 0
        self.total_mtv4 = 0
        self.total_timeouts = 0
        self.total_fails = 0
        self.skip_counter = 0
        self.scan_level = 1
        self.scan_phase = None
        self.current_base_three_octets = None
        
        self.update_status_bar()
        print("\n")
        
        while self.running:
            if self.scan_level == 1:
                # Cek checkpoint untuk base L1
                progress = self.cache_manager.get_base_progress(base_input)
                start_octet = progress[0] + 1 if progress else 1
                
                if start_octet > 254:
                    print(f"\n[!] Level 1 untuk base {base_input}.x sudah selesai sebelumnya. Berpindah ke Level 2 (Explore)...")
                    self.scan_level = 2
                    self.scan_phase = 'explore'
                    self.skip_counter = 0
                    time.sleep(2)
                    continue

                print(f"\n\n[LEVEL 1] Memindai dari oktet .{start_octet} sampai 254 (base {base_input}.x) ...")
                valid_found = 0
                for ip, current_octet in self.ip_generator.generate_ips_level1_full(base_level1, start_octet):
                    if not self.running:
                        break
                    
                    # Simpan progress checkpoint
                    self.cache_manager.save_base_progress(base_input, current_octet)
                    
                    # Langsung proses IP tanpa memanggil is_ip_processed
                    if ip:
                        self.scanner.process_ip(ip)
                        valid_found += 1
                
                print(f"\n[!] Level 1 selesai. Berpindah ke Level 2 (Explore)...")
                self.scan_level = 2
                self.scan_phase = 'explore'
                self.skip_counter = 0
                time.sleep(2)
            
            elif self.scan_level == 2 and self.scan_phase == 'explore':
                print(f"\n\n[LEVEL 2 - EXPLORE] Mencari base 3 oktet baru dari {base_two_octets}x.y ...")
                found_new = False
                for ip in self.ip_generator.generate_ips_level2_explore(base_two_octets, Config.MAX_VALID_RNG):
                    if not self.running:
                        break
                    
                    # Pada mode explore (random), langsung proses IP valid yang ditemukan
                    found_new = True
                    self.scanner.process_ip(ip)
                    
                    parts = ip.split('.')
                    if len(parts) == 4:
                        new_base = '.'.join(parts[:3]) + '.'
                        print(f"\n[✓] Base baru ditemukan: {new_base}. Berpindah ke Sampling...")
                        self.scan_phase = 'sampling'
                        self.current_base_three_octets = new_base
                        self.skip_counter = 0
                        break
                
                if not found_new and self.running and self.scan_phase == 'explore':
                    time.sleep(3)
            
            elif self.scan_level == 2 and self.scan_phase == 'sampling':
                is_good, sampled_ips, domain_counts, good_ip = self.sample_base_quality(self.current_base_three_octets)
                
                for ip in sampled_ips:
                    if not self.cache_manager.is_ip_processed(ip):
                        st = 'sampled_good' if domain_counts.get(ip, 0) >= Config.MIN_DOMAINS_PER_IP else 'sampled_bad'
                        self.cache_manager.mark_ip_processed(ip, st)
                
                if not is_good:
                    print(f"[!] Base {self.current_base_three_octets}x berkualitas rendah. Kembali ke Explore...")
                    self.scan_phase = 'explore'
                    self.current_base_three_octets = None
                    self.skip_counter = 0
                    time.sleep(1)
                    continue
                
                print(f"[✓] Base berkualitas tinggi! Melanjutkan ke Exploit (Full Scan)...")
                self.scan_phase = 'exploit'
                time.sleep(1)
            
            elif self.scan_level == 2 and self.scan_phase == 'exploit':
                base_key = self.current_base_three_octets.rstrip('.')
                exp_progress = self.cache_manager.get_base_progress(base_key)
                exp_start = exp_progress[0] + 1 if exp_progress else 1
                
                if exp_start > 254:
                    print(f"\n[!] Exploit untuk {self.current_base_three_octets}x sudah selesai sebelumnya. Kembali ke Explore...")
                    self.scan_phase = 'explore'
                    self.current_base_three_octets = None
                    self.skip_counter = 0
                    time.sleep(2)
                    continue

                print(f"\n\n[LEVEL 2 - EXPLOIT] Memindai penuh base {self.current_base_three_octets}x (mulai oktet .{exp_start}) ...")
                valid_found = 0
                for ip, current_octet in self.ip_generator.generate_ips_level2_exploit_full(self.current_base_three_octets, exp_start):
                    if not self.running:
                        break
                    
                    self.cache_manager.save_base_progress(base_key, current_octet)
                    
                    if ip and not self.cache_manager.is_ip_processed(ip):
                        self.scanner.process_ip(ip)
                        valid_found += 1
                
                print(f"\n[!] Exploit selesai untuk {self.current_base_three_octets}x. Kembali ke Explore...")
                self.scan_phase = 'explore'
                self.current_base_three_octets = None
                self.skip_counter = 0
                time.sleep(2)
    
    def show_stats(self):
        print("\n" + "═"*60)
        print(" STATISTIK SISTEM")
        print("═"*60)
        cache_stats = self.cache_manager.get_stats()
        for k, v in cache_stats.items():
            print(f"  - {k}: {v}")
        
        if self.proxy_manager:
            self.proxy_manager.print_stats()
        
        print("\n📁 File Output:")
        for name, filename in Config.OUTPUT_FILES.items():
            if os.path.exists(filename):
                size = os.path.getsize(filename) / 1024
                print(f"  - {filename}: {size:.2f} KB")
            elif os.path.exists(Config.TEMP_DIR + filename):
                size = os.path.getsize(Config.TEMP_DIR + filename) / 1024
                print(f"  - {filename} (temp): {size:.2f} KB")
        print("═"*60)

def main():
    scanner = MovableTypeMassScanner()
    scanner.run()

if __name__ == "__main__":
    main()
