# main.py
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

class MovableTypeMassScanner:
    def __init__(self):
        self.proxy_manager = None
        self.cache_manager = None
        self.scanner = None
        self.running = True
        
        # Setup signal handlers
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        # Register cleanup
        atexit.register(self.cleanup)
    
    def signal_handler(self, signum, frame):
        """Handle Ctrl+C"""
        print("\n\n[!] Received interrupt signal. Cleaning up...")
        self.running = False
        self.cleanup()
        sys.exit(0)
    
    def cleanup(self):
        """Bersihkan resources"""
        print("[*] Cleaning up resources...")
        
        # Bersihkan cache lama
        if self.cache_manager:
            stats = self.cache_manager.get_stats()
            print(f"[*] Cache stats: {stats}")
        
        # Tampilkan statistik proxy
        if self.proxy_manager:
            self.proxy_manager.print_stats()
        
        print("[✓] Cleanup completed")
    
    def print_header(self):
        """Tampilkan header"""
        print("""
    ╔════════════════════════════════════════════════════════════╗
    ║         Movable Type Mass Scanner v2.0 (Enterprise)        ║
    ║  - Auto Proxy Refresh (30 menit)                           ║
    ║  - SQLite Cache System                                     ║
    ║  - Multiple Base IP Support                                ║
    ║  - Run for Days Without Issues                             ║
    ╚════════════════════════════════════════════════════════════╝
        """)
    
    def run(self):
        """Main execution"""
        self.print_header()
        
        # Inisialisasi komponen
        print("[*] Initializing components...")
        
        # Proxy Manager (auto-refresh)
        print("[*] Starting Proxy Manager...")
        self.proxy_manager = ProxyManager()
        
        # Cache Manager
        print("[*] Starting Cache Manager...")
        self.cache_manager = CacheManager()
        
        # Scanner
        self.scanner = MovableTypeScanner(self.proxy_manager, self.cache_manager)
        
        # IP Generator
        self.ip_generator = IPGenerator(self.cache_manager)
        
        # Pilih metode
        print("\n" + "="*50)
        print("SELECT INPUT METHOD")
        print("="*50)
        print("1. Scan from IP list file")
        print("2. Scan with RNG IP (auto-generate)")
        print("3. Continuous scan (run forever)")
        print("4. Show statistics")
        
        choice = input("\nChoice (1-4): ").strip()
        
        if choice == '1':
            self.scan_from_file()
        elif choice == '2':
            self.scan_with_rng()
        elif choice == '3':
            self.continuous_scan()
        elif choice == '4':
            self.show_stats()
        else:
            print("[!] Invalid choice!")
    
    def scan_from_file(self):
        """Scan dari file"""
        filename = input("IP list file: ").strip()
        
        try:
            with open(filename, 'r') as f:
                ips = [line.strip() for line in f if line.strip()]
            
            print(f"[*] Loaded {len(ips)} IPs")
            
            from concurrent.futures import ThreadPoolExecutor, as_completed
            
            with ThreadPoolExecutor(max_workers=Config.MAX_THREADS_REVERSE) as executor:
                futures = []
                for ip in ips:
                    if not self.running:
                        break
                    
                    # Skip jika sudah diproses
                    if not self.cache_manager.is_ip_processed(ip):
                        futures.append(executor.submit(self.scanner.process_ip, ip))
                    else:
                        print(f"[↺] Skipping cached IP: {ip}")
                
                for future in as_completed(futures):
                    if not self.running:
                        break
                    try:
                        future.result()
                    except Exception as e:
                        print(f"[-] Error: {e}")
                        
        except Exception as e:
            print(f"[!] Error: {e}")
    
    def scan_with_rng(self):
        """Scan dengan RNG IP"""
        base_ip = input("Base IP (e.g., 157.7.44): ").strip()
        
        # Format IP
        if base_ip.count('.') == 2:
            base_ip = base_ip + '.1'
        
        # Jumlah IP
        try:
            max_valid = input(f"Number of IPs (default {Config.MAX_VALID_RNG}): ").strip()
            if max_valid:
                max_valid = min(int(max_valid), Config.MAX_VALID_RNG_LIMIT)
            else:
                max_valid = Config.MAX_VALID_RNG
        except:
            max_valid = Config.MAX_VALID_RNG
        
        print(f"[*] Will generate up to {max_valid} valid IPs")
        
        # Stream dan proses
        self.ip_generator.stream_ips(
            base_ip, 
            self.scanner.process_ip,
            max_valid
        )
    
    def continuous_scan(self):
        """Continuous scan mode with multiple base IPs"""
        print("\n[*] Continuous Scan Mode")
        print("[*] Press Ctrl+C to stop\n")
        
        # Pilih metode input
        print("Select input method:")
        print("1. Input base IPs manually (dynamic)")
        print("2. Load from file")
        method = input("Choice (1-2): ").strip()
        
        base_ips = []
        
        if method == '1':
            # Dynamic manual input
            try:
                num_ips = int(input("\nBerapa base IP yang mau di generate? : ").strip())
                if num_ips <= 0:
                    print("[!] Number must be positive!")
                    return
                if num_ips > 100:
                    confirm = input(f"[!] {num_ips} base IPs is a lot. Continue? (y/n): ").strip().lower()
                    if confirm != 'y':
                        return
            except ValueError:
                print("[!] Invalid number!")
                return
            
            print()
            for i in range(num_ips):
                while True:
                    base_ip = input(f"Base IP {i+1} : ").strip()
                    # Validasi format IP (minimal 3 oktet)
                    if base_ip.count('.') >= 2:
                        # Format jika hanya 3 oktet
                        if base_ip.count('.') == 2:
                            base_ip = f"{base_ip}.1"
                        base_ips.append(base_ip)
                        break
                    else:
                        print("[!] Invalid format! Use format like: 157.7.44 or 157.7.44.1")
            
        elif method == '2':
            # Load from file
            filename = input("\nIP list file: ").strip()
            try:
                with open(filename, 'r') as f:
                    base_ips = [line.strip() for line in f if line.strip()]
                    # Format IP
                    base_ips = [ip if ip.count('.') == 3 else f"{ip}.1" for ip in base_ips]
                print(f"[*] Loaded {len(base_ips)} base IPs")
            except FileNotFoundError:
                print(f"[!] File {filename} not found!")
                return
            except Exception as e:
                print(f"[!] Error reading file: {e}")
                return
        else:
            print("[!] Invalid choice!")
            return
        
        if not base_ips:
            print("[!] No base IPs provided!")
            return
        
        # Tampilkan ringkasan
        print(f"\n{'='*50}")
        print("BASE IP SUMMARY")
        print('='*50)
        for i, ip in enumerate(base_ips[:10], 1):
            print(f"  {i}. {ip}")
        if len(base_ips) > 10:
            print(f"  ... and {len(base_ips) - 10} more")
        print('='*50)
        
        # Jumlah IP per base per cycle
        try:
            max_valid_input = input(f"\nIPs per base per cycle (default {Config.MAX_VALID_RNG}): ").strip()
            if max_valid_input:
                max_valid = min(int(max_valid_input), Config.MAX_VALID_RNG_LIMIT)
            else:
                max_valid = Config.MAX_VALID_RNG
        except ValueError:
            max_valid = Config.MAX_VALID_RNG
        
        # Pilih mode scanning
        print("\nSelect scanning mode:")
        print("1. Sequential (finish one range, then next)")
        print("2. Round-robin (alternate between ranges)")
        mode = input("Choice (1-2, default 1): ").strip()
        round_robin_mode = (mode == '2')
        
        # Konfirmasi start
        print(f"\n{'='*50}")
        print("SCAN CONFIGURATION")
        print('='*50)
        print(f"  Base IP ranges : {len(base_ips)}")
        print(f"  IPs per range  : {max_valid}")
        print(f"  Scan mode      : {'Round-robin' if round_robin_mode else 'Sequential'}")
        print(f"  Cache cleanup  : Every {Config.CACHE_CLEANUP_INTERVAL//60} minutes")
        print('='*50)
        
        confirm = input("\nStart scanning? (y/n): ").strip().lower()
        if confirm != 'y':
            print("[!] Aborted.")
            return
        
        cycle = 0
        
        while self.running:
            cycle += 1
            print(f"\n{'#'*60}")
            print(f"# CYCLE #{cycle} - {time.strftime('%Y-%m-%d %H:%M:%S')}")
            print(f"# Active ranges: {len(base_ips)}")
            print('#'*60)
            
            if round_robin_mode:
                # Mode Round-robin (alternating per IP)
                self._scan_round_robin(base_ips, max_valid)
            else:
                # Mode Sequential (one range at a time)
                for idx, base_ip in enumerate(base_ips, 1):
                    if not self.running:
                        break
                    
                    print(f"\n[{idx}/{len(base_ips)}] Processing range: {base_ip}")
                    print('-'*40)
                    
                    # Generate dan proses IP untuk base IP ini
                    self.ip_generator.stream_ips(
                        base_ip,
                        self.scanner.process_ip,
                        max_valid
                    )
            
            # Tampilkan statistik
            self.show_stats(quiet=True)
            
            # Istirahat antar cycle
            if self.running:
                print(f"\n[*] Cycle #{cycle} completed. Waiting 60 seconds...")
                for i in range(60):
                    if not self.running:
                        break
                    time.sleep(1)
                    if i % 10 == 0 and i > 0:
                        print(f"[*] Next cycle in {60-i}s...", end='\r')
                print()
    
    def _scan_round_robin(self, base_ips, max_valid_per_range):
        """Scan multiple base IPs in round-robin mode (alternating per IP)"""
        
        # Inisialisasi generator untuk setiap base IP
        generators = []
        for base_ip in base_ips:
            gen = self.ip_generator.generate_ips(base_ip, max_valid_per_range)
            generators.append({
                'base_ip': base_ip,
                'generator': gen,
                'completed': False,
                'count': 0
            })
        
        active_count = len(generators)
        total_processed = 0
        round_num = 1
        
        print(f"\n[*] Round-robin mode active: {active_count} ranges")
        print("[*] Will alternate 1 IP from each range sequentially\n")
        
        while self.running and active_count > 0:
            print(f"\n--- Round #{round_num} ---")
            round_processed = 0
            
            for g in generators:
                if not self.running:
                    break
                if g['completed']:
                    continue
                
                try:
                    ip = next(g['generator'])
                    g['count'] += 1
                    total_processed += 1
                    round_processed += 1
                    
                    print(f"  [{g['base_ip']}] → {ip} (total: {g['count']})")
                    
                    # Proses IP
                    if not self.cache_manager.is_ip_processed(ip):
                        self.scanner.process_ip(ip)
                    else:
                        print(f"    ↺ Skipping cached IP")
                        
                except StopIteration:
                    g['completed'] = True
                    active_count -= 1
                    print(f"  [!] Range {g['base_ip']} COMPLETED ({g['count']} valid IPs)")
            
            if round_processed == 0:
                # No IPs processed this round, all completed
                break
            
            round_num += 1
            
            # Small delay between rounds to be polite
            if self.running and active_count > 0:
                time.sleep(2)
        
        print(f"\n[*] Round-robin completed: {total_processed} total IPs processed")
    
    def save_base_ips_to_file(self, base_ips, filename=None):
        """Save base IPs configuration to file"""
        if filename is None:
            filename = f"base_ips_{time.strftime('%Y%m%d_%H%M%S')}.txt"
        
        try:
            with open(filename, 'w') as f:
                for ip in base_ips:
                    f.write(f"{ip}\n")
            print(f"[✓] Base IPs saved to {filename}")
            return True
        except Exception as e:
            print(f"[-] Error saving: {e}")
            return False
    
    def show_stats(self, quiet=False):
        """Tampilkan statistik"""
        if not quiet:
            print("\n" + "="*60)
            print("SYSTEM STATISTICS")
            print("="*60)
        
        # Cache stats
        cache_stats = self.cache_manager.get_stats()
        print(f"\n📦 Cache Database:")
        for table, count in cache_stats.items():
            print(f"  - {table}: {count} entries")
        
        # Proxy stats
        self.proxy_manager.print_stats()
        
        # File stats
        print("\n📁 Output Files:")
        for name, filename in Config.OUTPUT_FILES.items():
            if os.path.exists(filename):
                size = os.path.getsize(filename) / 1024  # KB
                print(f"  - {filename}: {size:.2f} KB")
            elif os.path.exists(Config.TEMP_DIR + filename):
                size = os.path.getsize(Config.TEMP_DIR + filename) / 1024
                print(f"  - {filename} (temp): {size:.2f} KB")

def main():
    scanner = MovableTypeMassScanner()
    scanner.run()

if __name__ == "__main__":
    main()