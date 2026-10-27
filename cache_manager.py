# cache_manager.py - WITH PROCESSED IPS CACHE
import sqlite3
import time
import os
import threading
from queue import Queue, Empty
from config import Config

class CacheManager:
    def __init__(self):
        self.temp_dir = self._get_full_temp_dir()
        self.db_path = os.path.join(self.temp_dir, Config.OUTPUT_FILES['cache'])
        self.lock = threading.Lock()
        
        self.init_database()
        
        self.write_queue = Queue()
        self.start_writer_thread()
        self.start_cleanup_thread()
    
    def _get_full_temp_dir(self):
        temp_dir = os.path.abspath(os.path.expanduser(Config.TEMP_DIR))
        if not os.path.exists(temp_dir):
            os.makedirs(temp_dir, exist_ok=True)
        return temp_dir
    
    def _get_connection(self):
        conn = sqlite3.connect(self.db_path, timeout=30, check_same_thread=False)
        conn.execute('PRAGMA journal_mode = WAL')
        conn.execute('PRAGMA synchronous = NORMAL')
        conn.execute('PRAGMA foreign_keys = ON')
        conn.execute('PRAGMA cache_size = -32000')
        return conn

    def init_database(self):
        Config.ensure_temp_dir()
        conn = self._get_connection()
        cursor = conn.cursor()
        
        cursor.execute('PRAGMA auto_vacuum = INCREMENTAL')
        
        # Tabel Hasil Scan URL (untuk deduplikasi endpoint/URL)
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS scan_results (
                domain TEXT PRIMARY KEY,
                result TEXT,
                timestamp REAL
            )
        ''')
        
        # Tabel Checkpoint Base IP & Last Octet (untuk resume progress)
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS base_progress (
                base_ip TEXT PRIMARY KEY,
                last_octet INTEGER,
                status TEXT,
                timestamp REAL
            )
        ''')
        
        # Tabel IP yang sudah diproses (Ditambahkan kembali)
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS processed_ips (
                ip TEXT PRIMARY KEY,
                status TEXT,
                timestamp REAL
            )
        ''')
        
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_scan_timestamp ON scan_results(timestamp)')
        cursor.execute('CREATE INDEX IF NOT EXISTS idx_processed_timestamp ON processed_ips(timestamp)')
        
        conn.commit()
        conn.close()
        print(f"[✓] Database initialized (With IP Cache, Checkpoint & Scan Results) at: {self.db_path}")
    
    def start_writer_thread(self):
        def writer_worker():
            conn = self._get_connection()
            cursor = conn.cursor()
            while True:
                batch = []
                try:
                    item = self.write_queue.get(timeout=1.0)
                    batch.append(item)
                    
                    while len(batch) < 100:
                        try:
                            batch.append(self.write_queue.get_nowait())
                        except Empty:
                            break
                    
                    cursor.execute('BEGIN TRANSACTION')
                    for query, params in batch:
                        cursor.execute(query, params)
                    conn.commit()
                    
                    for _ in batch:
                        self.write_queue.task_done()
                except Empty:
                    continue
                except Exception as e:
                    try:
                        conn.rollback()
                    except:
                        pass
                    print(f"[-] Database writer error: {e}")
                    
        t = threading.Thread(target=writer_worker, daemon=True)
        t.start()

    def is_url_scanned(self, url_key):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('SELECT timestamp FROM scan_results WHERE domain = ?', (url_key,))
            row = cursor.fetchone()
            conn.close()
            return row is not None
        except Exception:
            return False

    def save_scan_result(self, url_key, result_data=""):
        query = '''INSERT OR IGNORE INTO scan_results (domain, result, timestamp) VALUES (?, ?, ?)'''
        self.write_queue.put((query, (url_key, str(result_data), time.time())))

    def get_base_progress(self, base_ip):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('SELECT last_octet, status FROM base_progress WHERE base_ip = ?', (base_ip,))
            row = cursor.fetchone()
            conn.close()
            return row if row else None
        except Exception:
            return None

    def save_base_progress(self, base_ip, last_octet, status='running'):
        query = '''INSERT OR REPLACE INTO base_progress (base_ip, last_octet, status, timestamp) VALUES (?, ?, ?, ?)'''
        self.write_queue.put((query, (base_ip, last_octet, status, time.time())))

    # --- TAMBAHAN FAKTOR CACHE IP ---
    def is_ip_processed(self, ip):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('SELECT timestamp FROM processed_ips WHERE ip = ?', (ip,))
            row = cursor.fetchone()
            conn.close()
            return row is not None
        except Exception:
            return False

    def mark_ip_processed(self, ip, status='success'):
        query = '''INSERT OR REPLACE INTO processed_ips (ip, status, timestamp) VALUES (?, ?, ?)'''
        self.write_queue.put((query, (ip, status, time.time())))
    # ---------------------------------

    def cleanup_old_cache(self):
        while True:
            try:
                time.sleep(Config.CACHE_CLEANUP_INTERVAL)
                conn = self._get_connection()
                cursor = conn.cursor()
                
                now = time.time()
                # Membersihkan scan_results dan processed_ips lama (>30 hari)
                cursor.execute('DELETE FROM scan_results WHERE timestamp < ?', (now - 2592000,))
                cursor.execute('DELETE FROM processed_ips WHERE timestamp < ?', (now - 2592000,))
                conn.commit()
                
                cursor.execute('PRAGMA incremental_vacuum(500)')
                conn.commit()
                conn.close()
            except Exception as e:
                print(f"[-] Auto cleanup error: {e}")
    
    def start_cleanup_thread(self):
        cleanup_thread = threading.Thread(target=self.cleanup_old_cache, daemon=True)
        cleanup_thread.start()
    
    def get_stats(self):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            stats = {}
            for table in ['scan_results', 'base_progress', 'processed_ips']:
                cursor.execute(f'SELECT COUNT(*) FROM {table}')
                stats[table] = cursor.fetchone()[0]
            
            if os.path.exists(self.db_path):
                stats['db_size_mb'] = os.path.getsize(self.db_path) / (1024 * 1024)
            else:
                stats['db_size_mb'] = 0
            conn.close()
            return stats
        except Exception as e:
            return {'error': str(e)}

    def clear_all_cache(self):
        try:
            conn = self._get_connection()
            cursor = conn.cursor()
            cursor.execute('DELETE FROM scan_results')
            cursor.execute('DELETE FROM base_progress')
            cursor.execute('DELETE FROM processed_ips')
            conn.commit()
            cursor.execute('PRAGMA incremental_vacuum')
            conn.close()
            return True
        except Exception:
            return False
