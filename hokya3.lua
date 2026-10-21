-- Ada 2 PlaceId plaza; keduanya dianggap "sudah di dalam plaza" (tidak ada false hop)
local PLAZA_PLACE_IDS = {
    [79378095465365] = true,
    [82602826017494] = true,
}
local function isPlazaPlace(placeId)
    return PLAZA_PLACE_IDS[placeId] == true
end

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local GuiService = game:GetService("GuiService")

local WEB_URL = "http://bulbul.org/mt/r/plaza/api.php"
local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name
local maxPlayers = Players.MaxPlayers

local MAX_BOOTH_SLOTS = 10 

-- ==========================================
-- ANTI-NYANGKUT: Penanganan Eror Teleport (Error 772 / Server Full)
-- ==========================================
local lastHopFailed = false      -- true kalau teleport ditolak game (Error 772 / server full / dll)
local pendingHopJobId = nil     -- JobId yang sedang dituju
local failedJobIds = {}         -- JobId gagal -> waktu gagal (diblacklist sementara)

TeleportService.TeleportInitFailed:Connect(function(player, teleportResult, errorMessage)
    if player == LocalPlayer then
        if pendingHopJobId then failedJobIds[pendingHopJobId] = os.time() end
        lastHopFailed = true
        pcall(function()
            GuiService:ClearError()
        end)
    end
end)

-- shouldAbort (opsional): fungsi yang di-cek terus selama jalan; kalau return true, jalan dihentikan.
-- return true = sampai / selesai jalan, false = dibatalkan oleh shouldAbort
local function moveToTarget(humanoid, rootPart, targetPos, shouldAbort)
    local function aborted()
        if shouldAbort and shouldAbort() then
            pcall(function() humanoid:MoveTo(rootPart.Position) end)
            return true
        end
        return false
    end

    local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
    local success = pcall(function() path:ComputeAsync(rootPart.Position, targetPos) end)

    if success and path.Status == Enum.PathStatus.Success then
        for _, waypoint in ipairs(path:GetWaypoints()) do
            if aborted() then return false end
            humanoid:MoveTo(waypoint.Position)
            if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
            local reached = false
            local conn
            conn = humanoid.MoveToFinished:Connect(function() reached = true; if conn then conn:Disconnect() end end)
            local startT = tick()
            while not reached and (rootPart.Position - waypoint.Position).Magnitude > 3 and (tick() - startT) < 5 do
                if aborted() then
                    if conn then conn:Disconnect() end
                    return false
                end
                task.wait()
            end
            if conn then conn:Disconnect() end
        end
    else
        humanoid:MoveTo(targetPos)
        local startT = tick()
        -- (bug lama: kondisi "< 6" membuat loop langsung berhenti; sekarang menunggu sampai dekat ATAU timeout 6 dtk)
        repeat
            task.wait(0.1)
            if aborted() then return false end
        until (rootPart.Position - targetPos).Magnitude < 4 or (tick() - startT) > 6
    end
    return true
end

-- Belum di plaza: jalan kaki, pastikan sampai tujuan, lalu klik dengan natural
if not isPlazaPlace(game.PlaceId) then
    task.spawn(function()
        local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
        local humanoid = character:WaitForChild("Humanoid")
        local rootPart = character:WaitForChild("HumanoidRootPart")
        
        -- Koordinat portal Plaza
        local portalPos = Vector3.new(-36, 10, 2807)
        
        while not isPlazaPlace(game.PlaceId) do
            -- Hitung jarak karakter ke portal
            local distanceToPortal = (rootPart.Position - portalPos).Magnitude
            
            -- Tahap 1: Jika masih jauh, terus jalan ke target
            if distanceToPortal > 5 then
                moveToTarget(humanoid, rootPart, portalPos)
                task.wait(0.5) -- Beri waktu fungsi jalan bekerja
            
            -- Tahap 2: Sudah sampai di depan portal
            else
                -- Berhenti melangkah (timpa dengan posisi berdiri saat ini)
                humanoid:MoveTo(rootPart.Position)
                
                -- Simulasi delay manusia sebelum memencet tombol (0.5 - 1 detik)
                task.wait(math.random(5, 10) / 10)
                
                local promptClicked = false
                
                -- Cari prompt di area sekitar bot berdiri
                for _, obj in ipairs(Workspace:GetDescendants()) do
                    if obj:IsA("ProximityPrompt") then
                        local actText = obj.ActionText or ""
                        local objText = obj.ObjectText or ""
                        
                        -- Verifikasi ini benar-benar prompt portal
                        if string.find(actText, "Plaza") or string.find(objText, "Teleporter") then
                            local parentObj = obj.Parent
                            local promptPos = nil
                            
                            if parentObj:IsA("Attachment") then
                                promptPos = parentObj.WorldPosition
                            elseif parentObj:IsA("BasePart") then
                                promptPos = parentObj.Position
                            elseif parentObj:IsA("Model") and parentObj.PrimaryPart then
                                promptPos = parentObj.PrimaryPart.Position
                            end
                            
                            -- Validasi ganda: jarak bot dengan titik prompt aktual harus dekat (< 10 stud)
                            if promptPos and (rootPart.Position - promptPos).Magnitude <= 10 then
                                fireproximityprompt(obj)
                                promptClicked = true
                                break
                            end
                        end
                    end
                end
                
                -- Jika sudah sampai tapi prompt gagal diklik/tidak ketemu, geser karakter sedikit agar tidak bug/nyangkut
                if not promptClicked then
                    humanoid:MoveTo(portalPos + Vector3.new(math.random(-3, 3), 0, math.random(-3, 3)))
                end
                
                -- Tunggu efek loading game memproses perpindahan server
                task.wait(3)
            end
        end
    end)
    return
end

-- Anti-AFK Metode Bersih (Mematikan sinyal idle dari akarnya via getconnections)
task.spawn(function()
    pcall(function()
        for _, connection in ipairs(getconnections(LocalPlayer.Idled)) do
            connection:Disable()
        end
    end)
end)

local successReplion, Replion = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Replion")) 
end)
local successItemUtil, ItemUtility = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemUtility")) 
end)
local successTrade, TradeData = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Trading"):WaitForChild("TradeData"))
end)

local allVariants = {}
if successItemUtil and ItemUtility then
    pcall(function()
        local successVar, vars = pcall(ItemUtility.GetVariants)
        if successVar and vars then allVariants = vars end
    end)
end

local successInternal, InternalUtility = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ToolTip"):WaitForChild("Internal"):WaitForChild("Utility")) 
end)

if not successReplion or not successItemUtil or not successTrade then
    return
end

local serverBrowserReplion = Replion.Client:WaitReplion("ServerBrowser")

local TIMER_DURATION = 900 
local hopDeadline = os.time() + TIMER_DURATION   -- waktu absolut kapan harus hop (anti-drift)
local hasActiveStock = true
local isBoothClaimed = false
local isHopping = false
local HOP_RETRY_DELAY = 10     -- jeda coba lagi kalau hop gagal
local NO_STOCK_RECHECK = 60    -- booth kosong: cek ulang tiap 60 dtk (tidak hop)

-- Hop otomatis kalau server sepi
local MIN_PLAYERS = 14             -- server dengan pemain < angka ini dianggap sepi -> hop
local LOW_PLAYER_GRACE = 6         -- tunggu sebentar setelah join supaya daftar player lengkap

-- Aturan server tujuan hop (berlaku untuk SEMUA jenis hop: timer habis, server sepi, gagal claim booth)
local MIN_RAP_PRIMARY  = 250000    -- target utama: server dengan RAP >= 250k
local MIN_RAP_FALLBACK = 100000    -- cadangan terakhir: RAP >= 100k (HANYA setelah target utama benar-benar gagal)
local RETRY_PER_ROUND  = 5         -- maks percobaan masuk per 1 list server
local RETRY_DELAY      = 5         -- jeda antar percobaan (detik); selama jeda server blacklist tetap dipantau
local PRIMARY_ROUNDS   = 3         -- berapa kali list di-refresh & diulang untuk target utama sebelum turun ke cadangan
local REFRESH_WAIT     = 3         -- lama proses refresh list (detik); server blacklist tetap dipantau
local BLACKLIST_TTL    = 120       -- lama (detik) server gagal masuk blacklist
local WATCH_COOLDOWN   = 4         -- jeda minimal sebelum server blacklist boleh dicoba lagi saat dipantau
local WATCH_STEP       = 0.5       -- interval pemantauan slot server blacklist (detik)

-- Claim booth
local MAX_CLAIM_ATTEMPTS = 6       -- berapa kali boleh ganti/ulang booth target
local CLAIM_FIRE_TRIES = 3         -- berapa kali menekan prompt pada 1 booth
local CLAIM_VERIFY_TIMEOUT = 3     -- detik menunggu bukti kepemilikan setelah menekan prompt
local CLAIM_STAND_OFFSET = 5         -- jarak berdiri dari prompt booth (stud). Lebih jauh dari dinding booth = bot tidak nyangkut
local CLAIM_STAND_RADIUS = 2         -- ruang kosong minimal di sekeliling titik berdiri (stud)
local isClaiming = false           -- true selama proses claim berjalan (watcher sepi menunggu)

local function getPlayerCount()
    return #Players:GetPlayers()
end

local function getTimeLeft()
    return math.max(0, hopDeadline - os.time())
