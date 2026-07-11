-- ==============================================
-- AUTO TWEEN SCRIPT - DELTA EXECUTOR
-- TANPA API KEY, TANPA LOG CONSOLE, PAKAI UI
-- ==============================================

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

-- ===== KONFIGURASI =====
local CONFIG = {
    API_URL = "http://ez.mn/tmpl/feeds/feed/tween/tween_control.php", -- GANTI
    CHECK_INTERVAL = 1.5,
    SEND_COORD_INTERVAL = 1,
    DEFAULT_SPEED = 3,
    MIN_SPEED = 0.5,
    MAX_SPEED = 20
}

-- ===== VARIABEL =====
local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local rootPart = character:WaitForChild("HumanoidRootPart")

local currentTween = nil
local isMoving = false
local isPaused = false
local tweenSpeed = CONFIG.DEFAULT_SPEED
local isConnected = false

-- ===== BUAT UI =====
local function createUI()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TweenUI"
    screenGui.ResetOnSpawn = false
    
    local mainFrame = Instance.new("Frame")
    mainFrame.Size = UDim2.new(0, 300, 0, 180)
    mainFrame.Position = UDim2.new(0.5, -150, 0.5, -90)
    mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 35)
    mainFrame.BackgroundTransparency = 0.1
    mainFrame.BorderSizePixel = 0
    mainFrame.ClipsDescendants = true
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = mainFrame
    
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 40)
    title.Position = UDim2.new(0, 0, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "🚀 Auto Tween Control"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 18
    title.Font = Enum.Font.GothamBold
    title.Parent = mainFrame
    
    -- Status Connection
    local statusFrame = Instance.new("Frame")
    statusFrame.Size = UDim2.new(0.9, 0, 0, 45)
    statusFrame.Position = UDim2.new(0.05, 0, 0.28, 0)
    statusFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 50)
    statusFrame.BorderSizePixel = 0
    
    local statusCorner = Instance.new("UICorner")
    statusCorner.CornerRadius = UDim.new(0, 8)
    statusCorner.Parent = statusFrame
    
    local statusDot = Instance.new("Frame")
    statusDot.Size = UDim2.new(0, 14, 0, 14)
    statusDot.Position = UDim2.new(0.05, 0, 0.5, -7)
    statusDot.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
    statusDot.BorderSizePixel = 0
    
    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(1, 0)
    dotCorner.Parent = statusDot
    
    local statusText = Instance.new("TextLabel")
    statusText.Size = UDim2.new(1, -30, 1, 0)
    statusText.Position = UDim2.new(0.15, 0, 0, 0)
    statusText.BackgroundTransparency = 1
    statusText.Text = "Checking connection..."
    statusText.TextColor3 = Color3.fromRGB(200, 200, 200)
    statusText.TextSize = 14
    statusText.TextXAlignment = Enum.TextXAlignment.Left
    statusText.Font = Enum.Font.Gotham
    
    statusDot.Parent = statusFrame
    statusText.Parent = statusFrame
    statusFrame.Parent = mainFrame
    
    -- Status Movement
    local moveStatus = Instance.new("TextLabel")
    moveStatus.Size = UDim2.new(1, -20, 0, 25)
    moveStatus.Position = UDim2.new(0, 10, 0.65, 0)
    moveStatus.BackgroundTransparency = 1
    moveStatus.Text = "⏸ Idle"
    moveStatus.TextColor3 = Color3.fromRGB(150, 150, 150)
    moveStatus.TextSize = 14
    moveStatus.Font = Enum.Font.Gotham
    moveStatus.Parent = mainFrame
    
    -- Speed Display
    local speedLabel = Instance.new("TextLabel")
    speedLabel.Size = UDim2.new(1, -20, 0, 25)
    speedLabel.Position = UDim2.new(0, 10, 0.82, 0)
    speedLabel.BackgroundTransparency = 1
    speedLabel.Text = "⚡ Speed: 3.0s"
    speedLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
    speedLabel.TextSize = 13
    speedLabel.Font = Enum.Font.Gotham
    speedLabel.Parent = mainFrame
    
    -- Close Button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 30, 0, 30)
    closeBtn.Position = UDim2.new(1, -35, 0, 5)
    closeBtn.BackgroundTransparency = 1
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.fromRGB(150, 150, 150)
    closeBtn.TextSize = 18
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = mainFrame
    closeBtn.MouseButton1Click:Connect(function()
        screenGui:Destroy()
    end)
    
    statusDot.Parent = statusFrame
    statusText.Parent = statusFrame
    statusFrame.Parent = mainFrame
    mainFrame.Parent = screenGui
    screenGui.Parent = player.PlayerGui
    
    return {
        frame = mainFrame,
        dot = statusDot,
        statusText = statusText,
        moveStatus = moveStatus,
        speedLabel = speedLabel,
        gui = screenGui
    }
end

