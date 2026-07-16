import os
import json
import urllib.request
import urllib.error

# Cek API Key
api_key = os.environ.get("GEMINI_API_KEY")
if not api_key:
    print("Error: GEMINI_API_KEY belum diset!")
    print("Jalankan: export GEMINI_API_KEY='isi_key_anda'")
    exit()

url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro:generateContent?key={api_key}"

# Menyimpan riwayat obrolan agar AI tidak pelupa
history = []

print("="*45)
print("🤖 Gemini AI (Versi API Langsung Tanpa Error)")
print("Ketik 'keluar' untuk menghentikan program.")
print("="*45 + "\n")

while True:
    user_input = input("Anda: ")
    
    if user_input.lower() in ['keluar', 'exit', 'quit']:
        print("Meninggalkan obrolan...")
        break
        
    if not user_input.strip():
        continue

    # Masukkan pertanyaan ke riwayat
    history.append({"role": "user", "parts": [{"text": user_input}]})
    
    # Siapkan data untuk dikirim
    data = {"contents": history}
    req = urllib.request.Request(
        url, 
        data=json.dumps(data).encode('utf-8'), 
        headers={'Content-Type': 'application/json'}
    )

    try:
        # Kirim ke server Google
        response = urllib.request.urlopen(req)
        result = json.loads(response.read().decode('utf-8'))
        
        # Ambil teks jawaban
        bot_text = result['candidates'][0]['content']['parts'][0]['text']
        print(f"\nGemini: {bot_text}\n")
        
        # Simpan jawaban ke riwayat
        history.append({"role": "model", "parts": [{"text": bot_text}]})
        print("-" * 45)
        
    except urllib.error.HTTPError as e:
        error_msg = e.read().decode('utf-8')
        print(f"\n[Gagal Terhubung ke Google]: Kode {e.code}")
        print(error_msg, "\n")
        history.pop() # Hapus chat terakhir jika gagal terkirim
    except Exception as e:
        print(f"\n[Terjadi Kesalahan Sistem]: {e}\n")
        history.pop()