end

local function getBotTokens()
    local tokens = 0
    pcall(function()
        local playerData = Replion.Client:WaitReplion("Data")
        if playerData then
            tokens = playerData:Get("Tokens") or 0
        end
    end)
    return tokens
end

local function getItemRAP(itemType, itemId)
    local rapVal = 0
    pcall(function()
        local rapReplion = Replion.Client:GetReplion("RAP")
        if not rapReplion then
            rapReplion = Replion.Client:WaitReplion("RAP")
        end
        
        if rapReplion and itemId then
            local itemData = ItemUtility.GetItemDataFromItemType(itemType, itemId)
            if itemData then
                local tId = TradeData.GetItemId(itemType, itemData)
                local val = rapReplion:Get({ "RAPs", itemType, tId })
                if val and val ~= -1 then
                    rapVal = tonumber(val) or 0
                end
            end
        end
    end)
    return rapVal
end

local function formatItemName(realName, weight, sizeCategory)
    if sizeCategory == "Max" then
        return "Big " .. realName .. " [MAX] [" .. weight .. "kg]"
    elseif sizeCategory == "Big" then
        return "Big " .. realName .. " [" .. weight .. "kg]"
    else
        return realName .. " [" .. weight .. "kg]"
    end
end

local function extractItemMetadata(itemInfo, itemData, categoryName)
    local metadata = itemData.Metadata or {}
    local rawMutation = metadata.VariantId
    local isShiny = metadata.Shiny == true
    
    local finalMutation = ""
    if rawMutation and isShiny then finalMutation = tostring(rawMutation) .. " Shiny"
    elseif rawMutation then finalMutation = tostring(rawMutation)
    elseif isShiny then finalMutation = "Shiny" end

    local mutationColorStr = ""
    if rawMutation then
        local currentVariants = allVariants
        if not currentVariants or not next(currentVariants) then
            pcall(function()
                local s, v = pcall(ItemUtility.GetVariants)
                if s and v then currentVariants = v end
            end)
        end

        for k, v in pairs(currentVariants) do
            local mutName = v._moduleScript or tostring(k)
            if tostring(mutName) == tostring(rawMutation) then
                local tierColor = (v.Data and v.Data.TierColor)
                if tierColor then
                    mutationColorStr = tostring(tierColor)
                end
                break
            end
        end
    end

    local rarityName = "Common"
    if successInternal and InternalUtility and InternalUtility.getTierData then
        local succTier, tierData = pcall(function() return InternalUtility.getTierData(itemInfo) end)
        if succTier and tierData and tierData.Name then rarityName = tostring(tierData.Name) end
    end

    local rawChance = 0
    if itemInfo.Probability and type(itemInfo.Probability) == "table" then
        rawChance = tonumber(itemInfo.Probability.Chance) or 0
    end

    return finalMutation, mutationColorStr, isShiny, rarityName, rawChance
end

-- ==========================================
-- SERVER HOP: selalu cari server RAP tinggi, JANGAN menyerah, blacklist + pantau slot
--
-- Alur (Hop Utama):
--   1. Ambil server terbaik dengan RAP >= MIN_RAP_PRIMARY (250k), bukan blacklist, ada slot.
--   2. Gagal masuk -> coba lagi sampai RETRY_PER_ROUND (5x), jeda RETRY_DELAY (5 dtk) per percobaan.
--   3. 5x gagal -> refresh list server (data segar), ulang dari langkah 1 (maks PRIMARY_ROUNDS putaran).
--   4. Selama jeda & refresh, server yang di-blacklist TETAP DIPANTAU: begitu ada slot kosong
--      langsung dicoba saat itu juga (tidak menunggu TTL blacklist habis).
--   5. Target utama habis semua -> turun ke RAP >= MIN_RAP_FALLBACK (100k) dengan logika yang sama,
--      dan terus mencoba (tidak menyerah) sampai berhasil.
--   Tidak ada lagi teleport ke server acak.
--
-- opts.sepi    = true -> hop karena server sepi: tujuan WAJIB berpemain >= MIN_PLAYERS
-- opts.abortIf = fungsi; kalau return true proses dihentikan (mis. server sudah tidak sepi lagi)
-- return true  = teleport sedang berjalan
-- return false = dibatalkan (abortIf) / sedang hopping / error
-- ==========================================
local function serverHopHighestRAP(opts)
    opts = opts or {}
    local sepiMode = opts.sepi == true
    local abortIf = opts.abortIf
    if isHopping then return false end
    isHopping = true

    task.spawn(function()
        pcall(function()
            request({
                Url = WEB_URL .. "?action=bot_status&username=" .. HttpService:UrlEncode(username) .. "&state=hopping",
                Method = "GET"
            })
        end)
    end)

    local function aborted()
        if not abortIf then return false end
        local okA, r = pcall(abortIf)
        return okA and r == true
    end

    local function getServers()
        local servers = serverBrowserReplion and serverBrowserReplion.Data and serverBrowserReplion.Data.Servers
        if type(servers) == "table" then return servers end
        return nil
    end

    local function readRAP(serverData)
        return tonumber(serverData.RAP or serverData.TotalRAP or serverData.Value) or 0
    end

    local function readCount(serverData)
        return tonumber(serverData.Players or serverData.PlayerCount)
    end

    -- Statistik list server (buat log diagnosa kalau tidak ada kandidat)
    local function listStats()
        local total, maxRAP = 0, 0
        pcall(function()
            local servers = getServers()
            if not servers then return end
            for _, sd in pairs(servers) do
                if type(sd) == "table" then
                    total = total + 1
                    local r = readRAP(sd)
                    if r > maxRAP then maxRAP = r end
                end
            end
        end)
        return total, maxRAP
    end

    -- Server terbaik: RAP >= minRAP, bukan blacklist, pemain >= minPlayers, masih ada slot
    local function pickBest(minRAP, minPlayers)
        local bestJobId, highestRAP = nil, -1
        pcall(function()
            local servers = getServers()
            if not servers then return end
            local now = os.time()
            for jobId, serverData in pairs(servers) do
                local failedAt = failedJobIds[jobId]
                local blacklisted = failedAt and (now - failedAt) < BLACKLIST_TTL
                if jobId ~= game.JobId and type(serverData) == "table" and not blacklisted then
                    local playerCount = readCount(serverData)
                    -- jumlah pemain tidak diketahui (field kosong) -> jangan dibuang oleh filter pemain
                    local okMin = (playerCount == nil) or (playerCount >= minPlayers)
                    local okMax = (playerCount == nil) or (playerCount < (maxPlayers - 1))
                    local serverRAP = readRAP(serverData)
                    if okMin and okMax and serverRAP >= minRAP and serverRAP > highestRAP then
                        highestRAP = serverRAP
                        bestJobId = jobId
                    end
                end
            end
        end)
        return bestJobId
    end

    -- Server BLACKLIST yang sekarang punya slot kosong (RAP tertinggi dulu).
    -- Blacklist tetap berlaku untuk pemilihan biasa; ini hanya "pintu cepat" kalau slot terbuka.
    local function pickBlacklistedWithSlot(minRAP, minPlayers)
        local bestJobId, highestRAP = nil, -1
        pcall(function()
            local servers = getServers()
            if not servers then return end
            local now = os.time()
            for jobId, failedAt in pairs(failedJobIds) do
                local age = now - failedAt
                local serverData = servers[jobId]
                if jobId ~= game.JobId and age >= WATCH_COOLDOWN and age < BLACKLIST_TTL and type(serverData) == "table" then
                    local playerCount = readCount(serverData)
                    local serverRAP = readRAP(serverData)
                    if playerCount and playerCount < maxPlayers and playerCount >= minPlayers
                        and serverRAP >= minRAP and serverRAP > highestRAP then
                        highestRAP = serverRAP
                        bestJobId = jobId
                    end
                end
            end
        end)
        return bestJobId
    end

    -- 1 percobaan teleport. true = tidak ada sinyal gagal (teleport berjalan), false = ditolak/gagal.
    local function tryTeleport(jobId)
        lastHopFailed = false
        pendingHopJobId = jobId
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer)
        end)
        if not ok then
            failedJobIds[jobId] = os.time()
            pendingHopJobId = nil
            return false
        end
        local t0 = tick()
        while tick() - t0 < 15 and not lastHopFailed do task.wait(0.5) end
        if lastHopFailed then
            failedJobIds[jobId] = os.time()   -- pastikan masuk blacklist walau handler telat
            pendingHopJobId = nil
            return false
        end
        return true
    end

    -- Menunggu `seconds` detik, TAPI tetap memantau server blacklist: ada slot -> langsung gas.
    -- return "ok" (teleport berjalan) / "abort" / nil (waktu habis)
    local function waitAndWatch(seconds, minRAP)
        local watchMinPlayers = sepiMode and MIN_PLAYERS or 0
        local t0 = tick()
        while tick() - t0 < seconds do
            if aborted() then return "abort" end
            local lockId = pickBlacklistedWithSlot(minRAP, watchMinPlayers)
            if lockId then
                warn("[HOP] Slot terbuka di server blacklist, langsung masuk: " .. tostring(lockId))
                if tryTeleport(lockId) then return "ok" end
            end
            task.wait(WATCH_STEP)
        end
        return nil
    end

    -- 1 putaran = maks RETRY_PER_ROUND percobaan pada list yang ada
    -- return "ok" / "abort" / "fail"
    local function runRound(minRAP)
        for attempt = 1, RETRY_PER_ROUND do
            if aborted() then return "abort" end

            local jobId = pickBest(minRAP, MIN_PLAYERS)
            if not jobId and not sepiMode then
                jobId = pickBest(minRAP, 0)   -- hop biasa: RAP tetap wajib, jumlah pemain boleh berapa saja
            end

            if jobId then
                if tryTeleport(jobId) then return "ok" end
                warn(string.format("[HOP] Gagal masuk server (percobaan %d/%d, RAP>=%d)", attempt, RETRY_PER_ROUND, minRAP))
            else
                local total, maxRAP = listStats()
                warn(string.format("[HOP] Tidak ada server RAP>=%d yang bisa dituju (percobaan %d/%d, server di list: %d, RAP tertinggi: %d)",
                    minRAP, attempt, RETRY_PER_ROUND, total, maxRAP))
            end

            if attempt < RETRY_PER_ROUND then
                local r = waitAndWatch(RETRY_DELAY, minRAP)
                if r then return r end
            end
        end
        return "fail"
    end

    -- Refresh list: ambil handle replion segar + buang blacklist yang sudah kedaluwarsa.
    -- Selama refresh, server blacklist tetap dipantau (lock-in).
    -- return "ok" / "abort" / nil
    local function refreshServerList(minRAP)
        pcall(function()
            local fresh = Replion.Client:GetReplion("ServerBrowser")
            if fresh then serverBrowserReplion = fresh end
        end)
        local now = os.time()
        for jobId, failedAt in pairs(failedJobIds) do
            if now - failedAt >= BLACKLIST_TTL then failedJobIds[jobId] = nil end
        end
        warn("[HOP] Refresh list server...")
        return waitAndWatch(REFRESH_WAIT, minRAP)
    end

    local function core()
        local tiers = {
            { minRAP = MIN_RAP_PRIMARY,  rounds = PRIMARY_ROUNDS },
            { minRAP = MIN_RAP_FALLBACK, rounds = math.huge },   -- cadangan: tidak pernah menyerah
        }
        for tierIndex, tier in ipairs(tiers) do
            if tierIndex > 1 then
                warn("[HOP] Server RAP>=" .. MIN_RAP_PRIMARY .. " tidak berhasil, turun ke RAP>=" .. tier.minRAP)
            end
            local round = 0
            while round < tier.rounds do
                round = round + 1
                local r = runRound(tier.minRAP)
                if r == "ok" then return true end
                if r == "abort" then return false end

                local rr = refreshServerList(tier.minRAP)
                if rr == "ok" then return true end
                if rr == "abort" then return false end
            end
        end
        return false
    end

    -- pcall supaya error tak pernah meninggalkan isHopping = true (bot nyangkut)
    local okCore, result = pcall(core)
    isHopping = false
    if not okCore then
        warn("[HOP] Error di serverHopHighestRAP: " .. tostring(result))
        return false
    end
    return result == true
