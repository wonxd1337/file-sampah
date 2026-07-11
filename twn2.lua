local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- Ganti dengan URL langsung menuju file data.json di web kamu
local webURL = "https://domainkamu.com/data.json" 

local lastTimestamp = 0
local currentTween = nil

local function tweenTo(x, y, z, speed)
	local character = LocalPlayer.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then return end
	
	local rootPart = character.HumanoidRootPart
	local targetCFrame = CFrame.new(x, y, z)
	
	-- Kalkulasi waktu agar kecepatan selalu konstan berapapun jaraknya
	local distance = (rootPart.Position - targetCFrame.Position).Magnitude
	local timeToTake = distance / speed 
	
	local tweenInfo = TweenInfo.new(
		timeToTake, 
		Enum.EasingStyle.Linear, 
		Enum.EasingDirection.Out
	)
	
	-- Jika ada tween yang sedang berjalan, batalkan agar bisa pindah arah
	if currentTween then
		currentTween:Cancel()
	end
	
	currentTween = TweenService:Create(rootPart, tweenInfo, {CFrame = targetCFrame})
	currentTween:Play()
end

-- Sistem Polling: Mengecek dashboard setiap 1 detik
task.spawn(function()
	while task.wait(1) do
		pcall(function()
			-- Mengambil data dari web
			local response = game:HttpGet(webURL .. "?t=" .. tostring(os.time()))
			local data = HttpService:JSONDecode(response)
			
			-- Mengecek apakah ada perintah baru berdasarkan timestamp
			if data and data.timestamp and data.timestamp > lastTimestamp then
				lastTimestamp = data.timestamp
				
				-- Jalankan tween
				tweenTo(data.x, data.y, data.z, data.speed or 100)
			end
		end)
	end
end)

print("Berhasil Terkoneksi ke Dashboard!")
