import os
import json
import urllib.request
import urllib.error

# 1. Cek API Key
api_key = os.environ.get("GEMINI_API_KEY")
if not api_key:
    print("Error: GEMINI_API_KEY belum diset!")
    print("Jalankan: export GEMINI_API_KEY='isi_key_anda'")
    exit()

# 2. Mengambil daftar model dari API Google
print("Mengambil daftar model yang tersedia...")
list_url = f"https://generativelanguage.googleapis.com/v1beta/models?key={api_key}"

try:
    req_list = urllib.request.Request(list_url)
    response = urllib.request.urlopen(req_list)
    result = json.loads(response.read().decode('utf-8'))
    
    # Memfilter hanya model yang mendukung fitur chat (generateContent)
    available_models = []
    for model in result.get('models', []):
        if 'generateContent' in model.get('supportedGenerationMethods', []):
            available_models.append(model)
            
    if not available_models:
        print("Tidak ada model obrolan yang ditemukan di akun Anda.")
        exit()
        
except Exception as e:
    print(f"Gagal mengambil daftar model: {e}")
    exit()

# 3. Menampilkan menu pilihan model
print("\n" + "="*45)
print("DAFTAR MODEL GEMINI")
print("="*45)
for i, model in enumerate(available_models):
    # Membersihkan awalan "models/" agar lebih enak dibaca
    name = model.get('name').replace('models/', '') 
    display_name = model.get('displayName', 'Tidak ada nama')
    print(f"{i + 1}. {name} ({display_name})")

# Meminta input pengguna untuk memilih
selected_index = -1
while True:
    try:
        choice = input(f"\nPilih nomor model (1-{len(available_models)}): ")
        selected_index = int(choice) - 1
        if 0 <= selected_index < len(available_models):
            break
        else:
            print("Nomor tidak valid. Silakan pilih nomor yang ada di daftar.")
    except ValueError:
        print("Harap masukkan angka!")

# Mendapatkan nama model yang dipilih
selected_model = available_models[selected_index]['name'].replace('models/', '')
print(f"\nModel terpilih: {selected_model}")

# 4. Menyiapkan URL untuk obrolan berdasarkan model pilihan
chat_url = f"https://generativelanguage.googleapis.com/v1beta/models/{selected_model}:generateContent?key={api_key}"

# 5. Memulai Sesi Obrolan
history = []

print("\n" + "="*45)
print(f"🤖 Memulai Chat dengan {selected_model}")
print("Ketik 'keluar' untuk menghentikan program.")
print("="*45 + "\n")

while True:
    user_input = input("Anda: ")
    
    if user_input.lower() in ['keluar', 'exit', 'quit']:
        print("Meninggalkan obrolan. Sampai jumpa!")
        break
        
    if not user_input.strip():
        continue

    # Menyimpan pertanyaan ke memori (history)
    history.append({"role": "user", "parts": [{"text": user_input}]})
    
    # Menyiapkan paket data untuk dikirim ke Google
    data = {"contents": history}
    req = urllib.request.Request(
        chat_url, 
        data=json.dumps(data).encode('utf-8'), 
        headers={'Content-Type': 'application/json'}
    )

    try:
        # Mengirim data dan menerima jawaban
        response = urllib.request.urlopen(req)
        result = json.loads(response.read().decode('utf-8'))
        
        bot_text = result['candidates'][0]['content']['parts'][0]['text']
        print(f"\nGemini: {bot_text}\n")
        
        # Menyimpan jawaban AI ke memori (history)
        history.append({"role": "model", "parts": [{"text": bot_text}]})
        print("-" * 45)
        
    except urllib.error.HTTPError as e:
        error_msg = e.read().decode('utf-8')
        print(f"\n[Gagal Terhubung ke Google]: Kode {e.code}")
        print(error_msg, "\n")
        history.pop() # Menghapus chat terakhir dari memori jika gagal terkirim
    except Exception as e:
        print(f"\n[Terjadi Kesalahan Sistem]: {e}\n")
        history.pop()