end

local function resetInactivityTimer()
    hopDeadline = os.time() + TIMER_DURATION
end

-- Item BARU dipajang: timer cuma +3 menit (tidak lebih dari batas TIMER_DURATION)
local TIMER_ADD_NEW_ITEM = 180
local function extendInactivityTimer(sec)
    hopDeadline = math.min(hopDeadline + sec, os.time() + TIMER_DURATION)
end

-- ==========================================
-- CLAIM BOOTH + VERIFIKASI
-- Status kepemilikan dibaca dari attribute "Owner" pada booth:
--   "free"    = kosong
--   "mine"    = milik bot (cocok UserId / Name / DisplayName)
--   "other"   = milik player lain (cocok dengan player lain di server)
--   "unknown" = terisi tapi formatnya tidak dikenali (dianggap berhasil hanya
--               kalau barusan kita yang menekan prompt & tidak ada player lain yang cocok)
-- ==========================================
local function boothOwnerState(booth)
    local owner = booth:GetAttribute("Owner")
    if owner == nil or owner == 0 or owner == "" or owner == false then return "free" end
    local s = tostring(owner)
    if s == tostring(LocalPlayer.UserId) or s == LocalPlayer.Name or s == LocalPlayer.DisplayName then
        return "mine"
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and (s == tostring(p.UserId) or s == p.Name or s == p.DisplayName) then
            return "other"
        end
    end
    return "unknown"
end

local function findMyBooth()
    for _, booth in ipairs(CollectionService:GetTagged("Booth")) do
        if boothOwnerState(booth) == "mine" then return booth end
    end
    return nil
end

local function pickFreeBooth(rootPart, skipped)
    local targetBooth, shortestDist = nil, math.huge
    pcall(function()
        for _, booth in ipairs(CollectionService:GetTagged("Booth")) do
            if not skipped[booth] and boothOwnerState(booth) == "free" then
                local bPart = booth.PrimaryPart or booth:FindFirstChildWhichIsA("BasePart")
                local hasPrompt = booth:FindFirstChildWhichIsA("ProximityPrompt", true)
                if bPart and hasPrompt then
                    local dist = (rootPart.Position - bPart.Position).Magnitude
                    if dist < shortestDist then shortestDist = dist; targetBooth = booth end
                end
            end
        end
    end)
    return targetBooth
end

local function getPromptPosition(prompt)
    local p = prompt.Parent
    if not p then return nil end
    if p:IsA("Attachment") then return p.WorldPosition end
    if p:IsA("BasePart") then return p.Position end
    if p:IsA("Model") then return p:GetPivot().Position end
    return nil
end

local function getPromptCFrame(prompt)
    local p = prompt.Parent
    if not p then return nil end
    if p:IsA("Attachment") then return p.WorldCFrame end
    if p:IsA("BasePart") then return p.CFrame end
    if p:IsA("Model") then return p:GetPivot() end
    return nil
end

-- true kalau titik tidak menempel / tertanam di benda yang bisa ditabrak (dinding booth, properti, dll)
local function isStandSpotClear(pos)
    local ok, parts = pcall(function()
        local params = OverlapParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { LocalPlayer.Character }
        -- pusat dinaikkan sedikit supaya lantai tidak ikut terhitung
        return Workspace:GetPartBoundsInRadius(pos + Vector3.new(0, 2.5, 0), CLAIM_STAND_RADIUS, params)
    end)
    if not ok or type(parts) ~= "table" then return true end   -- tidak bisa dicek: anggap kosong (perilaku lama)
    for _, part in ipairs(parts) do
        if part.CanCollide then return false end
    end
    return true
end

