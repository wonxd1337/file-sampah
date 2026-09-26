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

-- Variabel pelacak posisi badan karakter
local isTurnedAway = false

-- 1. UI Proporsional untuk 4 Layar Kecil (Nyaman Dipencet)
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "WnXD37_StealthKA"
pcall(function() screenGui.Parent = CoreGui end)
if not screenGui.Parent then screenGui.Parent = playerGui end

-- Container Utama
local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 150, 0, 56)
mainFrame.Position = UDim2.new(0.05, 0, 0.12, 0)
mainFrame.BackgroundTransparency = 1
mainFrame.Parent = screenGui

-- Header (Area Hitam Semi-Transparan untuk Geser-geser) - Lebih luas & gampang dipegang
local headerFrame = Instance.new("Frame")
headerFrame.Size = UDim2.new(0, 150, 0, 26)
headerFrame.Position = UDim2.new(0, 0, 0, 0)
headerFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
headerFrame.BackgroundTransparency = 0.4 -- Hitam semi-transparan
headerFrame.Parent = mainFrame

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 6)
headerCorner.Parent = headerFrame

-- Teks Judul di Header
local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(0, 110, 0, 26)
titleLabel.Position = UDim2.new(0, 8, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.SourceSansBold
titleLabel.Text = "Stealth KA"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextSize = 11
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = headerFrame

-- Tombol Minimize / Maximize di Header (Diperbesar jadi 22x22 agar gampang dipencet)
local minMaxButton = Instance.new("TextButton")
minMaxButton.Size = UDim2.new(0, 22, 0, 22)
minMaxButton.Position = UDim2.new(1, -24, 0, 2)
minMaxButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
minMaxButton.BackgroundTransparency = 0.3
minMaxButton.Font = Enum.Font.SourceSansBold
minMaxButton.Text = "-"
minMaxButton.TextColor3 = Color3.fromRGB(255, 255, 255)
minMaxButton.TextSize = 13
minMaxButton.Parent = headerFrame

local minCorner = Instance.new("UICorner")
minCorner.CornerRadius = UDim.new(0, 4)
minCorner.Parent = minMaxButton

-- Tombol Utama (Toggle ON/OFF) di bawah header
local toggleButton = Instance.new("TextButton")
toggleButton.Size = UDim2.new(0, 150, 0, 28)
toggleButton.Position = UDim2.new(0, 0, 0, 28)
toggleButton.BackgroundColor3 = Color3.fromRGB(200, 50, 50) -- Merah (OFF)
toggleButton.Font = Enum.Font.SourceSansBold
toggleButton.Text = "KEEP: OFF"
toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleButton.TextSize = 11
toggleButton.Parent = mainFrame

local btnCorner = Instance.new("UICorner")
btnCorner.CornerRadius = UDim.new(0, 6)
btnCorner.Parent = toggleButton

-- Logika Minimize / Maximize
local isMinimized = false
minMaxButton.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        toggleButton.Visible = false
        mainFrame.Size = UDim2.new(0, 150, 0, 26) -- Hanya menyisakan header yang lebar & gampang digeser/dibuka lagi
        minMaxButton.Text = "+"
    else
        toggleButton.Visible = true
        mainFrame.Size = UDim2.new(0, 150, 0, 56)
        minMaxButton.Text = "-"
    end
end)

-- Fitur Geser (Draggable khusus ditarik dari bagian Header)
local dragging, dragInput, dragStart, startPos
headerFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
headerFrame.InputChanged:Connect(function(input)
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
        
        -- HANYA putar balik jika karakternya memang sedang membelakangi
        if isTurnedAway then
            turnAround()
            isTurnedAway = false
        end
    end
end)

-- 4. Background Task dengan Validasi Mutlak (Anti-False Trigger)
task.spawn(function()
    local lastActiveState = false
    
    while true do
        if getgenv().KeepAbilityEnabled then
            pcall(function()
                local data = playerData:Get()
                local abilities = data and data.Abilities
                
                if abilities then
                    local rawActive = abilities.Active
                    local isCurrentlyActive = (rawActive ~= nil and rawActive ~= "" and rawActive ~= false and rawActive ~= 0)
                    
                    if lastActiveState == nil then
                        lastActiveState = isCurrentlyActive
                    end
                    
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
            task.wait(3)
        end
    end
end)
