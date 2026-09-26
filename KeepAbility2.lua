local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

getgenv().KeepAbilityEnabled = false

local successReplion, Replion = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Replion"))
end)

if not successReplion or not Replion then return end

local playerData = Replion.Client:WaitReplion("Data")
local eventsReplion = Replion.Client:WaitReplion("Events")

-- Variabel pelacak posisi badan karakter
local isTurnedAway = false

-- Daftar Kata Kunci Target Event (Aman dari tambahan teks seperti " - Admin Event")
local targetKeywords = {
    "bloodmoon",
    "frostmoon",
    "1x1x1x1",
    "galaxy",
    "talon kikir",
}

local function isEventActiveInCurrentServer()
    local data = eventsReplion and eventsReplion:Get()
    if data then
        local function scanTable(tbl)
            if tbl and type(tbl) == "table" then
                for _, eventName in ipairs(tbl) do
                    local nameLower = string.lower(tostring(eventName))
                    for _, keyword in ipairs(targetKeywords) do
                        if string.find(nameLower, keyword, 1, true) then
                            return true
                        end
                    end
                end
            end
            return false
        end
        
        -- Cek di dalam tabel Events maupun AdminEvents[span_0](start_span)[span_0](end_span)
        if scanTable(data.Events) then return true end
        if scanTable(data.AdminEvents) then return true end
    end
    return false
end

-- 1. UI Minimalis dengan Header (Mudah Digeser & Nyaman)
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "WnXD37_StealthKA"
pcall(function() screenGui.Parent = CoreGui end)
if not screenGui.Parent then screenGui.Parent = playerGui end

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 160, 0, 72)
mainFrame.Position = UDim2.new(0.05, 0, 0.15, 0)
mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
mainFrame.BackgroundTransparency = 0.25
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui

local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(0, 8)
uiCorner.Parent = mainFrame

local uiStroke = Instance.new("UIStroke")
uiStroke.Color = Color3.fromRGB(255, 45, 85)
uiStroke.Transparency = 0.4
uiStroke.Thickness = 1.2
uiStroke.Parent = mainFrame

-- Header Bar (Area khusus untuk geser UI)
local headerBar = Instance.new("TextLabel")
headerBar.Size = UDim2.new(1, 0, 0, 24)
headerBar.BackgroundTransparency = 1
headerBar.Font = Enum.Font.SourceSansBold
headerBar.Text = " Keep Ability"
headerBar.TextColor3 = Color3.fromRGB(240, 240, 240)
headerBar.TextSize = 12
headerBar.TextXAlignment = Enum.TextXAlignment.Left
headerBar.Parent = mainFrame

-- Tombol Toggle Interaktif
local toggleButton = Instance.new("TextButton")
toggleButton.Size = UDim2.new(1, -12, 0, 34)
toggleButton.Position = UDim2.new(0, 6, 0, 28)
toggleButton.BackgroundColor3 = Color3.fromRGB(200, 50, 50) -- Merah (OFF)
toggleButton.Font = Enum.Font.SourceSansBold
toggleButton.Text = "KEEP: OFF"
toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleButton.TextSize = 12
toggleButton.Parent = mainFrame

local btnCorner = Instance.new("UICorner")
btnCorner.CornerRadius = UDim.new(0, 6)
btnCorner.Parent = toggleButton

-- Fitur Geser (Draggable via Header / MainFrame)
local dragging, dragInput, dragStart, startPos
mainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
mainFrame.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

-- 2. Fungsi Rotasi Karakter (Putar Badan 180 Derajat)
local function turnAround()
    local character = player.Character
    if character and character:FindFirstChild("HumanoidRootPart") then
        local rootPart = character.HumanoidRootPart
        rootPart.CFrame = rootPart.CFrame * CFrame.Angles(0, math.pi, 0)
    end
end

-- 3. Logika Tombol Toggle
toggleButton.MouseButton1Click:Connect(function()
    getgenv().KeepAbilityEnabled = not getgenv().KeepAbilityEnabled
    if getgenv().KeepAbilityEnabled then
        toggleButton.BackgroundColor3 = Color3.fromRGB(50, 200, 50) -- Hijau (ON)
        toggleButton.Text = "KEEP: ON"
    else
        toggleButton.BackgroundColor3 = Color3.fromRGB(200, 50, 50) -- Merah (OFF)
        toggleButton.Text = "KEEP: OFF"
        
        if isTurnedAway then
            turnAround()
            isTurnedAway = false
        end
    end
end)

-- 4. Background Task (Keyword Event Detection + Keep Ability + Anti-Reset Akurat)
task.spawn(function()
    local lastActiveState = nil
    
    while true do
        if getgenv().KeepAbilityEnabled then
            pcall(function()
                -- Prioritas 1: Jika target event aktif dan karakter sedang membelakangi air, putar kembali menghadap air
                if isTurnedAway and isEventActiveInCurrentServer() then
                    turnAround()
                    isTurnedAway = false
                    return
                end
                
                -- Prioritas 2: Cek Status Ability (Anti-Konsumsi)
                local data = playerData:Get()
                local abilities = data and data.Abilities
                
                if abilities then
                    local rawActive = abilities.Active
                    local isCurrentlyActive = (rawActive ~= nil and rawActive ~= "" and rawActive ~= false and rawActive ~= 0)
                    
                    -- Pengecekan pertama kali / setelah server reset
                    if lastActiveState == nil then
                        lastActiveState = isCurrentlyActive
                        if isCurrentlyActive then
                            isTurnedAway = true
                        end
                        return
                    end
                    
                    -- Transisi: Hanya berputar KETIKA status berubah dari TIDAK AKTIF menjadi AKTIF
                    if isCurrentlyActive and not lastActiveState then
                        if not isTurnedAway then
                            turnAround()
                            isTurnedAway = true
                        end
                    end
                    
                    lastActiveState = isCurrentlyActive
                end
            end)
            task.wait(1)
        else
            lastActiveState = nil
            isTurnedAway = false
            task.wait(3)
        end
    end
end)
