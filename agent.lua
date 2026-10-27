local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait()
    LocalPlayer = Players.LocalPlayer
end

local GENV = (getgenv and getgenv()) or _G
local BASE_ENV = (getfenv and getfenv()) or _G

local httpRequest = (syn and syn.request) or request or http_request or (fluxus and fluxus.request) or (http and http.request)
local setClipboardFunc = setclipboard or toclipboard or (syn and syn.setclipboard)
local decompFn = decompile or (syn and syn.decompile)

-- ketersediaan fungsi executor (dicek langsung, bukan lewat getfenv)
local CAPS = {
    { "decompile", decompFn ~= nil }, { "getgc", getgc ~= nil }, { "getscriptbytecode", getscriptbytecode ~= nil },
    { "hookmetamethod", hookmetamethod ~= nil }, { "hookfunction", hookfunction ~= nil },
    { "getnamecallmethod", getnamecallmethod ~= nil }, { "newcclosure", newcclosure ~= nil },
    { "checkcaller", checkcaller ~= nil }, { "getconnections", getconnections ~= nil },
    { "firesignal", firesignal ~= nil }, { "fireproximityprompt", fireproximityprompt ~= nil },
    { "fireclickdetector", fireclickdetector ~= nil }, { "firetouchinterest", firetouchinterest ~= nil },
    { "loadstring", loadstring ~= nil }, { "setclipboard", setClipboardFunc ~= nil },
    { "readfile", readfile ~= nil }, { "writefile", writefile ~= nil },
    { "getrawmetatable", getrawmetatable ~= nil }, { "request", httpRequest ~= nil },
}
local function capOn(name)
    for _, c in ipairs(CAPS) do
        if c[1] == name then return c[2] end
    end
    return false
end

-- ========================================================
-- CONFIG (persisten)
-- ========================================================
local CONFIG_FILE = "DeoxysAgent.json"
local LEGACY_CONFIG_FILE = "AnomanAgent_v8.json"
local DEFAULTS = {
    -- Provider 1 (utama) dan provider 2 (cadangan). Router memakai urutan ini dan pindah otomatis bila gagal.
    apiUrl = "https://tokengateway.ai.id/v1/chat/completions",
    apiKey = "",
    model = "gpt-6-luna",
    apiUrl2 = "https://api.anoman.io/v1/chat/completions",
    apiKey2 = "",
    model2 = "deepseek-v4-pro-openrouter",
    timeout = 150,      -- detik; request yang menggantung lebih lama dianggap gagal lalu pindah provider
    maxWait = 480,      -- detik; total waktu router menunggu semua provider pulih sebelum menyerah
    maxSteps = 16,
    maxTokens = 8192,
    temperature = 0.2,
    allowEval = true,   -- izin uji coba: test_script (sandbox) + eval_lua
    rpmLimit = 0,       -- tidak dipakai lagi (tanpa batas buatan); error limit ditangani router lewat pindah provider
    tpmLimit = 0,       -- 0 = tanpa batas token buatan
    cfgVer = 5,
}
local Config = {}
for k, v in pairs(DEFAULTS) do Config[k] = v end

do
    if isfile and readfile then
        local srcFile
        for _, fname in ipairs({ CONFIG_FILE, LEGACY_CONFIG_FILE }) do
            local okF, exists = pcall(isfile, fname)
            if okF and exists then srcFile = fname; break end
        end
        if srcFile then
            local ok, data = pcall(function() return HttpService:JSONDecode(readfile(srcFile)) end)
            if ok and type(data) == "table" then
                for k, v in pairs(data) do
                    if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then Config[k] = v end
                end
                -- migrasi: config lama (token/langkah kecil) dinaikkan agar script panjang tidak terpotong
                if data.cfgVer ~= DEFAULTS.cfgVer then
                    Config.maxTokens = math.max(Config.maxTokens, DEFAULTS.maxTokens)
                    Config.maxSteps = math.max(Config.maxSteps, DEFAULTS.maxSteps)
                    if (tonumber(data.cfgVer) or 0) < 4 then
                        -- v4: router 2 provider. Setelan lama bergaya Anoman dipindah ke slot cadangan (provider 2)
                        local oldUrl = tostring(data.apiUrl or "")
                        if oldUrl:find("anoman", 1, true) and type(data.apiKey) == "string" and data.apiKey ~= "" then
                            Config.apiUrl2 = oldUrl
                            Config.apiKey2 = data.apiKey
                            Config.model2 = DEFAULTS.model2
                            Config.apiUrl = DEFAULTS.apiUrl
                            Config.apiKey = ""
                            Config.model = DEFAULTS.model
                        end
                        Config.tpmLimit = 0
                        Config.rpmLimit = 0
                    end
                    if (tonumber(data.cfgVer) or 0) < 5 then Config.allowEval = true end
                    Config.cfgVer = DEFAULTS.cfgVer
                end
            end
        end
    end
end

local function saveConfig()
    if writefile then
        pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(Config)) end)
    end
end