-- Titik berdiri di depan booth, dengan offset CLAIM_STAND_OFFSET dari prompt.
-- Kandidat dicoba berurutan (depan, belakang, samping) pada beberapa jarak; dipilih yang ruangnya kosong
-- dan masih dalam jangkauan prompt. Kalau tidak ada yang kosong, pakai kandidat pertama (depan).
local function getStandPosition(booth, prompt)
    local cf = getPromptCFrame(prompt)
    if not cf then
        return booth:GetPivot().Position + Vector3.new(0, 0, CLAIM_STAND_OFFSET)
    end
    local function flat(v)
        local f = Vector3.new(v.X, 0, v.Z)
        if f.Magnitude < 0.05 then return nil end
        return f.Unit
    end
    local look, right = flat(cf.LookVector), flat(cf.RightVector)
    local dirs = {}
    if look then dirs[#dirs + 1] = look; dirs[#dirs + 1] = -look end
    if right then dirs[#dirs + 1] = right; dirs[#dirs + 1] = -right end
    if #dirs == 0 then dirs[1] = Vector3.new(0, 0, 1) end

    local maxRange = math.max(4, math.min(tonumber(prompt.MaxActivationDistance) or 10, 10) - 1.5)
    local first = nil
    for _, dist in ipairs({ CLAIM_STAND_OFFSET, CLAIM_STAND_OFFSET - 1.5, CLAIM_STAND_OFFSET + 1.5 }) do
        if dist >= 2 and dist <= maxRange then
            for _, dir in ipairs(dirs) do
                local pos = cf.Position + dir * dist
                first = first or pos
                if isStandSpotClear(pos) then return pos end
            end
        end
    end
    return first or (cf.Position + dirs[1] * CLAIM_STAND_OFFSET)
end

-- Bot terjepit / macet dekat booth: lompat lalu mundur menjauhi booth supaya jalur dihitung ulang
local function unstickFromBooth(humanoid, rootPart, booth)
    pcall(function()
        local away = rootPart.Position - booth:GetPivot().Position
        away = Vector3.new(away.X, 0, away.Z)
        if away.Magnitude < 0.1 then away = Vector3.new(0, 0, 1) end
        humanoid.Jump = true
        humanoid:MoveTo(rootPart.Position + away.Unit * 6)
        task.wait(1.2)
    end)
end

-- Satu percobaan claim pada satu booth.
-- return "ok" (terverifikasi milik bot) | "stolen" (diambil player lain) | "failed" (prompt tidak merespons)
local function tryClaimBooth(booth, humanoid, rootPart)
    local prompt = booth:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not prompt then return "failed" end

    -- Jalan ke booth sambil terus memantau: kalau keduluan player lain, jalan langsung dibatalkan
    local gotStolen = false
    local reached = moveToTarget(humanoid, rootPart, getStandPosition(booth, prompt), function()
        if boothOwnerState(booth) ~= "free" then gotStolen = true; return true end
        return false
    end)
    if gotStolen or boothOwnerState(booth) == "other" then return "stolen" end
    if boothOwnerState(booth) == "mine" then return "ok" end
    task.wait(0.3)

    for fireTry = 1, CLAIM_FIRE_TRIES do
        local state = boothOwnerState(booth)
        if state == "mine" then return "ok" end
        if state ~= "free" then return "stolen" end

        -- pastikan benar-benar dekat dengan prompt sebelum menekan
        local pp = getPromptPosition(prompt)
        if pp and (rootPart.Position - pp).Magnitude > 10 then
            if fireTry >= 2 then unstickFromBooth(humanoid, rootPart, booth) end   -- sudah gagal sekali: kemungkinan nyangkut
            moveToTarget(humanoid, rootPart, getStandPosition(booth, prompt), function()
                return boothOwnerState(booth) ~= "free"
            end)
            if boothOwnerState(booth) ~= "free" then
                return boothOwnerState(booth) == "mine" and "ok" or "stolen"
            end
        end

        task.wait((prompt.HoldDuration or 0.5) + 0.1)
        pcall(fireproximityprompt, prompt)

        -- tunggu bukti kepemilikan
        local t0 = tick()
        while tick() - t0 < CLAIM_VERIFY_TIMEOUT do
            local st = boothOwnerState(booth)
            if st == "mine" then return "ok" end
            if st == "other" then return "stolen" end
            if st == "unknown" then
                -- terisi tapi bukan milik player lain mana pun -> hampir pasti milik bot (format Owner tidak dikenal)
                warn("[BOOTH] Format Owner tidak dikenal, dianggap berhasil:", tostring(booth:GetAttribute("Owner")))
                return "ok"
            end
            task.wait(0.2)
        end
        -- belum berubah: tekan lagi
    end
    return "failed"
end

-- Claim booth dengan verifikasi + retry (ganti booth kalau keduluan).
-- return true HANYA kalau kepemilikan sudah terverifikasi.
local function autoClaimBooth()
    isClaiming = true
    local claimed = false

    local ok, err = pcall(function()
        local skipped = {}      -- booth yang sudah gagal / keduluan -> jangan dicoba lagi
        local failCount = {}

        for attempt = 1, MAX_CLAIM_ATTEMPTS do
            local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
            local humanoid = character:WaitForChild("Humanoid")
            local rootPart = character:WaitForChild("HumanoidRootPart")

            -- sudah punya booth (mis. claim sebelumnya ternyata masuk)
            if findMyBooth() then claimed = true; return end

            local booth = pickFreeBooth(rootPart, skipped)
            if not booth then
                warn("[BOOTH] Tidak ada booth kosong tersisa (percobaan " .. attempt .. ")")
                return
            end

            local result = tryClaimBooth(booth, humanoid, rootPart)
            if result == "ok" or boothOwnerState(booth) == "mine" or findMyBooth() then
                claimed = true
                return
            elseif result == "stolen" then
                warn("[BOOTH] Booth keduluan player lain, cari booth lain (percobaan " .. attempt .. ")")
                skipped[booth] = true
            else
                failCount[booth] = (failCount[booth] or 0) + 1
                warn("[BOOTH] Claim tidak merespons (percobaan " .. attempt .. ")")
                if failCount[booth] >= 2 then skipped[booth] = true end
            end
            task.wait(0.5)
        end
    end)

    isClaiming = false
    if not ok then warn("[BOOTH] autoClaimBooth error:", err) end
    return ok and claimed
end

-- Cache booth sendiri. Listing yang hilang dari booth = kandidat item terjual; dicocokkan dengan event penjualan
-- supaya identitas item (nama, mutasi, berat, dll) diambil dari listing itu sendiri, bukan ditebak.
local boothCache = {}         -- uuid -> {row, base, id}  (listing yang sedang ada di booth)
local boothVanished = {}      -- uuid -> {row, base, id, t}  (baru hilang dari booth)
local boothIgnoreVanish = {}  -- uuid yang sengaja di-unlist bot: hilangnya bukan penjualan
local BOOTH_VANISH_TTL = 30   -- detik kandidat terjual disimpan
local BOOTH_MATCH_WINDOW = 8  -- kandidat dianggap cocok kalau hilangnya <= sekian detik dari event penjualan

local function updateBoothCache(presentSet, entries)
    local now = tick()
    for uuid, e in pairs(boothCache) do
        if not presentSet[uuid] then
            if boothIgnoreVanish[uuid] then
                boothIgnoreVanish[uuid] = nil
            else
                e.t = now
                boothVanished[uuid] = e
            end
        end
    end
    for uuid, e in pairs(entries) do
        boothVanished[uuid] = nil   -- muncul lagi (mis. dipasang ulang) = bukan terjual
        boothCache[uuid] = e
    end
    for uuid in pairs(boothCache) do
        if not presentSet[uuid] then boothCache[uuid] = nil end
    end
    for uuid, e in pairs(boothVanished) do
        if now - e.t > BOOTH_VANISH_TTL then boothVanished[uuid] = nil end
    end
end

local function getActiveBoothItems()
    local boothItemsPayload = {}
    local readOk, presentSet, cacheEntries = false, {}, {}
    pcall(function()
        local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
        if not saleListingsReplion then return end
        local listings = saleListingsReplion:Get({"Players", tostring(LocalPlayer.UserId), "Booth"})
        
        if listings and type(listings) == "table" then
            readOk = true   -- hanya kalau booth benar-benar terbaca, cache boleh diperbarui
            for listingId, listingData in pairs(listings) do
                if listingData and listingData.Item then
                    local item = listingData.Item
                    presentSet[tostring(item.UUID)] = true
                    local catName = listingData.ItemType or "Items"
                    local price = listingData.Price or 0
                    local sInfo, itemInfo = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, item.Id) end)
                    
                    if sInfo and itemInfo and itemInfo.Data then
                        local realData = itemInfo.Data
                        local metadata = item.Metadata or {}
                        local weight = tonumber(metadata.Weight) or 0
                        
                        local bigMin = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Min) or 0
                        local bigMax = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Max) or 0

                        local sizeCategory = "Biasa"
                        if itemInfo.Weight and itemInfo.Weight.Big then
                            if weight >= bigMax then
                                sizeCategory = "Max"
                            elseif weight >= bigMin then
                                sizeCategory = "Big"
                            end
                        end

                        local finalName = formatItemName(realData.Name, weight, sizeCategory)
                        local finalMutation, mutationColorStr, isShiny, rarityName, rawChance = extractItemMetadata(itemInfo, item, catName)
                        local itemRAP = getItemRAP(realData.Type or catName, item.Id)

                        local row = {
                            UUID = tostring(item.UUID),
                            Name = finalName,
                            Type = tostring(realData.Type or catName),
                            Category = tostring(catName),
                            Icon = tostring(realData.Icon or realData.Image or itemInfo.Icon or itemInfo.Image or ""),
                            Weight = weight,
                            SizeCategory = sizeCategory,
                            BigMin = bigMin,
                            BigMax = bigMax,
                            Mutation = finalMutation,
                            MutationColor = mutationColorStr,
                            Shiny = isShiny,
                            RAP = itemRAP,
                            Price = tonumber(price) or 0,
                            Rarity = rarityName,
                            Chance = rawChance
                        }
                        table.insert(boothItemsPayload, row)
                        cacheEntries[row.UUID] = { row = row, base = tostring(realData.Name), id = item.Id }
                    end
                end
            end
        end
    end)
    if readOk then pcall(updateBoothCache, presentSet, cacheEntries) end
    return boothItemsPayload
end

