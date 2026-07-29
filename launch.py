import requests
import time
import os

SOURCE_URL = "http://ez.mn/tmpl/feeds/feed/rob/bot_source.py"

def start_bot():
    print("Mencoba mengunduh update terbaru dari server...")
    try:
        # 1. ANTI-CACHE URL: Tambahkan timestamp agar URL selalu unik tiap kali ditarik
        # Contoh jadinya: http://.../bot_source.py?t=1691234567
        url_with_nocache = f"{SOURCE_URL}?t={int(time.time())}"
        
        # 2. ANTI-CACHE HEADERS: Memaksa Nginx/Apache/Cloudflare memberikan file terbaru
        headers = {
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache",
            "Expires": "0"
        }
        
        # Tarik file menggunakan URL unik dan header bypass cache
        response = requests.get(url_with_nocache, headers=headers, timeout=10)
        
        if response.status_code == 200:
            bot_code = response.text
            print("Berhasil mengunduh source code! Menjalankan bot...\n")
            print("-" * 40)
            
            # Jalankan kode ke memori
            exec(bot_code, globals())
        else:
            print(f"Gagal mengambil source code. HTTP Status: {response.status_code}")
            time.sleep(5)
            
    except Exception as e:
        print(f"Terjadi kesalahan saat menghubungi server web: {e}")
        time.sleep(5)

if __name__ == "__main__":
    while True:
        start_bot()
        print("\nBot terhenti. Mencoba restart dalam 5 detik...")
        time.sleep(5)
        os.system('clear')