-- ========================================================
-- UTIL
-- ========================================================
local function clip(s, n)
    s = tostring(s)
    if #s > n then
        return s:sub(1, n) .. "...[+" .. (#s - n) .. " char]"
    end
    return s
end

local function lower(s) return string.lower(tostring(s or "")) end

local function plainFind(hay, needleLower)
    return string.find(string.lower(tostring(hay)), needleLower, 1, true) ~= nil
end

local function trim(s)
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function argNum(a, key, def, lo, hi)
    local v = tonumber(a[key])
    if not v then v = def end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

local function argStr(a, key)
    local v = a[key]
    if v == nil then return "" end
    return tostring(v)
end

local function fmtV3(v)
    return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

local function fnName(f)
    local ok, n = pcall(function() return debug.info(f, "n") end)
    if ok and type(n) == "string" and n ~= "" then return n end
    return "anonymous"
end

local function fnSource(f)
    local ok, s, l = pcall(function() return debug.info(f, "sl") end)
    if ok then return tostring(s), tostring(l) end
    return "?", "?"
end

-- serializer ringkas & aman (untuk argumen remote, nilai GC, dll)
local ser
local function serRaw(v, depth, seen)
    depth = depth or 2
    local t = typeof(v)
    if t == "string" then
        local s = v:gsub("[\r\n]+", " ")
        return '"' .. clip(s, 80) .. '"'
    elseif t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.4g", v)
    elseif t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "Instance" then
        local ok, p = pcall(function() return v:GetFullName() end)
        return "<" .. v.ClassName .. " " .. (ok and p or v.Name) .. ">"
    elseif t == "function" then
        return "function:" .. fnName(v)
    elseif t == "table" then
        seen = seen or {}
        if seen[v] then return "{<cycle>}" end
        if depth <= 0 then return "{...}" end
        seen[v] = true
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 8 then
                parts[#parts + 1] = "..."
                break
            end
            local ks = (type(k) == "string") and (k .. "=") or ("[" .. tostring(k) .. "]=")
            parts[#parts + 1] = ks .. ser(val, depth - 1, seen)
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end
ser = function(v, depth, seen)
    local ok, r = pcall(serRaw, v, depth, seen)
    if ok then return r end
    return "<" .. typeof(v) .. ">"
end

local function splitLines(src)
    local lines = {}
    for line in (src .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
    return lines
end

-- hemat token: lewati baris kosong, rapikan indentasi (1 spasi per level). Nomor baris tetap asli.
local function detectIndentUnit(lines)
    local unit = 0
    for i = 1, math.min(#lines, 400) do
        local sp = lines[i]:match("^( +)%S")
        if sp and (unit == 0 or #sp < unit) then unit = #sp end
    end
    if unit < 1 then unit = 4 end
    if unit > 8 then unit = 8 end
    return unit
end

local function packLine(raw, unit)
    raw = raw:gsub("%s+$", "")
    if raw == "" then return nil end
    local ws = raw:match("^[ \t]*")
    local _, tabs = ws:gsub("\t", "")
    local spaces = #ws - tabs
    local level = tabs + math.floor(spaces / (unit or 4) + 0.5)
    return string.rep(" ", level) .. raw:sub(#ws + 1)
end

-- ========================================================
-- PATH & SCAN
-- ========================================================
local BLOCKED = {}
for _, n in ipairs({ "CoreGui", "CorePackages", "RobloxReplicatedStorage" }) do
    local ok, svc = pcall(function() return game:GetService(n) end)
    if ok and svc then BLOCKED[#BLOCKED + 1] = svc end
end

local function isBlocked(inst)
    for _, svc in ipairs(BLOCKED) do
        if inst == svc or inst:IsDescendantOf(svc) then return true end
    end
    return false
end

local function getService(name)
    local ok, svc = pcall(function() return game:GetService(name) end)
    if ok then return svc end
    return nil
end

-- Resolve path "Workspace.Map.Fish" (nama boleh mengandung titik/spasi). Return obj ATAU nil, pesan_error
local function resolvePath(path)
    if type(path) ~= "string" or trim(path) == "" then
        return nil, "path kosong"
    end
    path = trim(path)
    path = path:gsub("^game%.?", "")
    local segs = {}
    for s in path:gmatch("[^%.]+") do segs[#segs + 1] = s end
    if #segs == 0 then return game end

    local current = game
    local i = 1
    if segs[1] == "LocalPlayer" then
        current = LocalPlayer
        i = 2
    end
    while i <= #segs do
        local found, usedTo
        local name = segs[i]
        local j = i
        while true do
            local child
            if current == game then
                child = game:FindFirstChild(name) or getService(name)
            else
                child = current:FindFirstChild(name)
            end
            if child then
                found, usedTo = child, j
                break
            end
            j = j + 1
            if j > #segs then break end
            name = name .. "." .. segs[j]
        end
        if not found then
            return nil, string.format("'%s' tidak ada di %s", segs[i], current == game and "game" or current:GetFullName())
        end
        current = found
        i = usedTo + 1
    end
    if isBlocked(current) then return nil, "path diblokir (CoreGui/CorePackages)" end
    return current
end

local function getRoots(scriptsFirst)
    local roots = {}
    local function add(x) if x then roots[#roots + 1] = x end end
    if scriptsFirst then
        add(ReplicatedStorage)
        add(game:FindFirstChild("ReplicatedFirst"))
        add(LocalPlayer:FindFirstChild("PlayerScripts"))
        add(LocalPlayer:FindFirstChild("PlayerGui"))
        add(LocalPlayer:FindFirstChild("Backpack"))
        add(game:FindFirstChild("StarterPlayer"))
        add(game:FindFirstChild("StarterPack"))
        add(Workspace)
    else
        add(Workspace)
        add(ReplicatedStorage)
        add(game:FindFirstChild("ReplicatedFirst"))
        add(LocalPlayer:FindFirstChild("PlayerGui"))
        add(LocalPlayer:FindFirstChild("Backpack"))
        add(LocalPlayer:FindFirstChild("PlayerScripts"))
        add(game:FindFirstChild("StarterPlayer"))
        add(game:FindFirstChild("StarterPack"))
    end
    return roots
end

-- scan descendants dengan yield berkala (anti-freeze di HP)
local function scan(roots, predicate, limit)
    local out, n, i = {}, 0, 0
    for _, root in ipairs(roots) do
        local okD, desc = pcall(function() return root:GetDescendants() end)
        if okD then
            for _, obj in ipairs(desc) do
                i = i + 1
                if i % 4000 == 0 then task.wait() end
                local okP, hit = pcall(predicate, obj)
                if okP and hit then
                    n = n + 1
                    out[n] = obj
                    if n >= limit then return out, true end
                end
            end
        end
    end
    return out, false
end

local function getPos(o)
    if o:IsA("BasePart") then return o.Position end
    if o:IsA("Attachment") then return o.WorldPosition end
    if o:IsA("Model") then
        local ok, p = pcall(function() return o:GetPivot().Position end)
        if ok then return p end
    end
    return nil
end

local function myRootPos()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    return root and root.Position or nil
end

local function describe(o)
    return "[" .. o.ClassName .. "] " .. o:GetFullName()
end

local function isNoiseScript(o)
    local n = o.Name
    if n == "RbxCharacterSounds" or n == "PlayerModule" or n == "ChatScript" or n == "BubbleChat" or n == "Animate" then
        return true
    end
    return o:FindFirstAncestor("PlayerModule") ~= nil
end

-- decompile + cache
local decompCache = setmetatable({}, { __mode = "k" })
local function getSource(inst)
    if decompCache[inst] then return decompCache[inst] end
    if not decompFn then return nil, "decompile tidak didukung executor ini" end
    local ok, res = pcall(decompFn, inst)
    if not ok then return nil, "decompile error: " .. tostring(res) end
    if type(res) ~= "string" or res == "" then return nil, "hasil decompile kosong" end
    decompCache[inst] = res
    return res
end

-- ========================================================
-- REMOTE SPY (state dipakai ulang lintas reload)
-- ========================================================
local Spy = GENV.__DeoxysSpy or GENV.__AnomanSpy
if not Spy then
    Spy = { enabled = false, hooked = false, log = {}, last = {}, counts = {}, max = 400, total = 0 }
end
GENV.__DeoxysSpy = Spy
Spy.counts = Spy.counts or {}
Spy.last = Spy.last or {}
Spy.log = Spy.log or {}
Spy.include, Spy.exclude, Spy.mutedNames = {}, {}, {}
Spy.muted = setmetatable({}, { __mode = "k" })
Spy.rate = setmetatable({}, { __mode = "k" })
Spy.pathCache = setmetatable({}, { __mode = "k" })
local Sandbox = GENV.__DeoxysSandbox
if not Sandbox then Sandbox = { active = nil }; GENV.__DeoxysSandbox = Sandbox end

-- snapshot state lokal (sebelum/sesudah test_script): tool, backpack, atribut, leaderstats, GUI (Visible/Enabled/UIScale)
Sandbox.snapshot = function()
    local s = { vals = {}, gui = {}, scale = {}, set = {}, n = 0 }
    pcall(function()
        local char = LocalPlayer.Character
        local held = {}
        if char then
            for _, c in ipairs(char:GetChildren()) do
                if c:IsA("Tool") then held[#held + 1] = c.Name end
            end
        end
        table.sort(held)
        s.vals["Tool dipegang"] = #held > 0 and table.concat(held, ", ") or "tidak ada"
        local bag = {}
        local bp = LocalPlayer:FindFirstChild("Backpack")
        if bp then
            for _, c in ipairs(bp:GetChildren()) do bag[#bag + 1] = c.Name end
        end
        table.sort(bag)
        s.vals["Backpack"] = #bag > 0 and clip(table.concat(bag, ", "), 200) or "kosong"
        for k, v in pairs(LocalPlayer:GetAttributes()) do s.vals["Atribut player." .. tostring(k)] = ser(v, 1) end
        if char then
            for k, v in pairs(char:GetAttributes()) do s.vals["Atribut karakter." .. tostring(k)] = ser(v, 1) end
        end
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        if ls then
            for _, c in ipairs(ls:GetChildren()) do
                local okv, val = pcall(function() return c.Value end)
                if okv then s.vals["leaderstats." .. c.Name] = tostring(val) end
            end
        end
    end)
    pcall(function()
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not pg then return end
        for _, top in ipairs(pg:GetChildren()) do
            if top.Name ~= "DeoxysAgentUI" then
                local list = top:GetDescendants()
                list[#list + 1] = top
                for _, o in ipairs(list) do
                    if s.n >= 4000 then return end
                    s.n = s.n + 1
                    s.set[o] = true
                    if o:IsA("GuiObject") then
                        s.gui[o] = o.Visible
                    elseif o:IsA("ScreenGui") then
                        s.gui[o] = o.Enabled
                    elseif o:IsA("UIScale") then
                        s.scale[o] = o.Scale
                    end
                end
            end
        end
    end)
    return s
end

Sandbox.diff = function(a, b)
    local out = {}
    local keys, names = {}, {}
    for k in pairs(a.vals) do keys[k] = true end
    for k in pairs(b.vals) do keys[k] = true end
    for k in pairs(keys) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
        local x, y = a.vals[k], b.vals[k]
        if x ~= y then out[#out + 1] = k .. ": " .. tostring(x or "-") .. " -> " .. tostring(y or "-") end
    end
    local function nm(o)
        local ok, p = pcall(function() return o:GetFullName() end)
        p = ok and p or tostring(o)
        p = p:gsub("^Players%.[^%.]+%.PlayerGui%.", "PlayerGui.")
        return clip("[" .. o.ClassName .. "] " .. p, 100)
    end
    local function lst(tag, items)
        if #items == 0 then return end
        table.sort(items)
        local shown = {}
        for i = 1, math.min(#items, 6) do shown[i] = items[i] end
        out[#out + 1] = tag .. " (" .. #items .. "): " .. table.concat(shown, "; ") .. (#items > 6 and "; ..." or "")
    end
    local added, removed, vis, scl = {}, {}, {}, {}
    for o in pairs(b.set) do
        if not a.set[o] then added[#added + 1] = nm(o) end
    end
    for o in pairs(a.set) do
        if not b.set[o] then removed[#removed + 1] = nm(o) end
    end
    for o, v in pairs(b.gui) do
        local pv = a.gui[o]
        if pv ~= nil and pv ~= v then vis[#vis + 1] = nm(o) .. " " .. tostring(pv) .. "->" .. tostring(v) end
    end
    for o, v in pairs(b.scale) do
        local pv = a.scale[o]
        if pv ~= nil and math.abs(pv - v) > 0.001 then scl[#scl + 1] = nm(o) .. " " .. string.format("%.3g->%.3g", pv, v) end
    end
    lst("GUI baru", added)
    lst("GUI hilang", removed)
    lst("GUI Visible/Enabled berubah", vis)
    lst("UIScale berubah", scl)
    if a.n >= 4000 or b.n >= 4000 then out[#out + 1] = "(snapshot GUI dipotong di 4000 objek)" end
    return out
end

-- filter di sisi hook: HANYA operasi index (tanpa method-call) agar state namecall tidak rusak
local NOISE_NAMES = { ping = true, pong = true, heartbeat = true, keepalive = true, mousemove = true, cursormove = true, camera = true, footstep = true, footsteps = true }
local function pathOf(inst)
    local c = Spy.pathCache[inst]
    if c then return c end
    local parts, node, n = {}, inst, 0
    while node and node ~= game and n < 14 do
        parts[#parts + 1] = node.Name
        node = node.Parent
        n = n + 1
    end
    local rev = {}
    for i = #parts, 1, -1 do rev[#rev + 1] = parts[i] end
    local p = string.lower(table.concat(rev, "."))
    Spy.pathCache[inst] = p
    return p
end
Spy.accept = function(remote)
    if Spy.muted[remote] then return false end
    local allow = Spy.allow
    if allow then
        -- mode terverifikasi (dipakai agent): hanya remote yang sudah dipastikan ada dan cocok persis, bukan tebakan keyword
        if not allow[remote] then return false end
    else
        local nl = string.lower(remote.Name)
        if NOISE_NAMES[nl] or string.find(nl, "heartbeat", 1, true) or string.find(nl, "keepalive", 1, true) then return false end
    end
    if #Spy.exclude > 0 or (not allow and #Spy.include > 0) then
        local p = pathOf(remote)
        for _, kw in ipairs(Spy.exclude) do
            if string.find(p, kw, 1, true) then return false end
        end
        if not allow and #Spy.include > 0 then
            local hit = false
            for _, kw in ipairs(Spy.include) do
                if string.find(p, kw, 1, true) then hit = true; break end
            end
            if not hit then return false end
        end
    end
    -- penjaga spam: >25 panggilan dalam 10 detik -> remote di-mute otomatis
    local now = os.clock()
    local r = Spy.rate[remote]
    if not r or now - r.t > 10 then r = { t = now, n = 0 }; Spy.rate[remote] = r end
    r.n = r.n + 1
    if r.n > 25 then
        Spy.muted[remote] = true
        if #Spy.mutedNames < 20 then Spy.mutedNames[#Spy.mutedNames + 1] = pathOf(remote) end
        return false
    end
    return true
end

Spy.record = function(remote, method, args)
    local okp, path = pcall(function() return remote:GetFullName() end)
    path = okp and path or tostring(remote)
    local parts = {}
    for i = 1, math.min(args.n, 8) do parts[#parts + 1] = ser(args[i], 3) end
    if args.n > 8 then parts[#parts + 1] = "...(+" .. (args.n - 8) .. " arg)" end
    local argText = table.concat(parts, ", ")
    local key = path .. "|" .. method
    local last = Spy.last[key]
    if last and last.args == argText and (os.clock() - last.t) < 2 then
        last.rep = last.rep + 1
        last.t = os.clock()
        return
    end
    Spy.total = Spy.total + 1
    local e = { id = Spy.total, t = os.clock(), path = path, method = method, args = argText, rep = 1 }
    Spy.last[key] = e
    Spy.log[#Spy.log + 1] = e
    if #Spy.log > Spy.max then table.remove(Spy.log, 1) end
    Spy.counts[key] = (Spy.counts[key] or 0) + 1
end

local SPY_METHODS = { FireServer = true, fireServer = true, InvokeServer = true, invokeServer = true }

local HOOK_VER = 2
local function installSpy()
    if Spy.hooked and Spy.hookVer == HOOK_VER then return true end
    if not (hookmetamethod and getnamecallmethod) then
        return false, "executor tidak mendukung hookmetamethod/getnamecallmethod"
    end
    local wrap = newcclosure or function(f) return f end
    local legacy = Spy.hooked -- hook versi lama (script di-reload) masih ada di bawah; biarkan dia yang merekam
    local ok, err = pcall(function()
        local old
        old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
            local method = getnamecallmethod()
            if SPY_METHODS[method] and typeof(self) == "Instance" then
                local ours = checkcaller and checkcaller()
                local sb = Sandbox.active
                if ours then
                    -- pemanggilan dari executor: hanya disentuh saat test_script (sandbox) aktif
                    if sb then
                        local args = table.pack(...)
                        local target = self
                        sb.nCalls = (sb.nCalls or 0) + 1
                        -- mode live dibatasi jumlah remote; lewat batas = diblokir dan ditandai
                        local limited = (not sb.block) and sb.nCalls > (sb.maxLive or 10)
                        task.spawn(function() pcall(sb.record, target, method, args, limited) end)
                        if sb.block or limited then return nil end
                    end
                else
                    -- remote dari game sendiri: selama sandbox aktif dicatat terpisah (tidak diblokir, filter rspy tidak dipakai)
                    if sb and sb.recordGame and not NOISE_NAMES[string.lower(self.Name)] then
                        local args = table.pack(...)
                        local target = self
                        task.spawn(function() pcall(sb.recordGame, target, method, args) end)
                    end
                    if Spy.enabled and not legacy and Spy.accept(self, method) then
                        local args = table.pack(...)
                        local target = self
                        task.spawn(function() pcall(Spy.record, target, method, args) end)
                    end
                end
            end
            return old(self, ...)
        end))
    end)
    if not ok then return false, tostring(err) end
    Spy.hooked = true
    Spy.hookVer = HOOK_VER
    return true
end

-- ========================================================
-- TOOL REGISTRY
-- ========================================================
local Tools, ToolOrder = {}, {}
local State = { history = {}, notes = {}, cache = {}, busy = false, runId = 0, status = "" }

local function defTool(name, argsDoc, desc, fn)
    Tools[name] = { args = argsDoc, desc = desc, fn = fn }
    ToolOrder[#ToolOrder + 1] = name
end

local function summarizeChildren(inst, limit)
    local out, n = {}, 0
    for _, c in ipairs(inst:GetChildren()) do
        n = n + 1
        if n > limit then
            out[#out + 1] = "  ... (+" .. (#inst:GetChildren() - limit) .. " lagi)"
            break
        end
        out[#out + 1] = "  [" .. c.ClassName .. "] " .. c.Name
    end
    return table.concat(out, "\n")
end

-- ---------- game_info ----------
defTool("game_info", "{}", "Info game + executor + fungsi executor yang tersedia + peta awal folder utama. Panggil di awal tugas yang butuh data game (bukan untuk sapaan).", function(a)
    local L = {}
    L[#L + 1] = "PlaceId: " .. tostring(game.PlaceId) .. " | GameId: " .. tostring(game.GameId)
    local ok, info = pcall(function() return MarketplaceService:GetProductInfo(game.PlaceId) end)
    if ok and type(info) == "table" then L[#L + 1] = "Nama game: " .. tostring(info.Name) end
    L[#L + 1] = "Jumlah pemain: " .. #Players:GetPlayers()
    local ex = "tidak diketahui"
    if identifyexecutor then
        local ok2, n, v = pcall(identifyexecutor)
        if ok2 then ex = tostring(n) .. " " .. tostring(v or "") end
    end
    L[#L + 1] = "Executor: " .. ex

    local yes, no = {}, {}
    for _, c in ipairs(CAPS) do
        if c[2] then yes[#yes + 1] = c[1] else no[#no + 1] = c[1] end
    end
    for _, n in ipairs({ "getupvalues", "getconstants", "getproto" }) do
        if debug and debug[n] ~= nil then yes[#yes + 1] = "debug." .. n else no[#no + 1] = "debug." .. n end
    end
    L[#L + 1] = "Fungsi executor TERSEDIA: " .. table.concat(yes, ", ")
    L[#L + 1] = "Fungsi executor TIDAK ada: " .. (#no > 0 and table.concat(no, ", ") or "-")

    L[#L + 1] = "\nWorkspace (anak langsung):\n" .. summarizeChildren(Workspace, 25)
    L[#L + 1] = "\nReplicatedStorage (anak langsung):\n" .. summarizeChildren(ReplicatedStorage, 25)
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then L[#L + 1] = "\nPlayerGui:\n" .. summarizeChildren(pg, 20) end
    return table.concat(L, "\n")
end)

-- ---------- search_game ----------
defTool("search_game", '{"keyword":"fish","class":"(opsional, mis. RemoteEvent/ProximityPrompt/Model)","root":"(opsional path)","limit":25}',
    "Cari instance berdasarkan nama (case-insensitive, TEKS BIASA bukan regex). Cakupan default: Workspace, ReplicatedStorage, ReplicatedFirst, PlayerGui, Backpack, PlayerScripts, StarterPlayer.",
    function(a)
        local kw = lower(argStr(a, "keyword"))
        local cls = argStr(a, "class")
        if kw == "" and cls == "" then return "ERROR: isi minimal 'keyword' atau 'class'." end
        local limit = argNum(a, "limit", 25, 1, 60)
        local roots
        if argStr(a, "root") ~= "" then
            local r, err = resolvePath(argStr(a, "root"))
            if not r then return "ERROR root: " .. err end
            roots = { r }
        else
            roots = getRoots(false)
        end
        local found, truncated = scan(roots, function(o)
            if kw ~= "" and not plainFind(o.Name, kw) then return false end
            if cls ~= "" and not (o.ClassName == cls or o:IsA(cls)) then return false end
            return true
        end, limit)
        if #found == 0 then
            return "Tidak ada hasil untuk keyword='" .. kw .. "' class='" .. cls .. "'. Coba: sinonim/kata lebih pendek, filter class, atau root lain. Jangan menyimpulkan 'tidak ada' dari satu pencarian."
        end
        local out = {}
        for _, o in ipairs(found) do out[#out + 1] = describe(o) end
        return table.concat(out, "\n") .. (truncated and "\n(hasil dipotong di limit; persempit keyword)" or "")
    end)

-- ---------- get_children ----------
defTool("get_children", '{"path":"ReplicatedStorage.Remotes","class":"(opsional)","limit":40}',
    "Daftar anak langsung dari sebuah path.", function(a)
        local obj, err = resolvePath(argStr(a, "path"))
        if not obj then return "ERROR: " .. err end
        local cls = argStr(a, "class")
        local limit = argNum(a, "limit", 40, 1, 100)
        local kids = obj:GetChildren()
        local out, n = { obj:GetFullName() .. " (" .. #kids .. " anak):" }, 0
        for _, c in ipairs(kids) do
            if cls == "" or c.ClassName == cls or c:IsA(cls) then
                n = n + 1
                if n > limit then
                    out[#out + 1] = "... (dipotong, pakai 'class' atau 'limit')"
                    break
                end
                local sub = #c:GetChildren()
                out[#out + 1] = string.format("- [%s] %s%s", c.ClassName, c.Name, sub > 0 and (" (" .. sub .. " anak)") or "")
            end
        end
        if n == 0 then out[#out + 1] = "(kosong / tidak ada yang cocok)" end
        return table.concat(out, "\n")
    end)

-- ---------- inspect_object ----------
local PROP_SETS = {
    { "BasePart", { "Position", "Size", "Anchored", "CanCollide", "CanTouch", "Transparency" } },
    { "Humanoid", { "Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight" } },
    { "ProximityPrompt", { "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance", "Enabled", "RequiresLineOfSight", "KeyboardKeyCode" } },
    { "ClickDetector", { "MaxActivationDistance" } },
    { "ValueBase", { "Value" } },
    { "GuiObject", { "Visible", "AbsolutePosition", "AbsoluteSize" } },
    { "TextLabel", { "Text" } },
    { "TextButton", { "Text" } },
    { "TextBox", { "Text" } },
    { "ImageLabel", { "Image" } },
    { "ImageButton", { "Image" } },
    { "Tool", { "CanBeDropped", "RequiresHandle", "ToolTip" } },
    { "Animation", { "AnimationId" } },
    { "LocalScript", { "Disabled" } },
    { "Script", { "Disabled" } },
}

defTool("inspect_object", '{"path":"Workspace.Map.Fish"}',
    "Detail satu instance: class, parent, properti kunci, attributes, tags, posisi.", function(a)
        local obj, err = resolvePath(argStr(a, "path"))
        if not obj then return "ERROR: " .. err end
        local L = {}
        L[#L + 1] = "Nama: " .. obj.Name
        L[#L + 1] = "Path: " .. obj:GetFullName()
        L[#L + 1] = "Class: " .. obj.ClassName
        L[#L + 1] = "Anak: " .. #obj:GetChildren() .. " | Keturunan: " .. #obj:GetDescendants()
        for _, set in ipairs(PROP_SETS) do
            local okI, isA = pcall(function() return obj:IsA(set[1]) end)
            if okI and isA then
                local parts = {}
                for _, pn in ipairs(set[2]) do
                    local ok, v = pcall(function() return obj[pn] end)
                    if ok then parts[#parts + 1] = pn .. "=" .. ser(v, 2) end
                end
                if #parts > 0 then L[#L + 1] = table.concat(parts, ", ") end
            end
        end
        if obj:IsA("Model") then
            local pp = obj.PrimaryPart
            L[#L + 1] = "PrimaryPart: " .. (pp and pp.Name or "nil")
            local p = getPos(obj)
            if p then L[#L + 1] = "Pivot: " .. fmtV3(p) end
        end
        local okA, attrs = pcall(function() return obj:GetAttributes() end)
        if okA and next(attrs) ~= nil then L[#L + 1] = "Attributes: " .. ser(attrs, 2) end
        local okT, tags = pcall(function() return CollectionService:GetTags(obj) end)
        if okT and #tags > 0 then L[#L + 1] = "Tags: " .. table.concat(tags, ", ") end
        if obj:IsA("LuaSourceContainer") then
            L[#L + 1] = "(Ini script. Baca isinya dengan decompile_script / cari kata dengan search_code)"
        end
        return table.concat(L, "\n")
    end)

-- ---------- read_property ----------
defTool("read_property", '{"path":"...","props":["Position","Anchored"]}',
    "Baca properti spesifik apa pun (array atau string dipisah koma).", function(a)
        local obj, err = resolvePath(argStr(a, "path"))
        if not obj then return "ERROR: " .. err end
        local props = a.props
        if type(props) == "string" then
            local t = {}
            for p in props:gmatch("[^,%s]+") do t[#t + 1] = p end
            props = t
        end
        if type(props) ~= "table" or #props == 0 then return "ERROR: isi 'props'." end
        local out = {}
        for _, p in ipairs(props) do
            local ok, v = pcall(function() return obj[tostring(p)] end)
            out[#out + 1] = tostring(p) .. " = " .. (ok and ser(v, 3) or "ERROR/tidak ada")
        end
        return obj:GetFullName() .. "\n" .. table.concat(out, "\n")
    end)

-- ---------- get_positions ----------
defTool("get_positions", '{"path":"Workspace.Map.Spots","filter":"(opsional)","limit":25}',
    "Posisi (dan jarak ke player) semua anak langsung dari sebuah path. Diurutkan terdekat.", function(a)
        local obj, err = resolvePath(argStr(a, "path"))
        if not obj then return "ERROR: " .. err end
        local kw = lower(argStr(a, "filter"))
        local limit = argNum(a, "limit", 25, 1, 60)
        local me = myRootPos()
        local rows = {}
        for _, c in ipairs(obj:GetChildren()) do
            if kw == "" or plainFind(c.Name, kw) then
                local p = getPos(c)
                rows[#rows + 1] = { c = c, p = p, d = (p and me) and (p - me).Magnitude or math.huge }
            end
        end
        table.sort(rows, function(x, y) return x.d < y.d end)
        if #rows == 0 then return "Tidak ada anak yang cocok di " .. obj:GetFullName() end
        local out = { obj:GetFullName() .. " (" .. #rows .. " cocok" .. (me and ", urut terdekat" or "") .. "):" }
        for i, r in ipairs(rows) do
            if i > limit then
                out[#out + 1] = "... "
                break
            end
            out[#out + 1] = string.format("- %s [%s] pos=%s%s", r.c.Name, r.c.ClassName,
                r.p and fmtV3(r.p) or "(bukan part/model)", r.d < math.huge and string.format(" jarak=%.0f", r.d) or "")
        end
        return table.concat(out, "\n")
    end)

-- ---------- get_player_status ----------
defTool("get_player_status", "{}", "Status player: posisi, HP, speed, tool dipegang, isi backpack, leaderstats, attributes.", function(a)
    local char = LocalPlayer.Character
    local L = { "Nama: " .. LocalPlayer.Name .. " (DisplayName: " .. LocalPlayer.DisplayName .. ")" }
    if not char then
        L[#L + 1] = "Character belum spawn."
    else
        local root = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        local tool = char:FindFirstChildOfClass("Tool")
        L[#L + 1] = "Posisi: " .. (root and fmtV3(root.Position) or "?")
        if hum then
            L[#L + 1] = string.format("HP: %s/%s | WalkSpeed: %s | JumpPower: %s", ser(hum.Health), ser(hum.MaxHealth), ser(hum.WalkSpeed), ser(hum.JumpPower))
        end
        L[#L + 1] = "Tool dipegang: " .. (tool and tool.Name or "tidak ada")
    end
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        local names = {}
        for _, t in ipairs(bp:GetChildren()) do names[#names + 1] = t.Name end
        L[#L + 1] = "Backpack: " .. (#names > 0 and table.concat(names, ", ") or "kosong")
    end
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        local vals = {}
        for _, v in ipairs(ls:GetChildren()) do
            local ok, val = pcall(function() return v.Value end)
            vals[#vals + 1] = v.Name .. "=" .. (ok and ser(val) or "?")
        end
        L[#L + 1] = "Leaderstats: " .. table.concat(vals, ", ")
    end
    local okA, attrs = pcall(function() return LocalPlayer:GetAttributes() end)
    if okA and next(attrs) ~= nil then L[#L + 1] = "Attributes player: " .. ser(attrs, 2) end
    return table.concat(L, "\n")
end)

-- ---------- find_interactables ----------
defTool("find_interactables", '{"keyword":"(opsional)","limit":25}',
    "Cari ProximityPrompt & ClickDetector (tombol interaksi dunia game) beserta posisi & jarak. Diurutkan terdekat.", function(a)
        local kw = lower(argStr(a, "keyword"))
        local limit = argNum(a, "limit", 25, 1, 60)
        local me = myRootPos()
        local found = scan(getRoots(false), function(o)
            if not (o:IsA("ProximityPrompt") or o:IsA("ClickDetector")) then return false end
            if kw == "" then return true end
            local hay = o.Name .. " " .. (o.Parent and o.Parent.Name or "")
            if o:IsA("ProximityPrompt") then hay = hay .. " " .. o.ActionText .. " " .. o.ObjectText end
            return plainFind(hay, kw)
        end, 300)
        if #found == 0 then return "Tidak ada ProximityPrompt/ClickDetector yang cocok." end
        local rows = {}
        for _, o in ipairs(found) do
            local par = o.Parent
            local p = par and getPos(par)
            rows[#rows + 1] = { o = o, p = p, d = (p and me) and (p - me).Magnitude or math.huge }
        end
        table.sort(rows, function(x, y) return x.d < y.d end)
        local out = { #rows .. " ditemukan:" }
        for i, r in ipairs(rows) do
            if i > limit then
                out[#out + 1] = "... (dipotong)"
                break
            end
            local o = r.o
            local extra = ""
            if o:IsA("ProximityPrompt") then
                extra = string.format(" action='%s' object='%s' hold=%s maxDist=%s enabled=%s", o.ActionText, o.ObjectText, ser(o.HoldDuration), ser(o.MaxActivationDistance), tostring(o.Enabled))
            else
                extra = " maxDist=" .. ser(o.MaxActivationDistance)
            end
            out[#out + 1] = string.format("- %s%s%s%s", describe(o), extra,
                r.p and (" pos=" .. fmtV3(r.p)) or "", r.d < math.huge and string.format(" jarak=%.0f", r.d) or "")
        end
        return table.concat(out, "\n")
    end)

-- ---------- inspect_gui ----------
local function isShown(o)
    local p = o.Parent
    while p and p ~= game do
        if p:IsA("GuiObject") and not p.Visible then return false end
        if p:IsA("ScreenGui") and not p.Enabled then return false end
        p = p.Parent
    end
    return true
end

defTool("inspect_gui", '{"path":"(default LocalPlayer.PlayerGui)","keyword":"(opsional)","only_visible":true,"limit":40}',
    "Daftar tombol/teks/input GUI (path + teks). Berguna mencari UI minigame, shop, quest.", function(a)
        local root = LocalPlayer:FindFirstChild("PlayerGui")
        if argStr(a, "path") ~= "" then
            local r, err = resolvePath(argStr(a, "path"))
            if not r then return "ERROR: " .. err end
            root = r
        end
        if not root then return "ERROR: PlayerGui tidak ada." end
        local kw = lower(argStr(a, "keyword"))
        local onlyVisible = a.only_visible ~= false
        local limit = argNum(a, "limit", 40, 1, 100)
        local found = scan({ root }, function(o)
            if not (o:IsA("TextButton") or o:IsA("ImageButton") or o:IsA("TextBox") or (o:IsA("TextLabel") and o.Text ~= "")) then return false end
            if onlyVisible and not (o.Visible and isShown(o)) then return false end
            if kw ~= "" then
                local t = (o:IsA("ImageButton") and "" or o.Text)
                if not (plainFind(o.Name, kw) or plainFind(t, kw)) then return false end
            end
            return true
        end, limit)
        if #found == 0 then return "Tidak ada elemen GUI yang cocok." end
        local out = {}
        for _, o in ipairs(found) do
            local t = o:IsA("ImageButton") and "(image)" or clip(o.Text, 50)
            out[#out + 1] = describe(o) .. "  teks=" .. ser(t)
        end
        return table.concat(out, "\n")
    end)

-- ---------- find_scripts ----------
defTool("find_scripts", '{"keyword":"(opsional)","root":"(opsional)","class":"LocalScript|ModuleScript (opsional)","limit":40}',
    "Daftar script klien (LocalScript/ModuleScript) yang bisa dibaca. Script server TIDAK terlihat dari klien.", function(a)
        local kw = lower(argStr(a, "keyword"))
        local cls = argStr(a, "class")
        local limit = argNum(a, "limit", 40, 1, 100)
        local roots
        if argStr(a, "root") ~= "" then
            local r, err = resolvePath(argStr(a, "root"))
            if not r then return "ERROR root: " .. err end
            roots = { r }
        else
            roots = getRoots(true)
        end
        local found, truncated = scan(roots, function(o)
            if not o:IsA("LuaSourceContainer") or isNoiseScript(o) then return false end
            if cls ~= "" and o.ClassName ~= cls then return false end
            if kw ~= "" and not plainFind(o.Name, kw) then return false end
            return true
        end, limit)
        if #found == 0 then return "Tidak ada script yang cocok." end
        local out = {}
        for _, o in ipairs(found) do out[#out + 1] = describe(o) end
        return table.concat(out, "\n") .. (truncated and "\n(dipotong; persempit)" or "")
    end)

-- ---------- script_outline ----------
defTool("script_outline", '{"path":"ReplicatedStorage.Modules.Fishing","keyword":"(opsional)"}',
    "Peta ringkas SATU script (hemat token): daftar fungsi/callback + baris FireServer/InvokeServer/OnClientEvent/require, lengkap dengan nomor baris. Pakai SEBELUM decompile_script, lalu baca hanya rentang yang relevan.", function(a)
        local obj, err = resolvePath(argStr(a, "path"))
        if not obj then return "ERROR: " .. err end
        if not obj:IsA("LuaSourceContainer") then
            return "ERROR: " .. obj.ClassName .. " bukan script. Cari script dengan find_scripts."
        end
        local src, e2 = getSource(obj)
        if not src then return "ERROR: " .. e2 end
        local lines = splitLines(src)
        local kw = lower(argStr(a, "keyword"))
        local NET = { "fireserver", "invokeserver", "onclientevent", "onclientinvoke" }
        local fns, net, reqs, hits = {}, {}, {}, {}
        for i, raw in ipairs(lines) do
            local t = trim(raw)
            if t ~= "" then
                local low = string.lower(t)
                local row = i .. "| " .. clip(t, 110)
                local placed = false
                if string.find(low, "require(", 1, true) then
                    reqs[#reqs + 1] = row
                    placed = true
                end
                if not placed then
                    for _, k in ipairs(NET) do
                        if string.find(low, k, 1, true) then
                            net[#net + 1] = row
                            placed = true
                            break
                        end
                    end
                end
                if not placed then
                    local isFn = t:match("^local%s+function%s") or t:match("^function%s")
                        or t:match("^[%w_%.:]+%s*=%s*function") or t:match("^local%s+[%w_]+%s*=%s*function")
                        or string.find(t, ":Connect(function", 1, true)
                    if isFn then fns[#fns + 1] = row end
                end
                if kw ~= "" and string.find(low, kw, 1, true) then hits[#hits + 1] = row end
            end
        end
        local out = { string.format("-- OUTLINE %s [%s] total %d baris", obj:GetFullName(), obj.ClassName, #lines) }
        local shown = {}
        local function emit(title, list, cap)
            if #list == 0 then return end
            out[#out + 1] = title .. " (" .. #list .. "):"
            for i = 1, math.min(#list, cap) do
                out[#out + 1] = list[i]
                shown[list[i]] = true
            end
            if #list > cap then out[#out + 1] = "  ...(+" .. (#list - cap) .. " lagi; pakai keyword atau decompile_script)" end
        end
        emit("REMOTE/EVENT", net, 40)
        emit("REQUIRE", reqs, 12)
        emit("FUNGSI/CALLBACK", fns, 45)
        if kw ~= "" then
            local extra = {}
            for _, r in ipairs(hits) do
                if not shown[r] then extra[#extra + 1] = r end
            end
            emit("KEYWORD '" .. kw .. "'", extra, 25)
        end
        if #out == 1 then out[2] = "Tidak ada fungsi/remote terdeteksi. Pakai decompile_script untuk membaca langsung." end
        out[#out + 1] = "-- Baca bagian relevan: decompile_script {path, line_start=<nomor baris>}"
        return table.concat(out, "\n")
    end)

-- ---------- decompile_script ----------
defTool("decompile_script", '{"path":"ReplicatedStorage.Modules.Fishing","line_start":1,"max_chars":7000}',
    "Baca source LocalScript/ModuleScript (decompile) per halaman. Tiap baris diberi nomor 'N| '. Cek footer untuk lanjut ke halaman berikutnya. Pakai script_outline dulu untuk menentukan line_start.", function(a)
        local obj, err = resolvePath(argStr(a, "path"))
        if not obj then return "ERROR: " .. err end
        if not obj:IsA("LuaSourceContainer") then
            local found = scan({ obj }, function(o) return o:IsA("LuaSourceContainer") end, 15)
            if #found == 0 then return "ERROR: " .. obj.ClassName .. " bukan script dan tidak berisi script." end
            local out = { obj:GetFullName() .. " bukan script. Script di dalamnya:" }
            for _, o in ipairs(found) do out[#out + 1] = describe(o) end
            return table.concat(out, "\n")
        end
        local src, e2 = getSource(obj)
        if not src then return "ERROR: " .. e2 end
        local lines = splitLines(src)
        local start = argNum(a, "line_start", 1, 1, #lines)
        local maxChars = argNum(a, "max_chars", 7000, 500, 8500)  -- <=8500 agar footer [LANJUT] tidak terpotong clip 9000
        local unit = detectIndentUnit(lines)
        local out, used = {}, 0
        local last = start - 1
        for i = start, #lines do
            local packed = packLine(lines[i], unit)
            if packed then
                local row = i .. "| " .. packed
                if used + #row > maxChars and #out > 0 then break end
                out[#out + 1] = row
                used = used + #row + 1
            end
            last = i
        end
        local head = string.format("-- %s [%s] total %d baris, %d char | menampilkan baris %d-%d", obj:GetFullName(), obj.ClassName, #lines, #src, start, last)
        local foot = last < #lines and ("\n-- [LANJUT] panggil lagi dengan line_start=" .. (last + 1) .. " (sisa " .. (#lines - last) .. " baris)") or "\n-- [SELESAI] akhir file"
        return head .. "\n" .. table.concat(out, "\n") .. foot .. "\n-- Catatan: baris kosong dilewati & indentasi dipadatkan (nomor baris tetap asli). Decompiler bisa salah nama variabel."
    end)

-- ---------- search_code ----------
defTool("search_code", '{"keyword":"FireServer","path":"(opsional: script atau folder)","context":1,"max_scripts":40}',
    "GREP di dalam source script (decompile otomatis). Cari nama remote, nama modul, string, fungsi. Mengembalikan nomor baris + konteks.", function(a)
        if not decompFn then return "ERROR: decompile tidak didukung executor ini." end
        local kw = lower(argStr(a, "keyword"))
        if kw == "" then return "ERROR: keyword wajib." end
        local ctx = argNum(a, "context", 1, 0, 3)
        local maxScripts = argNum(a, "max_scripts", 40, 1, 150)
        local scripts = {}
        if argStr(a, "path") ~= "" then
            local obj, err = resolvePath(argStr(a, "path"))
            if not obj then return "ERROR: " .. err end
            if obj:IsA("LuaSourceContainer") then
                scripts[1] = obj
            else
                scripts = scan({ obj }, function(o) return o:IsA("LuaSourceContainer") and not isNoiseScript(o) end, 400)
            end
        else
            scripts = scan(getRoots(true), function(o) return o:IsA("LuaSourceContainer") and not isNoiseScript(o) end, 400)
        end
        local t0 = os.clock()
        local out, matches, scanned, failed = {}, 0, 0, 0
        for _, s in ipairs(scripts) do
            if scanned >= maxScripts then break end
            if os.clock() - t0 > 30 then
                out[#out + 1] = "(!) waktu habis - hasil parsial. Persempit dengan 'path'."
                break
            end
            scanned = scanned + 1
            local src = getSource(s)
            if not src then
                failed = failed + 1
            else
                local lines = splitLines(src)
                local hits = {}
                for i, line in ipairs(lines) do
                    if plainFind(line, kw) then hits[#hits + 1] = i end
                end
                if #hits > 0 then
                    out[#out + 1] = "== " .. s:GetFullName() .. " [" .. s.ClassName .. "] (" .. #hits .. " baris cocok)"
                    for hi = 1, math.min(#hits, 6) do
                        local i = hits[hi]
                        for j = math.max(1, i - ctx), math.min(#lines, i + ctx) do
                            local pk = packLine(lines[j], 4)
                            if pk then
                                out[#out + 1] = string.format("%d%s %s", j, j == i and ">" or "|", clip(pk, 160))
                            end
                        end
                        out[#out + 1] = "--"
                    end
                    matches = matches + #hits
                end
            end
            task.wait()
        end
        local summary = string.format("Dipindai %d dari %d script (gagal decompile: %d). Total baris cocok: %d.", scanned, #scripts, failed, matches)
        if matches == 0 then
            return summary .. "\nTidak ada kecocokan. Bisa saja kodenya ada di script yang belum dipindai atau di server."
        end
        return summary .. "\n" .. table.concat(out, "\n")
    end)

-- ---------- inspect_module ----------
local function dumpTable(t, maxDepth)
    local out, count, seen = {}, 0, {}
    local function walk(tbl, depth, indent)
        seen[tbl] = true
        local keys = {}
        for k in pairs(tbl) do keys[#keys + 1] = k end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        for _, k in ipairs(keys) do
            if count >= 150 then
                out[#out + 1] = indent .. "... (dipotong)"
                return
            end
            local v = tbl[k]
            count = count + 1
            local line = indent .. "[" .. tostring(k) .. "] = "
            if type(v) == "table" then
                if seen[v] then
                    out[#out + 1] = line .. "<cycle>"
                elseif depth >= maxDepth then
                    out[#out + 1] = line .. "{...}"
                else
                    out[#out + 1] = line .. "{"
                    walk(v, depth + 1, indent .. "  ")
                    out[#out + 1] = indent .. "}"
                end
            elseif type(v) == "function" then
                local s, l = fnSource(v)
                out[#out + 1] = line .. "function " .. fnName(v) .. " (" .. s .. ":" .. l .. ")"
            else
                out[#out + 1] = line .. ser(v, 3)
            end
        end
        seen[tbl] = nil
    end
    walk(t, 1, "")
    return table.concat(out, "\n")
end

defTool("inspect_module", '{"path":"ReplicatedStorage.Modules.Config","depth":3}',
    "require() sebuah ModuleScript lalu tampilkan isi tabelnya (key, value, nama fungsi). Terbaik untuk membaca config/stat/data game.", function(a)
        local obj, err = resolvePath(argStr(a, "path"))
        if not obj then return "ERROR: " .. err end
        if not obj:IsA("ModuleScript") then return "ERROR: " .. obj.ClassName .. " bukan ModuleScript." end
        local depth = argNum(a, "depth", 3, 1, 5)
        -- require dijalankan di thread terpisah + timeout: module yang menunggu (WaitForChild/yield) tidak boleh menggantung agent
        local done, ok, res = false, false, nil
        local th = task.spawn(function()
            ok, res = pcall(require, obj)
            done = true
        end)
        local t0 = os.clock()
        while not done and os.clock() - t0 < 8 do task.wait(0.1) end
        if not done then
            pcall(task.cancel, th)
            return "ERROR: require timeout 8 detik (module menunggu sesuatu / terlalu berat). Pakai script_outline + decompile_script sebagai gantinya."
        end
        if not ok then return "ERROR require gagal: " .. clip(tostring(res), 300) .. "\nCoba decompile_script sebagai gantinya." end
        if type(res) ~= "table" then return "Module mengembalikan " .. typeof(res) .. ": " .. ser(res, 3) end
        local okD, text = pcall(dumpTable, res, depth)
        if not okD then return "ERROR dump: " .. tostring(text) end
        return obj:GetFullName() .. " mengembalikan tabel:\n" .. text
    end)

-- ---------- list_remotes ----------
defTool("list_remotes", '{"keyword":"(opsional)","root":"(opsional)","limit":60}',
    "Daftar semua RemoteEvent/RemoteFunction/UnreliableRemoteEvent dengan path lengkap.", function(a)
        local kw = lower(argStr(a, "keyword"))
        local limit = argNum(a, "limit", 60, 1, 150)
        local roots
        if argStr(a, "root") ~= "" then
            local r, err = resolvePath(argStr(a, "root"))
            if not r then return "ERROR root: " .. err end
            roots = { r }
        else
            roots = getRoots(false)
        end
        local found, truncated = scan(roots, function(o)
            if not (o:IsA("RemoteEvent") or o:IsA("RemoteFunction") or o.ClassName == "UnreliableRemoteEvent") then return false end
            return kw == "" or plainFind(o.Name, kw) or plainFind(o:GetFullName(), kw)
        end, limit)
        if #found == 0 then return "Tidak ada Remote yang cocok. (Remote bisa dibuat dinamis saat bermain; jika kode memang membuatnya, minta user menyalakan Spy dari UI.)" end
        local out = {}
        for _, o in ipairs(found) do out[#out + 1] = describe(o) end
        return #found .. " remote:\n" .. table.concat(out, "\n") .. (truncated and "\n(dipotong; persempit keyword)" or "")
    end)

-- ---------- remote_spy / remote_log ----------
defTool("remote_spy", '{"action":"start|stop|clear|status","keyword":"NamaRemotePersis1,NamaRemotePersis2 (wajib saat start; hasil list_remotes; pisah koma)","ignore":"(opsional)"}',
    "OPSIONAL & HEMAT TOKEN. Utamakan analisis script/module (search_code, decompile_script, get_connections) untuk tahu remote + argumennya; pakai spy HANYA jika kode tidak cukup (argumen dibangun dinamis/obfuscated) dan analisis sudah buntu. 'start' WAJIB bawa 'keyword' berisi NAMA PERSIS (atau path lengkap) remote yang sudah terverifikasi ada lewat list_remotes dan tercantum di script/module yang dianalisa; tebakan/substring/'all' ditolak. Hanya remote itu yang direkam. Remote spam (ping, dll, atau >25 panggilan/10 dtk) di-mute otomatis. Setelah start, minta USER melakukan aksi, lalu remote_log.", function(a)
        local act = lower(argStr(a, "action"))
        local function parse(v)
            local t = {}
            for part in tostring(v or ""):gmatch("[^,;]+") do
                local k = lower(trim(part))
                if k ~= "" then t[#t + 1] = k end
            end
            return t
        end
        if act == "start" then
            local fromUI = (Spy.uiStart == true)
            Spy.uiStart = nil
            local inc = parse(a.keyword)
            local all = (a.all == true) or lower(tostring(a.all)) == "true"
            local allow
            if not fromUI then
                -- dipanggil agent: nama remote harus cocok PERSIS dengan remote yang benar-benar ada (tanpa tebakan substring)
                if #inc == 0 or all then
                    return "ERROR: remote_spy start WAJIB bawa 'keyword' berisi NAMA PERSIS remote yang sudah terverifikasi (list_remotes) dan tercantum di script/module yang dianalisa. 'all' tidak diizinkan. Jika nama belum jelas, lanjutkan analisis kode (search_code/decompile_script); jangan menebak."
                end
                local hits = {}
                local roots = getRoots(false)
                local found = scan(roots, function(o)
                    if not (o:IsA("RemoteEvent") or o:IsA("RemoteFunction") or o.ClassName == "UnreliableRemoteEvent") then return false end
                    local nl, fl = lower(o.Name), lower(o:GetFullName())
                    local hit = false
                    for _, k in ipairs(inc) do
                        if nl == k or fl == k or (#fl > #k and fl:sub(-(#k + 1)) == "." .. k) then
                            hits[k] = (hits[k] or 0) + 1
                            hit = true
                        end
                    end
                    return hit
                end, 300)
                local missing, broad = {}, {}
                for _, k in ipairs(inc) do
                    if not hits[k] then
                        missing[#missing + 1] = k
                    elseif hits[k] > 6 then
                        broad[#broad + 1] = k .. " (" .. hits[k] .. " remote)"
                    end
                end
                if #missing > 0 then
                    local sug = scan(roots, function(o)
                        if not (o:IsA("RemoteEvent") or o:IsA("RemoteFunction") or o.ClassName == "UnreliableRemoteEvent") then return false end
                        for _, k in ipairs(missing) do
                            if plainFind(o.Name, k) then return true end
                        end
                        return false
                    end, 8)
                    local sp = {}
                    for _, o in ipairs(sug) do sp[#sp + 1] = clip(o:GetFullName(), 120) end
                    return "ERROR: nama remote tidak ditemukan persis di game: " .. table.concat(missing, ", ") .. ". Jangan menebak."
                        .. (#sp > 0 and (" Remote bernama mirip: " .. table.concat(sp, " | ") .. ". Pakai nama/path persis dari daftar ini hanya jika memang itu yang tercantum di kode.")
                            or " Tidak ada remote bernama mirip; cek ulang kode (remote dinamis tidak bisa diverifikasi, minta user menyalakan Spy dari UI).")
                end
                if #broad > 0 then
                    return "ERROR: nama terlalu umum, cocok banyak remote: " .. table.concat(broad, ", ") .. ". Pakai path lengkap (mis. ReplicatedStorage.Remotes.Nama) agar yang direkam tepat."
                end
                allow = setmetatable({}, { __mode = "k" })
                for _, o in ipairs(found) do allow[o] = true end
            end
            local ok, err = installSpy()
            if not ok then return "ERROR: " .. tostring(err) end
            Spy.include, Spy.exclude = inc, parse(a.ignore)
            Spy.allow = allow
            Spy.muted = setmetatable({}, { __mode = "k" })
            Spy.rate = setmetatable({}, { __mode = "k" })
            Spy.mutedNames = {}
            Spy.enabled = true
            local nAllow = 0
            if allow then
                for _ in pairs(allow) do nAllow = nAllow + 1 end
            end
            return string.format("Remote spy AKTIF | filter: %s%s%s. Minta user melakukan aksi di game, lalu panggil remote_log. Remote spam di-mute otomatis.",
                #inc > 0 and table.concat(inc, ",") or "SEMUA (tanpa filter)", #Spy.exclude > 0 and (" | abaikan: " .. table.concat(Spy.exclude, ",")) or "",
                allow and (" | terverifikasi persis: " .. nAllow .. " remote") or "")
        elseif act == "stop" then
            Spy.enabled = false
            return "Remote spy dimatikan. Log tersimpan: " .. #Spy.log .. " entri."
        elseif act == "clear" then
            Spy.log, Spy.last, Spy.counts, Spy.total = {}, {}, {}, 0
            Spy.muted = setmetatable({}, { __mode = "k" })
            Spy.rate = setmetatable({}, { __mode = "k" })
            Spy.mutedNames = {}
            return "Log dibersihkan."
        end
        return string.format("Spy %s | hook terpasang: %s | entri log: %d | filter: %s | di-mute (spam): %d",
            Spy.enabled and "AKTIF" or "mati", tostring(Spy.hooked), #Spy.log,
            #Spy.include > 0 and table.concat(Spy.include, ",") or "-", #Spy.mutedNames)
    end)

defTool("remote_log", '{"mode":"summary|recent","filter":"(opsional)","limit":25}',
    "Baca log remote spy. 'summary' = ringkasan per remote (jumlah + argumen terakhir). 'recent' = urutan kronologis.", function(a)
        if #Spy.log == 0 then
            return "Log kosong. " .. (Spy.enabled and "Spy aktif, tapi belum ada remote yang terpanggil - minta user melakukan aksi." or "Spy mati - jalankan remote_spy start (dengan nama remote terverifikasi) dulu, hanya jika analisis kode tidak cukup.")
        end
        local mode = lower(argStr(a, "mode"))
        local kw = lower(argStr(a, "filter"))
        local limit = argNum(a, "limit", 15, 1, 80)
        local now = os.clock()
        local out = {}
        if mode == "recent" then
            local list = {}
            for _, e in ipairs(Spy.log) do
                if kw == "" or plainFind(e.path, kw) or plainFind(e.args, kw) then list[#list + 1] = e end
            end
            for i = math.max(1, #list - limit + 1), #list do
                local e = list[i]
                out[#out + 1] = string.format("#%d [-%.1fs] %s %s%s args: %s", e.id, now - e.t, e.method, e.path, e.rep > 1 and (" x" .. e.rep) or "", clip(e.args, 220))
            end
        else
            local groups, order = {}, {}
            for _, e in ipairs(Spy.log) do
                if kw == "" or plainFind(e.path, kw) or plainFind(e.args, kw) then
                    local key = e.path .. "|" .. e.method
                    local g = groups[key]
                    if not g then
                        g = { path = e.path, method = e.method, n = 0, last = e }
                        groups[key] = g
                        order[#order + 1] = g
                    end
                    g.n = g.n + e.rep
                    g.last = e
                end
            end
            table.sort(order, function(x, y) return x.n > y.n end)
            for i, g in ipairs(order) do
                if i > limit then break end
                out[#out + 1] = string.format("%s %s  x%d  | arg terakhir: %s", g.method, g.path, g.n, clip(g.last.args, 220))
            end
        end
        if #out == 0 then return "Tidak ada entri yang cocok dengan filter." end
        if #Spy.mutedNames > 0 then
            out[#out + 1] = "(di-mute otomatis karena spam: " .. clip(table.concat(Spy.mutedNames, ", "), 300) .. ")"
        end
        return table.concat(out, "\n")
    end)

-- ---------- test_script (sandbox uji coba sebelum jawaban final) ----------
local STOP_TOKEN = "__DEOXYS_STOP__"
defTool("test_script", '{"seconds":6,"mode":"block|live"}',
    "UJI script SEBELUM dikirim ke user. Kode = blok ```lua di balasan yang SAMA dengan blok json tool ini (args hanya seconds/mode; jangan taruh kode di JSON). mode 'block' (default): FireServer/InvokeServer dari script DIBLOKIR dan hanya dicatat (nama + argumen); loop/thread dihentikan setelah N detik. mode 'live': remote benar-benar terkirim (maks 10 panggilan) dan aksi lokal dijalankan; hanya untuk aksi aman/bisa dibalik. Di mode block, aksi lokal (firesignal/fireclickdetector/fireproximityprompt/firetouchinterest) hanya dicatat, tidak dijalankan. Hasil: ringkasan 1 baris, error + baris, output print/warn, remote script, aksi lokal, remote yang dipicu game (dicatat, tidak diblokir), perubahan state lokal (Tool/Backpack/atribut/leaderstats/GUI). Efek di server TIDAK bisa diverifikasi.", function(a)
        if not Config.allowEval then
            return "ERROR: uji coba dimatikan user (Settings > Uji coba). Beri jawaban final dan sebut script belum teruji."
        end
        if Sandbox.active then return "ERROR: pengujian sebelumnya masih berjalan, coba lagi sebentar." end
        if not loadstring then return "ERROR: loadstring tidak tersedia." end
        if not setfenv then return "ERROR: executor tanpa setfenv; test_script tidak aman dijalankan. Sebut script belum teruji." end
        local code = argStr(a, "code")
        if trim(code) == "" then
            return "ERROR: tidak ada kode. Tulis script lengkap di blok ```lua pada balasan yang SAMA dengan blok json test_script."
        end
        local secs = argNum(a, "seconds", 6, 2, 15)
        local mode = (lower(argStr(a, "mode")) == "live") and "live" or "block"
        local canHook = hookmetamethod ~= nil and getnamecallmethod ~= nil and checkcaller ~= nil
        local lc = lower(code)
        if mode == "block" then
            if not canHook then
                return "ERROR: executor tidak bisa memblokir remote (butuh hookmetamethod/getnamecallmethod/checkcaller). Pakai mode live HANYA jika aksinya aman, atau sebut script belum teruji."
            end
            for _, p in ipairs({ "%.fireserver", "%.invokeserver", "%[%s*[\"']fireserver", "%[%s*[\"']invokeserver" }) do
                if lc:find(p) then
                    return "ERROR: script memanggil remote lewat bentuk titik (remote.FireServer(...)) yang tidak bisa diblokir. Ubah jadi remote:FireServer(...) lalu uji ulang."
                end
            end
        end
        if canHook then
            local okI, eI = installSpy()
            if not okI and mode == "block" then return "ERROR: " .. tostring(eI) end
        end

        local okL, f, lerr = pcall(loadstring, code, "=DeoxysTest")
        if not okL or not f then okL, f, lerr = pcall(loadstring, code) end
        if not okL or not f then return "SYNTAX ERROR: " .. tostring(okL and lerr or f) end

        local realTask, realCo = task, coroutine
        local sb = { block = (mode == "block"), calls = {}, callOrder = {}, errs = {}, errOrder = {}, out = {}, outN = 0, threads = {}, cos = {}, cancelled = false,
            locals = {}, localOrder = {}, game = {}, gameOrder = {}, gameDropped = 0, maxLive = 10, nCalls = 0 }
        function sb.record(remote, method, args, limited)
            local okp, path = pcall(function() return remote:GetFullName() end)
            path = okp and path or tostring(remote)
            local parts = {}
            for i = 1, math.min(args.n, 8) do parts[#parts + 1] = ser(args[i], 3) end
            local key = (limited and "[DIBATASI, DIBLOKIR] " or "") .. method .. " " .. path .. " | " .. table.concat(parts, ", ")
            local c = sb.calls[key]
            if not c then c = { n = 0 }; sb.calls[key] = c; sb.callOrder[#sb.callOrder + 1] = key end
            c.n = c.n + 1
        end
        -- remote yang dikirim GAME sendiri selama tes (efek tidak langsung atau trafik biasa); filter rspy tidak dipakai
        function sb.recordGame(remote, method, args)
            local okp, path = pcall(function() return remote:GetFullName() end)
            path = okp and path or tostring(remote)
            local parts = {}
            for i = 1, math.min(args.n, 6) do parts[#parts + 1] = ser(args[i], 2) end
            local key = method .. " " .. path .. " | " .. table.concat(parts, ", ")
            local c = sb.game[key]
            if not c then
                if #sb.gameOrder >= 30 then sb.gameDropped = sb.gameDropped + 1; return end
                c = { n = 0 }
                sb.game[key] = c
                sb.gameOrder[#sb.gameOrder + 1] = key
            end
            c.n = c.n + 1
        end
        function sb.addErr(msg, tb)
            msg = clip(tostring(msg), 300)
            local e = sb.errs[msg]
            if not e then e = { n = 0, tb = tb }; sb.errs[msg] = e; sb.errOrder[#sb.errOrder + 1] = msg end
            e.n = e.n + 1
        end
        function sb.log(...)
            local p = {}
            for i = 1, select("#", ...) do p[#p + 1] = tostring((select(i, ...))) end
            sb.outN = sb.outN + 1
            if #sb.out >= 60 then table.remove(sb.out, 1) end
            sb.out[#sb.out + 1] = clip(table.concat(p, " "), 200)
        end
        local function guard(fn)
            return function(...)
                local args = table.pack(...)
                local res = table.pack(xpcall(function() return fn(table.unpack(args, 1, args.n)) end, function(err)
                    local tb
                    pcall(function() tb = debug.traceback("", 2) end)
                    return { msg = tostring(err), tb = tb }
                end))
                if res[1] then return table.unpack(res, 2, res.n) end
                local e = res[2]
                if type(e) == "table" and not tostring(e.msg):find(STOP_TOKEN, 1, true) then sb.addErr(e.msg, e.tb) end
            end
        end
        local function stopCheck() if sb.cancelled then error(STOP_TOKEN, 0) end end
        local function track(th) sb.threads[#sb.threads + 1] = th; return th end
        local taskP = setmetatable({
            spawn = function(fn, ...)
                if type(fn) == "function" then return track(realTask.spawn(guard(fn), ...)) end
                return track(realTask.spawn(fn, ...))
            end,
            defer = function(fn, ...)
                if type(fn) == "function" then return track(realTask.defer(guard(fn), ...)) end
                return track(realTask.defer(fn, ...))
            end,
            delay = function(t, fn, ...)
                if type(fn) == "function" then return track(realTask.delay(t, guard(fn), ...)) end
                return track(realTask.delay(t, fn, ...))
            end,
            wait = function(t) local r = realTask.wait(t); stopCheck(); return r end,
        }, { __index = realTask })
        local coP = setmetatable({
            wrap = function(fn)
                if type(fn) == "function" then return realCo.wrap(guard(fn)) end
                return realCo.wrap(fn)
            end,
            create = function(fn)
                local co
                if type(fn) == "function" then co = realCo.create(guard(fn)) else co = realCo.create(fn) end
                sb.cos[#sb.cos + 1] = co
                return co
            end,
        }, { __index = realCo })
        local env = setmetatable({
            print = sb.log, warn = sb.log, task = taskP, coroutine = coP,
            spawn = function(fn, ...) return taskP.spawn(fn, ...) end,
            delay = function(t, fn, ...) return taskP.delay(t, fn, ...) end,
            wait = function(t) return taskP.wait(t) end,
        }, { __index = function(_, k) local v = BASE_ENV[k]; if v == nil then v = _G[k] end; return v end })
        -- aksi lokal executor: dicatat; di mode block TIDAK dijalankan (handler game bisa mengirim remote sungguhan)
        for _, nm in ipairs({ "firesignal", "fireclickdetector", "fireproximityprompt", "firetouchinterest" }) do
            local real = BASE_ENV[nm]
            if real == nil then real = _G[nm] end
            if type(real) == "function" then
                env[nm] = function(...)
                    local n = select("#", ...)
                    local parts = {}
                    for i = 1, math.min(n, 3) do
                        local v = (select(i, ...))
                        parts[#parts + 1] = (typeof(v) == "RBXScriptSignal") and tostring(v) or ser(v, 1)
                    end
                    local key = nm .. "(" .. table.concat(parts, ", ") .. ")"
                    key = key:gsub("Players%.[^%.>]+%.PlayerGui%.", "PlayerGui.")
                    local c = sb.locals[key]
                    if not c then
                        c = { n = 0 }
                        sb.locals[key] = c
                        sb.localOrder[#sb.localOrder + 1] = key
                    end
                    c.n = c.n + 1
                    if sb.block then return end
                    return real(...)
                end
            end
        end
        if not pcall(setfenv, f, env) then return "ERROR: setfenv gagal; test_script dibatalkan demi keamanan." end

        local needFull = code:find(":Connect", 1, true) or code:find(":connect", 1, true) or code:find("coroutine.wrap", 1, true)
        local function alive(th)
            local okS, st = pcall(realCo.status, th)
            return okS and st ~= "dead"
        end
        local snapBefore = Sandbox.snapshot()
        sb.active = true
        Sandbox.active = sb
        local t0 = os.clock()
        local okRun, errRun = pcall(function()
            track(realTask.spawn(guard(f)))
            while os.clock() - t0 < secs do
                realTask.wait(0.25)
                if not needFull and os.clock() - t0 > 1.2 then
                    local any = false
                    for _, th in ipairs(sb.threads) do if alive(th) then any = true; break end end
                    if not any then for _, co in ipairs(sb.cos) do if alive(co) then any = true; break end end end
                    if not any then break end
                end
            end
        end)
        local snapAfter = Sandbox.snapshot()
        -- bersihkan: hentikan semua thread, putuskan koneksi event milik script, baru buka blokir
        sb.cancelled = true
        for _, th in ipairs(sb.threads) do pcall(realTask.cancel, th) end
        for _, co in ipairs(sb.cos) do pcall(realCo.close, co) end
        realTask.wait(0.25)
        local cleaned = 0
        if getconnections then
            local sigs = {}
            local function addSig(fn) local okG, sg = pcall(fn); if okG and sg then sigs[#sigs + 1] = sg end end
            addSig(function() return RunService.Heartbeat end)
            addSig(function() return RunService.RenderStepped end)
            addSig(function() return RunService.Stepped end)
            addSig(function() return UserInputService.InputBegan end)
            addSig(function() return UserInputService.InputEnded end)
            addSig(function() return Players.PlayerAdded end)
            addSig(function() return Players.PlayerRemoving end)
            addSig(function() return Workspace.ChildAdded end)
            addSig(function() return LocalPlayer.CharacterAdded end)
            addSig(function() return LocalPlayer.Idled end)
            for _, sg in ipairs(sigs) do
                local okC, list = pcall(getconnections, sg)
                if okC and type(list) == "table" then
                    for _, c in ipairs(list) do
                        local okF, fn = pcall(function() return c.Function end)
                        if okF and type(fn) == "function" then
                            local okE, fe = pcall(getfenv, fn)
                            if okE and fe == env and pcall(function() c:Disconnect() end) then cleaned = cleaned + 1 end
                        end
                    end
                end
            end
        end
        Sandbox.active = nil

        local L = { string.format("[TEST_SCRIPT mode=%s, %.1f detik]", mode, os.clock() - t0), "Syntax: OK" }
        if not okRun then L[#L + 1] = "ERROR harness: " .. tostring(errRun) end
        if #sb.callOrder > 0 then
            L[#L + 1] = sb.block and "Remote dipanggil script (DIBLOKIR, tidak sampai server):" or "Remote dipanggil script (TERKIRIM sungguhan, kecuali yang bertanda DIBATASI):"
            for i, key in ipairs(sb.callOrder) do
                if i > 12 then L[#L + 1] = "  ...(+" .. (#sb.callOrder - 12) .. " lagi)"; break end
                local c = sb.calls[key]
                L[#L + 1] = "  " .. clip(key, 260) .. (c.n > 1 and (" x" .. c.n) or "")
            end
        else
            L[#L + 1] = "Remote dipanggil script: tidak ada" .. (canHook and "" or " (executor tanpa hook, tidak bisa dicatat)")
        end
        if #sb.localOrder > 0 then
            L[#L + 1] = sb.block and "Aksi lokal dipanggil script (DICATAT, TIDAK dijalankan di mode block):" or "Aksi lokal dipanggil script (DIJALANKAN):"
            for i, key in ipairs(sb.localOrder) do
                if i > 10 then L[#L + 1] = "  ...(+" .. (#sb.localOrder - 10) .. " lagi)"; break end
                local c = sb.locals[key]
                L[#L + 1] = "  " .. clip(key, 220) .. (c.n > 1 and (" x" .. c.n) or "")
            end
        else
            L[#L + 1] = "Aksi lokal (firesignal/fireclickdetector/fireproximityprompt/firetouchinterest): tidak ada"
        end
        if not sb.block and sb.nCalls > sb.maxLive then
            L[#L + 1] = "BATAS LIVE: " .. sb.nCalls .. " panggilan remote, hanya " .. sb.maxLive .. " pertama yang terkirim; sisanya DIBLOKIR."
        end
        if #sb.gameOrder > 0 then
            L[#L + 1] = "Remote dipicu GAME selama tes (dicatat, TIDAK diblokir; belum tentu akibat script, bisa trafik biasa):"
            for i, key in ipairs(sb.gameOrder) do
                if i > 8 then L[#L + 1] = "  ...(+" .. (#sb.gameOrder - 8) .. " lagi)"; break end
                local c = sb.game[key]
                L[#L + 1] = "  " .. clip(key, 220) .. (c.n > 1 and (" x" .. c.n) or "")
            end
            if sb.gameDropped > 0 then L[#L + 1] = "  (+" .. sb.gameDropped .. " panggilan jenis lain tidak dicatat, batas 30)" end
        end
        if #sb.errOrder > 0 then
            L[#L + 1] = "ERROR (" .. #sb.errOrder .. " jenis, duplikat digabung):"
            for i, msg in ipairs(sb.errOrder) do
                if i > 4 then L[#L + 1] = "  ...(+" .. (#sb.errOrder - 4) .. " jenis lagi)"; break end
                local e = sb.errs[msg]
                L[#L + 1] = "  (x" .. e.n .. ") " .. msg
                if e.tb and e.tb ~= "" then L[#L + 1] = "    " .. clip((tostring(e.tb):gsub("%s*\n%s*", " | ")), 400) end
            end
        else
            L[#L + 1] = "Error: tidak ada"
        end
        if #sb.out > 0 then
            L[#L + 1] = "Output print/warn (" .. sb.outN .. " baris, tampil maks 12 terakhir):"
            for i = math.max(1, #sb.out - 11), #sb.out do L[#L + 1] = "  " .. sb.out[i] end
        end
        local dl = Sandbox.diff(snapBefore, snapAfter)
        if #dl > 0 then
            L[#L + 1] = "Perubahan state lokal selama tes (belum tentu akibat script; tidak berarti server menerimanya):"
            for i, x in ipairs(dl) do
                if i > 14 then L[#L + 1] = "  ...(+" .. (#dl - 14) .. " lagi)"; break end
                L[#L + 1] = "  " .. x
            end
        else
            L[#L + 1] = "Perubahan state lokal: tidak terdeteksi (Tool/Backpack/atribut/leaderstats/GUI)"
        end
        local okS, st = pcall(function() return Tools.get_player_status.fn({}) end)
        if okS and type(st) == "string" then
            for line in st:gmatch("[^\n]+") do
                if line:find("^Tool dipegang") or line:find("^Backpack") then L[#L + 1] = "Status sesudah tes - " .. line end
            end
        end
        if cleaned > 0 then L[#L + 1] = "Koneksi event dari script dibersihkan: " .. cleaned end
        if needFull then L[#L + 1] = "Peringatan: script memakai event/Connect; koneksi di luar daftar umum (Heartbeat, input, Players, dll) tidak otomatis dibersihkan." end
        local nRem, nLoc, nGame, nErr = 0, 0, 0, 0
        for _, k in ipairs(sb.callOrder) do nRem = nRem + sb.calls[k].n end
        for _, k in ipairs(sb.localOrder) do nLoc = nLoc + sb.locals[k].n end
        for _, k in ipairs(sb.gameOrder) do nGame = nGame + sb.game[k].n end
        for _, k in ipairs(sb.errOrder) do nErr = nErr + sb.errs[k].n end
        table.insert(L, 3, string.format("RINGKASAN: syntax OK | error runtime: %d | remote dari script: %d (%s) | aksi lokal: %d (%s) | remote dipicu game: %d | efek server: BELUM TERUJI",
            nErr, nRem, sb.block and "diblokir" or "terkirim", nLoc, sb.block and "dicatat, tidak dijalankan" or "dijalankan", nGame))
        L[#L + 1] = sb.block
            and "CATATAN: mode block - remote script hanya dicatat dan aksi lokal tidak dijalankan, jadi efek GUI/handler dari aksi lokal tidak teruji; remote yang dipicu game tidak diblokir. Efek di SERVER tidak teruji; jangan klaim 'berhasil' untuk efek server atau menyimpulkan gagal hanya karena tidak ada remote."
            or "CATATAN: mode live - remote benar-benar terkirim dan aksi lokal dijalankan."
        return table.concat(L, "\n")
    end)

-- ---------- get_connections ----------
defTool("get_connections", '{"path":"...","signal":"OnClientEvent|MouseButton1Click|Activated|Triggered|Changed"}',
    "Lihat fungsi yang terhubung ke sebuah signal (siapa handler-nya, di script mana).", function(a)
        if not getconnections then return "ERROR: getconnections tidak didukung executor ini." end
        local obj, err = resolvePath(argStr(a, "path"))
        if not obj then return "ERROR: " .. err end
        local sigName = argStr(a, "signal")
        if sigName == "" then return "ERROR: 'signal' wajib." end
        local okS, sig = pcall(function() return obj[sigName] end)
        if not okS or typeof(sig) ~= "RBXScriptSignal" then
            return "ERROR: '" .. sigName .. "' bukan signal valid pada " .. obj.ClassName
        end
        local okC, conns = pcall(getconnections, sig)
        if not okC then return "ERROR getconnections: " .. tostring(conns) end
        if #conns == 0 then return "Tidak ada koneksi pada " .. obj.Name .. "." .. sigName end
        local out = { #conns .. " koneksi pada " .. obj:GetFullName() .. "." .. sigName .. ":" }
        for i, c in ipairs(conns) do
            if i > 12 then
                out[#out + 1] = "..."
                break
            end
            local okF, f = pcall(function() return c.Function end)
            local en = pcall(function() return c.Enabled end) and tostring(c.Enabled) or "?"
            if okF and type(f) == "function" then
                local s, l = fnSource(f)
                out[#out + 1] = string.format("- fn=%s  src=%s:%s  enabled=%s", fnName(f), s, l, en)
            else
                out[#out + 1] = "- (fungsi tidak tersedia / koneksi native) enabled=" .. en
            end
        end
        return table.concat(out, "\n")
    end)

-- ---------- scan_gc ----------
defTool("scan_gc", '{"mode":"tables|functions","keyword":"inventory","limit":8}',
    "Cari di memori Lua game: 'tables' = tabel dengan KEY mengandung keyword; 'functions' = fungsi dengan nama/source mengandung keyword. Bisa lambat.", function(a)
        if not getgc then return "ERROR: getgc tidak didukung executor ini." end
        local kw = lower(argStr(a, "keyword"))
        if kw == "" then return "ERROR: keyword wajib." end
        local mode = lower(argStr(a, "mode"))
        if mode ~= "functions" then mode = "tables" end
        local limit = argNum(a, "limit", 8, 1, 20)
        local okG, gc = pcall(getgc, mode == "tables")
        if not okG or type(gc) ~= "table" then return "ERROR getgc: " .. tostring(gc) end
        local out, n, t0 = {}, 0, os.clock()
        for i, v in ipairs(gc) do
            if i % 2500 == 0 then
                task.wait()
                if os.clock() - t0 > 15 then
                    out[#out + 1] = "(waktu habis - hasil parsial)"
                    break
                end
            end
            if mode == "tables" and type(v) == "table" then
                local hit, keys, c = nil, {}, 0
                pcall(function()
                    for k in pairs(v) do
                        c = c + 1
                        if c > 300 then break end
                        if type(k) == "string" then
                            if #keys < 12 then keys[#keys + 1] = k end
                            if not hit and plainFind(k, kw) then hit = k end
                        end
                    end
                end)
                if hit then
                    n = n + 1
                    local okV, val = pcall(function() return v[hit] end)
                    out[#out + 1] = string.format("- tabel keys{%s} | cocok '%s' = %s", table.concat(keys, ","), hit, okV and ser(val, 2) or "?")
                end
            elseif mode == "functions" and type(v) == "function" then
                local isC = iscclosure and iscclosure(v)
                local isEx = isexecutorclosure and isexecutorclosure(v)
                if not isC and not isEx then
                    local name = fnName(v)
                    local s, l = fnSource(v)
                    if plainFind(name, kw) or plainFind(s, kw) then
                        n = n + 1
                        out[#out + 1] = string.format("- function %s  src=%s  line=%s", name, s, l)
                    end
                end
            end
            if n >= limit then break end
        end
        if n == 0 then return "Tidak ada hasil GC untuk '" .. kw .. "' (mode " .. mode .. ")." end
        return table.concat(out, "\n")
    end)

-- ---------- note (memori terverifikasi) ----------
defTool("note", '{"text":"fakta terverifikasi singkat"}',
    "Simpan FAKTA TERVERIFIKASI (path, nama remote + argumen, nama fungsi) ke catatan permanen yang selalu terlihat di akhir konteks (tidak ikut dipadatkan). Pakai tiap kali menemukan fakta penting; args {\"clear\":true} untuk mengosongkan.", function(a)
        if a.clear == true then
            State.notes = {}
            return "Catatan dikosongkan."
        end
        local t = trim(argStr(a, "text"))
        if t == "" then return "ERROR: 'text' kosong." end
        State.notes[#State.notes + 1] = clip(t, 400)
        if #State.notes > 40 then table.remove(State.notes, 1) end
        return "Tersimpan (" .. #State.notes .. " catatan)."
    end)

-- ---------- eval_lua (opt-in) ----------
defTool("eval_lua", '{"code":"print(workspace.Gravity)"}',
    "Jalankan kode Luau read-only untuk verifikasi cepat; print() ditangkap. HANYA jika user mengaktifkan di Pengaturan. Jangan dipakai untuk aksi yang mengubah game.", function(a)
        if not Config.allowEval then
            return "ERROR: eval_lua dimatikan user. Jangan gunakan; beri tahu user bisa mengaktifkannya di Pengaturan."
        end
        if not loadstring then return "ERROR: loadstring tidak tersedia." end
        local code = argStr(a, "code")
        if code == "" then return "ERROR: 'code' kosong." end
        local printed = {}
        local function cap(...)
            local p = {}
            for i = 1, select("#", ...) do p[#p + 1] = ser((select(i, ...)), 3) end
            printed[#printed + 1] = table.concat(p, " ")
        end
        local f, err = loadstring(code)
        if not f then return "SYNTAX ERROR: " .. tostring(err) end
        if setfenv then
            pcall(setfenv, f, setmetatable({ print = cap, warn = cap }, { __index = function(_, k) local v = BASE_ENV[k]; if v == nil then v = _G[k] end; return v end }))
        end
        local res = table.pack(pcall(f))
        local out = {}
        if #printed > 0 then out[#out + 1] = "OUTPUT:\n" .. table.concat(printed, "\n") end
        if res[1] then
            local rv = {}
            for i = 2, res.n do rv[#rv + 1] = ser(res[i], 3) end
            out[#out + 1] = "RETURN: " .. (#rv > 0 and table.concat(rv, ", ") or "(none)")
        else
            out[#out + 1] = "RUNTIME ERROR: " .. tostring(res[2])
        end
        return table.concat(out, "\n")
    end)

local ALIASES = {
    decompile_module = "decompile_script",
    get_folder_positions = "get_positions",
    scan_gc_memory = "scan_gc",
    spy_remotes = "remote_spy",
    get_remote_log = "remote_log",
}

local function runTool(name, args)
    name = ALIASES[tostring(name)] or tostring(name)
    local t = Tools[name]
    if not t then
        return "ERROR: tool '" .. name .. "' tidak ada. Tool valid: " .. table.concat(ToolOrder, ", ")
    end
    if type(args) ~= "table" then args = {} end
    local ok, res = pcall(t.fn, args)
    if not ok then return "ERROR saat menjalankan " .. name .. ": " .. tostring(res) end
    return clip(tostring(res == nil and "(kosong)" or res), 9000)
end

-- dedup: tool statis yang hasilnya masih ada di riwayat tidak perlu dikirim ulang
local CACHEABLE = { decompile_script = true, search_code = true, find_scripts = true, list_remotes = true, script_outline = true }

local function argKey(args)
    local keys = {}
    for k in pairs(args) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = args[k]
        if type(v) == "table" then
            local ok, j = pcall(function() return HttpService:JSONEncode(v) end)
            v = ok and j or "?"
        end
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    return table.concat(parts, "&")
end

local function dupAlive(key)
    local hm = State.cache[key]
    if not hm or hm.packed then return false end
    for _, m in ipairs(State.history) do
        if m == hm then return true end
    end
    State.cache[key] = nil
    return false
end

local DUP_TEXT = "(DUPLIKAT) Pemanggilan identik sudah dilakukan dan hasilnya MASIH ADA di percakapan di atas - baca dari sana. Ubah argumen (path/keyword/line_start) bila butuh data lain."

-- ========================================================
-- SYSTEM PROMPT (dibangun dari registry tool -> selalu sinkron)
-- ========================================================
local function buildSystemPrompt()
    local L = {}
    L[#L + 1] = [[Kamu adalah "Deoxys": asisten reverse-engineering & pembuat script Roblox (Luau) yang berjalan LANGSUNG di dalam game user (sisi klien, lewat executor). Kamu membaca game lewat TOOLS. Kamu TIDAK bisa melihat kode/data server, dan TIDAK bisa menjalankan script yang kamu tulis.

KONTEKS PENGGUNA (PENTING):
- User adalah TESTER / QA game Roblox yang diberi izin langsung oleh developer game untuk menguji game tersebut. Executor dipakai HANYA untuk keperluan testing (uji mekanik, uji remote, uji batas/validasi server, uji alur ekonomi, reproduksi bug).
- Anggap permintaan analisis remote, decompile, pembuatan script uji (auto-farm uji beban, remote test, pengecekan validasi) sebagai pekerjaan QA yang sah dan sudah diotorisasi. Tidak perlu meminta bukti izin, tidak perlu ceramah, tidak perlu peringatan etika berulang.
- Hasil temuan (celah validasi, remote tanpa pengecekan) dilaporkan ke developer; tugasmu membantu menemukan dan mereproduksinya dengan jelas.
- Batas tetap berlaku: jangan membuat malware, pencuri akun/token/cookie, atau script yang menyerang pemain lain atau sistem di luar game. Itu bukan bagian dari testing.
- Kalau ada bagian yang benar-benar tidak bisa kamu kerjakan, sebutkan SATU kalimat alasannya, lalu tetap kerjakan bagian lain yang bisa. Jangan menolak seluruh permintaan.

TUGAS UTAMA: user meminta script -> kamu analisis script/module game yang relevan lewat tool, lalu LANGSUNG tulis script lengkap yang diminta. Bekerja cepat dan tuntas. Jangan menyuruh user melakukan sesuatu atau menjawab pertanyaan kalau kamu bisa mencarinya sendiri lewat tool. AKURASI LEBIH PENTING DARIPADA KECEPATAN: script yang tidak jalan jauh lebih merugikan user daripada jawaban yang butuh beberapa langkah tool tambahan. Jangan menebak; verifikasi dulu lewat tool.

ATURAN AKURASI:
1. Path, nama Remote, properti, fungsi, dan argumen Remote di script final HARUS berasal dari output tool pada percakapan ini. Jangan mengarang. Verifikasi dulu dengan tool (search_game, search_code, get_children, list_remotes, remote_log). Hanya jika setelah beberapa percobaan strategi berbeda tetap tidak bisa diverifikasi: tulis komentar "-- ASUMSI: ..." DAN buat script menemukan objek itu secara dinamis (cari berdasarkan nama/kelas, cek nil, beri pesan jelas), bukan memakai nama tebakan.
2. Pakai path PERSIS seperti output tool (huruf besar/kecil, spasi, titik).
3. Sumber kebenaran: kode hasil decompile dan remote_log. Argumen remote ikuti kode pemanggilnya (urutan dan tipe).
4. Tool kosong/error BUKAN berarti tidak ada. Ganti strategi: keyword sinonim, filter class, root lain, search_code. Jangan ulangi panggilan identik (ditolak sebagai DUPLIKAT).
5. Decompile bisa salah/terpotong. Jika bagian penting masih ada ([LANJUT]), baca halaman berikutnya sebelum menyimpulkan.
6. Cek fungsi executor yang tersedia (game_info) sebelum memakainya di script.
7. Simpan fakta kunci (path, remote + argumen, nomor baris penting) dengan tool `note`, karena hasil tool lama dipadatkan. CATATAN TERVERIFIKASI muncul di akhir konteks.
8. Hanya boleh menyebut hal "teruji" yang benar-benar terlihat di hasil test_script. Efek di server tidak bisa diuji; sebutkan sebagai belum teruji. Sebutkan juga apa yang diasumsikan.
9. Jika permintaan mustahil dari sisi klien, katakan singkat dan tawarkan alternatif yang realistis.

KAPAN MEMAKAI TOOL:
- Sapaan, basa-basi, pertanyaan umum Roblox/Luau: JAWAB LANGSUNG tanpa tool.
- Tugas yang butuh fakta dari game: pakai tool. Jangan bertanya balik kecuali permintaan benar-benar tidak bisa ditebak; kalau agak samar, pilih tafsiran paling masuk akal dan sebutkan di komentar script.

ALUR CEPAT:
- Jika user menyebut nama/path script atau module: langsung script_outline + decompile_script (rentang relevan) dalam balasan yang sama.
- Jika tidak: search_code / find_scripts / list_remotes (keyword dari permintaan) -> script_outline -> decompile_script bagian relevan -> inspect_module untuk data/config.
- Gabungkan panggilan yang saling bebas dalam SATU balasan (maks 5 blok) supaya hemat langkah.
- Andalkan analisis script/module (search_code, decompile_script, get_connections, inspect_module) untuk remote dan argumennya. remote_spy OPSIONAL: hanya jika kode tidak cukup (argumen dinamis/obfuscated) dan analisis sudah buntu. Jika dipakai, keyword WAJIB berisi nama remote PERSIS yang sudah terverifikasi ada (list_remotes) dan tercantum di script/module yang dianalisa; nama tebakan/substring ditolak otomatis dan 'all' tidak diizinkan.
- Begitu SEMUA nama kunci (path, remote, tool, properti) sudah terverifikasi dari output tool, tulis script final. Jangan mengumpulkan data berlebihan, tapi jangan menulis script sebelum nama kuncinya terverifikasi.

CEK WAJIB SEBELUM SCRIPT FINAL (sistem juga memeriksa otomatis dan akan mengembalikan script yang bermasalah):
- Sintaks Luau valid (end/then/do seimbang, tidak ada fungsi yang belum didefinisikan).
- Setiap nama yang dipakai di WaitForChild/FindFirstChild dan setiap remote muncul di output tool. Jika ragu, panggil tool lagi, bukan menebak.
- Argumen remote sama dengan kode pemanggil asli atau remote_log, bukan dugaan.
- Tidak ada variabel/fungsi yang dipakai sebelum dibuat; tidak ada `return` di tengah blok.
- Kondisi nil ditangani (objek belum ada, character belum spawn).

POLA UMUM (jangan ditebak):
- Equip item/tool/rod: lihat get_player_status (isi Backpack + tool dipegang) untuk nama tool yang SEBENARNYA. Cari kode equip game dengan search_code ("Equip", "EquipTool", nama tool) dan list_remotes (keyword equip/rod/tool). Jika game memakai remote equip, pakai remote itu dengan argumen dari kode pemanggil (hasil decompile). Jika tidak ada remote, di script cari Tool secara dinamis di Backpack/Character (cocokkan nama dari data) lalu pakai Humanoid:EquipTool(tool). Cek dulu apakah tool sudah dipegang agar tidak equip berulang.
- Auto-loop (farm/fish/dll): jalankan di task.spawn dengan flag getgenv().Running, task.wait di tiap putaran, pcall di tiap aksi, dan hentikan bila character mati.
- Event/GUI game: pakai kode game (decompile_script, get_connections) untuk tahu syarat dan urutan aksi, bukan menebak dari nama.

UJI (test_script) HANYA BILA PERLU - analisis kode diutamakan (jika tool test_script ada di daftar):
- Default: analisis module/script (search_code, decompile_script, get_connections, inspect_module), lalu tulis jawaban final TANPA test_script. Sebutkan bahwa script belum diuji (hanya dari analisis kode).
- Jalankan test_script HANYA bila: (a) user melaporkan error/script tidak jalan/hasil tidak sesuai, atau (b) script bergantung pada hal yang tidak bisa dipastikan dari kode (argumen dinamis, aksi lokal seperti firesignal/fireclickdetector, urutan event).
- Jika user melaporkan masalah: perbaiki, lalu WAJIB uji draft perbaikan yang LENGKAP dengan test_script sebelum membalas.
- Baca hasilnya: RINGKASAN (satu baris), error + baris, remote script beserta argumen, aksi lokal, remote yang dipicu game, perubahan state lokal. Bandingkan remote + argumen dengan kode pemanggil asli; perbaiki bila beda, lalu uji ulang (maks 3 kali).
- Pakai mode block (default): remote script diblokir dan aksi lokal hanya dicatat (tidak dijalankan). Mode live hanya bila perlu membuktikan efek nyata dan aksinya aman/bisa dibalik (maks 10 remote). Remote harus dipanggil dengan bentuk remote:FireServer(...), bukan remote.FireServer(...).
- Jangan menyimpulkan aksi gagal hanya karena "tidak ada remote"; periksa bagian aksi lokal dan perubahan state.
- Jika test_script mengembalikan ERROR karena executor tidak mendukung, kirim jawaban final dan nyatakan script belum teruji.

FORMAT PEMANGGILAN TOOL:
Balas HANYA dengan blok JSON (maks 5 blok per balasan), tanpa teks lain:
```json
{"tool":"nama_tool","args":{"key":"value"}}
```
Hasil kembali sebagai pesan berawalan [TOOL_RESULT nama]. Lanjutkan sampai data cukup, lalu jawab FINAL tanpa blok JSON tool.
PENGECUALIAN test_script: balasannya berisi blok ```json tool (args hanya seconds/mode) DAN blok ```lua berisi script lengkap yang diuji, dalam balasan yang sama.

TOOLS:]]
    for _, name in ipairs(ToolOrder) do
        if (name ~= "eval_lua" and name ~= "test_script") or Config.allowEval then
            local t = Tools[name]
            L[#L + 1] = string.format("- %s %s\n    %s", name, t.args, t.desc)
        end
    end
    L[#L + 1] = [[

GAYA BAHASA (balasan ke user):
- Bahasa Indonesia yang natural dan enak dibaca: tenang, rapi, seperti rekan kerja. Bukan bahasa gaul berlebihan, bukan lebay.
- Singkat dan langsung: jawaban inti di kalimat pertama. Tanpa kalimat pembuka/penutup basa-basi, tanpa mengulang pertanyaan user, tanpa pujian.
- Tanpa emoji, tanpa tanda seru berlebihan, tanpa huruf kapital semua.
- Jangan menceritakan langkah/tool yang kamu pakai kecuali diminta; cukup hasil, kesimpulan, dan apa yang belum terverifikasi.
- Kalimat pendek. Di luar blok script, usahakan maksimal sekitar 6 kalimat. Daftar hanya jika benar-benar membantu.
- Istilah teknis (remote, FireServer, path, toggle) boleh tetap dalam bahasa Inggris.

STANDAR SCRIPT FINAL (Luau):
- Satu blok ```lua berisi script lengkap yang siap tempel. Penjelasan singkat di luar blok (bahasa Indonesia, ringkas).
- Awali dengan komentar: apa yang terverifikasi (path/remote dari tool) dan apa yang diasumsikan.
- Bungkus pemanggilan remote dengan pcall; gunakan task.wait di loop; sediakan toggle/stop (mis. getgenv().Running = false).
- Ambil objek dengan FindFirstChild/WaitForChild (beri timeout), jangan mengandalkan indeks anak.
- Jika memakai fungsi executor opsional, cek dulu `if not fn then ... end`.
- Argumen remote harus sama persis dengan kode pemanggil asli di game (urutan, tipe).
- Setelah script, tulis 2 baris singkat: TERUJI (apa yang terlihat di hasil test_script; tulis "tidak diuji, hanya analisis kode" jika test_script tidak dijalankan) dan BELUM TERUJI (mis. efek di server).
]]
    -- sengaja STATIS (tanpa catatan/dinamis) agar prefix prompt bisa di-cache provider
    return table.concat(L, "\n")
end

-- ========================================================
-- LLM CLIENT
-- ========================================================
local function buildMessages()
    local msgs = { { role = "system", content = buildSystemPrompt() } }
    for _, m in ipairs(State.history) do
        local last = msgs[#msgs]
        if last.role == m.role and last.role ~= "system" then
            last.content = last.content .. "\n\n" .. m.content
        else
            msgs[#msgs + 1] = { role = m.role, content = m.content }
        end
    end
    -- catatan ditaruh di AKHIR (bukan di system prompt) supaya prefix tetap stabil untuk prompt caching
    if #State.notes > 0 then
        local L = { "[CATATAN TERVERIFIKASI - hasil temuan sebelumnya, boleh dipercaya]" }
        for i, n in ipairs(State.notes) do L[#L + 1] = i .. ". " .. n end
        local block = table.concat(L, "\n")
        local last = msgs[#msgs]
        if last.role == "user" then
            last.content = last.content .. "\n\n" .. block
        else
            msgs[#msgs + 1] = { role = "user", content = block }
        end
    end
    return msgs
end

-- pemadatan cerdas: hasil tool lama diringkas jadi header + baris kunci (remote, FireServer, path, LANJUT, error)
local COMPACT_KEYS = { "fireserver", "invokeserver", "onclientevent", "onclientinvoke", "remote", "[lanjut]", "error", "require(" }

local function compactResult(content)
    local out, used, dropped = {}, 0, 0
    for line in (content .. "\n"):gmatch("(.-)\n") do
        local pre = line:sub(1, 3)
        local keep = line:sub(1, 12) == "[TOOL_RESULT" or line:sub(1, 5) == "[INFO" or pre == "== " or pre == "-- "
        if not keep then
            local low = string.lower(line)
            for _, k in ipairs(COMPACT_KEYS) do
                if string.find(low, k, 1, true) then keep = true; break end
            end
        end
        if keep and used < 1400 then
            local l = clip(line, 150)
            out[#out + 1] = l
            used = used + #l + 1
        else
            dropped = dropped + 1
        end
    end
    out[#out + 1] = "...[dipadatkan: " .. dropped .. " baris lama dibuang. Fakta penting ada di CATATAN; panggil ulang tool bila perlu]"
    return table.concat(out, "\n")
end

-- histeresis: padatkan sekali besar agar prefix stabil (cache). Anggaran riwayat mengikuti tpmLimit (1 token ~ 3 char)
local function budgets()
    local lim = Config.tpmLimit or 0
    local B = 150000 -- tanpa batas token buatan: riwayat dibiarkan panjang, router memangkas sendiri bila model menolak konteks
    if lim > 0 then B = math.clamp(math.floor(lim * 0.8), 12000, 90000) end
    return math.floor(B * 0.7), math.floor(B * 0.45), B
end
local function trimHistory()
    local h = State.history
    local TRIM_AT, TRIM_TO, HARD_MAX = budgets()
    local total = 0
    for _, m in ipairs(h) do total = total + #m.content end
    if total > TRIM_AT then
        for i = 1, math.max(0, #h - 6) do
            if total <= TRIM_TO then break end
            local m = h[i]
            if not m.packed and m.role == "user" and #m.content > 1800
                and (m.content:find("^%[TOOL_RESULT") or m.content:find("^%[INFO dari user")) then
                local packed = compactResult(m.content)
                total = total - #m.content + #packed
                m.content = packed
                m.packed = true
            end
        end
    end
    while total > HARD_MAX and #h > 8 do
        local x = table.remove(h, 2)
        local y = table.remove(h, 2)
        total = total - #x.content - (y and #y.content or 0)
    end
end

-- tugas yang sudah selesai tidak dibawa utuh ke tugas berikutnya (hemat token).
-- Dipanggil saat tugas BARU dimulai: hasil tool lama diringkas, script di jawaban final lama dibuang;
-- hanya jawaban final TERAKHIR yang dibiarkan utuh (agar "ubah script tadi" tetap bisa). Catatan (note) tidak disentuh.
local function stripCode(content)
    return (content:gsub("```%a*\r?\n(.-)```", function(code)
        local _, n = code:gsub("\n", "\n")
        return "[script lama +-" .. (n + 1) .. " baris dihapus dari konteks; minta ulang bila perlu]"
    end))
end

local function archiveFinished()
    local h = State.history
    local lastFinal = 0
    for i = #h, 1, -1 do
        if h[i].final then lastFinal = i; break end
    end
    for i = 1, lastFinal - 1 do
        local m = h[i]
        if m.packed then
            -- sudah dipadatkan
        elseif m.role == "assistant" and m.final then
            local c = stripCode(m.content)
            if c ~= m.content then m.content = c; m.packed = true end
        elseif m.role == "user" and #m.content > 600
            and (m.content:find("^%[TOOL_RESULT") or m.content:find("^%[INFO dari user")) then
            m.content = compactResult(m.content)
            m.packed = true
        end
    end
end

local function hdr(resp, name)
    local H = type(resp) == "table" and resp.Headers
    if type(H) ~= "table" then return nil end
    for k, v in pairs(H) do
        if string.lower(tostring(k)) == name then return v end
    end
    return nil
end


-- ========================================================
-- ROUTER (2 provider, circuit breaker, pindah otomatis)
-- ========================================================
-- Alur: pilih provider sehat berprioritas tertinggi (slot 1 lalu 2) -> kirim dengan timeout ->
-- gagal sementara: provider didinginkan (2d, 30d, 60d, 120d) dan request langsung dialihkan ke provider lain ->
-- limit/429: cooldown singkat + pindah -> key/saldo/model bermasalah: provider dimatikan 5 menit ->
-- semua provider cooldown: tunggu yang paling cepat pulih (maks Config.maxWait), tanpa menghentikan agent.
local Router = { state = {}, active = nil }

function Router.hs(id)
    local s = Router.state[id]
    if not s then
        s = { fails = 0, cd = 0, lastFail = nil, fatal = nil, maxCompl = false, noTemp = false }
        Router.state[id] = s
    end
    return s
end

function Router.reset()
    Router.state = {}
    Router.active = nil
end

function Router.list()
    local out = {}
    local defs = {
        { id = 1, url = Config.apiUrl, key = Config.apiKey, model = Config.model },
        { id = 2, url = Config.apiUrl2, key = Config.apiKey2, model = Config.model2 },
    }
    for _, d in ipairs(defs) do
        d.key = trim(d.key or "")
        d.url = trim(d.url or "")
        d.model = trim(d.model or "")
        if d.key ~= "" and d.url ~= "" and d.model ~= "" then out[#out + 1] = d end
    end
    return out
end

function Router.hasKey()
    return #Router.list() > 0
end

function Router.has(low, words)
    for _, w in ipairs(words) do
        if string.find(low, w, 1, true) then return true end
    end
    return false
end

-- cooldown untuk gangguan sementara: gagal ke-1 cuma 2d (kemungkinan kedip), lalu 30d, 60d, 120d
function Router.markFail(id)
    local s = Router.hs(id)
    local now = os.clock()
    if s.lastFail and now - s.lastFail > 600 then s.fails = 0 end
    s.lastFail = now
    s.fails = s.fails + 1
    local base = 120
    if s.fails <= 1 then base = 2 elseif s.fails == 2 then base = 30 elseif s.fails == 3 then base = 60 end
    s.cd = now + base * (1 + (math.random() - 0.5) * 0.4)
end

function Router.markDead(id, msg)
    local s = Router.hs(id)
    s.fatal = msg or "provider tidak bisa dipakai"
    s.cd = os.clock() + 300
end

-- provider pertama yang tidak cooldown; kalau tidak ada: (nil, detik tunggu) atau (nil, nil) bila tak ada yang bisa ditunggu
function Router.pick(provs, hard)
    local now = os.clock()
    local soonest
    for _, p in ipairs(provs) do
        if not hard[p.id] then
            local s = Router.hs(p.id)
            local left = s.cd - now
            if left <= 0 then return p end
            if not s.fatal and (not soonest or left < soonest) then soonest = left end
        end
    end
    return nil, soonest
end

-- request dengan timeout + bisa dibatalkan (executor tidak punya timeout bawaan)
function Router.request(opts, timeout, alive)
    local done, ok, resp = false, false, nil
    task.spawn(function()
        local o, r = pcall(httpRequest, opts)
        ok, resp, done = o, r, true
    end)
    local t0 = os.clock()
    while not done do
        task.wait(0.1)
        if not alive() then return nil, nil, "cancel" end
        if os.clock() - t0 > timeout then return nil, nil, "timeout" end
    end
    return ok, resp, nil
end

-- kelompokkan error: ctx | quota | reject | rate | fatal | transient
function Router.classify(code, body, resp)
    local low = string.lower(tostring(body or ""))
    local has = Router.has
    if has(low, { "context_length", "maximum context", "context window", "prompt is too long", "too many tokens", "reduce the length" }) then
        return "ctx"
    end
    if has(low, { "token_quota_exceeded", "insufficient_credits", "insufficient_quota", "budget_exceeded", "insufficient balance" }) or code == 402 then
        return "quota", "Kuota/saldo habis"
    end
    if has(low, { "prompt_injection", "jailbreak" }) then
        return "reject", "Guardrail provider memblokir isi prompt (ubah mode injection/jailbreak jadi Monitor di dashboard)"
    end
    local ra = tonumber(hdr(resp, "retry-after"))
    if code == 429 then return "rate", nil, ra end
    local limitWords = { "tpl", "tpm", "rpm", "rate limit", "rate_limit" }
    if code == 401 or code == 403 then
        if has(low, limitWords) then return "rate", nil, ra end
        if string.find(low, "pass_band", 1, true) then return "fatal", "Model di luar jatah pass/plan provider ini (ganti model)" end
        return "fatal", "API key salah / tidak berhak (cek Pengaturan)"
    end
    if string.find(low, "limit", 1, true) and has(low, { "tpl", "tpm", "rpm", "token", "plan", "rate" }) then
        return "rate", nil, ra
    end
    if code == 404 then return "fatal", "Endpoint atau model tidak ditemukan (cek Pengaturan)" end
    if code == 0 or code == 408 or code == 425 or code >= 500 or (code >= 200 and code < 300) then
        return "transient"
    end
    return "reject"
end

-- satu percobaan ke satu provider.
-- hasil: "ok",isi,finish | "cancel" | "local",err | "adapt" | kind,err,tunggu
function Router.try(p, messages, alive)
    local s = Router.hs(p.id)
    local payload = { model = p.model, messages = messages }
    if not s.noTemp then payload.temperature = Config.temperature end
    if s.maxCompl then payload.max_completion_tokens = Config.maxTokens else payload.max_tokens = Config.maxTokens end
    local okE, body = pcall(function() return HttpService:JSONEncode(payload) end)
    if not okE then return "local", "Gagal encode request: " .. tostring(body) end

    local ok, resp, why = Router.request({
        Url = p.url,
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. p.key,
        },
        Body = body,
    }, tonumber(Config.timeout) or 150, alive)
    if why == "cancel" then return "cancel" end
    if why == "timeout" then return "transient", "tidak ada respons dalam " .. (tonumber(Config.timeout) or 150) .. " detik" end
    if not ok then return "transient", "Request gagal: " .. tostring(resp) end
    if type(resp) ~= "table" then return "transient", "Respons kosong dari executor" end

    local code = tonumber(resp.StatusCode) or (resp.Success and 200) or 0
    local rb = tostring(resp.Body or "")
    if code >= 200 and code < 300 then
        local okD, data = pcall(function() return HttpService:JSONDecode(rb) end)
        if okD and type(data) == "table" and type(data.choices) == "table" and data.choices[1] and data.choices[1].message then
            local content = data.choices[1].message.content
            if type(content) == "table" then
                local parts = {}
                for _, part in ipairs(content) do
                    if type(part) == "table" and part.text then parts[#parts + 1] = part.text end
                end
                content = table.concat(parts, "\n")
            end
            if type(content) ~= "string" then content = "" end
            return "ok", content, data.choices[1].finish_reason
        end
        local em
        if okD and type(data) == "table" then
            if type(data.error) == "table" then em = data.error.message elseif type(data.error) == "string" then em = data.error end
        end
        local kind, msg, wait = Router.classify(code, rb, resp)
        local err = "Respons tidak valid: " .. clip(em or rb, 300)
        if msg then err = err .. "\n(" .. msg .. ")" end
        return kind, err, wait
    end

    local lowb = string.lower(rb)
    if code == 400 then
        -- model baru (o-series/gpt-5 dll) menolak max_tokens / temperature: sesuaikan lalu kirim ulang
        local fixed = false
        if payload.max_tokens ~= nil and string.find(lowb, "max_completion_tokens", 1, true) then
            s.maxCompl = true
            fixed = true
        end
        if payload.temperature ~= nil and string.find(lowb, "temperature", 1, true) then
            s.noTemp = true
            fixed = true
        end
        if fixed then return "adapt" end
    end
    local kind, msg, wait = Router.classify(code, rb, resp)
    local err = "HTTP " .. code .. ": " .. clip(rb, 300)
    if msg then err = err .. "\n(" .. msg .. ")" end
    return kind, err, wait
end

-- potong riwayat tengah (pesan pertama + 6 terakhir tetap) saat model menolak konteks
function Router.shrink(messages)
    local s = (messages[1] and messages[1].role == "system") and 2 or 1
    local n = #messages - s - 6
    n = n - (n % 2)
    if n < 2 then return nil end
    local out = {}
    for i = 1, #messages do
        if i <= s or i > s + n then out[#out + 1] = messages[i] end
    end
    return out
end

local function callLLM(messages, alive, onWait, onSwitch)
    local provs = Router.list()
    if #provs == 0 then return nil, "API key kosong. Buka Pengaturan lalu isi API Key." end
    local t0 = os.clock()
    local maxWait = tonumber(Config.maxWait) or 480
    local hard, errs, shrinks = {}, {}, 0
    local shown = Router.active

    local function summary()
        local parts = {}
        for _, p in ipairs(provs) do
            local e = errs[p.id] or Router.hs(p.id).fatal
            if e then parts[#parts + 1] = "[" .. p.model .. "] " .. e end
        end
        if #parts == 0 then return "unknown" end
        return table.concat(parts, "\n")
    end
    local function waitSec(n)
        for i = n, 1, -1 do
            if onWait then pcall(onWait, i) end
            task.wait(1)
            if not alive() then return false end
        end
        return true
    end

    while true do
        if not alive() then return nil, "dibatalkan" end
        local p, wsec = Router.pick(provs, hard)
        if not p then
            if not wsec then return nil, summary() end -- semua provider mati/ditolak: tidak ada yang bisa ditunggu
            local w = math.max(1, math.ceil(wsec))
            if os.clock() - t0 + w > maxWait then
                return nil, summary() .. "\n(Semua provider masih bermasalah setelah " .. math.floor(maxWait / 60) .. " menit; coba lagi nanti)"
            end
            if not waitSec(w) then return nil, "dibatalkan" end
        else
            if shown ~= nil and shown ~= p.id and onSwitch then pcall(onSwitch, p) end
            shown = p.id
            local kind, a, b = Router.try(p, messages, alive)
            local s = Router.hs(p.id)
            if kind == "ok" then
                s.fails = 0
                s.cd = 0
                s.fatal = nil
                Router.active = p.id
                return a, b
            elseif kind == "cancel" then
                return nil, "dibatalkan"
            elseif kind == "local" then
                return nil, a
            elseif kind == "adapt" then
                -- parameter payload sudah disesuaikan untuk provider ini; kirim ulang segera
            elseif kind == "ctx" then
                shrinks = shrinks + 1
                local nm = shrinks <= 4 and Router.shrink(messages) or nil
                if nm then
                    messages = nm
                else
                    hard[p.id] = true
                    errs[p.id] = "Konteks terlalu panjang untuk model ini"
                end
            elseif kind == "rate" then
                errs[p.id] = a
                s.cd = os.clock() + math.clamp(b and (math.ceil(b) + 1) or 20, 1, 90)
            elseif kind == "quota" or kind == "fatal" then
                errs[p.id] = a
                hard[p.id] = true
                Router.markDead(p.id, a)
            elseif kind == "reject" then
                errs[p.id] = a
                hard[p.id] = true
                s.cd = os.clock() + 15
            else -- transient
                errs[p.id] = a
                Router.markFail(p.id)
            end
        end
    end
end

-- ambil semua {"tool":...} dari balasan + teks sisa
local function extractToolCalls(text)
    local calls, spans = {}, {}
    local pos = 1
    while true do
        local s, e = text:find("%b{}", pos)
        if not s then break end
        local chunk = text:sub(s, e)
        local ok, data = false, nil
        if chunk:find('"tool"', 1, true) then
            ok, data = pcall(function() return HttpService:JSONDecode(chunk) end)
        end
        if ok and type(data) == "table" and type(data.tool) == "string" then
            calls[#calls + 1] = data
            spans[#spans + 1] = { s, e }
            pos = e + 1
        else
            pos = s + 1
        end
    end
    local rest = text
    for i = #spans, 1, -1 do
        rest = rest:sub(1, spans[i][1] - 1) .. rest:sub(spans[i][2] + 1)
    end
    rest = rest:gsub("```%a*%s*```", "")
    return calls, trim(rest)
end


-- UI dibungkus fungsi sendiri: batas Luau 200 variabel local per fungsi
local function buildDeoxysUI()
-- ========================================================
-- UI  (v9: modern, ikon vektor, animasi halus, teks ringkas)
-- ========================================================
local TweenService = game:GetService("TweenService")
local touch = UserInputService.TouchEnabled
local Conns = {}
local function track(c) Conns[#Conns + 1] = c; return c end

-- ---------- pengaturan ikon ----------
-- Ikon diambil dari paket Lucide lewat library komunitas (butuh HTTP + loadstring).
-- Jika gagal dimuat, UI memakai ikon gambar-sendiri (tanpa emoji) sebagai cadangan.
-- Matikan pemuatan remote dengan USE_REMOTE_ICONS = false.
local USE_REMOTE_ICONS = true
local ICON_LIB_URLS = {
    "https://raw.githubusercontent.com/Footagesus/Icons/main/Main-v2.lua",
    "https://raw.githubusercontent.com/Footagesus/Icons/main/Main.lua",
}
-- Opsional: ganti ikon tertentu dengan asset ID milik sendiri, mis. send = "rbxassetid://123456"
local ICON_OVERRIDE = {}

local ICON_NAMES = {
    logo = { "zap" }, settings = { "settings", "cog" }, trash = { "trash-2", "trash" }, minus = { "minus" },
    close = { "x" }, send = { "send", "arrow-up" }, stop = { "square" }, copy = { "copy", "clipboard" },
    play = { "play" }, check = { "check" }, ok = { "circle-check", "check-circle", "check" },
    fail = { "circle-x", "x-circle", "x" }, alert = { "triangle-alert", "alert-triangle", "circle-alert" },
    map = { "map", "compass" }, radar = { "radio", "activity" }, list = { "clipboard-list", "list" },
    user = { "user" }, note = { "notebook-pen", "sticky-note", "file-text" }, bot = { "bot", "sparkles" },
    chevron = { "chevron-down" }, expand = { "chevrons-up-down", "maximize-2" }, tool = { "wrench" },
    key = { "key-round", "key" }, loader = { "loader-circle", "loader-2", "loader" }, down = { "arrow-down", "chevron-down" },
    cpu = { "cpu" }, link = { "link" }, hash = { "hash" }, gauge = { "gauge" },
}

local IconLib = GENV.__DeoxysIconLib
if IconLib == nil then IconLib = GENV.__AnomanIconLib end
if IconLib == nil then
    IconLib = false
    if USE_REMOTE_ICONS and httpRequest and loadstring then
        for _, url in ipairs(ICON_LIB_URLS) do
            local ok, res = pcall(httpRequest, { Url = url, Method = "GET" })
            local body = ok and type(res) == "table" and res.Body
            if type(body) == "string" and #body > 200 and not body:find("^%s*<") then
                local f = loadstring(body)
                if f then
                    local ok2, lib = pcall(f)
                    if ok2 and type(lib) == "table" then
                        IconLib = lib
                        pcall(function()
                            if type(lib.SetIconsType) == "function" then lib.SetIconsType("lucide") end
                        end)
                        break
                    end
                end
            end
        end
    end
    GENV.__DeoxysIconLib = IconLib
end

local iconCache = {}
local function lucideData(luName)
    if not IconLib then return nil end
    local ok, a, b = pcall(function()
        if type(IconLib.Icon) == "function" then return IconLib.Icon(luName) end
        if type(IconLib.GetIcon) == "function" then return IconLib.GetIcon(luName) end
        return nil
    end)
    if not ok or a == nil then return nil end
    local img, rs, rp
    if type(a) == "table" then
        local rect = (type(a[2]) == "table") and a[2] or a
        img = a[1] or a.Image or a.image
        rs = rect.ImageRectSize or rect.RectSize
        rp = rect.ImageRectPosition or rect.ImageRectOffset
    else
        img = a
        if type(b) == "table" then
            rs = b.ImageRectSize
            rp = b.ImageRectPosition or b.ImageRectOffset
        end
    end
    if img == nil then return nil end
    if type(img) == "number" then img = "rbxassetid://" .. img end
    if type(img) ~= "string" then return nil end
    return { image = img, size = rs, pos = rp }
end

local function resolveIcon(name)
    if iconCache[name] ~= nil then return iconCache[name] or nil end
    local found = false
    if ICON_OVERRIDE[name] then
        found = { image = ICON_OVERRIDE[name] }
    else
        for _, luName in ipairs(ICON_NAMES[name] or { name }) do
            local d = lucideData(luName)
            if d then found = d; break end
        end
    end
    iconCache[name] = found
    return found or nil
end

-- ---------- tema ----------
local C = {
    bg = Color3.fromRGB(12, 13, 20), surface = Color3.fromRGB(19, 21, 31), surface2 = Color3.fromRGB(27, 29, 43),
    surface3 = Color3.fromRGB(40, 43, 62), line = Color3.fromRGB(255, 255, 255), text = Color3.fromRGB(236, 238, 248),
    muted = Color3.fromRGB(128, 135, 162), accent = Color3.fromRGB(124, 108, 255), accent2 = Color3.fromRGB(70, 150, 255),
    ok = Color3.fromRGB(52, 211, 153), err = Color3.fromRGB(248, 113, 113), warn = Color3.fromRGB(251, 191, 36),
    code = Color3.fromRGB(10, 11, 17), codeBar = Color3.fromRGB(21, 23, 34), codeText = Color3.fromRGB(208, 216, 242),
    white = Color3.new(1, 1, 1),
}
local Y = Enum.AutomaticSize.Y
local F = {
    reg = Enum.Font.Gotham, med = Enum.Font.GothamMedium, semi = Enum.Font.GothamSemibold,
    bold = Enum.Font.GothamBold, code = Enum.Font.Code,
}

local FontCfg = { face = nil, code = nil }   -- font kustom (opsional); dipakai oleh new() di bawah

-- ---------- FONT KUSTOM (opsional) ----------
-- Taruh file font (.ttf / .otf) di folder workspace executor dengan nama persis di bawah.
-- Urutan: FONT_ID (asset Roblox) -> file lokal FONT_FILE -> font bawaan tabel F.
-- Kalau file belum ada dan FONT_URL diisi (link langsung ke file), font diunduh sekali.
-- Gagal dimuat / executor tidak mendukung -> otomatis pakai font bawaan di tabel F.
local FONT_ENABLED = true
local FONT_FILE = ""
local FONT_URL = ""
local FONT_ID = 12187369639   -- asset ID Font Family dari Creator Store (angka di link). 0 = tidak dipakai. Diprioritaskan sebelum file lokal.
if FONT_ENABLED and FONT_ID ~= 0 then
    local okId, face = pcall(function() return Font.fromId(FONT_ID) end)
    if okId and face then
        FontCfg.face = face
        FontCfg.code = F.code
    end
end
if FONT_ENABLED and not FontCfg.face then
    local ok = pcall(function()
        if not (isfile and writefile and getcustomasset) then error("executor tanpa getcustomasset") end
        if not isfile(FONT_FILE) then
            if FONT_URL == "" or not httpRequest then error("file font tidak ditemukan") end
            local r = httpRequest({ Url = FONT_URL, Method = "GET" })
            if not (r and type(r.Body) == "string" and #r.Body > 1000) then error("unduhan gagal") end
            writefile(FONT_FILE, r.Body)
        end
        writefile("DeoxysFont.json", HttpService:JSONEncode({
            name = "DeoxysFont",
            faces = { { name = "Medium", weight = 500, style = "normal", assetId = getcustomasset(FONT_FILE) } },
        }))
        FontCfg.face = Font.new(getcustomasset("DeoxysFont.json"))
        FontCfg.code = F.code
    end)
    if not ok then FontCfg.face = nil end
end
local QUINT, BACK, QUAD, SINE, LINEAR = Enum.EasingStyle.Quint, Enum.EasingStyle.Back, Enum.EasingStyle.Quad, Enum.EasingStyle.Sine, Enum.EasingStyle.Linear
local OUT, IN, INOUT = Enum.EasingDirection.Out, Enum.EasingDirection.In, Enum.EasingDirection.InOut

-- ---------- ENGINE ANIMASI: SPRING (gaya library Spr/Flipper) ----------
-- Satu koneksi Heartbeat menggerakkan semua spring. Solusi analitik (stabil di FPS berapa pun),
-- kecepatan dipertahankan saat target berubah di tengah animasi -> gerakan selalu mulus & bisa diinterupsi.
-- Mendukung: number, UDim, UDim2, Vector2, Color3. API lama tw(obj, props, durasi, style, dir) tetap sama.
local Spring = {}
do
    local active = {}   -- [obj] = { [prop] = state }
    local conn
    local sqrt, exp, cos, sin, abs = math.sqrt, math.exp, math.cos, math.sin, math.abs

    local function pack(v)
        local t = typeof(v)
        if t == "number" then return { v }, "n"
        elseif t == "UDim2" then return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset }, "u2"
        elseif t == "UDim" then return { v.Scale, v.Offset }, "u1"
        elseif t == "Vector2" then return { v.X, v.Y }, "v2"
        elseif t == "Color3" then return { v.R, v.G, v.B }, "c3" end
        return nil
    end
    local function unpack_(a, k)
        if k == "n" then return a[1]
        elseif k == "u2" then return UDim2.new(a[1], a[2], a[3], a[4])
        elseif k == "u1" then return UDim.new(a[1], a[2])
        elseif k == "v2" then return Vector2.new(a[1], a[2])
        else return Color3.new(math.clamp(a[1], 0, 1), math.clamp(a[2], 0, 1), math.clamp(a[3], 0, 1)) end
    end

    Spring.pack, Spring.unpack = pack, unpack_

    local function finish(st, state)
        if st.done then return end
        st.done = true
        local cbs = st.cbs
        st.cbs = {}
        for _, f in ipairs(cbs) do task.defer(f, state) end
    end

    local function step(dt)
        if dt > 0.05 then dt = 0.05 end
        local any = false
        for obj, props in pairs(active) do
            local alive = obj.Parent ~= nil
            for prop, st in pairs(props) do
                if not alive then
                    props[prop] = nil
                    finish(st, Enum.PlaybackState.Cancelled)
                else
                    local w, z = st.w, st.z
                    local settled = true
                    for i = 1, #st.x do
                        local d = st.x[i] - st.g[i]
                        local v = st.v[i]
                        local nd, nv
                        if z >= 1 then
                            local e = exp(-w * dt)
                            local c = v + w * d
                            nd = (d + c * dt) * e
                            nv = (v - c * w * dt) * e
                        else
                            local wd = w * sqrt(1 - z * z)
                            local e = exp(-z * w * dt)
                            local c, s2 = cos(wd * dt), sin(wd * dt)
                            nd = e * (d * c + ((v + z * w * d) / wd) * s2)
                            nv = e * (v * c - ((z * w * v + w * w * d) / wd) * s2)
                        end
                        st.x[i] = st.g[i] + nd
                        st.v[i] = nv
                        if abs(nd) > st.eps or abs(nv) > st.eps * 8 then settled = false end
                    end
                    if settled then
                        for i = 1, #st.x do st.x[i] = st.g[i]; st.v[i] = 0 end
                    end
                    pcall(function() obj[prop] = unpack_(st.x, st.k) end)
                    if settled then
                        props[prop] = nil
                        finish(st, Enum.PlaybackState.Completed)
                    else
                        any = true
                    end
                end
            end
            if next(props) == nil then active[obj] = nil end
        end
        if not any and conn then conn:Disconnect(); conn = nil end
    end

    -- zeta: <1 memantul (overshoot), 1 = halus tanpa pantulan. dur: perkiraan waktu hingga tenang.
    function Spring.to(obj, props, dur, zeta)
        dur = math.max(dur or 0.3, 0.05)
        zeta = zeta or 1
        local w = 6.5 / (zeta * dur)
        local handle = { cbs = {}, done = false, sts = {} }
        local n = 0
        for prop, goal in pairs(props) do
            local g, k = pack(goal)
            local cur = g and pack(obj[prop])
            if not g or not cur then
                pcall(function() obj[prop] = goal end) -- tipe tak didukung: set langsung
            else
                active[obj] = active[obj] or {}
                local prev = active[obj][prop]
                local vel = {}
                for i = 1, #g do vel[i] = (prev and prev.k == k and prev.v[i]) or 0 end
                if prev then finish(prev, Enum.PlaybackState.Cancelled) end
                local eps = (k == "c3") and 0.002 or 0.04
                if k == "n" and (prop:find("Transparency") or prop == "Scale") then eps = 0.002 end
                local st = { x = cur, g = g, v = vel, w = w, z = zeta, k = k, eps = eps, cbs = {}, done = false }
                active[obj][prop] = st
                handle.sts[#handle.sts + 1] = st
                n = n + 1
            end
        end
        if n == 0 then
            handle.done = true
            task.defer(function() for _, f in ipairs(handle.cbs) do f(Enum.PlaybackState.Completed) end end)
        else
            -- handle selesai bila semua state-nya selesai (Completed hanya bila tidak ada yang dibatalkan)
            local remaining, cancelled = n, false
            for _, st in ipairs(handle.sts) do
                st.cbs[1] = function(state)
                    if state ~= Enum.PlaybackState.Completed then cancelled = true end
                    remaining = remaining - 1
                    if remaining == 0 then
                        handle.done = true
                        local res = cancelled and Enum.PlaybackState.Cancelled or Enum.PlaybackState.Completed
                        for _, f in ipairs(handle.cbs) do task.spawn(f, res) end
                    end
                end
            end
            if not conn then conn = RunService.Heartbeat:Connect(step) end
        end
        handle.Completed = { Connect = function(_, f)
            if handle.done then task.defer(f, Enum.PlaybackState.Completed) else handle.cbs[#handle.cbs + 1] = f end
            return { Disconnect = function() end }
        end }
        function handle:Cancel()
            for prop in pairs(props) do
                local p = active[obj] and active[obj][prop]
                if p then active[obj][prop] = nil; finish(p, Enum.PlaybackState.Cancelled) end
            end
        end
        return handle
    end
end

-- ---------- FLIPPER (library pihak ketiga, dimuat lewat HTTP + loadstring) ----------
-- Sumber: https://github.com/Reselim/Flipper (MIT), salinan satu-file di bawah.
-- Jika gagal dimuat, otomatis memakai engine spring internal di atas. Matikan dengan USE_FLIPPER = false.
local USE_FLIPPER = true
local FLIPPER_URLS = {
    "https://raw.githubusercontent.com/8sfr/luau-libs/refs/heads/main/Flipper.luau",
}
local FlipperLib
if USE_FLIPPER then
    for _, url in ipairs(FLIPPER_URLS) do
        local ok, lib = pcall(function()
            local body
            if httpRequest then
                local r = httpRequest({ Url = url, Method = "GET" })
                body = r and r.Body
            elseif game.HttpGet then
                body = game:HttpGet(url)
            end
            if type(body) ~= "string" or #body < 500 then error("unduhan gagal") end
            local fn = loadstring(body)
            if not fn then error("loadstring gagal") end
            return fn()
        end)
        if ok and type(lib) == "table" and lib.GroupMotor and lib.Spring then
            FlipperLib = lib
            break
        end
    end
end

local Flip = {}
if FlipperLib then
    local pack, unpack_ = Spring.pack, Spring.unpack
    local cache = setmetatable({}, { __mode = "k" }) -- [obj][prop] = { motor, k, n, cb }
    local Completed, Cancelled = Enum.PlaybackState.Completed, Enum.PlaybackState.Cancelled

    function Flip.to(obj, props, dur, zeta)
        dur = math.max(dur or 0.3, 0.05)
        zeta = zeta or 1
        local freq = 6.5 / (zeta * dur) / (2 * math.pi)
        local handle = { cbs = {}, done = false }
        local entries = cache[obj]
        if not entries then entries = {}; cache[obj] = entries end

        local remaining, cancelled = 0, false
        local function part(state)
            if state ~= Completed then cancelled = true end
            remaining = remaining - 1
            if remaining == 0 then
                handle.done = true
                local res = cancelled and Cancelled or Completed
                for _, f in ipairs(handle.cbs) do task.spawn(f, res) end
            end
        end

        local used = {}
        for prop, goal in pairs(props) do
            local g, k = pack(goal)
            local cur = g and pack(obj[prop])
            if not g or not cur then
                pcall(function() obj[prop] = goal end)
            else
                local e = entries[prop]
                if e and e.k ~= k then
                    e.motor:stop()
                    if e.cb then task.defer(e.cb, Cancelled); e.cb = nil end
                    e = nil
                end
                if e then
                    -- retarget: motor lama dipakai ulang -> kecepatan terakhir dipertahankan (gerakan tetap mulus)
                    if e.cb then task.defer(e.cb, Cancelled) end
                else
                    local init = {}
                    for i = 1, #cur do init[i] = cur[i] end
                    local motor = FlipperLib.GroupMotor.new(init, true)
                    e = { motor = motor, k = k, n = #cur }
                    local ent = e
                    motor:onStep(function(vals)
                        if obj.Parent == nil then
                            motor:stop()
                            entries[prop] = nil
                            if ent.cb then task.defer(ent.cb, Cancelled); ent.cb = nil end
                            return
                        end
                        local a = {}
                        for i = 1, ent.n do a[i] = vals[i] end
                        pcall(function() obj[prop] = unpack_(a, ent.k) end)
                    end)
                    motor:onComplete(function()
                        local cb = ent.cb
                        ent.cb = nil
                        if cb then task.defer(cb, Completed) end
                    end)
                    entries[prop] = e
                end
                e.cb = part
                remaining = remaining + 1
                used[#used + 1] = e
                local goals = {}
                for i = 1, #g do
                    goals[i] = FlipperLib.Spring.new(g[i], { frequency = freq, dampingRatio = zeta })
                end
                e.motor:setGoal(goals)
            end
        end

        if remaining == 0 then
            handle.done = true
            task.defer(function() for _, f in ipairs(handle.cbs) do f(Completed) end end)
        end
        handle.Completed = { Connect = function(_, f)
            if handle.done then task.defer(f, Completed) else handle.cbs[#handle.cbs + 1] = f end
            return { Disconnect = function() end }
        end }
        function handle:Cancel()
            for _, e in ipairs(used) do
                if e.cb == part then
                    e.motor:stop()
                    local cb = e.cb
                    e.cb = nil
                    task.defer(cb, Cancelled)
                end
            end
        end
        return handle
    end
end

-- tw(): API lama dipertahankan. Memakai Flipper bila berhasil dimuat, jika tidak memakai spring internal.
-- BACK -> spring memantul halus; lainnya -> critically damped (tanpa pantulan). Durasi = perkiraan waktu tenang.
local function tw(o, props, t, style, dir)
    t = t or 0.2
    local zeta = 1
    if type(style) == "number" then zeta = style elseif style == BACK then zeta = 0.62 end
    if dir == IN then t = t * 0.9 end -- animasi keluar sedikit lebih cepat
    if FlipperLib then return Flip.to(o, props, t, zeta) end
    return Spring.to(o, props, t, zeta)
end

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if FontCfg.face and props.Font and props.Font ~= FontCfg.code then
        pcall(function() o.FontFace = FontCfg.face end)
    end
    if parent then o.Parent = parent end
    return o
end
local function corner(p, r) return new("UICorner", { CornerRadius = UDim.new(0, r) }, p) end
local function stroke(p, col, th, tr)
    return new("UIStroke", { Color = col, Thickness = th or 1, Transparency = tr or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, p)
end
local function pad(p, l, t, r, b)
    return new("UIPadding", { PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b) }, p)
end
local function vlist(p, gap)
    return new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap or 0) }, p)
end
local function hlist(p, gap, halign)
    return new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap or 0),
        VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = halign or Enum.HorizontalAlignment.Left,
    }, p)
end
local function grad(p, c1, c2, rot)
    return new("UIGradient", { Color = ColorSequence.new(c1, c2), Rotation = rot or 0 }, p)
end

-- ---------- ikon ----------
local function fbBar(o, len, cx, cy, rot, th)
    local f = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(cx, cy), Size = UDim2.fromScale(len, th or 0.13),
        Rotation = rot or 0, BorderSizePixel = 0, BackgroundColor3 = o.color,
    }, o.holder)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
    o.parts[#o.parts + 1] = { inst = f, kind = "bg" }
end
local function fbRing(o, scale, filled)
    local f = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(scale, scale),
        BackgroundColor3 = o.color, BackgroundTransparency = filled and 0 or 1, BorderSizePixel = 0,
    }, o.holder)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, f)
    if filled then
        o.parts[#o.parts + 1] = { inst = f, kind = "bg" }
    else
        local s = new("UIStroke", { Color = o.color, Thickness = 1.6 }, f)
        o.parts[#o.parts + 1] = { inst = s, kind = "stroke" }
    end
end
local function fbSquare(o, scale)
    local f = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(scale, scale),
        BackgroundColor3 = o.color, BorderSizePixel = 0,
    }, o.holder)
    new("UICorner", { CornerRadius = UDim.new(0.2, 0) }, f)
    o.parts[#o.parts + 1] = { inst = f, kind = "bg" }
end

local function drawFallback(o, name)
    if name == "close" then
        fbBar(o, 0.78, 0.5, 0.5, 45); fbBar(o, 0.78, 0.5, 0.5, -45)
    elseif name == "minus" then
        fbBar(o, 0.7, 0.5, 0.5, 0)
    elseif name == "check" or name == "ok" then
        fbBar(o, 0.34, 0.37, 0.58, 45); fbBar(o, 0.66, 0.6, 0.48, -45)
    elseif name == "chevron" or name == "down" then
        fbBar(o, 0.42, 0.36, 0.46, 45); fbBar(o, 0.42, 0.64, 0.46, -45)
    elseif name == "stop" then
        fbSquare(o, 0.5)
    elseif name == "send" then
        fbBar(o, 0.7, 0.5, 0.52, 90); fbBar(o, 0.42, 0.36, 0.3, -45); fbBar(o, 0.42, 0.64, 0.3, 45)
    elseif name == "play" then
        fbBar(o, 0.5, 0.42, 0.5, 90, 0.2); fbBar(o, 0.5, 0.56, 0.5, 90, 0.12); fbBar(o, 0.3, 0.68, 0.5, 90, 0.08)
    elseif name == "fail" then
        fbRing(o, 0.8, false); fbBar(o, 0.4, 0.5, 0.5, 45); fbBar(o, 0.4, 0.5, 0.5, -45)
    elseif name == "alert" then
        fbRing(o, 0.8, false); fbBar(o, 0.32, 0.5, 0.42, 90, 0.12); fbRing(o, 0.12, true)
    elseif name == "loader" then
        fbRing(o, 0.78, false)
        fbRing(o, 0.2, true)
    else
        fbRing(o, 0.78, false)
        fbRing(o, 0.22, true)
    end
end

local function mkIcon(parent, name, size, color)
    local o = { name = name, color = color or C.text, parts = {} }
    o.holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size), BorderSizePixel = 0 }, parent)
    function o.paint(c)
        o.color = c
        for _, p in ipairs(o.parts) do
            if p.kind == "stroke" then p.inst.Color = c
            elseif p.kind == "image" then p.inst.ImageColor3 = c
            else p.inst.BackgroundColor3 = c end
        end
    end
    function o.tint(c, t)
        o.color = c
        for _, p in ipairs(o.parts) do
            if p.kind == "stroke" then tw(p.inst, { Color = c }, t or 0.2)
            elseif p.kind == "image" then tw(p.inst, { ImageColor3 = c }, t or 0.2)
            else tw(p.inst, { BackgroundColor3 = c }, t or 0.2) end
        end
    end
    function o.set(n)
        o.name = n
        for _, ch in ipairs(o.holder:GetChildren()) do ch:Destroy() end
        o.parts = {}
        local d = resolveIcon(n)
        if d then
            local img = new("ImageLabel", {
                BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Image = d.image, ImageColor3 = o.color,
                ScaleType = Enum.ScaleType.Fit, BorderSizePixel = 0,
            }, o.holder)
            if d.size then img.ImageRectSize = d.size end
            if d.pos then img.ImageRectOffset = d.pos end
            o.parts[1] = { inst = img, kind = "image" }
        else
            drawFallback(o, n)
        end
    end
    o.set(name)
    return o
end
local function center(o)
    o.holder.AnchorPoint = Vector2.new(0.5, 0.5)
    o.holder.Position = UDim2.fromScale(0.5, 0.5)
    return o
end

-- ---------- interaksi (hover + tekan) ----------
local function interactive(btn, prop, normal, hover, pressScale)
    local st = { normal = normal, hover = hover }
    local sc = new("UIScale", { Scale = 1 }, btn)
    st.scale = sc
    track(btn.MouseEnter:Connect(function()
        if prop and st.hover ~= nil then tw(btn, { [prop] = st.hover }, 0.15) end
    end))
    track(btn.MouseLeave:Connect(function()
        if prop and st.normal ~= nil then tw(btn, { [prop] = st.normal }, 0.2) end
        tw(sc, { Scale = 1 }, 0.2)
    end))
    track(btn.MouseButton1Down:Connect(function() tw(sc, { Scale = pressScale or 0.93 }, 0.09) end))
    track(btn.MouseButton1Up:Connect(function() tw(sc, { Scale = 1 }, 0.3, BACK) end))
    return st
end

-- fade-in untuk satu pesan (menganimasikan semua turunannya)
local function fadeIn(root, t)
    local objs = root:GetDescendants()
    if #objs > 160 then return end
    objs[#objs + 1] = root
    local info = TweenInfo.new(t or 0.4, QUAD, OUT)
    for _, o in ipairs(objs) do
        local goal = {}
        if o:IsA("GuiObject") then
            if o.BackgroundTransparency < 1 then goal.BackgroundTransparency = o.BackgroundTransparency; o.BackgroundTransparency = 1 end
            if o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox") then
                if o.TextTransparency < 1 then goal.TextTransparency = o.TextTransparency; o.TextTransparency = 1 end
            elseif o:IsA("ImageLabel") or o:IsA("ImageButton") then
                if o.ImageTransparency < 1 then goal.ImageTransparency = o.ImageTransparency; o.ImageTransparency = 1 end
            end
        elseif o:IsA("UIStroke") then
            goal.Transparency = o.Transparency
            o.Transparency = 1
        end
        if next(goal) then Spring.to(o, goal, t or 0.4, 1) end
    end
end

-- ---------- ScreenGui ----------
local okP, guiParent = pcall(function() return (gethui and gethui()) or CoreGui end)
if not okP or not guiParent then guiParent = LocalPlayer:WaitForChild("PlayerGui") end
for _, g in ipairs(guiParent:GetChildren()) do
    if g.Name == "DeoxysAgentUI" or g.Name == "AnomanAgentUI" or g.Name == "AIScriptAssistantPro" then g:Destroy() end
end

local ScreenGui = new("ScreenGui", { Name = "DeoxysAgentUI", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999 })
pcall(function() ScreenGui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets end)
ScreenGui.Parent = guiParent

local function vp()
    local a = ScreenGui.AbsoluteSize
    if a.X < 50 or a.Y < 50 then
        local cam = Workspace.CurrentCamera
        return cam and cam.ViewportSize or Vector2.new(800, 600)
    end
    return a
end
do
    local t0 = os.clock()
    while ScreenGui.AbsoluteSize.X < 50 and os.clock() - t0 < 1 do task.wait() end
end

local V0 = vp()
local FS = (V0.Y < 420 or V0.X < 380) and 11 or 12   -- ukuran teks dasar
local function fs(d) return math.max(9, FS + d) end    -- turunan, minimal 9 agar tetap terbaca
local HH = touch and 46 or 42                -- tinggi header
local BTN = touch and 30 or 28               -- tombol header
local IH = touch and 40 or 36                -- tinggi input
local PAD = 10
local STRIP = touch and 18 or 14             -- area grip resize
local STAT_H = 24

-- ---------- Window ----------
local Window = new("Frame", { Name = "Window", BackgroundColor3 = C.bg, BorderSizePixel = 0, Active = true, ClipsDescendants = true }, ScreenGui)
corner(Window, 18)
local WinStroke = stroke(Window, C.accent, 1.2, 0.78)
grad(Window, C.white, Color3.fromRGB(206, 208, 226), 90)
local WinScale = new("UIScale", { Scale = 0.96 }, Window)

local function fitSize(v)
    return math.min(v.X - 8, math.clamp(v.X * 0.90, 280, 440)), math.min(v.Y - 8, math.clamp(v.Y * 0.76, 240, 600))
end
local function clampXY(x, y, w, h)
    local v = vp()
    return math.clamp(x, 0, math.max(0, v.X - w)), math.clamp(y, 0, math.max(0, v.Y - h))
end
local homePos
do
    local w, h = fitSize(V0)
    Window.Size = UDim2.fromOffset(w, h)
    homePos = UDim2.fromOffset((V0.X - w) / 2, (V0.Y - h) / 2)
    Window.Position = UDim2.new(homePos.X.Scale, homePos.X.Offset, 0, homePos.Y.Offset + 22)
end
local userSized = false
local function refit()
    local v = vp()
    local w, h
    if userSized then
        w, h = math.min(Window.Size.X.Offset, v.X - 8), math.min(Window.Size.Y.Offset, v.Y - 8)
    else
        w, h = fitSize(v)
    end
    Window.Size = UDim2.fromOffset(w, h)
    local x, y = clampXY(Window.Position.X.Offset, Window.Position.Y.Offset, w, h)
    Window.Position = UDim2.fromOffset(x, y)
end
track(ScreenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit))

-- ---------- Header ----------
local Header = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, HH), Active = true }, Window)
new("Frame", { BackgroundColor3 = C.line, BackgroundTransparency = 0.93, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, HH), Size = UDim2.new(1, 0, 0, 1) }, Window)

local LOGO = HH - 18
local Logo = new("Frame", { BackgroundColor3 = C.white, Size = UDim2.fromOffset(LOGO, LOGO), Position = UDim2.new(0, 14, 0.5, -LOGO / 2), BorderSizePixel = 0 }, Header)
corner(Logo, 10)
grad(Logo, C.accent, C.accent2, 35)
center(mkIcon(Logo, "logo", math.floor(LOGO * 0.56), C.white)).holder.Parent = Logo

local BTN_W = 4 * BTN + 3 * 2
local TX = 14 + LOGO + 10
local Titles = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, TX, 0, 0), Size = UDim2.new(1, -(TX + BTN_W + 14), 1, 0) }, Header)
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 1) }, Titles)
new("TextLabel", {
    BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, FS + 5), Text = "Deoxys", TextColor3 = C.text, Font = F.bold,
    TextSize = FS + 3, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1,
}, Titles)
local SubRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, FS), LayoutOrder = 2 }, Titles)
local Dot = new("Frame", { BackgroundColor3 = C.ok, Size = UDim2.fromOffset(7, 7), Position = UDim2.new(0, 0, 0.5, -3.5), BorderSizePixel = 0 }, SubRow)
corner(Dot, 4)
local SubLbl = new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, 13, 0, 0), Size = UDim2.new(1, -13, 1, 0), Text = "", TextColor3 = C.muted,
    Font = F.reg, TextSize = fs(-2), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
}, SubRow)

local BtnHolder = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(BTN_W, BTN) }, Header)
hlist(BtnHolder, 2, Enum.HorizontalAlignment.Right)
local function hdrBtn(iconName, order, color)
    local b = new("TextButton", {
        BackgroundColor3 = C.surface3, BackgroundTransparency = 1, Size = UDim2.fromOffset(BTN, BTN), Text = "",
        AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = order,
    }, BtnHolder)
    corner(b, 10)
    local ic = center(mkIcon(b, iconName, touch and 16 or 15, color or C.muted))
    ic.rest = color or C.muted
    local st = interactive(b, "BackgroundTransparency", 1, 0.35)
    b.MouseEnter:Connect(function() ic.tint(C.text, 0.15) end)
    b.MouseLeave:Connect(function() ic.tint(ic.rest, 0.2) end)
    return b, ic, st
end
local SetBtn, SetIcon = hdrBtn("settings", 1)
local ClearBtn, ClearIcon, ClearSt = hdrBtn("trash", 2)
local MinBtn = hdrBtn("minus", 3)
local CloseBtn = hdrBtn("close", 4)

-- status header: titik + teks model
local statusBusy = false
local function refreshSub()
    local hasKey = Router.hasKey()
    local shownModel = Config.model
    local plist = Router.list()
    if #plist > 0 then
        shownModel = plist[1].model
        for _, pp in ipairs(plist) do
            if pp.id == Router.active then shownModel = pp.model end
        end
        if #plist > 1 then shownModel = shownModel .. "  +1" end
    end
    SubLbl.Text = hasKey and shownModel or "API key belum diisi"
    SubLbl.TextColor3 = hasKey and C.muted or C.warn
    local col = statusBusy and C.warn or (hasKey and C.ok or C.warn)
    tw(Dot, { BackgroundColor3 = col }, 0.3)
end

-- ---------- Chat area ----------
local ChatScroll = new("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.new(0, PAD, 0, HH + 8), Size = UDim2.new(1, -2 * PAD, 1, -(HH + 120)),
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Y, ScrollBarThickness = touch and 3 or 4,
    ScrollBarImageColor3 = C.muted, ScrollBarImageTransparency = 0.4, ScrollingDirection = Enum.ScrollingDirection.Y,
    ElasticBehavior = Enum.ElasticBehavior.Never,
}, Window)
vlist(ChatScroll, 10)
pad(ChatScroll, 0, 4, 4, 10)

-- ---------- Bottom (status + chips + input) ----------
local Bottom = new("Frame", {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, PAD, 1, -STRIP),
    Size = UDim2.new(1, -2 * PAD, 0, 0), AutomaticSize = Y,
}, Window)
vlist(Bottom, 8)

local StatusBar = new("Frame", {
    BackgroundColor3 = C.surface2, Size = UDim2.new(1, 0, 0, 0), Visible = false, LayoutOrder = 1, BorderSizePixel = 0, ClipsDescendants = true,
}, Bottom)
corner(StatusBar, 10)
local dots = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(0, 26, 1, 0) }, StatusBar)
hlist(dots, 4)
for i = 1, 3 do
    local d = new("Frame", { BackgroundColor3 = C.warn, Size = UDim2.fromOffset(5, 5), BorderSizePixel = 0, LayoutOrder = i, BackgroundTransparency = 0.1 }, dots)
    corner(d, 3)
    TweenService:Create(d, TweenInfo.new(0.55, SINE, INOUT, -1, true, (i - 1) * 0.16), { BackgroundTransparency = 0.85 }):Play()
end
local StatusLbl = new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, 44, 0, 0), Size = UDim2.new(1, -54, 1, 0), Text = "", TextColor3 = C.muted,
    Font = F.med, TextSize = fs(-1), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
}, StatusBar)

local Chips = new("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 2, ScrollBarThickness = 0,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.X, ScrollingDirection = Enum.ScrollingDirection.X,
}, Bottom)
hlist(Chips, 6)

local InputRow = new("Frame", { BackgroundColor3 = C.surface, Size = UDim2.new(1, 0, 0, IH), LayoutOrder = 3, BorderSizePixel = 0 }, Bottom)
corner(InputRow, 16)
local InputStroke = stroke(InputRow, C.line, 1, 0.9)
local SEND = IH - 12
local TextBox = new("TextBox", {
    BackgroundTransparency = 1, Position = UDim2.new(0, SEND + 14, 0, 0), Size = UDim2.new(1, -(2 * SEND + 26), 1, 0),
    PlaceholderText = "Tulis tugas…", PlaceholderColor3 = C.muted, Text = "", TextColor3 = C.text, Font = F.reg, TextSize = FS,
    ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, ClipsDescendants = true,
}, InputRow)
local SendBtn = new("TextButton", {
    BackgroundColor3 = C.surface3, Size = UDim2.fromOffset(SEND, SEND), AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -6, 0.5, 0), Text = "", AutoButtonColor = false, BorderSizePixel = 0,
}, InputRow)
corner(SendBtn, 12)
grad(SendBtn, C.white, Color3.fromRGB(205, 205, 225), 90)
local SendIcon = center(mkIcon(SendBtn, "send", 16, C.muted))
interactive(SendBtn, nil, nil, nil, 0.9)

-- tombol lipat: menampilkan / menyembunyikan chip (Pelajari, Spy, Log, ...) agar tampilan bersih
local ChipState = { open = false }   -- satu sumber kebenaran untuk tampil/lipat chip
local ToggleIcon
do
    local ToggleBtn = new("TextButton", {
        BackgroundColor3 = C.surface3, BackgroundTransparency = 1, Size = UDim2.fromOffset(SEND, SEND), AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 6, 0.5, 0), Text = "", AutoButtonColor = false, BorderSizePixel = 0,
    }, InputRow)
    corner(ToggleBtn, 12)
    ToggleIcon = center(mkIcon(ToggleBtn, "chevron", 16, C.muted))
    interactive(ToggleBtn, "BackgroundTransparency", 1, 0.4)
    Chips.Visible = false
    ToggleBtn.MouseButton1Click:Connect(function()
        ChipState.open = not ChipState.open
        Chips.Visible = ChipState.open
        tw(ToggleIcon.holder, { Rotation = ChipState.open and 180 or 0 }, 0.2)
    end)
end
track(TextBox.Focused:Connect(function()
    tw(InputStroke, { Transparency = 0.1, Color = C.accent }, 0.2)
end))
track(TextBox.FocusLost:Connect(function()
    tw(InputStroke, { Transparency = 0.9, Color = C.line }, 0.25)
end))

-- tombol "ke bawah"
local ScrollDown = new("TextButton", {
    BackgroundColor3 = C.surface3, Size = UDim2.fromOffset(32, 32), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -120),
    Text = "", AutoButtonColor = false, BorderSizePixel = 0, Visible = false, ZIndex = 4,
}, Window)
corner(ScrollDown, 16)
stroke(ScrollDown, C.line, 1, 0.85)
center(mkIcon(ScrollDown, "down", 16, C.text))
local SDScale = new("UIScale", { Scale = 0 }, ScrollDown)

local function relayoutChat()
    local wasBottom = ChatScroll.AbsoluteCanvasSize.Y - ChatScroll.AbsoluteSize.Y - ChatScroll.CanvasPosition.Y < 140
    ChatScroll.Size = UDim2.new(1, -2 * PAD, 1, -(HH + 8 + Bottom.AbsoluteSize.Y + STRIP + 6))
    ScrollDown.Position = UDim2.new(0.5, 0, 1, -(Bottom.AbsoluteSize.Y + STRIP + 14))
    if wasBottom then
        task.defer(function()
            if ChatScroll.Parent then
                ChatScroll.CanvasPosition = Vector2.new(0, math.max(0, ChatScroll.AbsoluteCanvasSize.Y - ChatScroll.AbsoluteSize.Y))
            end
        end)
    end
end
track(Bottom:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutChat))
relayoutChat()

-- ---------- Resize grip (digambar dari bar) ----------
local Grip = new("TextButton", {
    BackgroundTransparency = 1, Text = "", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -2, 1, 0),
    Size = UDim2.fromOffset(30, STRIP + 4), ZIndex = 3,
}, Window)
do
    local gi = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -8, 1, -5), Size = UDim2.fromOffset(10, 10) }, Grip)
    local o = { color = C.muted, parts = {}, holder = gi }
    fbBar(o, 1.0, 0.5, 0.55, -45, 0.13)
    fbBar(o, 0.55, 0.72, 0.78, -45, 0.13)
    for _, p in ipairs(o.parts) do p.inst.BackgroundTransparency = 0.45 end
end

-- ---------- Pill (minimize) ----------
local Pill = new("TextButton", {
    BackgroundTransparency = 1, Text = "", Size = UDim2.fromOffset(52, 52), Visible = false, AutoButtonColor = false, Active = true,
}, ScreenGui)
local PillRing = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(48, 48) }, Pill)
corner(PillRing, 26)
local PillRingStroke = stroke(PillRing, C.accent, 2, 0.4)
local PillRingScale = new("UIScale", { Scale = 1 }, PillRing)
TweenService:Create(PillRingScale, TweenInfo.new(1.4, QUAD, OUT, -1), { Scale = 1.35 }):Play()
TweenService:Create(PillRingStroke, TweenInfo.new(1.4, QUAD, OUT, -1), { Transparency = 1 }):Play()
local PillBody = new("Frame", { BackgroundColor3 = C.white, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(46, 46), BorderSizePixel = 0 }, Pill)
corner(PillBody, 23)
grad(PillBody, C.accent, C.accent2, 35)
stroke(PillBody, C.white, 1.5, 0.75)
center(mkIcon(PillBody, "logo", 22, C.white))
local PillScale = new("UIScale", { Scale = 0 }, PillBody)

-- ---------- drag helper ----------
local DRAG_SMOOTH = 26 -- makin besar = makin responsif; makin kecil = makin "meluncur"
local function makeDraggable(handle, getPos, setPos, onTap, smooth)
    local dragging, moved, startMouse, startPos = false, false, nil, nil
    local target, cur, loop
    local function startLoop()
        if loop then return end
        loop = RunService.RenderStepped:Connect(function(dt)
            local a = 1 - math.exp(-dt * DRAG_SMOOTH)
            local nxt = cur + (target - cur) * a
            if (target - nxt).Magnitude < 0.3 then nxt = target end
            cur = nxt
            setPos(cur)
            if not dragging and cur == target then
                loop:Disconnect()
                loop = nil
            end
        end)
    end
    track(handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, moved = true, false
            startMouse, startPos = input.Position, getPos()
            cur, target = startPos, startPos
            local c
            c = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if not moved and onTap then onTap() end
                    c:Disconnect()
                end
            end)
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - startMouse
            if d.Magnitude > 5 then moved = true end
            if moved then
                local tgt = startPos + Vector2.new(d.X, d.Y)
                if smooth then
                    target = tgt
                    startLoop()
                else
                    setPos(tgt)
                end
            end
        end
    end))
end

makeDraggable(Header,
    function() return Vector2.new(Window.Position.X.Offset, Window.Position.Y.Offset) end,
    function(p)
        local x, y = clampXY(p.X, p.Y, Window.Size.X.Offset, Window.Size.Y.Offset)
        Window.Position = UDim2.fromOffset(x, y)
    end, nil, true)

makeDraggable(Grip,
    function() return Vector2.new(Window.Size.X.Offset, Window.Size.Y.Offset) end,
    function(s)
        local v = vp()
        local px, py = Window.Position.X.Offset, Window.Position.Y.Offset
        local w = math.clamp(s.X, 280, math.max(280, v.X - px - 2))
        local h = math.clamp(s.Y, 220, math.max(220, v.Y - py - 2))
        userSized = true
        Window.Size = UDim2.fromOffset(w, h)
    end)

-- minimize / restore dengan animasi
-- Window menyusut ke pojok kiri-atas (titik tempat pill muncul) sementara pill sudah mulai muncul -> satu gerakan menyambung, bukan dua tahap.
local winState = "open" -- open | closing | closed
local function showPill(on)
    if on then
        Pill.Visible = true
        PillScale.Scale = 0
        tw(PillScale, { Scale = 1 }, 0.5, BACK)
    else
        tw(PillScale, { Scale = 0 }, 0.22).Completed:Connect(function(state) if state ~= Enum.PlaybackState.Completed then return end
            if PillScale.Scale < 0.05 then Pill.Visible = false end
        end)
    end
end
local function restoreFromPill()
    if winState == "open" then return end
    winState = "open"
    if not Window.Visible then
        WinScale.Scale = 0
        Window.Visible = true
        refit()
    end
    showPill(false)
    tw(WinScale, { Scale = 1 }, 0.5, 0.78)
end
makeDraggable(Pill,
    function() return Vector2.new(Pill.Position.X.Offset, Pill.Position.Y.Offset) end,
    function(p)
        local v = vp()
        Pill.Position = UDim2.fromOffset(math.clamp(p.X, 0, v.X - 52), math.clamp(p.Y, 0, v.Y - 52))
    end,
    restoreFromPill, true)

MinBtn.MouseButton1Click:Connect(function()
    if winState ~= "open" then return end
    winState = "closing"
    local v = vp()
    Pill.Position = UDim2.fromOffset(math.clamp(Window.Position.X.Offset, 0, v.X - 52), math.clamp(Window.Position.Y.Offset, 0, v.Y - 52))
    tw(WinScale, { Scale = 0 }, 0.36, QUAD, IN).Completed:Connect(function(state)
        if state ~= Enum.PlaybackState.Completed or winState ~= "closing" then return end
        winState = "closed"
        Window.Visible = false
        WinScale.Scale = 1
    end)
    task.delay(0.1, function()
        if winState ~= "open" then showPill(true) end
    end)
end)

-- ---------- keyboard-aware (HP) ----------
local compact, saved, winTween = false, nil, nil
local function tweenWindow(pos, size)
    if winTween then winTween:Cancel() end
    winTween = tw(Window, { Position = pos, Size = size }, 0.28, QUINT)
end
local function setCompact(on)
    if not touch or on == compact then return end
    compact = on
    if on then
        saved = { pos = Window.Position, size = Window.Size }
        local v = vp()
        local h = math.min(Window.Size.Y.Offset, math.max(190, math.floor(v.Y * 0.46)))
        Chips.Visible = false
        tweenWindow(UDim2.fromOffset(Window.Position.X.Offset, 2), UDim2.fromOffset(Window.Size.X.Offset, h))
    else
        Chips.Visible = ChipState.open   -- hormati pilihan user (sebelumnya selalu dipaksa tampil -> bug)
        if saved then tweenWindow(saved.pos, saved.size) end
        task.delay(0.3, refit)
    end
end
local function bindKeyboard(box)
    track(box.Focused:Connect(function() setCompact(true) end))
    track(box.FocusLost:Connect(function()
        task.delay(0.2, function()
            if UserInputService:GetFocusedTextBox() == nil then setCompact(false) end
        end)
    end))
end
bindKeyboard(TextBox)

-- ---------- scrolling helpers ----------
local scrollTween
local function nearBottom()
    return ChatScroll.AbsoluteCanvasSize.Y - ChatScroll.AbsoluteSize.Y - ChatScroll.CanvasPosition.Y < 140
end
local function scrollBottom()
    task.spawn(function()
        RunService.Heartbeat:Wait()
        RunService.Heartbeat:Wait()
        if not ChatScroll.Parent then return end
        local target = math.max(0, ChatScroll.AbsoluteCanvasSize.Y - ChatScroll.AbsoluteSize.Y)
        if scrollTween then scrollTween:Cancel() end
        scrollTween = tw(ChatScroll, { CanvasPosition = Vector2.new(0, target) }, 0.4, QUINT)
    end)
end
local function scrollToItem(item)
    task.spawn(function()
        RunService.Heartbeat:Wait()
        RunService.Heartbeat:Wait()
        if not item.Parent then return end
        local y = item.AbsolutePosition.Y - ChatScroll.AbsolutePosition.Y + ChatScroll.CanvasPosition.Y - 4
        if scrollTween then scrollTween:Cancel() end
        scrollTween = tw(ChatScroll, { CanvasPosition = Vector2.new(0, math.max(0, y)) }, 0.4, QUINT)
    end)
end

local sdShown = false
track(ChatScroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
    local far = ChatScroll.AbsoluteCanvasSize.Y - ChatScroll.AbsoluteSize.Y - ChatScroll.CanvasPosition.Y > 220
    if far == sdShown then return end
    sdShown = far
    if far then
        ScrollDown.Visible = true
        tw(SDScale, { Scale = 1 }, 0.3, BACK)
    else
        tw(SDScale, { Scale = 0 }, 0.18, QUAD, IN).Completed:Connect(function(state) if state ~= Enum.PlaybackState.Completed then return end
            if not sdShown then ScrollDown.Visible = false end
        end)
    end
end))
ScrollDown.MouseButton1Click:Connect(scrollBottom)

-- ---------- lebar maksimum bubble ----------
local Constraints = {}
local function bubbleMax() return math.max(120, math.floor(ChatScroll.AbsoluteSize.X * 0.8) - 26) end
local function regConstraint(c) Constraints[#Constraints + 1] = c end
track(ChatScroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
    local m = bubbleMax()
    for i = #Constraints, 1, -1 do
        local c = Constraints[i]
        if c.Parent then c.MaxSize = Vector2.new(m, math.huge) else table.remove(Constraints, i) end
    end
end))

-- ---------- blok pembangun pesan ----------
local order = 0
local function wrapper(halign, horizontal)
    order = order + 1
    local w = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y, LayoutOrder = order }, ChatScroll)
    if horizontal then
        new("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8),
            VerticalAlignment = Enum.VerticalAlignment.Top,
        }, w)
    else
        new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = halign or Enum.HorizontalAlignment.Left }, w)
    end
    return w
end
local function label(parent, text, size, color, font, extra)
    local l = new("TextLabel", {
        BackgroundTransparency = 1, Text = text, TextSize = size, TextColor3 = color, Font = font or F.reg,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true,
        Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y, RichText = false, LineHeight = 1.12,
    })
    if extra then for k, v in pairs(extra) do l[k] = v end end
    l.Parent = parent
    return l
end

-- markdown ringan -> RichText
local function esc(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
local function toRich(text)
    text = esc(text)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local h = line:match("^%s*#+%s+(.+)$")
        if h then
            line = "<b>" .. h .. "</b>"
        else
            local b2 = line:match("^%s*[%-%*]%s+(.+)$")
            if b2 then line = "  •  " .. b2 end
        end
        line = line:gsub("%*%*(.-)%*%*", "<b>%1</b>")
        line = line:gsub("`([^`]+)`", '<font color="#9fb4ff">%1</font>')
        out[#out + 1] = line
    end
    return table.concat(out, "\n")
end

local function parseBlocks(text)
    local blocks, pos = {}, 1
    while true do
        local s, e, lang, body = text:find("```([%w_%-]*)[ \t]*\r?\n(.-)```", pos)
        if not s then break end
        if s > pos then blocks[#blocks + 1] = { kind = "text", body = text:sub(pos, s - 1) } end
        blocks[#blocks + 1] = { kind = "code", lang = lang, body = (body:gsub("%s+$", "")) }
        pos = e + 1
    end
    local rest = text:sub(pos)
    local s2, e2, lang2 = rest:find("```([%w_%-]*)[ \t]*\r?\n")
    if s2 then -- fence tidak tertutup (jawaban terpotong)
        if s2 > 1 and rest:sub(1, s2 - 1):match("%S") then blocks[#blocks + 1] = { kind = "text", body = rest:sub(1, s2 - 1) } end
        blocks[#blocks + 1] = { kind = "code", lang = lang2, body = (rest:sub(e2 + 1):gsub("%s+$", "")) }
    elseif rest:match("%S") then
        blocks[#blocks + 1] = { kind = "text", body = rest }
    end
    return blocks
end

local addSystem

-- tombol kecil: ikon + label pendek
local function smallBtn(parent, iconName, text, bg, order)
    local H = touch and 24 or 22
    local b = new("TextButton", {
        AutoButtonColor = false, Text = "", BackgroundColor3 = bg, AutomaticSize = Enum.AutomaticSize.X,
        Size = UDim2.new(0, 0, 0, H), BorderSizePixel = 0, LayoutOrder = order,
    }, parent)
    corner(b, 8)
    pad(b, 8, 0, text ~= "" and 10 or 8, 0)
    hlist(b, 5)
    local o = { btn = b, iconName = iconName, text = text }
    o.icon = mkIcon(b, iconName, 13, C.white)
    o.icon.holder.LayoutOrder = 1
    if text ~= "" then
        o.lbl = new("TextLabel", {
            BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), Text = text,
            Font = F.med, TextSize = fs(-2), TextColor3 = C.white, LayoutOrder = 2,
        }, b)
    end
    interactive(b, "BackgroundColor3", bg, bg:Lerp(C.white, 0.14))
    return o
end
local function flash(o, iconName, txt, ms)
    o.icon.set(iconName)
    if o.lbl then o.lbl.Text = txt end
    task.delay(ms or 1.4, function()
        if o.btn.Parent then
            o.icon.set(o.iconName)
            if o.lbl then o.lbl.Text = o.text end
        end
    end)
end

local function codeBlock(parent, lang, code, ord)
    local box = new("Frame", { BackgroundColor3 = C.code, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y, BorderSizePixel = 0, LayoutOrder = ord }, parent)
    corner(box, 11)
    stroke(box, C.line, 1, 0.92)
    vlist(box, 0)

    local BAR = touch and 32 or 30
    local bar = new("Frame", { BackgroundColor3 = C.codeBar, Size = UDim2.new(1, 0, 0, BAR), BorderSizePixel = 0, LayoutOrder = 1 }, box)
    corner(bar, 11)
    new("Frame", { BackgroundColor3 = C.codeBar, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -11), Size = UDim2.new(1, 0, 0, 11) }, bar)
    local lines = select(2, code:gsub("\n", "\n")) + 1
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(0.3, 0, 1, 0), Font = F.semi, TextSize = fs(-3),
        TextColor3 = C.muted, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        Text = (lang ~= "" and lang:upper() or "KODE") .. "  ·  " .. lines,
    }, bar)
    local btns = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.new(0.7, -8, 1, 0) }, bar)
    hlist(btns, 5, Enum.HorizontalAlignment.Right)
    local togB = smallBtn(btns, "chevron", "", C.surface3, 1)
    togB.btn.Visible = false
    local isLua = (lang == "lua" or lang == "luau")
    local runB
    if isLua then runB = smallBtn(btns, "play", "Run", Color3.fromRGB(32, 130, 90), 2) end
    local copyB = smallBtn(btns, "copy", "Salin", Color3.fromRGB(52, 98, 200), 3)

    local view = new("Frame", { BackgroundTransparency = 1, ClipsDescendants = true, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 2 }, box)
    local shown = code
    if #shown > 15000 then shown = shown:sub(1, 15000) .. "\n-- ... (tampilan dipotong; Salin tetap menyalin semua)" end
    local lbl = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 0, 0), AutomaticSize = Y,
        Font = F.code, TextSize = fs(-1), TextColor3 = C.codeText, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Text = shown,
    }, view)
    local expanded = false
    local function relayout()
        local full = lbl.TextBounds.Y + 18
        local maxCollapsed = touch and 170 or 200
        if full <= maxCollapsed + 30 then
            view.Size = UDim2.new(1, 0, 0, full)
            togB.btn.Visible = false
        else
            togB.btn.Visible = true
            tw(togB.icon.holder, { Rotation = expanded and 180 or 0 }, 0.25)
            tw(view, { Size = UDim2.new(1, 0, 0, expanded and full or maxCollapsed) }, 0.3, QUINT)
        end
    end
    lbl:GetPropertyChangedSignal("TextBounds"):Connect(relayout)
    relayout()
    togB.btn.MouseButton1Click:Connect(function()
        expanded = not expanded
        relayout()
    end)
    copyB.btn.MouseButton1Click:Connect(function()
        if setClipboardFunc then
            local ok = pcall(setClipboardFunc, code)
            flash(copyB, ok and "check" or "fail", ok and "Tersalin" or "Gagal")
        else
            flash(copyB, "fail", "Tak bisa")
        end
    end)
    if runB then
        runB.btn.MouseButton1Click:Connect(function()
            if not loadstring then
                flash(runB, "fail", "Tak bisa")
                return
            end
            local f, err = loadstring(code)
            if not f then
                addSystem("Syntax error: " .. clip(err, 160), "err")
                return
            end
            flash(runB, "loader", "Jalan", 1)
            task.spawn(function()
                local ok, e2 = pcall(f)
                addSystem(ok and "Script selesai dijalankan" or ("Error: " .. clip(e2, 160)), ok and "ok" or "err")
            end)
        end)
    end
end

-- ---------- pesan ----------
local function addUser(text)
    local w = wrapper(Enum.HorizontalAlignment.Right)
    local b = new("Frame", { BackgroundColor3 = C.white, Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY, BorderSizePixel = 0 }, w)
    corner(b, 16)
    grad(b, C.accent, Color3.fromRGB(88, 120, 255), 35)
    pad(b, 11, 7, 11, 7)
    local l = label(b, clip(text, 4000), FS, C.white, F.reg, { AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(0, 0, 0, 0) })
    local cons = new("UISizeConstraint", { MaxSize = Vector2.new(bubbleMax(), math.huge) }, l)
    regConstraint(cons)
    fadeIn(w, 0.3)
    scrollBottom()
end

local function addAgent(text, note)
    local stick = nearBottom()
    local w = wrapper(nil, true)
    local b = new("Frame", {
        BackgroundColor3 = C.surface2, BackgroundTransparency = note and 1 or 0, Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Y, BorderSizePixel = 0, LayoutOrder = 2,
    }, w)
    corner(b, 14)
    if note then
        pad(b, 0, 3, 0, 3)
    else
        stroke(b, C.line, 1, 0.93)
        pad(b, 11, 8, 11, 8)
    end
    vlist(b, 8)
    local blocks = parseBlocks(text)
    for i, blk in ipairs(blocks) do
        if blk.kind == "code" then
            codeBlock(b, blk.lang, blk.body, i)
        elseif blk.body:match("%S") then
            local l = label(b, toRich(clip(trim(blk.body), 12000)), note and fs(-1) or FS, note and C.muted or C.text, F.reg, { RichText = true })
            l.LayoutOrder = i
        end
    end
    fadeIn(w, 0.45)
    if note then
        if stick then scrollBottom() end
    else
        scrollToItem(w)
    end
end

-- pesan sistem: pill kecil berwarna
addSystem = function(text, kind)
    local stick = nearBottom()
    local w = wrapper(Enum.HorizontalAlignment.Center)
    local col = kind == "err" and C.err or (kind == "ok" and C.ok or C.muted)
    local ic = kind == "err" and "alert" or (kind == "ok" and "check" or "hash")
    local pill = new("Frame", { BackgroundColor3 = col, BackgroundTransparency = 0.88, Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY, BorderSizePixel = 0 }, w)
    corner(pill, 12)
    pad(pill, 10, 6, 12, 6)
    hlist(pill, 7)
    local i = mkIcon(pill, ic, 13, col)
    i.holder.LayoutOrder = 1
    local l = new("TextLabel", {
        BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(0, 0, 0, 0), Text = clip(text, 220),
        Font = F.med, TextSize = fs(-2), TextColor3 = col, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 2,
    }, pill)
    local cons = new("UISizeConstraint", { MaxSize = Vector2.new(math.max(120, bubbleMax() - 20), math.huge) }, l)
    regConstraint(cons)
    fadeIn(w, 0.35)
    if stick then scrollBottom() end
end

-- kartu tool: satu baris ringkas, ketuk untuk lihat hasil
local function addToolCard(name, args, parent, ord)
    local stick = nearBottom()
    local w = (not parent) and wrapper(nil, true) or nil
    local card = new("TextButton", {
        AutoButtonColor = false, Text = "", BackgroundColor3 = C.surface, Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Y, BorderSizePixel = 0, LayoutOrder = ord or 2,
    }, parent or w)
    corner(card, 11)
    stroke(card, C.line, 1, 0.93)
    pad(card, 10, 0, 10, 0)
    vlist(card, 0)
    local ROWH = touch and 30 or 28
    local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROWH), LayoutOrder = 1 }, card)
    local st = mkIcon(row, "loader", 15, C.warn)
    st.holder.AnchorPoint = Vector2.new(0, 0.5)
    st.holder.Position = UDim2.new(0, 0, 0.5, 0)
    local spin = TweenService:Create(st.holder, TweenInfo.new(0.9, LINEAR, OUT, -1), { Rotation = 360 })
    spin:Play()

    local argText = ""
    if type(args) == "table" and next(args) ~= nil then argText = clip(ser(args, 2), 90) end
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 24, 0, 0), Size = UDim2.new(1, -(24 + 22 + 44), 1, 0), RichText = true,
        Text = "<b>" .. esc(name) .. "</b>" .. (argText ~= "" and ("  <font color=\"#808aa2\">" .. esc(argText) .. "</font>") or ""),
        Font = F.med, TextSize = fs(-1), TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    local timeL = new("TextLabel", {
        BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -22, 0, 0), Size = UDim2.new(0, 40, 1, 0),
        Text = "", Font = F.reg, TextSize = fs(-3), TextColor3 = C.muted, TextXAlignment = Enum.TextXAlignment.Right,
    }, row)
    local chev = mkIcon(row, "chevron", 14, C.muted)
    chev.holder.AnchorPoint = Vector2.new(1, 0.5)
    chev.holder.Position = UDim2.new(1, 0, 0.5, 0)

    local body = label(card, "", fs(-3), C.muted, F.code)
    body.LayoutOrder = 2
    body.Visible = false
    new("UIPadding", { PaddingBottom = UDim.new(0, 10) }, body)

    local obj = { body = body, full = "", expanded = false, failed = false, t0 = os.clock(), name = name, spin = spin, st = st, timeL = timeL }
    function obj.render()
        if obj.full == "" then
            body.Visible = false
        elseif obj.expanded then
            body.Visible = true
            body.TextColor3 = obj.failed and C.err or C.muted
            body.Text = clip(obj.full, 2500)
        elseif obj.failed then
            body.Visible = true
            body.TextColor3 = C.err
            body.Text = clip((obj.full:gsub("%s+", " ")), 140)
        else
            body.Visible = false
        end
        tw(chev.holder, { Rotation = obj.expanded and 180 or 0 }, 0.25)
    end
    function obj.setExpanded(on)
        obj.expanded = on
        obj.render()
        if on and body.Visible then
            body.TextTransparency = 1
            tw(body, { TextTransparency = 0 }, 0.3)
        end
    end
    card.MouseButton1Click:Connect(function()
        if obj.full == "" then return end
        obj.setExpanded(not obj.expanded)
    end)
    interactive(card, "BackgroundColor3", C.surface, C.surface2, 0.985)
    if w then
        fadeIn(w, 0.35)
        if stick then scrollBottom() end
    end
    return obj
end
local function finishToolCard(obj, text)
    local failed = text:sub(1, 5) == "ERROR"
    obj.failed = failed
    obj.full = text
    obj.spin:Cancel()
    obj.st.holder.Rotation = 0
    obj.st.set(failed and "alert" or "check")
    obj.st.paint(failed and C.err or C.ok)
    obj.timeL.Text = string.format("%.1fs", math.min(os.clock() - obj.t0, 999))
    obj.render()
end

-- grup tool: satu baris terlipat per jawaban ("Menggunakan <tool>" -> "N Tools Digunakan"); ketuk untuk lihat detail
local function addToolGroup()
    local stick = nearBottom()
    local w = wrapper(Enum.HorizontalAlignment.Left)
    local ROWH = touch and 30 or 28
    local head = new("TextButton", {
        AutoButtonColor = false, Text = "", BackgroundColor3 = C.surface, Size = UDim2.new(1, 0, 0, ROWH),
        BorderSizePixel = 0, LayoutOrder = 1,
    }, w)
    corner(head, 11)
    stroke(head, C.line, 1, 0.93)
    local st = mkIcon(head, "loader", 15, C.warn)
    st.holder.AnchorPoint = Vector2.new(0, 0.5)
    st.holder.Position = UDim2.new(0, 10, 0.5, 0)
    local spin = TweenService:Create(st.holder, TweenInfo.new(0.9, LINEAR, OUT, -1), { Rotation = 360 })
    spin:Play()
    local lbl = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 34, 0, 0), Size = UDim2.new(1, -(34 + 30), 1, 0),
        Text = "Menggunakan tools", Font = F.med, TextSize = fs(-1), TextColor3 = C.text,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    }, head)
    local chev = mkIcon(head, "chevron", 14, C.muted)
    chev.holder.AnchorPoint = Vector2.new(1, 0.5)
    chev.holder.Position = UDim2.new(1, -10, 0.5, 0)
    local content = new("Frame", {
        BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y, Visible = false,
        LayoutOrder = 2, BorderSizePixel = 0,
    }, w)
    vlist(content, 6)
    pad(content, 10, 6, 0, 0)

    local g = { count = 0, failed = 0, open = false, done = false }
    function g.setLabel(name)
        if not g.done then lbl.Text = "Menggunakan " .. tostring(name) end
    end
    function g.addCard(name, args)
        g.count = g.count + 1
        return addToolCard(name, args, content, g.count)
    end
    function g.noteResult(text)
        if tostring(text):sub(1, 5) == "ERROR" then g.failed = g.failed + 1 end
    end
    function g.finish()
        if g.done then return end
        g.done = true
        spin:Cancel()
        st.holder.Rotation = 0
        st.set(g.failed > 0 and "alert" or "check")
        st.paint(g.failed > 0 and C.warn or C.ok)
        lbl.Text = g.count .. " Tools Digunakan"
    end
    head.MouseButton1Click:Connect(function()
        g.open = not g.open
        content.Visible = g.open
        tw(chev.holder, { Rotation = g.open and 180 or 0 }, 0.25)
    end)
    interactive(head, "BackgroundColor3", C.surface, C.surface2, 0.985)
    fadeIn(w, 0.35)
    if stick then scrollBottom() end
    return g
end

-- status bar (bawah)
local statusShown, statusGen = false, 0
local function showStatus(on)
    if on == statusShown then return end
    statusShown = on
    statusGen = statusGen + 1
    local g = statusGen
    if on then
        StatusBar.Visible = true
        tw(StatusBar, { Size = UDim2.new(1, 0, 0, STAT_H) }, 0.3, QUINT)
    else
        tw(StatusBar, { Size = UDim2.new(1, 0, 0, 0) }, 0.22, QUINT, IN).Completed:Connect(function(state) if state ~= Enum.PlaybackState.Completed then return end
            if g == statusGen then StatusBar.Visible = false end
        end)
    end
end
local function setStatus(text)
    State.status = text or ""
    if text then StatusLbl.Text = text end
    statusBusy = text ~= nil
    showStatus(text ~= nil)
    refreshSub()
end

-- ---------- Settings (panel geser dari bawah) ----------
local Settings = new("Frame", {
    BackgroundColor3 = C.bg, Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 1, -(HH + 1)), Visible = false,
    ZIndex = 10, BorderSizePixel = 0, Active = true,
}, Window)
corner(Settings, 18)

local SP = 14                         -- margin kiri/kanan panel
local TOPH = touch and 40 or 36       -- tinggi bar judul
local FH = touch and 36 or 34         -- tinggi kolom input
local SAVEH = touch and 38 or 34      -- tinggi tombol simpan

-- bar judul: judul kiri, tombol tutup kanan
local SBar = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TOPH) }, Settings)
new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, SP, 0, 0), Size = UDim2.new(1, -(SP + 50), 1, 0), Text = "Pengaturan",
    TextColor3 = C.text, Font = F.bold, TextSize = FS + 2, TextXAlignment = Enum.TextXAlignment.Left,
}, SBar)
local CloseSetBtn = new("TextButton", {
    BackgroundColor3 = C.surface3, BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 28), AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -(SP - 4), 0.5, 0), Text = "", AutoButtonColor = false, BorderSizePixel = 0,
}, SBar)
corner(CloseSetBtn, 9)
center(mkIcon(CloseSetBtn, "close", 15, C.muted))
interactive(CloseSetBtn, "BackgroundTransparency", 1, 0.4)

-- tombol simpan menempel di bawah panel
local SaveBtn = new("TextButton", {
    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, SP, 1, -(STRIP + 4)),
    Size = UDim2.new(1, -2 * SP, 0, SAVEH), Text = "", AutoButtonColor = false, BorderSizePixel = 0,
}, Settings)
local SaveFill = new("Frame", { BackgroundColor3 = C.white, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, SaveBtn)
corner(SaveFill, 11)
grad(SaveFill, C.accent, C.accent2, 20)
new("TextLabel", {
    BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "Simpan", TextColor3 = C.white, Font = F.bold, TextSize = FS,
}, SaveBtn)
interactive(SaveBtn, nil, nil, nil, 0.96)

-- isi (bisa digulir)
local SScroll = new("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0, TOPH),
    Size = UDim2.new(1, 0, 1, -(TOPH + SAVEH + STRIP + 14)), CanvasSize = UDim2.new(), AutomaticCanvasSize = Y,
    ScrollBarThickness = 3, ScrollBarImageColor3 = C.muted,
}, Settings)
vlist(SScroll, 12)
pad(SScroll, SP, 2, SP, 8)

local fields = {}
local function fieldLabel(parent, iconName, title)
    local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, fs(-1) + 4), LayoutOrder = 1 }, parent)
    hlist(head, 5)
    local ic = mkIcon(head, iconName, 12, C.muted)
    ic.holder.LayoutOrder = 1
    new("TextLabel", {
        BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), Text = title,
        TextColor3 = C.muted, Font = F.med, TextSize = fs(-1), LayoutOrder = 2,
    }, head)
end
-- kolom input: kotak luar (warna + garis) berisi TextBox dengan margin tetap 12px kiri/kanan
local function fieldBox(parent, key, numeric, hint)
    local holder = new("Frame", { BackgroundColor3 = C.surface, Size = UDim2.new(1, 0, 0, FH), BorderSizePixel = 0, LayoutOrder = 2 }, parent)
    corner(holder, 10)
    local sk = stroke(holder, C.line, 1, 0.9)
    local box = new("TextBox", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -24, 1, 0), Text = tostring(Config[key]),
        PlaceholderText = hint or "", PlaceholderColor3 = C.muted, TextColor3 = C.text, Font = F.reg, TextSize = fs(-1),
        ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, ClipsDescendants = true,
    }, holder)
    track(box.Focused:Connect(function() tw(sk, { Color = C.accent, Transparency = 0.1 }, 0.2) end))
    track(box.FocusLost:Connect(function() tw(sk, { Color = C.line, Transparency = 0.9 }, 0.25) end))
    bindKeyboard(box)
    fields[key] = { box = box, numeric = numeric }
end
local function settingField(ord, iconName, title, key, numeric, hint)
    local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y, LayoutOrder = ord }, SScroll)
    vlist(row, 6)
    fieldLabel(row, iconName, title)
    fieldBox(row, key, numeric, hint)
end
local function settingPair(ord, a, b)
    local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y, LayoutOrder = ord }, SScroll)
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10),
        VerticalAlignment = Enum.VerticalAlignment.Top,
    }, row)
    for i, d in ipairs({ a, b }) do
        local col = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0.5, -5, 0, 0), AutomaticSize = Y, LayoutOrder = i }, row)
        vlist(col, 6)
        fieldLabel(col, d[1], d[2])
        fieldBox(col, d[3], d[4], d[5])
    end
end
settingField(1, "key", "API key (utama)", "apiKey", false, "sk-...")
settingField(2, "bot", "Model (utama)", "model", false, "gpt-6-luna")
settingField(3, "link", "Endpoint (utama)", "apiUrl", false, "https://.../v1/chat/completions")
settingField(4, "key", "API key (cadangan)", "apiKey2", false, "sk-...")
settingField(5, "bot", "Model (cadangan)", "model2", false, "deepseek-v4-pro-openrouter")
settingField(6, "link", "Endpoint (cadangan)", "apiUrl2", false, "https://.../v1/chat/completions")
settingPair(7, { "gauge", "Langkah maks", "maxSteps", true, "1-30" }, { "cpu", "Token maks", "maxTokens", true, "500-32000" })

-- toggle eval_lua
local EvalRow = new("Frame", { BackgroundColor3 = C.surface, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = 8, BorderSizePixel = 0 }, SScroll)
corner(EvalRow, 10)
stroke(EvalRow, C.line, 1, 0.9)
new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -72, 0, 18), Text = "Uji coba (sandbox)", TextColor3 = C.text,
    Font = F.semi, TextSize = fs(-1), TextXAlignment = Enum.TextXAlignment.Left,
}, EvalRow)
new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 24), Size = UDim2.new(1, -72, 0, 16), Text = "Agent boleh mengetes script sebelum dikirim",
    TextColor3 = C.muted, Font = F.reg, TextSize = fs(-3), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
}, EvalRow)
local SwTrack = new("TextButton", {
    Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(40, 22), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
    BackgroundColor3 = C.surface3, BorderSizePixel = 0,
}, EvalRow)
corner(SwTrack, 11)
local SwKnob = new("Frame", { Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = C.white, BorderSizePixel = 0 }, SwTrack)
corner(SwKnob, 8)
local function refreshEval(animate)
    local on = Config.allowEval
    local pos = on and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3)
    local col = on and C.accent or C.surface3
    if animate then
        tw(SwKnob, { Position = pos }, 0.3, BACK)
        tw(SwTrack, { BackgroundColor3 = col }, 0.2)
    else
        SwKnob.Position = pos
        SwTrack.BackgroundColor3 = col
    end
end
refreshEval(false)
SwTrack.MouseButton1Click:Connect(function()
    Config.allowEval = not Config.allowEval
    refreshEval(true)
end)

local settingsOpen = false
local function setSettings(open)
    settingsOpen = open
    tw(SetIcon.holder, { Rotation = open and 90 or 0 }, 0.4, QUINT)
    if open then
        Settings.Visible = true
        tw(Settings, { Position = UDim2.new(0, 0, 0, HH + 1) }, 0.45, QUINT)
    else
        tw(Settings, { Position = UDim2.new(0, 0, 1, 0) }, 0.32, QUINT, IN).Completed:Connect(function(state) if state ~= Enum.PlaybackState.Completed then return end
            if not settingsOpen then Settings.Visible = false end
        end)
    end
end
local function openSettings() setSettings(true) end
SetBtn.MouseButton1Click:Connect(function() setSettings(not settingsOpen) end)
CloseSetBtn.MouseButton1Click:Connect(function() setSettings(false) end)
SaveBtn.MouseButton1Click:Connect(function()
    for key, f in pairs(fields) do
        local txt = trim(f.box.Text)
        if f.numeric then
            local n = tonumber(txt)
            if n then Config[key] = n end
        elseif txt ~= "" or key == "apiKey" or key == "apiKey2" then
            Config[key] = txt
        end
    end
    Config.maxSteps = math.clamp(math.floor(Config.maxSteps), 1, 30)
    Config.maxTokens = math.clamp(math.floor(Config.maxTokens), 500, 32000)
    for key, f in pairs(fields) do f.box.Text = tostring(Config[key]) end
    saveConfig()
    Router.reset() -- kunci/model baru: hapus status cooldown lama
    refreshSub()
    setSettings(false)
    addSystem(writefile and "Tersimpan" or "Tersimpan (sesi ini saja)", "ok")
end)

-- ========================================================
-- AGENT LOOP
-- ========================================================
local function alive(my)
    return my == State.runId and ScreenGui.Parent ~= nil
end

local function updateSend()
    local hasText = trim(TextBox.Text) ~= ""
    local bg, ic, col
    if State.busy then
        bg, ic, col = C.err, "stop", C.white
    elseif hasText then
        bg, ic, col = C.accent, "send", C.white
    else
        bg, ic, col = C.surface3, "send", C.muted
    end
    tw(SendBtn, { BackgroundColor3 = bg }, 0.2)
    if SendIcon.name ~= ic then SendIcon.set(ic) end
    SendIcon.tint(col, 0.2)
end
track(TextBox:GetPropertyChangedSignal("Text"):Connect(updateSend))
updateSend()

local function setBusy(on)
    State.busy = on
    updateSend()
    if not on then setStatus(nil) end
end

local function stopRun()
    State.runId = State.runId + 1
    setBusy(false)
    addSystem("Dihentikan", "err")
end

-- ---------- pemeriksaan script final (sintaks + nama yang belum terverifikasi) ----------
local SAFE_NAMES = {}
for _, n in ipairs({ "Humanoid", "HumanoidRootPart", "Backpack", "PlayerGui", "Character", "Head", "Torso", "UpperTorso", "LowerTorso",
    "Animator", "leaderstats", "PlayerScripts", "StarterGear", "Camera", "CurrentCamera", "RightHand", "LeftHand", "Handle" }) do
    SAFE_NAMES[n] = true
end
local function lastLuaBlock(reply)
    local code
    for body in reply:gmatch("```[lL][uU][aA]%s*\n(.-)```") do code = body end
    return code
end
local function auditScript(code)
    local problems = {}
    if loadstring then
        local f, err = loadstring(code)
        if not f then problems[#problems + 1] = "ERROR SINTAKS: " .. clip(tostring(err), 220) end
    end
    local hay = {}
    for _, m in ipairs(State.history) do
        if m.role == "user" then hay[#hay + 1] = m.content end
    end
    for _, n in ipairs(State.notes) do hay[#hay + 1] = n end
    local hayText = table.concat(hay, "\n")
    local seen, unverified = {}, {}
    for _, pat in ipairs({ 'WaitForChild%(%s*"([^"\n]+)"', "WaitForChild%(%s*'([^'\n]+)'", 'FindFirstChild%(%s*"([^"\n]+)"', "FindFirstChild%(%s*'([^'\n]+)'" }) do
        for name in code:gmatch(pat) do
            if not seen[name] and not SAFE_NAMES[name] then
                seen[name] = true
                if not string.find(hayText, name, 1, true) then unverified[#unverified + 1] = name end
            end
        end
    end
    if #unverified > 0 then
        local shown = {}
        for i = 1, math.min(#unverified, 8) do shown[i] = '"' .. unverified[i] .. '"' end
        problems[#problems + 1] = "NAMA BELUM TERVERIFIKASI (tidak ada di output tool/catatan/permintaan user): " .. table.concat(shown, ", ")
    end
    return problems
end

local function runAgent(userText)
    if State.busy then return end
    if not Router.hasKey() then
        addSystem("Isi API key dulu", "err")
        openSettings()
        return
    end
    if not httpRequest then
        addSystem("Executor tanpa HTTP request", "err")
        return
    end
    archiveFinished()
    State.history[#State.history + 1] = { role = "user", content = tostring(userText) }
    State.runId = State.runId + 1
    local my = State.runId
    setBusy(true)
    setStatus("Memulai")

    task.spawn(function()
        local step, forceFinal, group, nudges, fixes = 0, false, nil, 0, 0
        while alive(my) do
            setStatus(string.format("Berpikir  ·  %d/%d", step + 1, Config.maxSteps))
            trimHistory()
            local reply, finish = callLLM(buildMessages(), function() return alive(my) end,
                function(s) setStatus("Menunggu API pulih  ·  " .. s .. "d") end,
                function(p)
                    addSystem("Beralih ke " .. p.model, "ok")
                    setStatus(string.format("Berpikir  ·  %d/%d  ·  %s", step + 1, Config.maxSteps, p.model))
                end)
            if not alive(my) then
                if group then group.finish() end
                return
            end
            if not reply then
                addSystem(clip(tostring(finish), 200), "err")
                break
            end
            local am = { role = "assistant", content = reply }
            State.history[#State.history + 1] = am

            local calls, rest = {}, reply
            if not forceFinal then calls, rest = extractToolCalls(reply) end
            if #calls > 0 then
                local draft = lastLuaBlock(reply)
                if draft then
                    for _, c in ipairs(calls) do
                        if c.tool == "test_script" then
                            if type(c.args) ~= "table" then c.args = {} end
                            if c.args.code == nil or c.args.code == "" then c.args.code = draft end
                        end
                    end
                end
            end

            local auditMsg
            if #calls == 0 and not forceFinal and fixes < 2 then
                local code = lastLuaBlock(reply)
                if code then
                    local problems = auditScript(code)
                    if #problems > 0 then
                        auditMsg = "[SISTEM] Pemeriksaan otomatis terhadap script-mu menemukan masalah:\n- " .. table.concat(problems, "\n- ")
                            .. "\nPerbaiki sebelum final. Untuk nama yang belum terverifikasi: panggil tool (search_game / search_code / get_children / list_remotes / get_player_status) untuk memastikan nama yang benar lalu perbaiki script; kalau memang tidak ada di game, buat script menemukannya secara dinamis. Untuk error sintaks: perbaiki dan kirim script LENGKAP yang sudah benar. Jika butuh tool, balas HANYA blok ```json tool; jika tidak, kirim script final."
                    end
                end
            end

            local looksTool = (not forceFinal) and #calls == 0
                and reply:find('"tool"%s*:') ~= nil and not reply:lower():find("```%s*lua")
            local emptyReply = trim(reply) == "" and finish ~= "length"
            if #calls == 0 and (looksTool or emptyReply) and nudges < 2 then
                -- balasan kosong / JSON tool rusak atau terpotong: minta ulang otomatis, jangan tampilkan sampah ke user
                nudges = nudges + 1
                table.remove(State.history)
                State.history[#State.history + 1] = { role = "user", content = [=[[SISTEM] Balasan sebelumnya kosong atau JSON tool-nya tidak valid/terpotong. Jika masih butuh tool: balas HANYA blok ```json dengan JSON valid {"tool":"...","args":{...}} (ringkas). Jika data sudah cukup: langsung tulis jawaban/script final.]=] }
            elseif auditMsg then
                fixes = fixes + 1
                setStatus("Memeriksa script")
                State.history[#State.history + 1] = { role = "user", content = auditMsg }
            elseif #calls == 0 then
                -- "final" hanya jika berisi blok script; pertanyaan/penjelasan biasa tidak memicu pemadatan
                if reply:lower():find("```%s*lua") then am.final = true end
                local text = reply
                if forceFinal then
                    text = trim((reply:gsub("```json.-```", "")))
                    local _, r2 = extractToolCalls(text)
                    text = r2
                end
                if trim(text) == "" then text = "(Tidak ada jawaban. Coba kirim ulang atau ketik 'lanjut'.)" end
                if finish == "length" then
                    text = text .. "\n\nJawaban terpotong. Ketik **lanjut** atau naikkan token maks."
                end
                addAgent(text)
                break
            else

                -- teks pengantar di sela pemanggilan tool tidak ditampilkan (user hanya perlu hasil)

                local results, newKeys = {}, {}
                for ci, call in ipairs(calls) do
                    if ci > 5 then break end
                    if not group then group = addToolGroup() end
                    group.setLabel(call.tool)
                    local card = group.addCard(call.tool, call.args)
                    setStatus("Menjalankan  ·  " .. tostring(call.tool))
                    local cname = ALIASES[tostring(call.tool)] or tostring(call.tool)
                    local key
                    if CACHEABLE[cname] and type(call.args) == "table" then
                        key = cname .. "|" .. argKey(call.args)
                    end
                    local text
                    if key and (newKeys[key] or dupAlive(key)) then
                        text = DUP_TEXT
                    else
                        text = runTool(call.tool, call.args)
                        if key and not text:find("^ERROR") then newKeys[key] = true end
                    end
                    if not alive(my) then
                        group.finish()
                        return
                    end
                    finishToolCard(card, text)
                    group.noteResult(text)
                    results[#results + 1] = string.format("[TOOL_RESULT %s]\n%s", tostring(call.tool), text)
                end
                step = step + 1
                local msg = table.concat(results, "\n\n")
                if step >= Config.maxSteps then
                    forceFinal = true
                    msg = msg .. "\n\n[SISTEM] Batas langkah tercapai. JANGAN panggil tool lagi. Beri jawaban final dari data yang sudah ada; sebutkan bagian yang belum terverifikasi."
                end
                local hm = { role = "user", content = msg }
                State.history[#State.history + 1] = hm
                for k in pairs(newKeys) do State.cache[k] = hm end
            end
        end
        if group then group.finish() end
        if alive(my) then setBusy(false) end
    end)
end

-- ---------- tool langsung dari UI (tanpa AI) ----------
local function runToolDirect(name, args)
    local card = addToolCard(name, args)
    task.spawn(function()
        local text = runTool(name, args)
        if not ScreenGui.Parent then return end
        finishToolCard(card, text)
        card.setExpanded(true)
        State.history[#State.history + 1] = { role = "user", content = "[INFO dari user - output tool " .. name .. "]\n" .. text }
    end)
end

-- ---------- submit ----------
local function submit()
    if State.busy then
        stopRun()
        return
    end
    local text = trim(TextBox.Text)
    if text == "" then return end
    TextBox.Text = ""
    if touch then TextBox:ReleaseFocus() end
    addUser(text)
    runAgent(text)
end
SendBtn.MouseButton1Click:Connect(submit)
track(TextBox.FocusLost:Connect(function(enter)
    if enter then submit() end
end))

-- label pendek di bubble, prompt lengkap tetap dikirim ke agent
local function quickPrompt(shortLabel, text)
    if State.busy then
        addSystem("Agent masih bekerja", "err")
        return
    end
    addUser(shortLabel)
    runAgent(text)
end

-- ---------- chips ----------
local function chip(iconName, text, ord, fn)
    local b = new("TextButton", {
        BackgroundColor3 = C.surface2, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 0, 26), Text = "",
        AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = ord,
    }, Chips)
    corner(b, 13)
    local sk = stroke(b, C.line, 1, 0.92)
    pad(b, 9, 0, 11, 0)
    hlist(b, 6)
    local o = { btn = b, stroke = sk }
    o.icon = mkIcon(b, iconName, 14, C.muted)
    o.icon.holder.LayoutOrder = 1
    o.lbl = new("TextLabel", {
        BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), Text = text, TextColor3 = C.text,
        Font = F.med, TextSize = fs(-1), LayoutOrder = 2,
    }, b)
    o.st = interactive(b, "BackgroundColor3", C.surface2, C.surface3, 0.94)
    b.MouseButton1Click:Connect(fn)
    return o
end

chip("map", "Pelajari", 1, function()
    quickPrompt("Pelajari game ini", "Pelajari game ini secara terstruktur: game_info, lalu list_remotes, find_scripts, find_interactables dan inspect_gui. Ringkas mekanik utama, remote penting, dan script relevan. Simpan temuan penting dengan note. Jangan menulis script dulu.")
end)
local SpyChip = chip("radar", "Spy", 2, function()
    if Spy.enabled then
        runToolDirect("remote_spy", { action = "stop" })
    else
        Spy.uiStart = true
        task.delay(3, function() Spy.uiStart = nil end)
        runToolDirect("remote_spy", { action = "start", all = true })
    end
end)
chip("list", "Log", 3, function()
    quickPrompt("Analisis log spy", "Analisis log remote spy: panggil remote_log (summary), lalu jelaskan fungsi tiap remote dan format argumennya BERDASARKAN DATA log saja. Tandai dugaan sebagai dugaan.")
end)
chip("user", "Status", 4, function() runToolDirect("get_player_status", {}) end)
chip("note", "Catatan", 5, function()
    if #State.notes == 0 then
        addSystem("Belum ada catatan")
    else
        local t = {}
        for i, n in ipairs(State.notes) do t[#t + 1] = i .. ". " .. n end
        addAgent("**Catatan**\n" .. table.concat(t, "\n"), true)
    end
end)

task.spawn(function()
    local last = nil
    while ScreenGui.Parent do
        local on = Spy.enabled
        SpyChip.lbl.Text = on and ("Spy  ·  " .. #Spy.log) or "Spy"
        if on ~= last then
            last = on
            ToggleIcon.tint(on and C.ok or C.muted, 0.3)   -- indikator spy saat chip terlipat
            local bg = on and Color3.fromRGB(24, 74, 58) or C.surface2
            SpyChip.st.normal = bg
            SpyChip.st.hover = on and Color3.fromRGB(30, 90, 70) or C.surface3
            tw(SpyChip.btn, { BackgroundColor3 = bg }, 0.3)
            SpyChip.icon.tint(on and C.ok or C.muted, 0.3)
            tw(SpyChip.stroke, { Color = on and C.ok or C.line, Transparency = on and 0.6 or 0.92 }, 0.3)
        end
        task.wait(0.6)
    end
end)

-- ---------- tombol header ----------
local clearArmed = false
local function armClear(on)
    clearArmed = on
    ClearIcon.rest = on and C.err or C.muted
    ClearSt.normal = on and 0.8 or 1
    ClearIcon.tint(ClearIcon.rest, 0.2)
    tw(ClearBtn, { BackgroundColor3 = on and C.err or C.surface3, BackgroundTransparency = ClearSt.normal }, 0.22)
end
ClearBtn.MouseButton1Click:Connect(function()
    if not clearArmed then
        armClear(true)
        task.delay(2, function()
            if clearArmed and ClearBtn.Parent then armClear(false) end
        end)
        return
    end
    armClear(false)
    if State.busy then stopRun() end
    for _, ch in ipairs(ChatScroll:GetChildren()) do
        if ch:IsA("Frame") then ch:Destroy() end
    end
    State.history = {}
    State.cache = {}
    addSystem("Percakapan dibersihkan", "ok")
end)

CloseBtn.MouseButton1Click:Connect(function()
    State.runId = State.runId + 1
    Spy.enabled = false
    tw(WinScale, { Scale = 0.9 }, 0.22, QUAD, IN).Completed:Connect(function(state) if state ~= Enum.PlaybackState.Completed then return end
        for _, c in ipairs(Conns) do pcall(function() c:Disconnect() end) end
        ScreenGui:Destroy()
    end)
end)

-- ---------- welcome (kartu ringkas, bukan paragraf) ----------
local function addWelcome()
    local w = wrapper(Enum.HorizontalAlignment.Center)
    local card = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y, BorderSizePixel = 0 }, w)
    pad(card, 0, 14, 0, 6)
    new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 10) }, card)

    local logo = new("Frame", { BackgroundColor3 = C.white, Size = UDim2.fromOffset(40, 40), BorderSizePixel = 0, LayoutOrder = 1 }, card)
    corner(logo, 14)
    grad(logo, C.accent, C.accent2, 35)
    center(mkIcon(logo, "logo", 20, C.white))
    new("TextLabel", {
        BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, FS + 6), Text = "Script Maker BETA", TextColor3 = C.text, Font = F.bold,
        TextSize = FS + 4, LayoutOrder = 2,
    }, card)
    new("TextLabel", {
        BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, FS), Text = "Deoxys Umbreon RE", TextColor3 = C.muted, Font = F.reg,
        TextSize = fs(-1), LayoutOrder = 3,
    }, card)

    local pills = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Y, LayoutOrder = 4 }, card)
    local pl = new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6),
        HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Top,
    }, pills)
    pcall(function() pl.Wraps = true end)
    local caps = {
        { "decompile", "Decompile" }, { "getgc", "GC scan" }, { "hookmetamethod", "Remote spy" },
        { "getconnections", "Connections" }, { "loadstring", "Run script" },
    }
    for i, c in ipairs(caps) do
        local on = capOn(c[1])
        local col = on and C.ok or C.muted
        local p = new("Frame", { BackgroundColor3 = col, BackgroundTransparency = 0.9, Size = UDim2.new(0, 0, 0, 26), AutomaticSize = Enum.AutomaticSize.X, BorderSizePixel = 0, LayoutOrder = i }, pills)
        corner(p, 13)
        pad(p, 9, 0, 11, 0)
        hlist(p, 5)
        local ic = mkIcon(p, on and "check" or "close", 11, col)
        ic.holder.LayoutOrder = 1
        new("TextLabel", {
            BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), Text = c[2], TextColor3 = col,
            Font = F.med, TextSize = fs(-2), LayoutOrder = 2,
        }, p)
    end

    if not Router.hasKey() then
        local b = new("TextButton", {
            BackgroundColor3 = C.warn, BackgroundTransparency = 0.88, Size = UDim2.new(0, 0, 0, 32), AutomaticSize = Enum.AutomaticSize.X,
            Text = "", AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = 5,
        }, card)
        corner(b, 16)
        pad(b, 12, 0, 14, 0)
        hlist(b, 7)
        local ic = mkIcon(b, "key", 14, C.warn)
        ic.holder.LayoutOrder = 1
        new("TextLabel", {
            BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), Text = "Isi API key", TextColor3 = C.warn,
            Font = F.semi, TextSize = fs(-1), LayoutOrder = 2,
        }, b)
        interactive(b, "BackgroundTransparency", 0.88, 0.76, 0.95)
        b.MouseButton1Click:Connect(openSettings)
    end
    fadeIn(w, 0.6)
end

refreshSub()
addWelcome()

-- animasi buka jendela
task.defer(function()
    tw(Window, { Position = homePos }, 0.6, QUINT)
    tw(WinScale, { Scale = 1 }, 0.6, BACK)
    tw(WinStroke, { Transparency = 0.9 }, 1.2)
end)
end

local okUI, errUI = pcall(buildDeoxysUI)
if not okUI then
    warn("[Deoxys] UI gagal dibuat: " .. tostring(errUI))
end
