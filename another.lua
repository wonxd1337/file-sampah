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
-- Fungsi Noclip yang Diperbarui
local function setNoclip(state)
	local char = LocalPlayer.Character
	local rootPart = char and char:FindFirstChild("HumanoidRootPart")
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")

	if state then
		-- Jangan di-Anchor agar pergerakan tetap terkirim ke Server
		-- Matikan paksa fisika (berenang, jatuh, berjalan) dengan PlatformStand
		if humanoid then humanoid.PlatformStand = true end
		
		if not noclipConnection then
			noclipConnection = RunService.Stepped:Connect(function()
				if char then
					-- Tembus Tembok / Air
					for _, part in pairs(char:GetDescendants()) do
						if part:IsA("BasePart") and part.CanCollide then
							part.CanCollide = false
						end
					end
					
					-- Tahan dorongan gaya apung air setiap frame
					if rootPart then
						rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
						rootPart.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
					end
				end
			end)
		end
	else
		-- Kembalikan fungsi tubuh karakter seperti semula saat tween selesai
		if humanoid then humanoid.PlatformStand = false end
		
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
local function tweenTo(x, y, z, rx, ry, rz, speed)
	local character = LocalPlayer.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then return end
	
	local rootPart = character.HumanoidRootPart
	
	-- Gabungkan CFrame posisi dengan CFrame rotasi (dikonversi ke rad)
	local targetCFrame = CFrame.new(x, y, z) * CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
	
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
			-- Ambil posisi dan rotasi saat ini
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local posX, posY, posZ = 0, 0, 0
			local rotX, rotY, rotZ = 0, 0, 0
			
			if root then
				posX, posY, posZ = root.Position.X, root.Position.Y, root.Position.Z
				rotX, rotY, rotZ = root.Orientation.X, root.Orientation.Y, root.Orientation.Z
			end
			
			-- Susun data JSON dengan tambahan variabel rotasi (rx, ry, rz)
			local payload = HttpService:JSONEncode({
				username = LocalPlayer.Name,
				x = posX,
				y = posY,
				z = posZ,
				rx = rotX,
				ry = rotY,
				rz = rotZ
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
						-- Kirim juga parameter rx, ry, dan rz ke dalam fungsi tweenTo
						tweenTo(data.x, data.y, data.z, data.rx or 0, data.ry or 0, data.rz or 0, data.speed or 100)
					end
				end
			end
		end)
	end
end)

print("Berhasil Terhubung ke Dashboard sebagai: " .. LocalPlayer.Name)