-- Cari listing booth sendiri yang menjadi sumber event penjualan.
-- return entry, cara   (cara: "uuid" | "price_name" | "weight" | "name"); entry nil kalau tidak ketemu ("ambiguous" / "none")
local function findSoldListing(evUuid, evBase, evPrice, evWeight)
    local now = tick()
    -- 1) UUID persis (paling pasti)
    if evUuid and evUuid ~= "" then
        local e = boothVanished[evUuid] or boothCache[evUuid]
        if e then return e, "uuid" end
    end
    -- 2) kandidat = listing yang baru hilang dari booth
    local pool = {}
    for _, e in pairs(boothVanished) do
        if now - e.t <= BOOTH_MATCH_WINDOW then pool[#pool + 1] = e end
    end
    local byPN = {}
    for _, e in ipairs(pool) do
        if (not evBase or e.base == evBase) and (tonumber(e.row.Price) or 0) == evPrice then byPN[#byPN + 1] = e end
    end
    if #byPN == 1 then return byPN[1], "price_name" end
    if #byPN > 1 then
        local byW = {}
        for _, e in ipairs(byPN) do
            if math.abs((tonumber(e.row.Weight) or 0) - evWeight) < 0.001 then byW[#byW + 1] = e end
        end
        if #byW == 1 then return byW[1], "weight" end
        return nil, "ambiguous"
    end
    -- 3) harga di event bisa berbeda dari harga listing: terima kalau hanya 1 kandidat dengan nama sama
    if evBase then
        local byN = {}
        for _, e in ipairs(pool) do
            if e.base == evBase then byN[#byN + 1] = e end
        end
        if #byN == 1 then return byN[1], "name" end
        if #byN > 1 then return nil, "ambiguous" end
    end
    return nil, "none"
end

-- Segarkan cache dulu (listing yang baru terjual harus sudah terdeteksi hilang), coba sampai 3x.
-- Listing yang cocok langsung "dipakai" (dibuang dari cache) supaya tidak dicocokkan ke 2 penjualan.
local function resolveSoldListing(evUuid, evBase, evPrice, evWeight)
    local entry, how = nil, "none"
    for _ = 1, 3 do
        pcall(getActiveBoothItems)
        entry, how = findSoldListing(evUuid, evBase, evPrice, evWeight)
        if entry then
            boothVanished[entry.row.UUID] = nil
            boothCache[entry.row.UUID] = nil
            break
        end
        if how == "ambiguous" then break end
        task.wait(0.7)
    end
    return entry, how
end

-- Cache booth disegarkan tiap 2 detik supaya listing yang terjual/hilang cepat terdeteksi
task.spawn(function()
    while true do
        task.wait(2)
        pcall(getActiveBoothItems)
    end
end)

local function syncBoothOnly()
    local boothItemsPayload = getActiveBoothItems()
    local tokens = getBotTokens()
    hasActiveStock = (#boothItemsPayload > 0)

    pcall(function()
        request({
            Url = WEB_URL .."?action=sync_booth",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({ 
                username = username, 
                tokens = tokens,
                booth_items = boothItemsPayload
            })
        })
    end)
end

local function syncInventoryToWeb()
    local playerData = Replion.Client:WaitReplion("Data")
    if not playerData then return end
    local inventory = playerData:Get("Inventory")
    if not inventory then return end

    local payloadItems = {}
    for catName, items in pairs(inventory) do
        if type(items) == "table" then
            for _, itemData in ipairs(items) do
                if itemData and itemData.Id and itemData.UUID then
                    local sItem, itemInfo = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, itemData.Id) end)
                    if sItem and itemInfo and itemInfo.Data then
                        local canTrade = false
                        pcall(function() canTrade = TradeData.FollowTradeRules(itemInfo, { Metadata = itemData.Metadata }) end)
                        if canTrade then
                            local realData = itemInfo.Data
                            local metadata = itemData.Metadata or {}
                            local weight = tonumber(metadata.Weight) or 0
                            
                            local bigMin = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Min) or 0
                            local bigMax = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Max) or 0

                            local sizeCategory = "Biasa"
                            if itemInfo.Weight and itemInfo.Weight.Big then
                                if weight >= bigMax then
                                    sizeCategory = "Max"
                                elseif weight >= bigMin then
                                    sizeCategory = "Big"
                                end
                            end

                            local finalName = formatItemName(realData.Name, weight, sizeCategory)
                            local finalMutation, mutationColorStr, isShiny, rarityName, rawChance = extractItemMetadata(itemInfo, itemData, catName)
                            local itemRAP = getItemRAP(realData.Type or catName, itemData.Id)

                            table.insert(payloadItems, {
                                UUID = tostring(itemData.UUID),
                                Name = finalName,
                                Type = tostring(realData.Type or catName),
                            Category = tostring(catName),
                                Icon = tostring(realData.Icon or realData.Image or itemInfo.Icon or itemInfo.Image or ""),
                                Weight = weight,
                                SizeCategory = sizeCategory,
                                BigMin = bigMin,
                                BigMax = bigMax,
                                Mutation = finalMutation,
                                MutationColor = mutationColorStr,
                                Shiny = isShiny,
                                RAP = itemRAP,
                                Rarity = rarityName,
                                Chance = rawChance
                            })
                        end
                    end
                end
            end
        end
    end

    local boothItemsPayload = getActiveBoothItems()
    local tokens = getBotTokens()

    pcall(function()
        request({
            Url = WEB_URL .."?action=sync_inventory",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({ 
                username = username, 
                tokens = tokens,
                items = payloadItems,
                booth_items = boothItemsPayload
            })
        })
    end)
end

local function processQueue()
    pcall(function()
        local boothItems = getActiveBoothItems()
        if #boothItems >= MAX_BOOTH_SLOTS then
            return 
        end

        local response = request({
            Url = WEB_URL .."?action=get_next_queue&username=" .. HttpService:UrlEncode(username),
            Method = "GET"
        })

        if response.StatusCode == 200 then
            local resData = HttpService:JSONDecode(response.Body)
            if resData.status == 'ok' and resData.queue then
                local q = resData.queue
                local targetUuid = q.uuid
                local targetPrice = tonumber(q.price)

                local playerData = Replion.Client:WaitReplion("Data")
                local inventory = playerData and playerData:Get("Inventory")
                local targetType = nil

                if inventory then
                    for catName, items in pairs(inventory) do
                        for _, itm in ipairs(items) do
                            if itm.UUID == targetUuid then
                                local sInfo, info = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, itm.Id) end)
                                if sInfo and info and info.Data then
                                    targetType = info.Data.Type or catName
                                end
                                break
                            end
                        end
                        if targetType then break end
                    end
                end

                if targetType and targetPrice then
                    local success = pcall(function()
                        return TradeData.Remotes.CreateSaleListing:InvokeServer("Booth", targetType, targetUuid, targetPrice)
                    end)

                    if success then
                        -- timer +3 mnt ditangani watcher booth (item baru terdeteksi)
                        task.spawn(function() task.wait(1.5); syncBoothOnly() end)
                    end
                end
            end
        end
    end)
end

task.spawn(function()
    pcall(function()
        TradeData.Remotes.SaleListingSold.OnClientEvent:Connect(function(buyer, _, _, itemType, itemData, price)
            local ev = type(itemData) == "table" and itemData or {}
            local sInfo, itemInfo = pcall(function() return ItemUtility.GetItemDataFromItemType(itemType, ev.Id) end)
            local realData = (sInfo and itemInfo and itemInfo.Data) and itemInfo.Data or nil
            local metadata = type(ev.Metadata) == "table" and ev.Metadata or {}
            local weight = tonumber(metadata.Weight) or 0
            local sizeCategory = "Biasa"
            if sInfo and type(itemInfo) == "table" and itemInfo.Weight and itemInfo.Weight.Big then
                local bigMin = itemInfo.Weight.Big.Min or 0
                local bigMax = itemInfo.Weight.Big.Max or 0
                if weight >= bigMax then sizeCategory = "Max" elseif weight >= bigMin then sizeCategory = "Big" end
            end
            local itemName = realData and formatItemName(realData.Name, weight, sizeCategory) or "Unknown Item"
            local buyerName = (buyer and buyer.DisplayName) and buyer.DisplayName or "Player"
            local evPrice = tonumber(price) or 0

            -- detail item dari event (dipakai kalau listing sumbernya tidak ketemu)
            local infoTbl = (sInfo and type(itemInfo) == "table") and itemInfo or nil
            local saleMutation, saleMutColor, saleShiny, saleRarity = "", "", false, "Common"
            if infoTbl then
                local okM, m1, m2, m3, m4 = pcall(extractItemMetadata, infoTbl, ev, itemType)
                if okM then saleMutation, saleMutColor, saleShiny, saleRarity = m1, m2, m3, m4 end
            end
            local saleIcon = ""
            if realData then
                saleIcon = tostring(realData.Icon or realData.Image or (infoTbl and (infoTbl.Icon or infoTbl.Image)) or "")
            end
            local saleRAP = 0
            pcall(function() saleRAP = getItemRAP((realData and realData.Type) or itemType, ev.Id) end)
            local saleBase = realData and realData.Name or nil
            local saleUuid = ev.UUID and tostring(ev.UUID) or nil
            local saleCategory = tostring(itemType)

            -- VERIFIKASI: cocokkan dengan listing booth sendiri yang baru hilang.
            -- Kalau ketemu, identitas item diambil dari listing itu (data per UUID), bukan dari event.
            local entry, matchSrc = resolveSoldListing(saleUuid, saleBase and tostring(saleBase) or nil, evPrice, weight)
            if entry then
                local row = entry.row
                if saleBase and tostring(saleBase) ~= entry.base then
                    warn("[SOLD] Event & listing berbeda item -> pakai data listing:", tostring(saleBase), "!=", entry.base)
                end
                itemName = row.Name
                saleMutation, saleMutColor, saleShiny, saleRarity = row.Mutation, row.MutationColor, row.Shiny, row.Rarity
                saleIcon = row.Icon
                weight = tonumber(row.Weight) or 0
                sizeCategory = row.SizeCategory
                saleRAP = row.RAP
                saleBase = entry.base
                saleUuid = row.UUID
                saleCategory = row.Category
            else
                matchSrc = (matchSrc == "ambiguous") and "ambiguous" or "event_only"
            end
            warn(string.format("[SOLD] cocok=%s | event=%s | listing=%s | harga=%s",
                tostring(matchSrc), tostring(saleBase), entry and entry.base or "-", tostring(evPrice)))

            pcall(function()
                request({
                    Url = WEB_URL .."?action=record_sale",
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode({
                        username = username,
                        item_name = itemName,
                        price = evPrice,
                        buyer_name = buyerName,
                        item_uuid = saleUuid,
                        base_name = saleBase,
                        icon = saleIcon,
                        mutation = saleMutation,
                        mutation_color = saleMutColor,
                        shiny = saleShiny == true,
                        weight = weight,
                        size_category = sizeCategory,
                        rarity = saleRarity,
                        category = saleCategory,
                        rap = saleRAP,
                        match = matchSrc
                    })
                })
            end)
            resetInactivityTimer()   -- terjual: reset penuh
            syncBoothOnly()
            task.spawn(processQueue)
            task.spawn(function() task.wait(2); pcall(syncInventoryToWeb) end) -- inventaris dashboard ikut diperbarui
        end)
    end)
end)

