-- Script Pendukung Ultra Potato + Sembunyikan Pemain Lain
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- 1. Matikan Efek Pencahayaan, Bayangan, & Post-Processing
Lighting.GlobalShadows = false
Lighting.FogEnd = 9e9
Lighting.Brightness = 2
for _, v in pairs(Lighting:GetChildren()) do
    if v:IsA("PostEffect") or v:IsA("Atmosphere") or v:IsA("Sky") or v:IsA("BlurEffect") or v:IsA("SunRaysEffect") then
        v:Destroy()
    end
end

-- 2. Turunkan Level Rendering Engine
pcall(function()
    settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
end)

-- 3. Ubah Material Objek Dunia Menjadi Polos & Hapus Partikel Berat
for _, v in pairs(Workspace:GetDescendants()) do
    if v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Fire") or v:IsA("Smoke") or v:IsA("Sparkles") then
        v:Destroy()
    elseif v:IsA("BasePart") then
        v.Material = Enum.Material.SmoothPlastic
        v.Reflectance = 0
        v.CastShadow = false
    end
end

-- 4. Sembunyikan & Hapus Beban Karakter Pemain Lain
local function optimizePlayer(player)
    if player ~= LocalPlayer then
        local function removeChar(char)
            for _, part in pairs(char:GetDescendants()) do
                if part:IsA("Accessory") or part:IsA("Clothing") or part:IsA("SpecialMesh") then
                    part:Destroy()
                elseif part:IsA("BasePart") then
                    part.Transparency = 1 -- Membuat bagian tubuh pemain lain transparan total
                    part.CanCollide = false -- Mematikan sentuhan agar tidak mengganggu
                end
            end
        end
        if player.Character then
            removeChar(player.Character)
        end
        player.CharacterAdded:Connect(removeChar)
    end
end

for _, player in pairs(Players:GetPlayers()) do
    optimizePlayer(player)
end
Players.PlayerAdded:Connect(optimizePlayer)

-- 5. Kunci FPS di 30 untuk Menjaga Suhu Perangkat
if setfpscap then
    setfpscap(30)
end
