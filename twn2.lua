local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

-- GANTI DENGAN URL MENUJU api.php DI WEB KAMU
local apiUrl = "http://ez.mn/tmpl/feeds/feed/tween/api.php" 

local lastTimestamp = 0
local currentTween = nil
local noclipConnection = nil
local isTweening = false

-- Executor HTTP Request Support (Bisa request atau http.request tergantung executor)
local httpRequest = (syn and syn.request) or (http and http.request) or http_request or fluxus and fluxus.request or request
if not httpRequest then
	warn("Executor kamu tidak mendukung HTTP Request!")
	return
end

-- Fungsi Noclip
local function setNoclip(state)
	if state then
		if not noclipConnection then
			noclipConnection = RunService.Stepped:Connect(function()
				local char = LocalPlayer.Character
				if char then
					for _, part in pairs(char:GetDescendants()) do
						if part:IsA("BasePart") and part.CanCollide then
							part.CanCollide = false
						end
					end
				end
			end)
		end
	else
		if noclipConnection then
			noclipConnection:Disconnect()
			noclipConnection = nil
		end
	end
end

-- Fungsi Stop
local function stopTween()
	isTweening = false
	if currentTween then
		currentTween:Cancel()
		currentTween = nil
	end
	setNoclip(false)
end

-- Fungsi Tween
local function tweenTo(x, y, z, speed)
	local character = LocalPlayer.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then return end
	
	local rootPart = character.HumanoidRootPart
	local targetCFrame = CFrame.new(x, y, z)
	
	stopTween()
	
	local distance = (rootPart.Position - targetCFrame.Position).Magnitude
	local timeToTake = distance / speed 
	
	local tweenInfo = TweenInfo.new(timeToTake, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	currentTween = TweenService:Create(rootPart, tweenInfo, {CFrame = targetCFrame})
	
	isTweening = true
	setNoclip(true)
	currentTween:Play()
	
	currentTween.Completed:Connect(function()
		if isTweening then stopTween() end
	end)
end

-- Sistem Laporan 2 Arah (Mengirim Info & Menerima Perintah)
task.spawn(function()
	while task.wait(1.5) do -- Polling setiap 1.5 detik
		pcall(function()
			-- Ambil posisi saat ini (Jika belum spawn, kirim 0,0,0)
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local posX, posY, posZ = 0, 0, 0
			
			if root then
				posX, posY, posZ = root.Position.X, root.Position.Y, root.Position.Z
			end
			
			-- Susun data JSON untuk dikirim ke web
			local payload = HttpService:JSONEncode({
				username = LocalPlayer.Name,
				x = posX,
				y = posY,
				z = posZ
			})
			
			-- Kirim POST Request
			local response = httpRequest({
				Url = apiUrl,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json"
				},
				Body = payload
			})
			
			-- Proses balasan (Perintah dari dashboard)
			if response.Success then
				local data = HttpService:JSONDecode(response.Body)
				
				if data and data.timestamp and data.timestamp > lastTimestamp then
					lastTimestamp = data.timestamp
					
					if data.action == "stop" then
						stopTween()
					elseif data.action == "tween" then
						tweenTo(data.x, data.y, data.z, data.speed or 100)
					end
				end
			end
		end)
	end
end)

print("Berhasil Terhubung ke Dashboard sebagai: " .. LocalPlayer.Name)