-- ===== FUNGSI UPDATE UI =====
local function updateUI(ui, connected, moving, paused, speed)
    if not ui then return end
    
    if connected then
        ui.dot.BackgroundColor3 = Color3.fromRGB(0, 255, 100)
        ui.statusText.Text = "🟢 Connected to server"
        ui.statusText.TextColor3 = Color3.fromRGB(100, 255, 150)
    else
        ui.dot.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
        ui.statusText.Text = "🔴 Disconnected from server"
        ui.statusText.TextColor3 = Color3.fromRGB(255, 100, 100)
    end
    
    if moving then
        ui.moveStatus.Text = "🏃 Moving..."
        ui.moveStatus.TextColor3 = Color3.fromRGB(255, 200, 50)
    elseif paused then
        ui.moveStatus.Text = "⏸ Paused"
        ui.moveStatus.TextColor3 = Color3.fromRGB(255, 100, 50)
    else
        ui.moveStatus.Text = "⏸ Idle"
        ui.moveStatus.TextColor3 = Color3.fromRGB(150, 150, 150)
    end
    
    ui.speedLabel.Text = "⚡ Speed: " .. string.format("%.1f", speed) .. "s"
end

-- ===== FUNGSI TWEEN =====
local function tweenToPosition(targetPos, speed)
    if not rootPart or isPaused then return false end
    if currentTween and currentTween.PlaybackState ~= Enum.PlaybackState.Completed then
        currentTween:Cancel()
        currentTween = nil
    end
    local x, y, z = targetPos.x or 0, targetPos.y or 0, targetPos.z or 0
    local duration = math.clamp(speed or tweenSpeed, CONFIG.MIN_SPEED, CONFIG.MAX_SPEED)
    local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
    currentTween = TweenService:Create(rootPart, tweenInfo, {CFrame = CFrame.new(Vector3.new(x, y, z))})
    isMoving = true
    currentTween:Play()
    currentTween.Completed:Connect(function()
        isMoving = false
        currentTween = nil
        if ui then updateUI(ui, isConnected, isMoving, isPaused, tweenSpeed) end
    end)
    return true
end

local function stopTween()
    if currentTween then
        currentTween:Cancel()
        currentTween = nil
        isMoving = false
        if ui then updateUI(ui, isConnected, isMoving, isPaused, tweenSpeed) end
    end
end

local function togglePause()
    isPaused = not isPaused
    if isPaused then
        if currentTween then currentTween:Pause() end
    else
        if currentTween then currentTween:Play() end
    end
    if ui then updateUI(ui, isConnected, isMoving, isPaused, tweenSpeed) end
end

local function getCurrentCoords()
    if not rootPart then return {x=0, y=0, z=0} end
    local p = rootPart.Position
    return {x = math.round(p.X * 10) / 10, y = math.round(p.Y * 10) / 10, z = math.round(p.Z * 10) / 10}
end

-- ===== CEK KONEKSI =====
local function checkConnection(ui)
    local success, response = pcall(function()
        return HttpService:GetAsync(CONFIG.API_URL .. "?ping=1")
    end)
    
    if success and response then
        isConnected = true
        if ui then updateUI(ui, true, isMoving, isPaused, tweenSpeed) end
        return true
    else
        isConnected = false
        if ui then updateUI(ui, false, isMoving, isPaused, tweenSpeed) end
        return false
    end
end

-- ===== KIRIM KOORDINAT =====
local function sendCoords()
    if not rootPart then return end
    local coords = getCurrentCoords()
    local data = {
        type = "coords",
        x = coords.x, y = coords.y, z = coords.z,
        isMoving = isMoving,
        isPaused = isPaused,
        speed = tweenSpeed,
        timestamp = os.time()
    }
    pcall(function()
        HttpService:PostAsync(CONFIG.API_URL .. "?coords=1",
            HttpService:JSONEncode(data),
            Enum.HttpContentType.ApplicationJson)
    end)
end

-- ===== BACA PERINTAH =====
local function checkCommand(ui)
    local success, response = pcall(function()
        return HttpService:GetAsync(CONFIG.API_URL)
    end)
    
    if not success or not response or response == "" then
        if isConnected then
            isConnected = false
            if ui then updateUI(ui, false, isMoving, isPaused, tweenSpeed) end
        end
        return
    end
    
    if not isConnected then
        isConnected = true
        if ui then updateUI(ui, true, isMoving, isPaused, tweenSpeed) end
    end
    
    local data = HttpService:JSONDecode(response)
    if not data then return end
    
    if data.speed then
        tweenSpeed = math.clamp(data.speed, CONFIG.MIN_SPEED, CONFIG.MAX_SPEED)
        if ui then updateUI(ui, isConnected, isMoving, isPaused, tweenSpeed) end
    end
    
    local command = data.command or "none"
    
    if command == "move" then
        tweenToPosition({x = data.x or 0, y = data.y or 0, z = data.z or 0}, data.speed)
        if ui then updateUI(ui, isConnected, isMoving, isPaused, tweenSpeed) end
    elseif command == "stop" then
        stopTween()
    elseif command == "pause" then
        togglePause()
    elseif command == "resume" then
        if isPaused then togglePause() end
    elseif command == "teleport" then
        if rootPart then
            rootPart.CFrame = CFrame.new(Vector3.new(data.x or 0, data.y or 0, data.z or 0))
        end
    end
end

-- ===== KEYBIND (Stop) =====
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 and 
       UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
        stopTween()
    end
end)

-- ===== START =====
local ui = createUI()
checkConnection(ui)

coroutine.wrap(function()
    while true do
        wait(CONFIG.SEND_COORD_INTERVAL)
        sendCoords()
    end
end)()

while wait(CONFIG.CHECK_INTERVAL) do
    checkCommand(ui)
end