task.spawn(function()
    task.wait(5)

    -- Server sepi: langsung hop (logika sama dengan Hop Utama, terus mencoba, tidak diam di server sepi)
    if getPlayerCount() < MIN_PLAYERS then
        local okHop, hopped = pcall(serverHopHighestRAP, {
            sepi = true,
            abortIf = function() return getPlayerCount() >= MIN_PLAYERS end,   -- server mendadak ramai -> batal hop
        })
        if okHop and hopped then return end   -- teleport sedang berjalan
        -- hanya sampai sini kalau server sudah tidak sepi lagi -> lanjut claim booth
    end

    isBoothClaimed = autoClaimBooth()   -- sudah termasuk verifikasi + retry
    if not isBoothClaimed then
        task.wait(2)
        while true do
            local ok, hopped = pcall(serverHopHighestRAP)
            task.wait((ok and hopped) and 20 or HOP_RETRY_DELAY)
        end
    end
    syncBoothOnly()
    processQueue()
    pcall(syncInventoryToWeb) -- inventaris selalu segar tiap bot masuk server baru
end)

task.spawn(function()
    local lastBoothHash = ""
    local lastIds = {}
    local function collectIds(listings)
        local ids = {}
        if type(listings) == "table" then
            for _, data in pairs(listings) do
                local uuid = data and data.Item and data.Item.UUID
                if uuid then ids[tostring(uuid)] = true end
            end
        end
        return ids
    end
    while true do
        task.wait(3)
        pcall(function()
            local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
            if saleListingsReplion then
                local listings = saleListingsReplion:Get({"Players", tostring(LocalPlayer.UserId), "Booth"})
                local currentState = HttpService:JSONEncode(listings or {})
                if lastBoothHash == "" then
                    lastBoothHash = currentState
                    lastIds = collectIds(listings)
                elseif lastBoothHash ~= currentState then
                    local ids = collectIds(listings)
                    local added, removed = false, false
                    for id in pairs(ids) do
                        if not lastIds[id] then added = true; break end
                    end
                    for id in pairs(lastIds) do
                        if not ids[id] then removed = true; break end
                    end
                    lastIds = ids
                    if removed then
                        resetInactivityTimer()                         -- item terjual/di-unlist: reset penuh
                    elseif added then
                        extendInactivityTimer(TIMER_ADD_NEW_ITEM)      -- item baru: +3 menit saja
                    end
                    lastBoothHash = currentState
                    syncBoothOnly()
                    processQueue()
                end
            end
        end)
    end
end)

-- Watcher server sepi: pemain < MIN_PLAYERS -> hop dengan logika Hop Utama (RAP tinggi, retry, refresh, pantau blacklist)
-- Tidak ada lagi jeda diam 30 dtk: fungsi hop terus mencoba sendiri sampai teleport berjalan
-- atau server sudah tidak sepi lagi.
task.spawn(function()
    task.wait(5 + LOW_PLAYER_GRACE)
    while true do
        task.wait(2)
        if not isHopping and not isClaiming and getPlayerCount() < MIN_PLAYERS then
            warn("[HOP] Server sepi (" .. getPlayerCount() .. "/" .. MIN_PLAYERS .. "), pindah server")
            local okHop, hopped = pcall(serverHopHighestRAP, {
                sepi = true,
                abortIf = function() return getPlayerCount() >= MIN_PLAYERS end,
            })
            if okHop and hopped then
                task.wait(20)   -- teleport sedang berjalan
            end
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(1)
        if isBoothClaimed and not isHopping and getTimeLeft() <= 0 then
            -- cek stok LANGSUNG dari booth (bukan flag yang bisa basi)
            local okItems, items = pcall(getActiveBoothItems)
            hasActiveStock = okItems and type(items) == "table" and #items > 0

            if hasActiveStock then
                local okHop, hopped = pcall(serverHopHighestRAP)
                -- JANGAN break: kalau hop gagal, loop tetap hidup dan coba lagi
                hopDeadline = os.time() + ((okHop and hopped) and 20 or HOP_RETRY_DELAY)
            else
                hopDeadline = os.time() + NO_STOCK_RECHECK   -- booth kosong: tidak hop
            end
        end
    end
end)

task.spawn(function()
    while true do
        pcall(function()
            local response = request({
                Url = WEB_URL .."?action=poll_commands&username=" .. HttpService:UrlEncode(username)
                    .. "&timer=" .. getTimeLeft() .. "&stock=" .. (hasActiveStock and 1 or 0),
                Method = "GET"
            })
            if response.StatusCode == 200 then
                local resData = HttpService:JSONDecode(response.Body)
                if resData.timer_duration then
                    local newDur = tonumber(resData.timer_duration)
                    if newDur and newDur > 0 and newDur ~= TIMER_DURATION then
                        TIMER_DURATION = newDur
                        if getTimeLeft() > TIMER_DURATION then hopDeadline = os.time() + TIMER_DURATION end
                    end
                end

                if resData.status == 'ok' and resData.command then
                    local cmd = resData.command
                    if cmd.action_type == 'refresh_inventory' then
                        task.spawn(syncInventoryToWeb)
                    elseif cmd.action_type == 'sell_item' then
                        local playerData = Replion.Client:WaitReplion("Data")
                        local inventory = playerData and playerData:Get("Inventory")
                        local targetType = nil
                        if inventory then
                            for catName, items in pairs(inventory) do
                                for _, itm in ipairs(items) do
                                    if itm.UUID == cmd.item_uuid then
                                        local sInfo, info = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, itm.Id) end)
                                        if sInfo and info and info.Data then targetType = info.Data.Type or catName end
                                        break
                                    end
                                end
                                if targetType then break end
                            end
                        end
                        if targetType then
                            local success, res = pcall(function()
                                return TradeData.Remotes.CreateSaleListing:InvokeServer("Booth", targetType, cmd.item_uuid, tonumber(cmd.price))
                            end)
                            if success and res ~= false then
                                -- timer +3 mnt ditangani watcher booth (item baru terdeteksi)
                                task.spawn(function() task.wait(1.5); syncBoothOnly() end)
                            else
                                warn("[CMD] Listing ditolak game:", res)
                                task.spawn(syncInventoryToWeb) -- data dashboard kemungkinan basi
                            end
                        else
                            warn("[CMD] Item tidak ada di inventaris bot (UUID basi), sinkron ulang inventaris:", cmd.item_uuid)
                            task.spawn(syncInventoryToWeb) -- item hilang dari dashboard otomatis
                        end
                    elseif cmd.action_type == 'unlist_item' then
                        pcall(function()
                            local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
                            if not saleListingsReplion then return end
                            local listings = saleListingsReplion:Get({"Players", tostring(LocalPlayer.UserId), "Booth"})
                            local targetListingId = nil
                            if listings and type(listings) == "table" then
                                for listingId, listingData in pairs(listings) do
                                    if listingData and listingData.Item and listingData.Item.UUID == cmd.item_uuid then
                                        targetListingId = listingId
                                        break
                                    end
                                end
                            end
                            if targetListingId then
                                local success = pcall(function()
                                    return TradeData.Remotes.DeleteSaleListing:InvokeServer("Booth", targetListingId)
                                end)
                                if success then
                                    boothIgnoreVanish[tostring(cmd.item_uuid)] = true   -- hilangnya karena di-unlist, bukan terjual
                                    resetInactivityTimer()
                                    task.spawn(function() task.wait(1.5); syncBoothOnly(); processQueue(); end)
                                end
                            end
                        end)
                    end
                end
            end
        end)
        task.wait(3)
    end
end)

-- ==========================================
-- KATALOG: sinkron nama mutasi & nama item ke API (hanya jalan di plaza)
-- Alur: tanya API apa yang sudah ada -> kirim HANYA yang belum ada -> yang baru otomatis ikut.
-- ==========================================
local CATALOG_FLUSH_INTERVAL = 20   -- detik antar pengecekan/kirim
local CATALOG_BATCH = 200           -- maks entri per kirim

local catKnownMut, catKnownItem = {}, {}   -- yang sudah ada di API
local catPendingMut, catPendingItem = {}, {}   -- yang baru dilihat bot, menunggu dikirim
local catKnownLoaded = false

