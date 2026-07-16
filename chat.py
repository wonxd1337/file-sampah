import os
from google import genai

# Mengecek apakah API Key sudah dimasukkan
if "AQ.Ab8RN6Is5a_ku1dVDsRzEwOgvHWxKVvrNWp6kUQM0CG-ikabmA" not in os.environ:
    print("Error: Anda belum memasukkan GEMINI_API_KEY!")
    exit()

# Inisialisasi klien
client = genai.Client()

# Membuat sesi chat agar AI ingat percakapan sebelumnya
chat = client.chats.create(model="gemini-2.5-flash")

print("="*40)
print("🤖 Gemini AI Chat di Termux")
print("Ketik 'keluar' untuk menghentikan program.")
print("="*40 + "\n")

# Loop agar bisa terus bertanya
while True:
    user_input = input("Anda: ")
    
    if user_input.lower() in ['keluar', 'exit', 'quit']:
        print("Meninggalkan obrolan. Sampai jumpa!")
        break
        
    if not user_input.strip():
        continue
        
    try:
        response = chat.send_message(user_input)
        print(f"\nGemini: {response.text}\n")
        print("-" * 40)
    except Exception as e:
        print(f"\n[Terjadi Kesalahan]: {e}\n")
