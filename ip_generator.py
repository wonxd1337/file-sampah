# ip_generator.py
import random
import socket
import time
from queue import Queue
from threading import Thread
from config import Config

class IPGenerator:
    def __init__(self, cache_manager):
        self.cache_manager = cache_manager
        self.valid_ips = Queue()
        self.running = True
    
    def check_ip_valid(self, ip):
        """Cek validitas IP dengan timeout"""
        try:
            socket.gethostbyaddr(ip)
            return True
        except:
            return False
    
    def generate_ips(self, base_ip, max_valid=None, max_attempts=None):
        """Generate IP random secara streaming"""
        if max_valid is None:
            max_valid = Config.MAX_VALID_RNG
        
        if max_attempts is None:
            max_attempts = max_valid * 3  # Maksimal 3x dari target
        
        base_parts = base_ip.split('.')
        if len(base_parts) != 4:
            print(f"[!] Invalid IP format: {base_ip}")
            return
        
        base = '.'.join(base_parts[:3]) + '.'
        valid_count = 0
        attempted = set()
        total_attempts = 0
        
        print(f"[*] Generating {max_valid} valid IPs from {base}[1-254]...")
        
        # Generator pattern
        while valid_count < max_valid and len(attempted) < 254 and total_attempts < max_attempts:
            last_octet = random.randint(1, 254)
            ip = base + str(last_octet)
            
            if ip in attempted:
                continue
                
            attempted.add(ip)
            total_attempts += 1
            
            # Cek validitas
            if self.check_ip_valid(ip):
                valid_count += 1
                yield ip
                print(f"[+] Valid IP: {ip} ({valid_count}/{max_valid})")
            
            # Small delay to prevent overwhelming
            if valid_count % 10 == 0 and valid_count > 0:
                time.sleep(0.1)
        
        if valid_count < max_valid:
            print(f"[!] Only found {valid_count} valid IPs (target: {max_valid})")
        else:
            print(f"[*] Generated {valid_count} valid IPs")
    
    def generate_ips_from_multiple(self, base_ips, max_valid_per_base=None):
        """Generate IP dari multiple base IP secara round-robin"""
        if max_valid_per_base is None:
            max_valid_per_base = Config.MAX_VALID_RNG
        
        # Buat generator untuk setiap base IP
        generators = []
        for base_ip in base_ips:
            gen = self.generate_ips(base_ip, max_valid_per_base)
            generators.append({
                'base_ip': base_ip,
                'generator': gen,
                'valid_count': 0,
                'completed': False
            })
        
        active_count = len(generators)
        
        while active_count > 0:
            for g in generators:
                if g['completed']:
                    continue
                
                try:
                    ip = next(g['generator'])
                    g['valid_count'] += 1
                    yield {
                        'ip': ip,
                        'base_ip': g['base_ip'],
                        'count': g['valid_count']
                    }
                except StopIteration:
                    g['completed'] = True
                    active_count -= 1
                    print(f"[*] Range {g['base_ip']} completed: {g['valid_count']} IPs")
    
    def stream_ips(self, base_ip, callback, max_valid=None):
        """Stream IP dan proses dengan callback"""
        for ip in self.generate_ips(base_ip, max_valid):
            # Cek cache dulu
            if not self.cache_manager.is_ip_processed(ip):
                callback(ip)
            else:
                print(f"[↺] Skipping cached IP: {ip}")
    
    def stream_ips_multi(self, base_ips, callback, max_valid_per_base=None):
        """Stream IP dari multiple base IP dan proses dengan callback"""
        for result in self.generate_ips_from_multiple(base_ips, max_valid_per_base):
            ip = result['ip']
            base_ip = result['base_ip']
            
            # Cek cache dulu
            if not self.cache_manager.is_ip_processed(ip):
                print(f"[→] From {base_ip}: {ip}")
                callback(ip)
            else:
                print(f"[↺] Skipping cached IP from {base_ip}: {ip}")