local function catColorStr(c)
    if type(c) == "table" then
        local parts = {}
        for _, x in ipairs(c) do parts[#parts + 1] = tostring(x) end
        return table.concat(parts, ",")
    end
    return c ~= nil and tostring(c) or ""
end

local function catNoteMutation(name, color)
    name = tostring(name or "")
    if name == "" or catKnownMut[name] or catPendingMut[name] then return end
    catPendingMut[name] = { name = name, color = catColorStr(color) }
end

local function catNoteItem(name, category, rarity, bigMin, bigMax, icon)
    name = tostring(name or "")
    category = tostring(category or "")
    if name == "" then return end
    local key = category .. "|" .. name
    if catKnownItem[key] or catPendingItem[key] then return end
    catPendingItem[key] = {
        name = name, category = category, rarity = tostring(rarity or ""),
        big_min = tonumber(bigMin) or 0, big_max = tonumber(bigMax) or 0,
        icon = tostring(icon or ""),
    }
end

-- Semua mutasi langsung dari game (satu kali per join)
local function catCollectVariants()
    local vars = allVariants
    if type(vars) ~= "table" or not next(vars) then
        local ok, v = pcall(ItemUtility.GetVariants)
        if ok and type(v) == "table" then vars = v end
    end
    if type(vars) ~= "table" then return end
    for k, v in pairs(vars) do
        if type(v) == "table" then
            local ms = v._moduleScript
            local name = ms ~= nil and tostring(ms) or tostring(k)
            name = name:match("([^%.]+)$") or name
            catNoteMutation(name, v.Data and v.Data.TierColor)
        end
    end
end

local function catPost(body)
    local res = request({
        Url = WEB_URL .. "?action=catalog_submit",
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode(body),
    })
    if not res or res.StatusCode ~= 200 then return false end
    local ok, d = pcall(HttpService.JSONDecode, HttpService, res.Body)
    return ok and type(d) == "table" and d.status == "ok"
end

local function catFlush()
    if not isPlazaPlace(game.PlaceId) then return end   -- hanya di plaza
    if next(catPendingMut) == nil and next(catPendingItem) == nil then return end

    -- 1) tanya API: apa saja yang sudah ada? (sekali per join)
    if not catKnownLoaded then
        local res = request({ Url = WEB_URL .. "?action=catalog_known", Method = "GET" })
        if not res or res.StatusCode ~= 200 then return end
        local ok, d = pcall(HttpService.JSONDecode, HttpService, res.Body)
        if not ok or type(d) ~= "table" or d.status ~= "ok" then return end
        for _, n in ipairs(d.mutations or {}) do catKnownMut[tostring(n)] = true end
        for _, k in ipairs(d.items or {}) do catKnownItem[tostring(k)] = true end
        catKnownLoaded = true
    end

    -- 2) saring: buang yang ternyata sudah ada, ambil sisanya (maks CATALOG_BATCH)
    local muts, mutKeys, items, itemKeys = {}, {}, {}, {}
    for name, e in pairs(catPendingMut) do
        if catKnownMut[name] then
            catPendingMut[name] = nil
        elseif #muts < CATALOG_BATCH then
            muts[#muts + 1] = e; mutKeys[#mutKeys + 1] = name
        end
    end
    for key, e in pairs(catPendingItem) do
        if catKnownItem[key] then
            catPendingItem[key] = nil
        elseif #items < CATALOG_BATCH then
            items[#items + 1] = e; itemKeys[#itemKeys + 1] = key
        end
    end
    if #muts == 0 and #items == 0 then return end

    -- 3) kirim hanya yang baru
    if catPost({ username = username, mutations = muts, items = items }) then
        for _, n in ipairs(mutKeys) do catKnownMut[n] = true; catPendingMut[n] = nil end
        for _, k in ipairs(itemKeys) do catKnownItem[k] = true; catPendingItem[k] = nil end
    end
end

task.spawn(function()
    task.wait(6)
    pcall(catCollectVariants)
    while true do
        pcall(catFlush)
        task.wait(CATALOG_FLUSH_INTERVAL)
    end
end)


-- ==========================================
-- FIND ITEMS: aturan dari dashboard (menu "Find Items") -> scan booth pemain lain -> lapor ke API
-- Webhook Discord diurus server (URL tidak ada di script).
-- Scan juga mengisi katalog (nama item & mutasi), jadi selalu jalan di plaza.
-- ==========================================
local FIND_SCAN_INTERVAL = 3    -- detik antar scan booth
local FIND_RULES_INTERVAL = 15  -- detik antar cek perubahan aturan (kalau tidak berubah, jawaban API sangat kecil)

local findRules = {}
local findEnabled = false
local findVer = ""              -- versi aturan yang sedang dipakai
local watchSeen = {}            -- UUID|harga yang sudah dievaluasi

local function lc(s) return string.lower(tostring(s or "")) end

local function toSet(list)
    local set, n = {}, 0
    if type(list) == "table" then
        for _, v in ipairs(list) do set[lc(v)] = true; n = n + 1 end
    end
    return set, n
end

local function fetchFindRules()
    local res = request({
        Url = WEB_URL .. "?action=find_rules&ver=" .. HttpService:UrlEncode(findVer),
        Method = "GET",
    })
    if not res or res.StatusCode ~= 200 then return end
    local ok, d = pcall(HttpService.JSONDecode, HttpService, res.Body)
    if not ok or type(d) ~= "table" or d.status ~= "ok" or d.unchanged then return end

    local rules = {}
    for _, r in ipairs(d.rules or {}) do
        local itemSet, itemN = toSet(r.items)
        local mutSet, mutN = toSet(r.mutations)
        rules[#rules + 1] = {
            id = tonumber(r.id) or 0,
            itemSet = itemSet, itemN = itemN,
            mutSet = mutSet, mutN = mutN,
            size = tostring(r.size or ""),
            minWeight = tonumber(r.min_weight) or 0,
            maxWeight = tonumber(r.max_weight) or 0,
            maxPrice = tonumber(r.max_price) or 0,
        }
    end
    findRules = rules
    findEnabled = (tonumber(d.enabled) or 0) == 1
    findVer = tostring(d.ver or "")
    watchSeen = {}   -- aturan berubah: evaluasi ulang semua listing yang ada
end

-- info: baseName, variant (VariantId mentah), weight, size ("Biasa"/"Big"/"Max"), price
-- Kosong (itemN/mutN = 0) = semua. 0 pada berat/harga = tanpa batas.
local function ruleMatches(r, info)
    if r.itemN > 0 and not r.itemSet[lc(info.baseName)] then return false end
    if r.mutN > 0 and not r.mutSet[lc(info.variant)] then return false end
    if r.size == "Big" and info.size == "Biasa" then return false end
    if r.size == "Max" and info.size ~= "Max" then return false end
    if r.minWeight > 0 and info.weight < r.minWeight then return false end
    if r.maxWeight > 0 and info.weight > r.maxWeight then return false end
    if r.maxPrice > 0 and info.price > r.maxPrice then return false end
    return true
end

local function reportHit(body)
    pcall(function()
        request({
            Url = WEB_URL .. "?action=find_hit",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode(body),
        })
    end)
end

local function scanOtherBooths()
    local rep = Replion.Client:WaitReplion("SaleListings")
    if not rep then return end
    local allPlayers = rep:Get({"Players"})
    if type(allPlayers) ~= "table" then return end
    local myId = tostring(LocalPlayer.UserId)

    for userId, pdata in pairs(allPlayers) do
        if tostring(userId) ~= myId and type(pdata) == "table" and type(pdata.Booth) == "table" then
            for _, ld in pairs(pdata.Booth) do
                local item = ld and ld.Item
                if item and item.UUID then
                    local price = tonumber(ld.Price) or 0
                    local key = tostring(item.UUID) .. "|" .. tostring(price)
                    if not watchSeen[key] then
                        watchSeen[key] = true

                        local catName = ld.ItemType or "Items"
                        local ok, itemInfo = pcall(ItemUtility.GetItemDataFromItemType, catName, item.Id)
                        if ok and type(itemInfo) == "table" and itemInfo.Data then
                            local realData = itemInfo.Data
                            local meta = item.Metadata or {}
                            local weight = tonumber(meta.Weight) or 0

                            local bigMin = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Min) or 0
                            local bigMax = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Max) or 0
                            local size = "Biasa"
                            if itemInfo.Weight and itemInfo.Weight.Big then
                                if weight >= bigMax then size = "Max"
                                elseif weight >= bigMin then size = "Big" end
                            end

                            local okM, mutation, _, shiny, rarityName = pcall(extractItemMetadata, itemInfo, item, catName)
                            if not okM then mutation = ""; shiny = false; rarityName = "" end
                            local icon = tostring(realData.Icon or realData.Image or itemInfo.Icon or itemInfo.Image or "")

                            -- catat ke katalog (dikirim ke API hanya kalau belum ada)
                            pcall(function()
                                catNoteItem(realData.Name, catName, rarityName, bigMin, bigMax, icon)
                                catNoteMutation(meta.VariantId, nil)
                            end)

                            -- cocokkan dengan aturan dari dashboard
                            if findEnabled and #findRules > 0 then
                                local info = {
                                    baseName = tostring(realData.Name or "?"),
                                    variant = tostring(meta.VariantId or ""),
                                    weight = weight, size = size, price = price,
                                }
                                for _, rule in ipairs(findRules) do
                                    if ruleMatches(rule, info) then
                                        local plr = Players:GetPlayerByUserId(tonumber(userId) or 0)
                                        task.spawn(reportHit, {
                                            username = username,
                                            rule_id = rule.id,
                                            uuid = tostring(item.UUID),
                                            base_name = info.baseName,
                                            mutation = tostring(mutation or ""),
                                            shiny = shiny == true,
                                            weight = weight,
                                            size = size,
                                            price = price,
                                            rap = getItemRAP(realData.Type or catName, item.Id),
                                            rarity = tostring(rarityName or ""),
                                            seller = plr and plr.Name or tostring(userId),
                                            icon = icon,
                                            job_id = game.JobId,
                                            place_id = game.PlaceId,
                                        })
                                        break   -- 1 item cukup 1 laporan walau cocok beberapa aturan
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

task.spawn(function()
    task.wait(8)   -- tunggu data booth pemain lain ter-replicate
    local lastRules = 0
    while true do
        if os.time() - lastRules >= FIND_RULES_INTERVAL then
            lastRules = os.time()
            pcall(fetchFindRules)
        end
        pcall(scanOtherBooths)
        task.wait(FIND_SCAN_INTERVAL)
    end
end)

-- ==========================================
-- SHOWCASE ITEM (Auto Equip): bot memegang item bermutasi pilihan dashboard supaya corak mutasinya terlihat calon pembeli
-- Alur per item: masuk hotbar (EquipItem) -> klik slot hotbar (EquipToolFromHotbar)
-- Kalau item Showcase > SHOWCASE_SLOTS: item yang paling lama tidak dipegang diturunkan dulu dari hotbar,
-- lalu item berikutnya di-add, bergantian. Hanya item yang di-add bot ini yang boleh diturunkan.
-- Dibungkus do...end supaya tidak menambah jumlah local di scope utama.
-- ==========================================
do
    local SHOWCASE_ENABLED = true
    local SHOWCASE_SLOTS = 4            -- maks item Showcase di hotbar sekaligus
    local SHOWCASE_ROTATE_SEC = 20      -- ganti item yang dipegang tiap N detik (kalau ada >1 item)
    local SHOWCASE_POLL_SEC = 8         -- cek perubahan daftar dari dashboard
    local HOTBAR_WAIT = 4               -- maks detik menunggu hotbar berubah setelah remote dipanggil

    -- TERVERIFIKASI di game: ReplicatedStorage.UnequipItem (RemoteEvent), argumen hanya UUID. EquipItem bukan toggle.
    local UNEQUIP_MODE = "remote"
    local UNEQUIP_REMOTE_NAME = "UnequipItem"
    local UNEQUIP_SEND_TYPE = false

    local equipItemRemote, equipToolRemote, unequipRemote
    local okNet, Net = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Net"))
    end)
    if okNet then
        pcall(function()
            equipItemRemote = Net:RemoteEvent("EquipItem")
            equipToolRemote = Net:RemoteEvent("EquipToolFromHotbar")
        end)
    end

    local list, listVer, showEnabled = {}, "", true   -- daftar dari dashboard (urut sesuai Preview)
    local ours = {}                                    -- uuid -> true : item yang di-add oleh Showcase (boleh diturunkan)
    local lastHeld = {}                                -- uuid -> os.time() terakhir dipegang
    local heldUuid, lastSwitch = nil, 0
    local warnedUnequip = false

    local function hotbarMap()
        local m = {}
        pcall(function()
            local dataReplion = Replion.Client:WaitReplion("Data")
            local equipped = dataReplion and dataReplion:Get("EquippedItems")
            if type(equipped) == "table" then
                for i, v in pairs(equipped) do
                    local n = tonumber(i)
                    if n and v then m[tostring(v)] = n end
                end
            end
        end)
        return m
    end

    local function hotbarCount(map)
        local c = 0
        for _ in pairs(map) do c = c + 1 end
        return c
    end

    local function inInventory(uuid)
        local found = false
        pcall(function()
            local dataReplion = Replion.Client:WaitReplion("Data")
            local inventory = dataReplion and dataReplion:Get("Inventory")
            if inventory then
                for _, items in pairs(inventory) do
                    if type(items) == "table" then
                        for _, itm in ipairs(items) do
                            if itm.UUID == uuid then found = true; return end
                        end
                    end
                end
            end
        end)
        return found
    end

    local function holdingAnyTool()
        local ok, has = pcall(function()
            local char = LocalPlayer.Character
            return char and char:FindFirstChildOfClass("Tool") ~= nil
        end)
        return ok and has
    end

    local function waitHotbar(uuid, shouldExist)
        local t0 = os.clock()
        while os.clock() - t0 < HOTBAR_WAIT do
            task.wait(0.3)
            local present = hotbarMap()[uuid] ~= nil
            if present == shouldExist then return true end
        end
        return false
    end

    -- turunkan item dari hotbar; return true kalau terbukti sudah turun
    local function removeFromHotbar(it)
        local ok = pcall(function()
            if UNEQUIP_MODE == "toggle" then
                equipItemRemote:FireServer(it.uuid, it.type)
            else
                if not unequipRemote then
                    unequipRemote = ReplicatedStorage:FindFirstChild(UNEQUIP_REMOTE_NAME)
                    if not unequipRemote then unequipRemote = Net:RemoteEvent(UNEQUIP_REMOTE_NAME) end
                end
                if UNEQUIP_SEND_TYPE then unequipRemote:FireServer(it.uuid, it.type)
                else unequipRemote:FireServer(it.uuid) end
            end
        end)
        if ok and waitHotbar(it.uuid, false) then
            ours[it.uuid] = nil
            return true
        end
        if not warnedUnequip then
            warnedUnequip = true
            warn("[SHOWCASE] gagal menurunkan item dari hotbar (server menolak / remote tidak ditemukan)")
        end
        return false
    end

    -- pastikan item ada di hotbar; return nomor slot atau nil
    local function ensureInHotbar(it, validSet)
        local map = hotbarMap()
        if map[it.uuid] then ours[it.uuid] = ours[it.uuid] or true; return map[it.uuid] end

        -- hotbar Showcase penuh: turunkan 1 item milik Showcase dulu (yang sudah dihapus dari daftar didahulukan, lalu yang paling lama tidak dipegang)
        local mine = {}
        for uuid in pairs(ours) do
            if map[uuid] then table.insert(mine, uuid) else ours[uuid] = nil end
        end
        if #mine >= SHOWCASE_SLOTS then
            table.sort(mine, function(a, b)
                local aKeep, bKeep = validSet[a] and 1 or 0, validSet[b] and 1 or 0
                if aKeep ~= bKeep then return aKeep < bKeep end
                return (lastHeld[a] or 0) < (lastHeld[b] or 0)
            end)
            local victimUuid = mine[1]
            local victimType = "Fish"
            for _, x in ipairs(list) do if x.uuid == victimUuid then victimType = x.type break end end
            if not removeFromHotbar({ uuid = victimUuid, type = victimType }) then return nil end
            if victimUuid == heldUuid then heldUuid = nil end
        end

        if not pcall(function() equipItemRemote:FireServer(it.uuid, it.type) end) then return nil end
        if not waitHotbar(it.uuid, true) then
            warn("[SHOWCASE] item tidak masuk hotbar: " .. tostring(it.name))
            return nil
        end
        ours[it.uuid] = true
        task.wait(0.3)
        return hotbarMap()[it.uuid]
    end

    -- poll daftar Showcase dari dashboard
    local function pollList()
        local response = request({
            Url = WEB_URL .. "?action=showcase_bot&username=" .. HttpService:UrlEncode(username) .. "&ver=" .. HttpService:UrlEncode(listVer),
            Method = "GET"
        })
        if response and response.StatusCode == 200 then
            local res = HttpService:JSONDecode(response.Body)
            if res.status == "ok" and not res.unchanged then
                listVer = tostring(res.ver or "")
                showEnabled = (tonumber(res.enabled) or 0) == 1
                local newList = {}
                for _, r in ipairs(res.items or {}) do
                    if r.uuid and r.uuid ~= "" then
                        table.insert(newList, { uuid = tostring(r.uuid), type = tostring(r.type or "Fish"), name = tostring(r.name or r.uuid) })
                    end
                end
                list = newList
            end
        end
    end

    if SHOWCASE_ENABLED and okNet and equipItemRemote and equipToolRemote then
        task.spawn(function()
            task.wait(8)
            while true do
                pcall(pollList)
                task.wait(SHOWCASE_POLL_SEC)
            end
        end)

        task.spawn(function()
            task.wait(12)   -- tunggu booth ter-claim & data ter-replicate
            while true do
                task.wait(2)
                pcall(function()
                    if not showEnabled or not isBoothClaimed or isHopping or isClaiming then
                        if isHopping then heldUuid = nil end
                        return
                    end

                    -- hanya item yang masih ada di inventaris (item terjual otomatis gugur)
                    local valid, validSet = {}, {}
                    for _, it in ipairs(list) do
                        if inInventory(it.uuid) then
                            table.insert(valid, it)
                            validSet[it.uuid] = true
                        end
                    end
                    if #valid == 0 then heldUuid = nil; return end

                    local curIdx = nil
                    for i, it in ipairs(valid) do
                        if it.uuid == heldUuid then curIdx = i; break end
                    end

                    local target = nil
                    if not curIdx then
                        target = valid[1]
                    elseif not holdingAnyTool() then
                        target = valid[curIdx]                              -- terlepas dari tangan: pegang lagi
                    elseif #valid > 1 and os.time() - lastSwitch >= SHOWCASE_ROTATE_SEC then
                        target = valid[(curIdx % #valid) + 1]               -- giliran item berikutnya
                    end

                    if target then
                        local slot = ensureInHotbar(target, validSet)
                        if slot and pcall(function() equipToolRemote:FireServer(slot) end) then
                            heldUuid = target.uuid
                            lastHeld[target.uuid] = os.time()
                            lastSwitch = os.time()
                        end
                    end
                end)
            end
        end)
    end
end
