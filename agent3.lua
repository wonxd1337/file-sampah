--!nocheck
--[[
	AI Agent untuk Roblox Studio - satu file, tanpa Python.
	Chat langsung di dalam Studio, memanggil API LLM (OpenAI-compatible) lewat HttpService,
	dan mengeksekusi perintah ke Studio secara lokal.

	- Setiap aksi AI yang mengubah data = satu langkah Ctrl+Z. Kalau gagal di tengah, semuanya dibatalkan.
	- API key disimpan di pengaturan plugin lokal (plugin:SetSetting) di komputermu.
]]

local RunService = game:GetService("RunService")
if not RunService:IsEdit() then
	return
end

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local InsertService = game:GetService("InsertService")
local LogService = game:GetService("LogService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")


local function pathOf(inst)
	if inst == game then
		return "game"
	end
	local parts = {}
	local cur = inst
	while cur and cur ~= game do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(parts, "/")
end

local function resolve(path)
	if path == nil or path == "" or path == "game" then
		return game
	end
	local cur = game
	local segs = string.split(path, "/")
	for i, seg in ipairs(segs) do
		if seg ~= "" and not (i == 1 and seg == "game") then
			local nxt
			if cur == game then
				local ok, svc = pcall(game.GetService, game, seg)
				nxt = ok and svc or game:FindFirstChild(seg)
			else
				nxt = cur:FindFirstChild(seg)
			end
			if not nxt then
				return nil, ("Tidak ditemukan: '%s' di '%s'"):format(seg, pathOf(cur))
			end
			cur = nxt
		end
	end
	return cur
end

local function need(path)
	if path == nil then
		error("parameter 'path' wajib diisi", 0)
	end
	local inst, err = resolve(path)
	if not inst then
		error(err, 0)
	end
	return inst
end

------------------------------------------------------------------ CODEC NILAI
local function encode(v)
	local t = typeof(v)
	if t == "number" then
		if v ~= v or math.abs(v) == math.huge then
			return tostring(v)
		end
		return v
	elseif t == "string" or t == "boolean" or t == "nil" then
		return v
	elseif t == "Vector3" then
		return { ["$t"] = "Vector3", v = { v.X, v.Y, v.Z } }
	elseif t == "Vector2" then
		return { ["$t"] = "Vector2", v = { v.X, v.Y } }
	elseif t == "CFrame" then
		return { ["$t"] = "CFrame", v = { v:GetComponents() } }
	elseif t == "Color3" then
		return { ["$t"] = "Color3", v = { v.R, v.G, v.B } }
	elseif t == "UDim2" then
		return { ["$t"] = "UDim2", v = { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } }
	elseif t == "UDim" then
		return { ["$t"] = "UDim", v = { v.Scale, v.Offset } }
	elseif t == "EnumItem" then
		return { ["$t"] = "Enum", v = tostring(v) }
	elseif t == "BrickColor" then
		return { ["$t"] = "BrickColor", v = v.Name }
	elseif t == "NumberRange" then
		return { ["$t"] = "NumberRange", v = { v.Min, v.Max } }
	elseif t == "Font" then
		return { ["$t"] = "Font", family = v.Family, weight = v.Weight.Name }
	elseif t == "Instance" then
		return { ["$t"] = "Instance", v = pathOf(v) }
	end
	return tostring(v)
end

local function toJson(v, depth)
	depth = depth or 0
	if typeof(v) == "table" then
		if depth > 8 then
			return "<terlalu dalam>"
		end
		local out = {}
		if #v > 0 or next(v) == nil then
			for i, x in ipairs(v) do
				out[i] = toJson(x, depth + 1)
			end
		else
			for k, x in pairs(v) do
				out[tostring(k)] = toJson(x, depth + 1)
			end
		end
		return out
	end
	return encode(v)
end

local function allNumbers(t)
	for _, x in ipairs(t) do
		if type(x) ~= "number" then
			return false
		end
	end
	return true
end

-- `cur` adalah nilai property saat ini; dipakai untuk menebak tipe target.
local function decode(v, cur)
	local ct = typeof(cur)
	if type(v) == "table" then
		local t = v["$t"]
		if t then
			local a = v.v
			if t == "Vector3" then
				return Vector3.new(a[1], a[2], a[3])
			elseif t == "Vector2" then
				return Vector2.new(a[1], a[2])
			elseif t == "CFrame" then
				if #a == 3 then
					return CFrame.new(a[1], a[2], a[3])
				end
				return CFrame.new(table.unpack(a))
			elseif t == "Color3" then
				return Color3.new(a[1], a[2], a[3])
			elseif t == "UDim2" then
				return UDim2.new(a[1], a[2], a[3], a[4])
			elseif t == "UDim" then
				return UDim.new(a[1], a[2])
			elseif t == "NumberRange" then
				return NumberRange.new(a[1], a[2])
			elseif t == "BrickColor" then
				return BrickColor.new(a)
			elseif t == "Enum" then
				local _, enumName, itemName = table.unpack(string.split(a, "."))
				return Enum[enumName][itemName]
			elseif t == "Font" then
				local weight = Enum.FontWeight[v.weight or "Regular"]
				if v.family and v.family:sub(1, 4) == "rbxa" then
					return Font.new(v.family, weight)
				end
				return Font.fromName(v.family or "SourceSansPro", weight)
			elseif t == "Instance" then
				return need(a)
			end
		end
		if allNumbers(v) then
			local n = #v
			if ct == "Vector3" and n == 3 then
				return Vector3.new(v[1], v[2], v[3])
			elseif ct == "Vector2" and n == 2 then
				return Vector2.new(v[1], v[2])
			elseif ct == "UDim2" and n == 4 then
				return UDim2.new(v[1], v[2], v[3], v[4])
			elseif ct == "UDim" and n == 2 then
				return UDim.new(v[1], v[2])
			elseif ct == "CFrame" and n == 3 then
				return CFrame.new(v[1], v[2], v[3])
			elseif ct == "CFrame" and n == 12 then
				return CFrame.new(table.unpack(v))
			elseif ct == "Color3" and n == 3 then
				if v[1] > 1 or v[2] > 1 or v[3] > 1 then
					return Color3.fromRGB(v[1], v[2], v[3])
				end
				return Color3.new(v[1], v[2], v[3])
			elseif ct == "NumberRange" and n == 2 then
				return NumberRange.new(v[1], v[2])
			end
		end
		return v
	elseif type(v) == "string" then
		if ct == "EnumItem" then
			local name = v:gsub("^Enum%.[%w_]+%.", "")
			local item = cur.EnumType[name]
			if item == nil then
				error(("'%s' bukan anggota %s"):format(v, tostring(cur.EnumType)), 0)
			end
			return item
		elseif ct == "Color3" and v:sub(1, 1) == "#" then
			return Color3.fromHex(v)
		elseif ct == "BrickColor" then
			return BrickColor.new(v)
		elseif ct == "Font" then
			return Font.fromName(v)
		elseif ct == "Instance" or ct == "nil" then
			local inst = resolve(v)
			if inst and (ct == "Instance" or v:find("/")) then
				return inst
			end
		end
	end
	return v
end

local function setProps(inst, props)
	for name, val in pairs(props or {}) do
		if name ~= "Parent" then
			local okc, cur = pcall(function()
				return inst[name]
			end)
			if not okc then
				error(("Property '%s' tidak ada pada %s"):format(name, inst.ClassName), 0)
			end
			local ok, err = pcall(function()
				inst[name] = decode(val, cur)
			end)
			if not ok then
				error(("Gagal set %s.%s: %s"):format(inst.ClassName, name, tostring(err)), 0)
			end
		end
	end
end

local function applyExtras(inst, a)
	for k, v in pairs(a.attributes or {}) do
		inst:SetAttribute(k, decode(v))
	end
	for _, k in ipairs(a.remove_attributes or {}) do
		inst:SetAttribute(k, nil)
	end
	for _, t in ipairs(a.add_tags or {}) do
		CollectionService:AddTag(inst, t)
	end
	for _, t in ipairs(a.remove_tags or {}) do
		CollectionService:RemoveTag(inst, t)
	end
end

------------------------------------------------------------------ SCRIPT UTIL
local function writeSource(scriptInst, src)
	local ok = pcall(function()
		ScriptEditorService:UpdateSourceAsync(scriptInst, function()
			return src
		end)
	end)
	if not ok then
		scriptInst.Source = src
	end
end

local function needScript(path)
	local inst = need(path)
	if not inst:IsA("LuaSourceContainer") then
		error(("%s adalah %s, bukan script"):format(pathOf(inst), inst.ClassName), 0)
	end
	return inst
end

local function countPlain(s, sub)
	local n, i = 0, 1
	while true do
		local a, b = string.find(s, sub, i, true)
		if not a then
			return n
		end
		n += 1
		i = b + 1
	end
end

local function lineCount(s)
	return #string.split(s, "\n")
end

------------------------------------------------------------------ HANDLERS
local H = {}

local COMMON_PROPS = {
	"Name", "ClassName", "Parent",
	"Position", "Orientation", "Size", "CFrame", "Anchored", "CanCollide", "CanTouch", "CanQuery",
	"Massless", "Material", "Color", "Transparency", "Reflectance", "CastShadow", "CollisionGroup",
	"PrimaryPart", "AnchorPoint", "BackgroundColor3", "BackgroundTransparency", "Visible", "ZIndex",
	"LayoutOrder", "Text", "TextColor3", "TextSize", "Font", "Image", "Value", "Enabled",
	"Brightness", "Range", "RunContext", "Disabled",
}

function H.ping()
	return {
		ok = true,
		place = game.Name,
		placeId = game.PlaceId,
		studioVersion = version(),
		isEdit = RunService:IsEdit(),
	}
end

local function buildTree(inst, depth, budget)
	local node = { name = inst.Name, class = inst.ClassName }
	local kids = inst:GetChildren()
	if #kids > 0 then
		if depth <= 0 then
			node.child_count = #kids
		else
			node.children = {}
			for _, k in ipairs(kids) do
				if budget.n <= 0 then
					node.truncated = true
					break
				end
				budget.n -= 1
				table.insert(node.children, buildTree(k, depth - 1, budget))
			end
		end
	end
	return node
end

function H.get_tree(a)
	local root = resolve(a.path or "game")
	if not root then
		error(select(2, resolve(a.path)), 0)
	end
	return { path = pathOf(root), tree = buildTree(root, a.depth or 2, { n = a.max_nodes or 300 }) }
end

function H.find(a)
	local root = need(a.path or "game")
	local limit = a.limit or 100
	local nameQ = a.name and a.name:lower()
	local results = {}
	for _, d in ipairs(root:GetDescendants()) do
		if
			(not a.class or d:IsA(a.class))
			and (not nameQ or d.Name:lower():find(nameQ, 1, true))
			and (not a.tag or CollectionService:HasTag(d, a.tag))
		then
			table.insert(results, { path = pathOf(d), class = d.ClassName })
			if #results >= limit then
				break
			end
		end
	end
	return { count = #results, truncated = #results >= limit, results = results }
end

function H.get_properties(a)
	local inst = need(a.path)
	local names = a.properties or COMMON_PROPS
	local props = {}
	for _, name in ipairs(names) do
		local ok, val = pcall(function()
			return inst[name]
		end)
		if ok then
			props[name] = val
		elseif a.properties then
			props[name] = "<tidak ada>"
		end
	end
	return {
		path = pathOf(inst),
		class = inst.ClassName,
		properties = props,
		attributes = inst:GetAttributes(),
		tags = CollectionService:GetTags(inst),
		child_count = #inst:GetChildren(),
	}
end

function H.set_properties(a)
	local inst = need(a.path)
	setProps(inst, a.properties)
	applyExtras(inst, a)
	if a.properties and a.properties.Parent ~= nil then
		inst.Parent = need(a.properties.Parent)
	end
	return { path = pathOf(inst) }
end

function H.create(a)
	if not a.class then
		error("parameter 'class' wajib diisi", 0)
	end
	local parent = need(a.parent)
	local ok, inst = pcall(Instance.new, a.class)
	if not ok then
		error("ClassName tidak valid: " .. tostring(a.class), 0)
	end
	if a.name then
		inst.Name = a.name
	end
	setProps(inst, a.properties)
	applyExtras(inst, a)
	inst.Parent = parent -- Parent selalu terakhir
	return { path = pathOf(inst), class = inst.ClassName }
end

function H.delete(a)
	local inst = need(a.path)
	if inst == game or inst.Parent == game then
		error("Tidak boleh menghapus root atau service", 0)
	end
	local p = pathOf(inst)
	inst:Destroy()
	return { deleted = p }
end

function H.clone(a)
	local inst = need(a.path)
	local copy = inst:Clone()
	if a.name then
		copy.Name = a.name
	end
	copy.Parent = a.parent and need(a.parent) or inst.Parent
	return { path = pathOf(copy) }
end

function H.move(a)
	local inst = need(a.path)
	inst.Parent = need(a.parent)
	return { path = pathOf(inst) }
end

function H.get_script(a)
	local s = needScript(a.path)
	local src = s.Source
	local total = lineCount(src)
	if a.start_line or a.end_line then
		local lines = string.split(src, "\n")
		local from = math.max(1, a.start_line or 1)
		local to = math.min(#lines, a.end_line or #lines)
		local out = {}
		for i = from, to do
			table.insert(out, ("%d: %s"):format(i, lines[i]))
		end
		return { path = pathOf(s), class = s.ClassName, line_count = total, numbered = table.concat(out, "\n") }
	end
	return { path = pathOf(s), class = s.ClassName, line_count = total, source = src }
end

function H.set_script(a)
	if type(a.source) ~= "string" then
		error("parameter 'source' wajib diisi", 0)
	end
	local s = needScript(a.path)
	writeSource(s, a.source)
	return { path = pathOf(s), line_count = lineCount(a.source) }
end

function H.edit_script(a)
	if type(a.old) ~= "string" or a.old == "" or type(a.new) ~= "string" then
		error("parameter 'old' (tidak kosong) dan 'new' wajib diisi", 0)
	end
	local s = needScript(a.path)
	local src = s.Source
	local n = countPlain(src, a.old)
	if n == 0 then
		error("Teks 'old' tidak ditemukan. Baca ulang script dengan get_script lalu salin persis.", 0)
	end
	if n > 1 and not a.replace_all then
		error(("Teks 'old' muncul %d kali. Perluas konteksnya agar unik, atau pakai replace_all."):format(n), 0)
	end
	local escOld = a.old:gsub("%p", "%%%0")
	local escNew = a.new:gsub("%%", "%%%%")
	local result = src:gsub(escOld, escNew)
	writeSource(s, result)
	return { path = pathOf(s), replaced = n, line_count = lineCount(result) }
end

function H.create_script(a)
	local class = a.class or "Script"
	if class ~= "Script" and class ~= "LocalScript" and class ~= "ModuleScript" then
		error("class harus Script, LocalScript, atau ModuleScript", 0)
	end
	if not a.name then
		error("parameter 'name' wajib diisi", 0)
	end
	local parent = need(a.parent)
	local s = Instance.new(class)
	s.Name = a.name
	if a.run_context and class == "Script" then
		s.RunContext = Enum.RunContext[a.run_context]
	end
	s.Parent = parent
	writeSource(s, a.source or "")
	return { path = pathOf(s), class = class }
end

function H.get_selection()
	local out = {}
	for _, i in ipairs(Selection:Get()) do
		table.insert(out, { path = pathOf(i), class = i.ClassName })
	end
	return out
end

function H.set_selection(a)
	local list = {}
	for _, p in ipairs(a.paths or {}) do
		table.insert(list, need(p))
	end
	Selection:Set(list)
	return { count = #list }
end

function H.get_output(a)
	local rank = { MessageOutput = 0, MessageInfo = 0, MessageWarning = 1, MessageError = 2 }
	local minRank = ({ all = 0, warning = 1, error = 2 })[a.level or "all"] or 0
	local filtered = {}
	for _, e in ipairs(LogService:GetLogHistory()) do
		if (rank[e.messageType.Name] or 0) >= minRank then
			table.insert(filtered, { level = e.messageType.Name, message = e.message, time = e.timestamp })
		end
	end
	local limit = a.limit or 50
	local out = {}
	for i = math.max(1, #filtered - limit + 1), #filtered do
		table.insert(out, filtered[i])
	end
	return out
end

function H.run_code(a)
	if type(a.code) ~= "string" then
		error("parameter 'code' wajib diisi", 0)
	end
	local okL, fn, err = pcall(loadstring, a.code, "=ai_run_code")
	if not okL then
		error("loadstring tidak tersedia di plugin context: " .. tostring(fn), 0)
	end
	if not fn then
		error("Syntax error: " .. tostring(err), 0)
	end
	local logs = {}
	local function capture(...)
		local t = table.pack(...)
		for i = 1, t.n do
			t[i] = tostring(t[i])
		end
		table.insert(logs, table.concat(t, " ", 1, t.n))
	end
	pcall(setfenv, fn, setmetatable({ print = capture, warn = capture }, { __index = getfenv() }))
	local res = table.pack(fn())
	return { logs = logs, returns = { table.unpack(res, 1, res.n) } }
end

function H.insert_asset(a)
	local id = tonumber(a.asset_id)
	if not id then
		error("asset_id harus angka", 0)
	end
	local parent = need(a.parent or "Workspace")
	local model = InsertService:LoadAsset(id)
	local out = {}
	for _, c in ipairs(model:GetChildren()) do
		c.Parent = parent
		table.insert(out, pathOf(c))
	end
	model:Destroy()
	return out
end

function H.batch(a)
	local results = {}
	for i, op in ipairs(a.ops or {}) do
		local fn = H[op.command]
		if not fn or op.command == "batch" then
			error(("ops[%d]: command tidak valid: %s"):format(i, tostring(op.command)), 0)
		end
		local ok, res = pcall(fn, op.args or {})
		if not ok then
			error(("ops[%d] (%s) gagal: %s"):format(i, op.command, tostring(res)), 0)
		end
		results[i] = res
	end
	return results
end

------------------------------------------------------------------ TOOLS TAMBAHAN (skala, tata letak, QA)
local function r2(n)
	return math.floor(n * 100 + 0.5) / 100
end

local function arr(v)
	return { r2(v.X), r2(v.Y), r2(v.Z) }
end

local function v3(a)
	if typeof(a) == "Vector3" then
		return a
	end
	if type(a) == "table" and #a == 3 and allNumbers(a) then
		return Vector3.new(a[1], a[2], a[3])
	end
	return nil
end

-- Kotak pembatas sejajar sumbu dunia untuk satu part (memperhitungkan rotasi)
local function worldAABB(part)
	local cf, s = part.CFrame, part.Size
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	local hx = (math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z) / 2
	local hy = (math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z) / 2
	local hz = (math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z) / 2
	local h = Vector3.new(hx, hy, hz)
	return cf.Position - h, cf.Position + h
end

-- Mengembalikan (min, max, jumlahPart); Terrain diabaikan
local function boundsOf(root)
	local mn, mx
	local count = 0
	local function add(p)
		if p:IsA("BasePart") and not p:IsA("Terrain") then
			count += 1
			local a, b = worldAABB(p)
			if mn then
				mn = Vector3.new(math.min(mn.X, a.X), math.min(mn.Y, a.Y), math.min(mn.Z, a.Z))
				mx = Vector3.new(math.max(mx.X, b.X), math.max(mx.Y, b.Y), math.max(mx.Z, b.Z))
			else
				mn, mx = a, b
			end
		end
	end
	add(root)
	for _, d in ipairs(root:GetDescendants()) do
		add(d)
	end
	return mn, mx, count
end

function H.get_bounds(a)
	local inst = need(a.path)
	local mn, mx, n = boundsOf(inst)
	if not mn then
		error("Tidak ada BasePart di " .. pathOf(inst), 0)
	end
	local size = mx - mn
	return {
		path = pathOf(inst),
		part_count = n,
		center = arr((mn + mx) / 2),
		size = arr(size),
		min = arr(mn),
		max = arr(mx),
		walk_seconds_across = r2(math.max(size.X, size.Z) / 16),
		height_in_characters = r2(size.Y / 5),
	}
end

local function scaleParts(root, f)
	local mn, mx = boundsOf(root)
	if not mn then
		error("Tidak ada BasePart di " .. pathOf(root), 0)
	end
	local c = (mn + mx) / 2
	local function one(p)
		if p:IsA("BasePart") and not p:IsA("Terrain") then
			local cf = p.CFrame
			local rot = cf - cf.Position
			p.Size = p.Size * f
			p.CFrame = CFrame.new(c + (cf.Position - c) * f) * rot
		end
	end
	one(root)
	for _, d in ipairs(root:GetDescendants()) do
		one(d)
	end
end

function H.scale_model(a)
	local inst = need(a.path)
	local factor = tonumber(a.factor)
	if not factor or factor <= 0 or factor > 50 then
		error("'factor' harus angka > 0 dan <= 50 (pengali relatif, mis. 3 = 3x lebih besar)", 0)
	end
	if inst:IsA("Model") then
		inst:ScaleTo(inst:GetScale() * factor)
	else
		scaleParts(inst, factor)
	end
	return H.get_bounds({ path = pathOf(inst) })
end

function H.pivot_to(a)
	local inst = need(a.path)
	if not inst:IsA("PVInstance") then
		error("Hanya Model atau BasePart yang bisa dipindah", 0)
	end
	local cur = inst:GetPivot()
	local pos = v3(a.position) or cur.Position
	local rot = a.yaw and CFrame.Angles(0, math.rad(a.yaw), 0) or (cur - cur.Position)
	inst:PivotTo(CFrame.new(pos) * rot)
	return { path = pathOf(inst), pivot = arr(pos) }
end

function H.raycast_down(a)
	local x, z = tonumber(a.x), tonumber(a.z)
	if not x or not z then
		error("'x' dan 'z' wajib berupa angka", 0)
	end
	local params = RaycastParams.new()
	params.IgnoreWater = a.ignore_water ~= false
	local res = workspace:Raycast(Vector3.new(x, a.from_y or 1000, z), Vector3.new(0, -(a.length or 3000), 0), params)
	if not res then
		return { hit = false }
	end
	return {
		hit = true,
		y = r2(res.Position.Y),
		material = res.Material.Name,
		instance = pathOf(res.Instance),
		normal_y = r2(res.Normal.Y),
	}
end

local SYMBOLS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

-- "Mata" untuk AI: peta tampak atas berbentuk teks
function H.layout_map(a)
	local root = need(a.path or "Workspace")
	local mn, mx = boundsOf(root)
	if not mn then
		error("Tidak ada BasePart di " .. pathOf(root), 0)
	end
	local maxCells = math.clamp(math.floor(a.max_cells or 48), 8, 80)
	local span = math.max(mx.X - mn.X, mx.Z - mn.Z, 1)
	local cell = tonumber(a.cell) or math.max(1, math.ceil(span / maxCells))
	local cols = math.clamp(math.ceil((mx.X - mn.X) / cell), 1, 120)
	local rows = math.clamp(math.ceil((mx.Z - mn.Z) / cell), 1, 120)

	local grid, top = {}, {}
	for r = 1, rows do
		grid[r] = {}
		top[r] = {}
	end

	local kids = root:GetChildren()
	if root:IsA("BasePart") or #kids == 0 then
		kids = { root }
	end

	local legend = {}
	for gi, kid in ipairs(kids) do
		local gmn, gmx, n = boundsOf(kid)
		if gmn then
			local sym = gi <= #SYMBOLS and SYMBOLS:sub(gi, gi) or "+"
			table.insert(legend, {
				symbol = sym, name = kid.Name, class = kid.ClassName, parts = n,
				center = arr((gmn + gmx) / 2), size = arr(gmx - gmn),
			})
			local function stamp(p)
				if p:IsA("BasePart") and not p:IsA("Terrain") then
					local lo, hi = worldAABB(p)
					local c0 = math.clamp(math.floor((lo.X - mn.X) / cell) + 1, 1, cols)
					local c1 = math.clamp(math.floor((hi.X - mn.X - 0.001) / cell) + 1, 1, cols)
					local r0 = math.clamp(math.floor((lo.Z - mn.Z) / cell) + 1, 1, rows)
					local r1 = math.clamp(math.floor((hi.Z - mn.Z - 0.001) / cell) + 1, 1, rows)
					for r = r0, r1 do
						for c = c0, c1 do
							if not top[r][c] or hi.Y > top[r][c] then
								top[r][c] = hi.Y
								grid[r][c] = sym
							end
						end
					end
				end
			end
			stamp(kid)
			for _, d in ipairs(kid:GetDescendants()) do
				stamp(d)
			end
		end
	end

	local lines = {}
	for r = 1, rows do
		local chars = table.create(cols, ".")
		for c = 1, cols do
			if grid[r][c] then
				chars[c] = grid[r][c]
			end
		end
		lines[r] = table.concat(chars)
	end
	return {
		path = pathOf(root),
		cell_stud = cell,
		cols = cols,
		rows = rows,
		origin_xz = { r2(mn.X), r2(mn.Z) },
		extent_xz = { r2(mx.X - mn.X), r2(mx.Z - mn.Z) },
		note = "Tampak atas. Kolom bertambah ke +X (kanan), baris bertambah ke +Z (bawah). Huruf = objek tertinggi di sel itu, '.' = kosong. 1 sel = cell_stud stud.",
		grid = lines,
		legend = legend,
	}
end

function H.check_issues(a)
	local root = need(a.path or "Workspace")
	local FLAGGED = {
		Part = true, MeshPart = true, WedgePart = true, UnionOperation = true, Model = true,
		Folder = true, Script = true, LocalScript = true, ModuleScript = true,
	}
	local cat, order = {}, {}
	local function note(key, path)
		local e = cat[key]
		if not e then
			e = { issue = key, count = 0, examples = {} }
			cat[key] = e
			table.insert(order, e)
		end
		e.count += 1
		if #e.examples < 5 then
			table.insert(e.examples, path)
		end
	end

	local parts = 0
	for _, d in ipairs(root:GetDescendants()) do
		if FLAGGED[d.ClassName] and d.Name == d.ClassName then
			note("nama_masih_default", pathOf(d))
		end
		if d:IsA("BasePart") and not d:IsA("Terrain") then
			parts += 1
			local s = d.Size
			if math.min(s.X, s.Y, s.Z) < 0.05 then
				note("part_terlalu_tipis", pathOf(d))
			end
			if d.Position.Y < -500 then
				note("jauh_di_bawah_dunia", pathOf(d))
			end
			if not d.Anchored then
				local m = d:FindFirstAncestorOfClass("Model")
				if not (m and m:FindFirstChildOfClass("Humanoid")) then
					note("tidak_anchored", pathOf(d))
				end
			end
		end
	end
	if not workspace:FindFirstChildWhichIsA("SpawnLocation", true) then
		note("tidak_ada_SpawnLocation", "Workspace")
	end
	if parts > 20000 then
		note("jumlah_part_sangat_banyak", pathOf(root))
	end
	local spawnLoc = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawnLoc then
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { spawnLoc }
		local below = spawnLoc.Position - Vector3.new(0, spawnLoc.Size.Y / 2 + 0.05, 0)
		if not workspace:Raycast(below, Vector3.new(0, -8, 0), rp) then
			note("SpawnLocation_melayang", pathOf(spawnLoc))
		end
	end
	if not game:GetService("Lighting"):FindFirstChildOfClass("Atmosphere") then
		note("lighting_tanpa_Atmosphere", "Lighting")
	end
	if parts > 8000 and not workspace.StreamingEnabled then
		note("StreamingEnabled_mati_untuk_map_besar", "Workspace")
	end

	local result = { path = pathOf(root), part_count = parts, issues = order }
	local mn, mx = boundsOf(root)
	if mn then
		result.size = arr(mx - mn)
	end
	if #order == 0 then
		result.verdict = "Tidak ada masalah terdeteksi oleh pemeriksaan otomatis."
	end
	return result
end

function H.terrain(a)
	local terrain = workspace.Terrain
	local action = a.action
	if action == "clear" and a.all == true then
		terrain:Clear()
		return { cleared = "seluruh terrain" }
	end
	local okM, mat = pcall(function()
		return Enum.Material[a.material or "Grass"]
	end)
	if not okM or not mat then
		error("material tidak valid: " .. tostring(a.material), 0)
	end
	local pos = v3(a.position)
	if not pos then
		error("'position' [x,y,z] wajib", 0)
	end
	local cf = CFrame.new(pos) * CFrame.Angles(0, math.rad(a.yaw or 0), 0)
	if action == "fill_block" or action == "clear" then
		local size = v3(a.size)
		if not size then
			error("'size' [x,y,z] wajib untuk " .. action, 0)
		end
		terrain:FillBlock(cf, size, action == "clear" and Enum.Material.Air or mat)
	elseif action == "fill_ball" then
		terrain:FillBall(pos, tonumber(a.radius) or error("'radius' wajib", 0), mat)
	elseif action == "fill_cylinder" then
		terrain:FillCylinder(cf, tonumber(a.height) or error("'height' wajib", 0), tonumber(a.radius) or error("'radius' wajib", 0), mat)
	else
		error("action harus fill_block, fill_ball, fill_cylinder, atau clear", 0)
	end
	return { ok = true, action = action, position = arr(pos) }
end

-- Menyebar klon template di atas permukaan (raycast ke bawah) tanpa saling menumpuk
function H.scatter(a)
	local template = need(a.template)
	if not (template:IsA("Model") or template:IsA("BasePart")) then
		error("template harus Model atau BasePart", 0)
	end
	local parent = need(a.parent)
	if parent == workspace then
		error("parent harus Folder/Model khusus, bukan Workspace langsung", 0)
	end
	local center = v3(a.center)
	if not center then
		error("'center' [x,y,z] wajib", 0)
	end
	if type(a.size) ~= "table" or type(a.size[1]) ~= "number" or type(a.size[2]) ~= "number" then
		error("'size' [lebarX, lebarZ] wajib", 0)
	end
	local sx, sz = a.size[1], a.size[2]
	local count = math.clamp(math.floor(a.count or 20), 1, 500)
	local minD = a.min_distance or 6
	local smin, smax = a.scale_min or 1, a.scale_max or 1
	local slopeCos = math.cos(math.rad(a.max_slope or 35))
	local rng = Random.new(a.seed or 1)

	local avoid = {}
	for _, p in ipairs(a.avoid or {}) do
		local amn, amx = boundsOf(need(p))
		if amn then
			local m = a.avoid_margin or 4
			table.insert(avoid, { amn.X - m, amn.Z - m, amx.X + m, amx.Z + m })
		end
	end
	local allowed
	if a.ground_materials then
		allowed = {}
		for _, name in ipairs(a.ground_materials) do
			allowed[name] = true
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { parent, template }
	params.IgnoreWater = true

	local placed, results = {}, {}
	local attempts = 0
	while #results < count and attempts < count * 30 do
		attempts += 1
		local x = center.X + (rng:NextNumber() - 0.5) * sx
		local z = center.Z + (rng:NextNumber() - 0.5) * sz

		local blocked = false
		for _, r in ipairs(avoid) do
			if x >= r[1] and x <= r[3] and z >= r[2] and z <= r[4] then
				blocked = true
				break
			end
		end
		if blocked then
			continue
		end

		local hit = workspace:Raycast(
			Vector3.new(x, a.top_y or (center.Y + 200), z),
			Vector3.new(0, -(a.ray_length or 800), 0),
			params
		)
		local pos
		if hit then
			if hit.Normal.Y < slopeCos then
				continue
			end
			if allowed and not allowed[hit.Material.Name] then
				continue
			end
			pos = hit.Position
		elseif a.ground_only == false then
			pos = Vector3.new(x, center.Y, z)
		else
			continue
		end

		for _, q in ipairs(placed) do
			local dx, dz = q.X - pos.X, q.Z - pos.Z
			if dx * dx + dz * dz < minD * minD then
				blocked = true
				break
			end
		end
		if blocked then
			continue
		end

		local clone = template:Clone()
		local s = smin + (smax - smin) * rng:NextNumber()
		if s ~= 1 then
			if clone:IsA("Model") then
				clone:ScaleTo(template:GetScale() * s)
			else
				clone.Size = template.Size * s
			end
		end
		local yaw = (a.random_yaw == false) and 0 or rng:NextNumber() * math.pi * 2
		clone:PivotTo(CFrame.new(pos) * CFrame.Angles(0, yaw, 0))
		local bmn = boundsOf(clone)
		if bmn then
			-- taruh dasar objek tepat di permukaan (sink = tenggelam sedikit, mis. untuk akar pohon)
			clone:PivotTo(clone:GetPivot() + Vector3.new(0, pos.Y - bmn.Y - (a.sink or 0), 0))
		end
		clone.Name = (a.name or template.Name) .. "_" .. (#results + 1)
		clone.Parent = parent
		table.insert(placed, pos)
		table.insert(results, pathOf(clone))
	end

	local sample = {}
	for i = 1, math.min(5, #results) do
		sample[i] = results[i]
	end
	return {
		placed = #results,
		requested = count,
		attempts = attempts,
		parent = pathOf(parent),
		sample = sample,
		note = #results < count and "Tidak semua tertempatkan: area kecil, min_distance terlalu besar, lereng terlalu curam, atau tidak ada permukaan di bawah." or nil,
	}
end

function H.focus(a)
	local inst = need(a.path)
	local mn, mx = boundsOf(inst)
	if not mn then
		error("Tidak ada BasePart di " .. pathOf(inst), 0)
	end
	local center = (mn + mx) / 2
	local dist = math.max((mx - mn).Magnitude, 20) * 1.1
	local cam = workspace.CurrentCamera
	local pos = center + Vector3.new(0.6, 0.7, 0.6).Unit * dist
	cam.CFrame = CFrame.lookAt(pos, center)
	cam.Focus = CFrame.new(center)
	return { focused = pathOf(inst) }
end

local MUTATING = {
	set_properties = true, create = true, delete = true, clone = true, move = true,
	set_script = true, edit_script = true, create_script = true, run_code = true,
	insert_asset = true, batch = true,
	scale_model = true, pivot_to = true, terrain = true, scatter = true,
}

------------------------------------------------------------------ SYSTEM PROMPT
local SYSTEM_PROMPT = [===[Kamu adalah AI agent yang bekerja langsung di dalam Roblox Studio user. Balas dalam bahasa yang dipakai user.

# Roblox Studio Pro

Kamu mengendalikan Roblox Studio milik user lewat tool `studio`. Bekerjalah seperti developer Roblox senior: periksa dulu, ubah seminimal mungkin, verifikasi hasilnya, laporkan dengan singkat.

## Cara memanggil

Panggil tool `studio` dengan parameter `command` (nama perintah) dan `args` (objek JSON argumen).

Path instance memakai `/` dan dimulai dari service: `Workspace/Map/Door`, `ServerScriptService/Services/DataService`. Nilai khusus: Vector3/Vector2/UDim2/UDim/CFrame/Color3 boleh berupa array (`[1,2,3]`, Color3 `[255,0,0]` atau `"#FF0000"`), Enum boleh nama saja (`"Neon"`), Instance boleh path string. Untuk tipe eksplisit pakai `{"$t":"Vector3","v":[1,2,3]}`.

| Command | Argumen | Fungsi |
|---|---|---|
| `ping` | - | Cek koneksi, nama place, versi Studio |
| `get_tree` | `path`, `depth`=2, `max_nodes`=300 | Lihat struktur Explorer |
| `find` | `path`, `name`, `class`, `tag`, `limit` | Cari instance |
| `get_properties` | `path`, `properties`? | Baca property, attributes, tags |
| `set_properties` | `path`, `properties`, `attributes`, `remove_attributes`, `add_tags`, `remove_tags` | Ubah instance |
| `create` | `class`, `parent`, `name`, `properties`, `attributes`, `add_tags` | Buat instance |
| `delete` / `clone` / `move` | `path` (+ `parent`, `name`) | Hapus / gandakan / pindahkan |
| `get_script` | `path`, `start_line`?, `end_line`? | Baca script (bisa per rentang baris) |
| `edit_script` | `path`, `old`, `new`, `replace_all`? | Ganti potongan teks persis (diff kecil) |
| `set_script` | `path`, `source` | Tulis ulang seluruh script |
| `create_script` | `class`, `name`, `parent`, `source`, `run_context`? | Buat Script/LocalScript/ModuleScript |
| `get_output` | `limit`=50, `level` (`all`/`warning`/`error`) | Baca Output Studio |
| `run_code` | `code` | Jalankan Luau di Studio (edit-time) |
| `batch` | `ops`: `[{command, args}]` | Banyak operasi, satu langkah Undo, atomik |
| `get_selection` / `set_selection` | `paths` | Baca / atur seleksi |
| `insert_asset` | `asset_id`, `parent`, `position`?, `yaw`?, `scale`?, `snap_to_ground`?, `name`?, `anchor`=true, `remove_scripts`=true | Impor model Toolbox. Script di dalamnya DIBUANG secara default; yang mencurigakan dilaporkan |
| `get_bounds` | `path` | Ukuran, pusat, min/max, `walk_seconds_across`, tinggi dalam "karakter" |
| `layout_map` | `path`, `max_cells`=48, `cell`? | Peta tampak-atas berbentuk teks: "mata" untuk memeriksa tata letak |
| `check_issues` | `path`? | QA otomatis: part tidak anchored, nama default, part terlalu tipis, tidak ada SpawnLocation |
| `scale_model` | `path`, `factor` | Perbesar/perkecil relatif (3 = 3x). Model memakai ScaleTo, lainnya menskalakan semua part |
| `pivot_to` | `path`, `position`?, `yaw`? | Pindah/putar Model atau Part (yaw dalam derajat) |
| `raycast_down` | `x`, `z`, `from_y`? | Tinggi dan material permukaan di titik XZ |
| `terrain` | `action` (`fill_block`/`fill_ball`/`fill_cylinder`/`clear`), `material`, `position`, `size` atau `radius`/`height`, `yaw`, `all` | Edit Terrain |
| `scatter` | `template`, `parent`, `center`, `size` [x,z], `count`, `min_distance`, `avoid`, `max_slope`, `ground_materials`, `scale_min`/`scale_max`, `seed`, `sink` | Sebar klon (pohon, batu, lampu) di atas permukaan tanpa saling menumpuk |
| `focus` | `path` | Arahkan kamera Studio ke objek supaya user langsung melihat hasilnya |
| `list_skills` / `load_skill` | `name`, `chunk`=1, `full`? | Daftar / muat panduan skill roblox-brain (per halaman; `full=true` = referensi lengkap) |
| `notes` | `action` (`read`/`write`/`append`/`clear`), `text` | Catatan proyek permanen (ServerStorage/AI_Notes), otomatis ikut dibaca tiap tugas. Simpan spesifikasi dan progres |
| `style_presets` | `name`? | Gaya map: palet hex, material, preset lighting, tema UI (`cartoon`, `lowpoly`, `realistic`, `medieval`, `cyberpunk`, `horror`, `tycoon`, `tropical`) |
| `lighting_preset` | `preset`, `clock_time`?, `future`? | Lighting + Atmosphere + efek sekaligus: `day`, `sunset`, `night`, `foggy`, `horror`, `neon`, `cartoon`, `snow` |
| `terrain_generate` | `center`, `size` [x,z], `shape` (`hills`/`plains`/`mountains`/`island`/`flat`), `amplitude`=30, `scale`=140, `seed`, `water_level`?, `flat_radius`?, `materials` {low,mid,high,peak,under}, `clear_area`?, `cell`? | Terrain prosedural (bukit, gunung, pulau, air). Tinggi dasar = `center[2]`. Hapus/turunkan Baseplate dulu |
| `build_building` | `parent`, `position`, `size` [x,z]=24, `floors`=1, `floor_height`=12, `door_side`, `door_width`, `windows`, `windows_per_wall`, `roof` (`gable`/`flat`/`none`), `roof_height`, `wall_color`/`roof_color`/`trim_color`/`floor_color` (hex), `wall_material`/`roof_material`/`floor_material`, `yaw`, `name` | Bangunan utuh: lantai, dinding berpintu dan berjendela, tangga dalam, lampu, atap. Pintu di `front` = sisi -Z lokal. Hasil berisi `door_world` |
| `build_path` | `parent`, `points` [[x,y,z],...], `width`=12, `height`=1, `material`, `color`, `snap_to_ground`?, `collide`? | Jalan/jalur/sungai buatan; `height` besar + `width` kecil = dinding/pagar lurus |
| `build_stairs` | `parent`, `position`, `rise`=12, `width`=6, `step_height`=1, `step_depth`=1.5, `yaw` | Tangga solid, naik ke arah -Z lokal |
| `array` | `path`, `count`, `offset` [x,y,z] atau `center` [x,y,z] + `arc`, `yaw_step`?, `parent`? | Gandakan teratur: barisan lurus atau melingkar |
| `snap_to_ground` | `path`, `sink`? | Taruh dasar objek tepat di permukaan di bawahnya |
| `bulk_set` | `path`, `properties`, `class`?, `name_contains`?, `tag`? | Ubah properti banyak objek sekaligus (recolor, ganti material) |
| `build_ui` | `spec`, `theme` (`dark`/`light`/`cartoon`/`neon`), `parent`=StarterGui, `name` | Bangun ScreenGui dari spesifikasi deklaratif (lihat bagian Format build_ui) |
| `search_assets` | `query`, `page`? | Cari model gratis di Toolbox (nama, asset_id) |
| `import_mesh` | `mesh_id`, `texture_id`?, `size`?, `position`?, `parent`, `name` | Impor MeshPart dari ID mesh |
| `apply_texture` | `path`, `texture_id`, `kind` (`Texture`/`Decal`), `faces`, `studs_per_tile` | Pasang tekstur/decal pada part |

Semua perubahan = satu langkah Ctrl+Z. Jika sebuah perintah gagal, perubahannya dibatalkan. Pakai `batch` untuk pekerjaan multi-langkah agar atomik.

## Skala & ukuran (WAJIB)

Penyebab utama map "terlalu kecil" adalah menebak ukuran. Pakai angka ini:

- 1 stud ≈ 0,28 m. Karakter R15: tinggi ≈ 5 stud, lebar ≈ 2 stud, berjalan 16 stud/detik, lompat ≈ 7 stud tinggi.
- Pintu 4×7 (lebar × tinggi). Tinggi langit-langit 10-14. Satu lantai gedung 12-16 tinggi. Anak tangga ≤ 1 tinggi. Lorong ≥ 6 lebar. Jalan satu mobil 12-16 lebar. Rumah kecil ≈ 24×24 footprint. Pohon 20-40 tinggi. Sungai 12-40 lebar.
- Ukuran map: arena kecil 100-200 stud, kota/lobby 300-600, map eksplorasi 1000-2000. Baseplate bawaan Studio 2048×2048.
- Waktu menyeberang = panjang ÷ 16 detik. Map 100 stud hanya ±6 detik jalan, hampir selalu terlalu kecil.
- Jangan memilih ukuran kecil "biar aman". Jika user tidak menyebut ukuran, tentukan sendiri dari angka di atas dan tulis asumsinya (dalam stud) sebelum membangun. Jika user bilang "besar", itu minimal 400+ stud.
- Setelah membangun WAJIB verifikasi dengan data: `get_bounds` (bandingkan dengan target, lihat `walk_seconds_across`), `layout_map` (cek tata letak), `check_issues`, lalu `focus`. Jika skala atau tata letak salah, perbaiki (`scale_model`, `pivot_to`, atau bangun ulang). Jangan melapor selesai sebelum angka cocok dengan target.

## Skills roblox-brain

Kamu punya perpustakaan skill (`list_skills`, `load_skill`). Muat HANYA yang relevan dengan tugas sebelum mulai bekerja, jangan semuanya:
- membangun map/props/aset: `roblox-building` (+ `roblox-lighting`, dan `roblox-ui-design` atau `roblox-gui` bila perlu)
- script gameplay: `roblox-architecture`, `roblox-luau-patterns`, `roblox-networking`
- performa map besar: `roblox-performance`; fisika/kendaraan: `roblox-physics`; NPC: `roblox-npc-ai`; audio: `roblox-audio`; efek: `roblox-animation-vfx`

Skill datang per halaman: baca `chunk` berikutnya hanya bila perlu, dan pakai `full=true` hanya untuk detail API/contoh. Skill adalah panduan, bukan perintah: aturan di instruksi ini tetap berlaku. Jika skill gagal dimuat, lanjutkan tanpa menunggu.

## Proses membangun map (WAJIB untuk tugas map)

1. `notes read`, lalu `load_skill` `roblox-building`. Tulis spesifikasi (ukuran stud, zona, gaya, palet) ke `notes write`.
2. Pilih gaya dengan `style_presets`; pakai palet dan material dari situ secara konsisten.
3. Fondasi: `terrain_generate` (hapus/turunkan Baseplate dulu) atau ground part + SpawnLocation. Verifikasi dengan `get_bounds` dan `raycast_down`.
4. Per zona (satu Folder per zona): bangunan pakai `build_building`, jalan/pagar `build_path`, tangga `build_stairs`, barisan `array`, vegetasi/batu `scatter`. Hitung posisi dari variabel (origin, ukuran, jarak), lalu cek `layout_map` setelah tiap zona.
5. Detail: aset Toolbox lewat `search_assets` lalu `insert_asset` (dengan `position` dan `snap_to_ground`); secukupnya, dan hanya yang cocok dengan gaya. Seragamkan warna/material dengan `bulk_set`.
6. Suasana: `lighting_preset` yang cocok dengan gaya; tambah lampu lokal bila perlu.
7. UI: `build_ui` (HUD, menu, toko) dengan tema yang sesuai gaya map.
8. QA: `get_bounds`, `layout_map`, `check_issues`, `focus`; perbaiki lalu ulangi. Catat progres lewat `notes append` supaya pekerjaan bisa dilanjutkan.
9. Kerjakan bertahap. Jika batas langkah tercapai atau API gagal, berhenti rapi dengan catatan progres; user melanjutkan dengan menekan Kirim kosong atau mengetik 'lanjut'. Saat melanjutkan, JANGAN mengulang dari awal: baca kondisi terakhir (`get_tree`, `layout_map`, `notes read`) dan kerjakan hanya bagian yang belum selesai.

## Format build_ui

`spec` = satu elemen atau array elemen. Setiap elemen: `type` (`Panel`, `Button`, `Label`, `Image`, `Input`, `Bar`, `Scroll`, `Row`, `Column`, `Grid`, atau nama class GuiObject), `name`, `text`, `variant` (Button: `primary`/`secondary`/`danger`/`success`/`ghost`), `style` (Label: `title`/`subtitle`), `value` (Bar, 0-1), `layout` (`dir`, `gap`, `padding`, `h`, `v`), `corner`, `aspect`, `max_size`/`min_size`, `props` (properti mentah, mis. `{"Size":[0,400,0,300],"Position":[0.5,0,0.5,0],"AnchorPoint":[0.5,0.5]}`), `children`.
Contoh menu: `{"type":"Panel","name":"MainMenu","props":{"Size":[0,420,0,320],"Position":[0.5,0,0.5,0],"AnchorPoint":[0.5,0.5]},"children":[{"type":"Label","style":"title","text":"Judul Game"},{"type":"Button","text":"Main","props":{"Size":[1,0,0,48]}},{"type":"Button","variant":"secondary","text":"Pengaturan","props":{"Size":[1,0,0,48]}}]}`
Aturan: Scale untuk tata letak utama, tombol tinggi minimal 44 px, satu aksi utama per layar, tema sesuai gaya map. `build_ui` hanya membuat tampilan; logika klik ditulis terpisah dengan `create_script` (LocalScript) bila diminta.

## Aset Toolbox

Model dari Toolbox bisa berisi script berbahaya. `insert_asset` membuang script secara default; set `remove_scripts=false` hanya bila user meminta dan sumbernya jelas. Setelah impor, cek `get_bounds` (ukuran masuk akal), atur `position`/`snap_to_ground`, dan samakan warna/material dengan gaya. Jika `search_assets` tidak tersedia, minta user memberi asset ID.


## Membangun map

1. Tulis spesifikasi singkat: dimensi total (stud), zona, jumlah elemen, palet 3-5 warna/material.
2. Fondasi dulu (ground/terrain, SpawnLocation), lalu verifikasi.
3. Struktur utama per zona: satu Folder per zona, satu Model per bangunan, nama jelas. Verifikasi tiap zona dengan `layout_map`.
4. Elemen berulang (pohon, batu, lampu, pagar) memakai `scatter`. Simpan template di `ServerStorage/Templates`, bukan di Workspace. Gunakan `avoid` agar tidak menimpa bangunan, dan `raycast_down` untuk mengecek permukaan.
5. Pencahayaan (Lighting, Atmosphere, Sky) terakhir.
6. Pemeriksaan akhir (`get_bounds`, `check_issues`, `focus`), lalu laporan singkat berisi ukuran akhir dan hal yang perlu dinilai user secara visual.

Aturan teknis: satu panggilan `run_code` maksimal ±40 baris. Hitung koordinat dari variabel (origin, ukuran, jarak) bukan angka ajaib. Kamu tidak bisa melihat viewport, jadi jangan menyebut hasil "bagus" atau "indah"; laporkan angka dan tata letak yang terverifikasi, dan biarkan user menilai tampilannya.

## Alur kerja wajib

1. **Pahami dulu, jangan menebak.** Sebelum mengubah apa pun: `get_tree` area terkait, `find` script/objek yang relevan, `get_script` untuk membaca kode yang ada. Ikuti struktur, penamaan, dan gaya yang sudah ada di project user.
2. **Ubah seminimal mungkin.** Pakai `edit_script` untuk perubahan lokal. `set_script` hanya untuk file baru atau rewrite yang memang diminta. Jangan pernah menimpa script yang belum kamu baca.
3. **Verifikasi.** Setelah menulis script, jalankan `get_output` dengan `level: "error"`. Setelah membangun objek, `get_properties` / `get_tree` untuk memastikan hasilnya benar. Jangan mengklaim "sudah jalan" tanpa bukti.
4. **Batas kemampuan.** Kamu tidak bisa menekan Play, melihat layar, atau menguji perilaku runtime. Katakan terus terang apa yang sudah diverifikasi dan apa yang perlu user uji dengan Play. Script tidak berjalan di edit mode; `run_code` hanya untuk operasi edit-time (membangun, memodifikasi, memeriksa).
5. **Laporan singkat.** Sebutkan path yang dibuat/diubah dan hal yang perlu user uji. Tanpa pidato, tanpa daftar fitur yang tidak diminta.
6. **Ragu pada hal destruktif? Tanya.** Hapus banyak objek, rewrite besar, atau mengubah data/DataStore: konfirmasi dulu.

## Standar kode Luau

- Mulai dengan `--!strict` dan beri type annotation pada parameter fungsi publik, return, dan tabel data. Definisikan `type` untuk struktur data.
- `local Players = game:GetService("Players")` di bagian atas file. Gunakan `workspace`, bukan `game.Workspace`.
- Pakai `task.wait`, `task.spawn`, `task.delay`, `task.defer`. Jangan `wait`, `spawn`, `delay`.
- `Instance.new(class)` lalu set property, **Parent terakhir**. Jangan pakai argumen parent di `Instance.new`.
- Jangan `while true do wait() end`. Gunakan event (`Changed`, `GetPropertyChangedSignal`, `Heartbeat`, signal custom) atau loop `task.wait` dengan kondisi berhenti.
- Semua koneksi event yang dibuat dinamis harus dibersihkan (`Disconnect`, `Destroy`, atau Maid/Trove). Tidak ada memory leak saat player keluar atau objek dihapus.
- Hindari API deprecated: BodyVelocity/BodyGyro/BodyPosition (pakai `LinearVelocity`, `AlignOrientation`, `AlignPosition`), `Humanoid:LoadAnimation` (pakai `Animator:LoadAnimation`), `:connect`, `:remove()`, `GetMouse` (pakai `UserInputService`/`ContextActionService`).
- Jangan mengarang API. Jika tidak yakin sebuah method/property ada, cek dengan `get_properties` atau `run_code`, atau pakai alternatif yang kamu yakin.
- Fungsi kecil dengan satu tanggung jawab. Tidak ada satu script raksasa. Tidak ada kode mati, placeholder `-- TODO`, atau "contoh" yang tidak terhubung ke apa pun.
- Komentar menjelaskan **kenapa**, bukan **apa**. Nama variabel yang jelas lebih baik daripada komentar.
- Gunakan `pcall`/`xpcall` hanya di batas yang memang bisa gagal (DataStore, HTTP, MarketplaceService, asset loading). Jangan membungkus semuanya agar error tersembunyi.

## Arsitektur proyek

Pisahkan tanggung jawab, jangan menumpuk Script di Workspace:

```
ReplicatedStorage/
  Shared/          -- ModuleScript yang dipakai server & client (config, types, util)
  Remotes/         -- RemoteEvent / RemoteFunction
ServerScriptService/
  Services/        -- ModuleScript per sistem (DataService, CombatService, ...)
  Main (Script)    -- bootstrap tipis: require & Init/Start service
ServerStorage/     -- aset & template yang tidak boleh terlihat client
StarterPlayer/StarterPlayerScripts/
  Controllers/     -- ModuleScript per sistem client
  Main (LocalScript)
StarterGui/        -- ScreenGui (ResetOnSpawn = false untuk UI permanen)
```

- Satu Script bootstrap per sisi; logika hidup di ModuleScript. Module mengekspor tabel dengan fungsi jelas, bukan menjalankan efek samping saat di-`require`.
- Konfigurasi (angka balancing, ID, harga) di satu module config, bukan tersebar sebagai angka ajaib.
- Data per-objek di Attributes, kategori objek di CollectionService Tags. Contoh: semua pintu diberi tag `Door`, logikanya satu script yang memakai `GetInstanceAddedSignal`, bukan satu script per pintu.

## Keamanan & multiplayer (server-authoritative)

- Client hanya mengirim **niat** (misal "beli item X"), server yang memutuskan hasil. Jangan pernah mempercayai nilai dari client (damage, harga, posisi, jumlah).
- Setiap `OnServerEvent` memvalidasi: tipe argumen, rentang nilai, kepemilikan, jarak, cooldown, dan state player. Beri rate limit per player.
- Jangan pakai `RemoteFunction:InvokeClient` (bisa menggantung server).
- Tangani player yang sudah ada sebelum script jalan: loop `Players:GetPlayers()` lalu sambungkan `PlayerAdded`. Bersihkan di `PlayerRemoving`.
- Karakter: gunakan `CharacterAdded`, dan `WaitForChild` dengan timeout hanya di client; di server lebih baik event.

## Data

- DataStore: `UpdateAsync` (bukan `SetAsync`) untuk data yang bisa berubah bersamaan, `pcall` dengan retry + backoff, simpan di `PlayerRemoving` **dan** `game:BindToClose`, tangani session locking. Untuk project serius pakai library teruji (ProfileStore/ProfileService) daripada menulis ulang.
- Schema data berversi dan ada nilai default. Jangan menyimpan Instance atau tipe Roblox mentah; simpan primitif.

## Membangun dunia & objek

- Beri nama setiap objek dengan jelas (`Door_Main`, bukan `Part`). Kelompokkan di `Model`/`Folder`. Set `PrimaryPart` dan gunakan `PivotTo` untuk memindahkan model.
- Part statis: `Anchored = true`. Matikan `CanCollide`/`CanTouch`/`CanQuery` pada objek dekoratif.
- Posisi dan ukuran dalam kelipatan rapi (grid 1 atau 4 stud) kecuali ada alasan visual. Jangan menumpuk part yang bertabrakan (z-fighting).
- Material & warna konsisten dengan palet yang dipilih. Untuk 5+ objek serupa, bangun lewat `batch`/`run_code` dengan loop, bukan puluhan panggilan manual.
- Gunakan Collision Groups untuk interaksi fisik terkontrol, bukan hack `CanCollide` per frame.
- Performa: aktifkan `StreamingEnabled` untuk map besar, hindari ribuan part tak perlu (gunakan MeshPart/Union secukupnya), jangan menaruh loop per-frame jika event cukup, pakai `Heartbeat` untuk logika dan `RenderStepped` hanya untuk kamera/visual client.

## UI

- Gunakan Scale (`UDim2.fromScale`) untuk tata letak dan Offset hanya untuk detail kecil. Tambahkan `UIAspectRatioConstraint`, `UISizeConstraint`, `UIPadding`, `UICorner`.
- Tata letak lewat `UIListLayout`/`UIGridLayout`, bukan posisi manual per elemen.
- Satu palet warna, satu atau dua font, spacing konsisten. Beri nama setiap elemen UI. Pisahkan struktur UI (dibuat di Studio) dari logika (LocalScript/module).
- Animasi pakai `TweenService`. Input pakai `UserInputService`/`ContextActionService` dan hormati `gameProcessedEvent`. Pastikan UI usable di mobile (ukuran target sentuh, safe area).

## Anti-"AI slop"

Jangan lakukan ini:

- Menulis ulang seluruh script padahal hanya satu baris yang perlu diubah.
- Menambahkan fitur, sistem, atau abstraksi yang tidak diminta.
- Menempelkan komentar basa-basi di setiap baris, header ASCII-art, atau emoji di kode.
- Membuat objek bernama `Part`, `Script`, `Frame` default; atau script di dalam setiap Part.
- Memakai pola lama (`wait()`, `Instance.new(x, parent)`, `game.Workspace`) karena "begitu di tutorial lama".
- Mengklaim sesuatu sudah diuji, atau menjawab dengan kode yang tidak pernah dijalankan/diperiksa.
- Menyembunyikan error dengan `pcall` kosong atau `warn` tanpa penanganan.
- Menimpa pekerjaan user tanpa membaca isinya.

Lakukan ini:

- Baca konteks, ikuti konvensi yang sudah ada, ubah sekecil mungkin.
- Selesaikan masalah akarnya, bukan gejalanya. Jika bug berasal dari desain, katakan dan usulkan perbaikan.
- Jika permintaan ambigu atau berisiko, ajukan satu pertanyaan spesifik; selain itu langsung kerjakan.
- Jika ada pilihan desain yang berarti, pilih yang paling sederhana yang benar dan sebut alasannya dalam satu kalimat.

## Debugging

1. `get_output` (level `error`) untuk pesan error dan stack trace.
2. `get_script` pada baris yang disebut error, dan baca kode di sekitarnya.
3. Reproduksi masalah dari data: `get_properties`, `find`, atau `run_code` untuk memeriksa state.
4. Perbaiki penyebabnya dengan `edit_script`, lalu cek `get_output` lagi. Jika butuh bukti runtime, minta user menekan Play dan menyalin Output, atau tambahkan log sementara lalu **hapus** setelah selesai.
]===]


------------------------------------------------------------------ EKSEKUSI
local MAX_RESULT = 12000

local function withHistory(name, fn)
	local rec = ChangeHistoryService:TryBeginRecording("AI: " .. name)
	local ok, res = pcall(fn)
	if rec then
		ChangeHistoryService:FinishRecording(
			rec,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		)
	end
	return ok, res
end

-- Mengembalikan (berhasil, teks JSON untuk model)
local function runTool(command, args)
	local fn = H[command]
	if not fn then
		return false, HttpService:JSONEncode({ ok = false, error = "Command tidak dikenal: " .. tostring(command) })
	end
	local ok, res
	if MUTATING[command] then
		ok, res = withHistory(command, function()
			return fn(args)
		end)
	else
		ok, res = pcall(fn, args)
	end
	if not ok then
		return false, HttpService:JSONEncode({ ok = false, error = tostring(res) })
	end
	local okJ, text = pcall(function()
		return HttpService:JSONEncode({ ok = true, data = toJson(res) })
	end)
	if not okJ then
		return false, HttpService:JSONEncode({ ok = false, error = "Hasil tidak bisa diserialisasi ke JSON" })
	end
	if #text > MAX_RESULT then
		local cut = MAX_RESULT
		while cut > 0 do
			local b = text:byte(cut + 1)
			if b and b >= 128 and b < 192 then
				cut -= 1
			else
				break
			end
		end
		text = text:sub(1, cut) .. "...[dipotong; persempit query atau pakai start_line/end_line]"
	end
	return true, text
end

------------------------------------------------------------------ PENGATURAN
local DEFAULTS = {
	url = "https://api.adacode.ai/v1/chat/completions",
	key = "",
	model = "",
	textMode = false,
	maxSteps = 25,
	maxRetries = 6,
	skillsOnline = true,
}

local cfg = {}
for k, v in pairs(DEFAULTS) do
	local saved = plugin:GetSetting("cfg_" .. k)
	if saved == nil then
		cfg[k] = v
	else
		cfg[k] = saved
	end
end

local function saveCfg()
	for k, v in pairs(cfg) do
		plugin:SetSetting("cfg_" .. k, v)
	end
end

------------------------------------------------------------------ SKILLS (roblox-brain) + TOOLS PEMBANGUN MAP
do
	local SKILL_REPO = "TabooHarmony/roblox-brain"

	local SKILLS = {
		{ "roblox-building", "geometri, map, props, aset hasil generate, acceptance gate (WAJIB untuk membangun map)" },
		{ "roblox-ui-design", "sistem visual UI: hierarki, komposisi, gaya konsisten" },
		{ "roblox-gui", "ScreenGui/SurfaceGui/BillboardGui, layout responsif, input, state UI" },
		{ "roblox-lighting", "Lighting, Atmosphere, post-processing, preset mood, siklus siang/malam" },
		{ "roblox-audio", "SoundService, audio spasial, musik, SFX, ambient" },
		{ "roblox-animation-vfx", "animasi, partikel, beam, trail, tween, cleanup" },
		{ "roblox-physics", "constraint, kendaraan, ragdoll, proyektil, lift, network ownership" },
		{ "roblox-performance", "profiling, streaming, budget part, performa mobile" },
		{ "roblox-studio-mcp", "alur kerja Studio MCP: membangun, menguji, keandalan" },
		{ "roblox-architecture", "struktur fitur, lokasi runtime, startup, client/server" },
		{ "roblox-luau-core", "sintaks Luau, closure, idiom, jebakan bahasa" },
		{ "roblox-luau-types", "type, generics, narrowing, tabel sealed/unsealed" },
		{ "roblox-luau-patterns", "batas modul, lifecycle objek, signal, scheduling, cleanup" },
		{ "roblox-networking", "remote server-authoritative, validasi, rate limit" },
		{ "roblox-security", "anti-exploit: movement, remote, ekonomi, data" },
		{ "roblox-data", "persistensi pemain, schema, migrasi, retry, session ownership" },
		{ "roblox-server-data", "OrderedDataStore, MessagingService, state global" },
		{ "roblox-npc-ai", "pathfinding, state machine, deteksi, spawning NPC" },
		{ "roblox-input", "UserInputService, ContextActionService, keyboard/mouse/gamepad/touch" },
		{ "roblox-camera", "tipe kamera, CFrame, controller kustom, cutscene, screen shake" },
		{ "roblox-analytics", "event kustom, tracking ekonomi, funnel" },
		{ "roblox-monetization", "Game Pass, Developer Product, receipt, subscription" },
		{ "roblox-growth-design", "onboarding, retensi, eksperimen, LiveOps" },
		{ "roblox-cloud", "Open Cloud REST, API key, OAuth, webhook" },
		{ "roblox-collaboration-mode", "mode kerja peer vs otonom, inisiatif sesuai risiko" },
		{ "roblox-code-review", "review via lensa keamanan, performa, korektness" },
		{ "roblox-publish-checklist", "gerbang rilis, bukti, rollback" },
		{ "roblox-tooling", "Rojo, Wally, Selene, StyLua, CI" },
		{ "roblox-localization", "LocalizationService, tabel terjemahan" },
	}

	-- Ringkasan bawaan (ditulis sendiri) dipakai kalau GitHub tidak terjangkau.
	local BUILTIN = {}
	BUILTIN["roblox-building"] = [==[
[ringkasan bawaan: roblox-building]
- Setiap panggilan tool itu stateless: baca ulang state dari Workspace sebelum mengubah, jangan menebak koordinat dari ingatan percakapan.
- Tentukan root (Folder/Model), origin, dan dimensi (stud) lebih dulu. Bangun per fase, lalu baca balik (get_bounds, layout_map).
- Skala: karakter ~5 stud, pintu 4x7, langit-langit 10-14, lorong >= 6, anak tangga <= 1 tinggi.
- Part statis Anchored = true. Dekor: CanCollide/CanTouch/CanQuery = false. Ukuran Part maksimum 2048 per sumbu.
- Hindari z-fighting (jangan menumpuk permukaan yang sebidang) dan part identik yang bertumpuk.
- Model + PrimaryPart/PivotTo, nama jelas, satu Folder per zona.
- Union/CSG mahal dan sering rusak di skala besar: pakai seperlunya, MeshPart untuk detail.
- Elemen berulang pakai scatter/array/build_path, bukan puluhan panggilan manual.
- Acceptance gate: ukuran sesuai target, tidak ada part tak-anchored, SpawnLocation ada dan berpijak, semua zona terjangkau (cek walk_seconds_across), tidak ada objek menembus tanah, jumlah part wajar.
]==]
	BUILTIN["roblox-ui-design"] = [==[
[ringkasan bawaan: roblox-ui-design]
- Mulai dari konten dan hierarki: satu aksi utama per layar; ukuran dan warna menegaskan prioritas.
- Satu palet (3-5 warna), satu atau dua font, spacing kelipatan 4/8, radius sudut konsisten.
- Warisi gaya UI yang sudah ada di project sebelum membuat gaya baru.
- Scale untuk tata letak, Offset untuk detail kecil; UIAspectRatioConstraint, UISizeConstraint, UIPadding; target sentuh >= 44 px; hormati safe area mobile.
- State (hover/pressed/disabled) harus jelas; animasi singkat (0.15-0.3 dtk) lewat TweenService.
- Teks harus terbaca: kontras cukup, TextSize >= 14 di mobile.
]==]
	BUILTIN["roblox-gui"] = BUILTIN["roblox-ui-design"]
	BUILTIN["roblox-lighting"] = [==[
[ringkasan bawaan: roblox-lighting]
- Atur Lighting (ClockTime, Brightness, Ambient/OutdoorAmbient, ExposureCompensation), tambahkan Atmosphere, lalu efek (Bloom, ColorCorrection, SunRays, DepthOfField) secukupnya.
- Technology Future memberi lampu realistis tapi lebih berat di mobile.
- Mood: siang (Density ~0.3), sunset (Haze tinggi, warna hangat), malam (Ambient biru gelap + Bloom), kabut (Density tinggi, Offset 0), horor (saturasi negatif, kontras naik).
- Lampu lokal: Range <= 20-30, jangan terlalu banyak light yang membuat shadow.
- Perpindahan zona: tween properti Lighting/Atmosphere, jangan melompat.
]==]

	local skillCache = {}
	local CHUNK = 6000

	local function safeCut(s, n) -- potong di n byte tanpa memecah karakter UTF-8
		if #s <= n then
			return s
		end
		local cut = n
		while cut > 0 do
			local b = s:byte(cut + 1)
			if b and b >= 128 and b < 192 then
				cut -= 1
			else
				break
			end
		end
		return s:sub(1, cut)
	end

	local function paginate(text)
		local pages, cur, size = {}, {}, 0
		for line in (text .. "\n"):gmatch("(.-)\n") do
			local ln = safeCut(line, CHUNK - 50)
			local len = #ln + 1
			if size + len > CHUNK and #cur > 0 then
				table.insert(pages, table.concat(cur, "\n"))
				cur, size = {}, 0
			end
			table.insert(cur, ln)
			size += len
		end
		if #cur > 0 then
			table.insert(pages, table.concat(cur, "\n"))
		end
		return pages
	end

	local function fetchRaw(path)
		local url = ("https://raw.githubusercontent.com/%s/main/%s"):format(SKILL_REPO, path)
		local ok, res = pcall(function()
			return HttpService:RequestAsync({ Url = url, Method = "GET" })
		end)
		if not ok then
			return nil, tostring(res)
		end
		if not res.Success then
			return nil, ("HTTP %d"):format(res.StatusCode)
		end
		return res.Body
	end

	local function getSkillPages(name, full)
		local key = name .. (full and "#full" or "")
		local hit = skillCache[key]
		if hit then
			return hit.pages, hit.source
		end
		local errMsg
		if cfg.skillsOnline ~= false then
			local file = full and "references/full.md" or "SKILL.md"
			local body, err = fetchRaw(("skills/%s/%s"):format(name, file))
			if body and #body > 0 then
				local entry = { pages = paginate(body), source = "github:" .. SKILL_REPO }
				skillCache[key] = entry
				return entry.pages, entry.source
			end
			errMsg = err
		end
		if not full and BUILTIN[name] then
			local why = errMsg and ("GitHub tidak terjangkau: " .. errMsg) or "mode online dimatikan"
			return paginate(BUILTIN[name]), "ringkasan-bawaan (" .. why .. ")"
		end
		return nil, errMsg or "mode online dimatikan di Setelan"
	end

	function H.list_skills()
		local out = {}
		for _, s in ipairs(SKILLS) do
			table.insert(out, { name = s[1], about = s[2] })
		end
		return { source = SKILL_REPO, online = cfg.skillsOnline ~= false, skills = out }
	end

	function H.load_skill(a)
		local name = tostring(a.name or "")
		if not name:match("^[%w%-]+$") then
			error("'name' tidak valid, lihat list_skills", 0)
		end
		local pages, info = getSkillPages(name, a.full == true)
		if not pages then
			error(
				("Skill '%s' tidak bisa dimuat: %s. Lanjutkan dengan aturan di instruksi sistem."):format(name, tostring(info)),
				0
			)
		end
		local n = math.floor(tonumber(a.chunk) or 1)
		if n < 1 or n > #pages then
			error(("chunk harus 1..%d"):format(#pages), 0)
		end
		return {
			skill = name,
			source = info,
			chunk = n,
			total_chunks = #pages,
			next = n < #pages and ("panggil load_skill lagi dengan chunk=" .. (n + 1)) or nil,
			more = (not a.full) and "tambahkan full=true untuk contoh dan detail API lengkap" or nil,
			content = pages[n],
		}
	end

	------------------------------------------------------------ helper umum
	local function col(v, fallback)
		if v == nil then
			return fallback
		end
		if typeof(v) == "Color3" then
			return v
		end
		if type(v) == "string" then
			local ok, c = pcall(Color3.fromHex, v)
			if ok then
				return c
			end
			error("warna tidak valid: " .. v, 0)
		end
		if type(v) == "table" and #v == 3 then
			if v[1] > 1 or v[2] > 1 or v[3] > 1 then
				return Color3.fromRGB(v[1], v[2], v[3])
			end
			return Color3.new(v[1], v[2], v[3])
		end
		error("warna harus '#RRGGBB' atau [r,g,b]", 0)
	end

	local function mat(name, fallback)
		if name == nil then
			return fallback
		end
		local ok, m = pcall(function()
			return Enum.Material[name]
		end)
		if not ok or not m then
			error("material tidak valid: " .. tostring(name), 0)
		end
		return m
	end

	local function snapToGround(inst, a)
		local mn = boundsOf(inst)
		if not mn then
			error("Tidak ada BasePart di " .. pathOf(inst), 0)
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { inst }
		params.IgnoreWater = a.ignore_water ~= false
		local pos = inst:GetPivot().Position
		local up = tonumber(a.from_above) or 500
		local hit = workspace:Raycast(Vector3.new(pos.X, pos.Y + up, pos.Z), Vector3.new(0, -(up + 3000), 0), params)
		if not hit then
			error("Tidak ada permukaan di bawah objek", 0)
		end
		local dy = hit.Position.Y - mn.Y - (tonumber(a.sink) or 0)
		inst:PivotTo(inst:GetPivot() + Vector3.new(0, dy, 0))
		return dy, hit.Material.Name
	end

	function H.snap_to_ground(a)
		local inst = need(a.path)
		if not inst:IsA("PVInstance") then
			error("Hanya Model atau BasePart", 0)
		end
		local dy, material = snapToGround(inst, a)
		return { path = pathOf(inst), moved_y = r2(dy), surface = material }
	end

	------------------------------------------------------------ catatan proyek permanen
	local function notesValue(create)
		local ss = game:GetService("ServerStorage")
		local v = ss:FindFirstChild("AI_Notes")
		if not v and create then
			v = Instance.new("StringValue")
			v.Name = "AI_Notes"
			v.Parent = ss
		end
		return v
	end

	function H.notes(a)
		local action = a.action or "read"
		if action == "read" then
			local v = notesValue(false)
			return { notes = v and v.Value or "" }
		end
		if action == "clear" then
			local v = notesValue(false)
			if v then
				v.Value = ""
			end
			return { cleared = true }
		end
		if action ~= "write" and action ~= "append" then
			error("action harus read, write, append, atau clear", 0)
		end
		if type(a.text) ~= "string" then
			error("parameter 'text' wajib diisi", 0)
		end
		local v = notesValue(true)
		if action == "write" then
			v.Value = a.text
		else
			v.Value = (v.Value ~= "" and (v.Value .. "\n") or "") .. a.text
		end
		if #v.Value > 6000 then
			error("Catatan terlalu panjang (> 6000 karakter). Ringkas dengan action=write.", 0)
		end
		return { length = #v.Value }
	end

	------------------------------------------------------------ preset lighting
	local C3 = Color3.fromRGB
	local LIGHT_PRESETS = {
		day = {
			desc = "siang cerah",
			lighting = { ClockTime = 14, Brightness = 3, ExposureCompensation = 0, Ambient = C3(70, 70, 70), OutdoorAmbient = C3(110, 120, 135) },
			atmosphere = { Density = 0.3, Offset = 0.25, Color = C3(199, 205, 215), Decay = C3(106, 112, 125), Glare = 0, Haze = 0 },
			bloom = { Intensity = 0.3, Size = 24, Threshold = 1.2 },
			cc = { Brightness = 0, Contrast = 0.05, Saturation = 0.1, TintColor = C3(255, 255, 255) },
			sunrays = { Intensity = 0.08, Spread = 0.6 },
		},
		sunset = {
			desc = "matahari terbenam hangat",
			lighting = { ClockTime = 17.9, Brightness = 2.4, ExposureCompensation = 0.1, Ambient = C3(90, 70, 70), OutdoorAmbient = C3(150, 110, 100) },
			atmosphere = { Density = 0.35, Offset = 0.1, Color = C3(255, 190, 150), Decay = C3(255, 120, 60), Glare = 0.6, Haze = 1.6 },
			bloom = { Intensity = 0.5, Size = 30, Threshold = 1 },
			cc = { Brightness = 0, Contrast = 0.1, Saturation = 0.15, TintColor = C3(255, 235, 215) },
			sunrays = { Intensity = 0.2, Spread = 0.8 },
		},
		night = {
			desc = "malam biru dengan bintang",
			lighting = { ClockTime = 0, Brightness = 0.6, ExposureCompensation = 0.2, Ambient = C3(25, 30, 55), OutdoorAmbient = C3(35, 40, 70) },
			atmosphere = { Density = 0.4, Offset = 0, Color = C3(40, 50, 90), Decay = C3(20, 25, 50), Glare = 0, Haze = 0.5 },
			bloom = { Intensity = 0.6, Size = 28, Threshold = 0.9 },
			cc = { Brightness = 0, Contrast = 0.1, Saturation = 0, TintColor = C3(220, 230, 255) },
			sky = { StarCount = 4000 },
		},
		foggy = {
			desc = "pagi berkabut",
			lighting = { ClockTime = 7, Brightness = 1.6, ExposureCompensation = 0, Ambient = C3(110, 115, 120), OutdoorAmbient = C3(140, 145, 150) },
			atmosphere = { Density = 0.62, Offset = 0, Color = C3(190, 195, 200), Decay = C3(150, 155, 160), Glare = 0, Haze = 2 },
			cc = { Brightness = 0, Contrast = -0.05, Saturation = -0.15, TintColor = C3(235, 240, 245) },
		},
		horror = {
			desc = "gelap, desaturasi, kontras naik",
			lighting = { ClockTime = 22.5, Brightness = 0.8, ExposureCompensation = -0.2, Ambient = C3(20, 22, 25), OutdoorAmbient = C3(35, 40, 38) },
			atmosphere = { Density = 0.55, Offset = 0, Color = C3(60, 70, 62), Decay = C3(25, 30, 28), Glare = 0, Haze = 1.2 },
			bloom = { Intensity = 0.25, Size = 20, Threshold = 1.1 },
			cc = { Brightness = -0.03, Contrast = 0.2, Saturation = -0.4, TintColor = C3(200, 215, 205) },
			dof = { FarIntensity = 0.15, FocusDistance = 60, InFocusRadius = 40, NearIntensity = 0 },
		},
		neon = {
			desc = "cyberpunk malam, bloom kuat",
			lighting = { ClockTime = 0.5, Brightness = 1, ExposureCompensation = 0.3, Ambient = C3(40, 10, 80), OutdoorAmbient = C3(30, 10, 70) },
			atmosphere = { Density = 0.45, Offset = 0, Color = C3(90, 40, 150), Decay = C3(40, 10, 90), Glare = 0.2, Haze = 1 },
			bloom = { Intensity = 1.2, Size = 40, Threshold = 0.7 },
			cc = { Brightness = 0, Contrast = 0.15, Saturation = 0.3, TintColor = C3(255, 220, 255) },
			dof = { FarIntensity = 0.2, FocusDistance = 90, InFocusRadius = 60, NearIntensity = 0 },
		},
		cartoon = {
			desc = "cerah bergaya kartun, warna jenuh",
			lighting = { ClockTime = 13, Brightness = 3.5, ExposureCompensation = 0.1, Ambient = C3(140, 140, 160), OutdoorAmbient = C3(160, 170, 190) },
			atmosphere = { Density = 0.15, Offset = 0, Color = C3(210, 225, 245), Decay = C3(170, 190, 220), Glare = 0, Haze = 0 },
			bloom = { Intensity = 0.2, Size = 20, Threshold = 1.3 },
			cc = { Brightness = 0, Contrast = 0.1, Saturation = 0.25, TintColor = C3(255, 255, 255) },
			sunrays = { Intensity = 0.05, Spread = 0.5 },
		},
		snow = {
			desc = "salju, putih kebiruan",
			lighting = { ClockTime = 11, Brightness = 2.6, ExposureCompensation = 0.2, Ambient = C3(130, 140, 155), OutdoorAmbient = C3(160, 170, 185) },
			atmosphere = { Density = 0.45, Offset = 0, Color = C3(225, 235, 245), Decay = C3(190, 205, 225), Glare = 0, Haze = 1 },
			bloom = { Intensity = 0.3, Size = 24, Threshold = 1.1 },
			cc = { Brightness = 0.02, Contrast = 0, Saturation = -0.15, TintColor = C3(235, 245, 255) },
		},
	}

	local EFFECTS = {
		BloomEffect = "bloom",
		ColorCorrectionEffect = "cc",
		SunRaysEffect = "sunrays",
		DepthOfFieldEffect = "dof",
	}

	local function applyProps(inst, props)
		for k, v in pairs(props) do
			pcall(function()
				inst[k] = v
			end)
		end
	end

	local function ensure(parent, class)
		local c = parent:FindFirstChildOfClass(class)
		if not c then
			c = Instance.new(class)
			c.Parent = parent
		end
		return c
	end

	function H.lighting_preset(a)
		local name = tostring(a.preset or "")
		local p = LIGHT_PRESETS[name]
		if not p then
			local names = {}
			for k in pairs(LIGHT_PRESETS) do
				table.insert(names, k)
			end
			table.sort(names)
			error("preset harus salah satu dari: " .. table.concat(names, ", "), 0)
		end
		local L = game:GetService("Lighting")
		applyProps(L, p.lighting)
		if tonumber(a.clock_time) then
			L.ClockTime = tonumber(a.clock_time)
		end
		applyProps(ensure(L, "Atmosphere"), p.atmosphere)
		for class, key in pairs(EFFECTS) do
			if p[key] then
				local fx = ensure(L, class)
				applyProps(fx, p[key])
				fx.Enabled = true
			else
				local fx = L:FindFirstChildOfClass(class)
				if fx then
					fx.Enabled = false
				end
			end
		end
		local sky = ensure(L, "Sky")
		if p.sky then
			applyProps(sky, p.sky)
		end
		if a.future == true then
			pcall(function()
				L.Technology = Enum.Technology.Future
			end)
		end
		return { preset = name, desc = p.desc, clock_time = L.ClockTime }
	end

	------------------------------------------------------------ gaya map
	local STYLES = {
		cartoon = {
			about = "cerah, bentuk membulat, warna jenuh",
			palette = { ground = "#7ED957", path = "#F2D49B", wall = "#FFE9B8", roof = "#FF7A3D", accent = "#4C8DFF", water = "#4FC3F7", wood = "#A8703A", rock = "#9AA5B1" },
			materials = { "SmoothPlastic", "Plastic", "Grass", "Sand", "Wood" },
			lighting = "cartoon", ui = "cartoon",
			rules = { "bentuk sederhana dan besar, minim detail kecil", "maksimal 5 warna utama", "hindari tekstur realistis; variasi lewat skala dan rotasi" },
		},
		lowpoly = {
			about = "facet datar, palet terbatas, siluet jelas",
			palette = { ground = "#6DBE6A", path = "#D8C79A", wall = "#E8E2D2", roof = "#C25B4E", accent = "#2F80ED", water = "#5BB5E0", wood = "#8B5E3C", rock = "#8E98A3" },
			materials = { "SmoothPlastic", "Plastic", "Slate" },
			lighting = "day", ui = "light",
			rules = { "tanpa tekstur, warna rata", "sudut tegas; pakai rotasi kecil agar tidak monoton", "perbedaan tinggi dan siluet lebih penting dari detail" },
		},
		realistic = {
			about = "material nyata, warna kalem, detail bertingkat",
			palette = { ground = "#5E7A45", path = "#8C8372", wall = "#B8AFA0", roof = "#5A4A42", accent = "#C98B3A", water = "#3E7C99", wood = "#6B4A2F", rock = "#6F7378" },
			materials = { "Grass", "Ground", "Concrete", "Brick", "Cobblestone", "Slate", "WoodPlanks" },
			lighting = "day", ui = "dark",
			rules = { "warna desaturasi, variasi kecil antar part", "campur 2-3 material per bangunan (dasar, dinding, atap)", "tambahkan props kecil dan scatter vegetasi", "aktifkan lighting Future bila target PC" },
		},
		medieval = {
			about = "kastil/desa abad pertengahan: batu, kayu, atap miring",
			palette = { ground = "#5F8A4B", path = "#9B8B6E", wall = "#B9B2A3", roof = "#7A3B2E", accent = "#C9A227", water = "#3F7F9F", wood = "#6B4423", rock = "#7B7F85" },
			materials = { "Cobblestone", "Brick", "WoodPlanks", "Slate", "Wood" },
			lighting = "sunset", ui = "dark",
			rules = { "dinding batu + rangka kayu", "atap gable dengan overhang", "obor/lentera sebagai titik cahaya hangat" },
		},
		cyberpunk = {
			about = "kota malam neon, permukaan gelap, aksen terang",
			palette = { ground = "#14111F", path = "#1E1B2E", wall = "#2A2640", roof = "#0F0D1A", accent = "#00E5FF", accent2 = "#FF2E97", water = "#1B2A4A", rock = "#2B2B3A" },
			materials = { "Metal", "Concrete", "SmoothPlastic", "Neon", "Glass" },
			lighting = "neon", ui = "neon",
			rules = { "dasar gelap, aksen Neon sempit (garis, papan)", "maksimal 2 warna neon", "gunakan Glass dan Metal untuk fasad" },
		},
		horror = {
			about = "gelap, sempit, desaturasi, kabut",
			palette = { ground = "#2F3A2C", path = "#3B3B36", wall = "#4A4640", roof = "#2A2522", accent = "#8B1A1A", water = "#1F2E2E", wood = "#3A2A1E", rock = "#3A3D40" },
			materials = { "Wood", "WoodPlanks", "Concrete", "Slate", "Ground" },
			lighting = "horror", ui = "dark",
			rules = { "sumber cahaya sedikit dan lokal", "ruang sempit, jalur berkelok", "kabut tebal membatasi jarak pandang" },
		},
		tycoon = {
			about = "area bersih berpetak, warna cerah, jalur jelas",
			palette = { ground = "#6FCF6B", path = "#E6D7B0", wall = "#F4F1E8", roof = "#E4572E", accent = "#2F80ED", accent2 = "#F2C94C", water = "#56CCF2", rock = "#A0AAB4" },
			materials = { "SmoothPlastic", "Plastic", "Concrete", "Grass", "Metal" },
			lighting = "day", ui = "cartoon",
			rules = { "plot berukuran sama dan terpisah jelas", "jalur dari spawn ke setiap plot", "area interaksi diberi warna kontras" },
		},
		tropical = {
			about = "pulau pasir, laut jernih, vegetasi lebat",
			palette = { ground = "#4FAE5A", path = "#F0DDA8", wall = "#F7F0DC", roof = "#C77D4B", accent = "#FF9F43", water = "#3FD0E0", wood = "#9A6A3A", rock = "#8C969E" },
			materials = { "Sand", "Grass", "Wood", "WoodPlanks", "Water" },
			lighting = "day", ui = "light",
			rules = { "terrain island dengan water_level", "pasir di tepi, rumput di tengah", "scatter pohon palem dan batu" },
		},
	}

	function H.style_presets(a)
		if a.name then
			local s = STYLES[tostring(a.name)]
			if not s then
				error("style tidak dikenal. Pakai style_presets tanpa 'name' untuk daftar.", 0)
			end
			return s
		end
		local out = {}
		for k, v in pairs(STYLES) do
			table.insert(out, { name = k, about = v.about })
		end
		table.sort(out, function(p, q)
			return p.name < q.name
		end)
		return out
	end

	------------------------------------------------------------ bulk set
	function H.bulk_set(a)
		local root = need(a.path)
		if type(a.properties) ~= "table" and not a.attributes and not a.add_tags then
			error("parameter 'properties' wajib diisi", 0)
		end
		local needle = a.name_contains and tostring(a.name_contains):lower()
		local limit = math.clamp(math.floor(tonumber(a.limit) or 2000), 1, 5000)
		local changed, skipped, errors = 0, 0, {}
		for _, d in ipairs(root:GetDescendants()) do
			if
				(not a.class or d:IsA(a.class))
				and (not needle or d.Name:lower():find(needle, 1, true))
				and (not a.tag or CollectionService:HasTag(d, a.tag))
			then
				local ok, err = pcall(function()
					setProps(d, a.properties)
					applyExtras(d, a)
				end)
				if ok then
					changed += 1
				else
					skipped += 1
					if #errors < 3 then
						table.insert(errors, pathOf(d) .. ": " .. tostring(err))
					end
				end
				if changed >= limit then
					break
				end
			end
		end
		return { changed = changed, skipped = skipped, errors = errors }
	end

	------------------------------------------------------------ array
	function H.array(a)
		local src = need(a.path)
		if not src:IsA("PVInstance") then
			error("path harus Model atau BasePart", 0)
		end
		local count = math.clamp(math.floor(tonumber(a.count) or 2), 1, 200)
		local parent = a.parent and need(a.parent) or src.Parent
		local base = src:GetPivot()
		local label = a.name or src.Name
		local out = {}
		local center = v3(a.center)
		local offset = v3(a.offset)
		if not center and not offset then
			error("isi 'offset' [x,y,z] (barisan lurus) atau 'center' [x,y,z] (melingkar)", 0)
		end
		local arc = tonumber(a.arc) or 360
		for i = 1, count do
			local cf
			if center then
				local step = (arc >= 360) and (360 / (count + 1)) or (arc / count)
				local rad = math.rad(step * i)
				cf = CFrame.new(center) * CFrame.Angles(0, rad, 0) * (CFrame.new(-center) * base)
			else
				cf = (base + offset * i) * CFrame.Angles(0, math.rad((tonumber(a.yaw_step) or 0) * i), 0)
			end
			local copy = src:Clone()
			copy.Name = label .. "_" .. i
			copy:PivotTo(cf)
			copy.Parent = parent
			table.insert(out, pathOf(copy))
		end
		local sample = {}
		for i = 1, math.min(5, #out) do
			sample[i] = out[i]
		end
		return { created = #out, sample = sample }
	end

	------------------------------------------------------------ tangga
	function H.build_stairs(a)
		local parent = need(a.parent)
		local pos = v3(a.position)
		if not pos then
			error("'position' [x,y,z] (tengah dasar anak tangga pertama) wajib", 0)
		end
		local rise = tonumber(a.rise) or 12
		local width = tonumber(a.width) or 6
		local stepH = math.clamp(tonumber(a.step_height) or 1, 0.5, 1)
		local steps = math.max(1, math.ceil(rise / stepH))
		local depth = tonumber(a.step_depth) or 1.5
		local base = CFrame.new(pos) * CFrame.Angles(0, math.rad(tonumber(a.yaw) or 0), 0)
		local color = col(a.color, Color3.fromRGB(150, 150, 150))
		local material = mat(a.material, Enum.Material.Concrete)
		local model = Instance.new("Model")
		model.Name = a.name or "Stairs"
		local h = rise / steps
		for i = 1, steps do
			local p = Instance.new("Part")
			p.Name = "Step_" .. i
			p.Anchored = true
			p.Size = Vector3.new(width, i * h, depth)
			p.CFrame = base * CFrame.new(0, i * h / 2, -(i - 0.5) * depth)
			p.Color = color
			p.Material = material
			p.Parent = model
		end
		model.Parent = parent
		return { path = pathOf(model), steps = steps, run = r2(steps * depth), rise = rise, note = "Tangga naik ke arah LookVector (-Z lokal); atur 'yaw'." }
	end

	------------------------------------------------------------ jalan / sungai / dinding lurus
	function H.build_path(a)
		local pts = a.points
		if type(pts) ~= "table" or #pts < 2 then
			error("'points' minimal 2 titik [[x,y,z],[x,y,z],...]", 0)
		end
		local parent = need(a.parent)
		local width = tonumber(a.width) or 12
		local height = tonumber(a.height) or 1
		local color = col(a.color, Color3.fromRGB(80, 80, 85))
		local material = mat(a.material, Enum.Material.Asphalt)
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { parent }
		local vs = {}
		for i, p in ipairs(pts) do
			local v = v3(p)
			if not v then
				error(("points[%d] harus [x,y,z]"):format(i), 0)
			end
			if a.snap_to_ground == true then
				local hit = workspace:Raycast(Vector3.new(v.X, v.Y + 500, v.Z), Vector3.new(0, -3000, 0), rp)
				if hit then
					v = Vector3.new(v.X, hit.Position.Y, v.Z)
				end
			end
			vs[i] = v
		end
		local model = Instance.new("Model")
		model.Name = a.name or "Path"
		local collide = a.collide ~= false
		local n, total = 0, 0
		local function disc(v)
			local d = Instance.new("Part")
			d.Name = "Joint"
			d.Shape = Enum.PartType.Cylinder
			d.Anchored = true
			d.Size = Vector3.new(height, width, width)
			d.CFrame = CFrame.new(v - Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			d.Color = color
			d.Material = material
			d.CanCollide = collide
			d.Parent = model
		end
		for i = 1, #vs - 1 do
			local p0, p1 = vs[i], vs[i + 1]
			local len = (p1 - p0).Magnitude
			if len > 0.05 then
				n += 1
				total += len
				local part = Instance.new("Part")
				part.Name = "Segment_" .. n
				part.Anchored = true
				part.Size = Vector3.new(width, height, len)
				part.CFrame = CFrame.lookAt((p0 + p1) / 2, p1) * CFrame.new(0, -height / 2, 0)
				part.Color = color
				part.Material = material
				part.CanCollide = collide
				part.Parent = model
			end
		end
		if a.joints ~= false then
			for i = 2, #vs - 1 do
				disc(vs[i])
			end
			if a.round_ends == true then
				disc(vs[1])
				disc(vs[#vs])
			end
		end
		model.Parent = parent
		return { path = pathOf(model), segments = n, length = r2(total), note = "Permukaan atas = garis titik. height besar + width kecil = dinding/pagar." }
	end

	------------------------------------------------------------ terrain prosedural
	function H.terrain_generate(a)
		local terrain = workspace.Terrain
		local center = v3(a.center) or Vector3.new(0, 0, 0)
		local sz = type(a.size) == "table" and a.size or {}
		local sizeX = tonumber(sz[1]) or 400
		local sizeZ = tonumber(sz[2]) or sizeX
		local base = center.Y
		local amp = tonumber(a.amplitude) or 30
		local scale = math.max(10, tonumber(a.scale) or 140)
		local seed = tonumber(a.seed) or 1
		local shape = a.shape or "hills"
		local depth = math.max(8, tonumber(a.depth) or 12)
		local water = tonumber(a.water_level)
		local flatR = tonumber(a.flat_radius) or 0
		local rockSlope = tonumber(a.rock_slope) or 0.9

		local function cellsFor(c)
			return math.ceil(sizeX / c) * math.ceil(sizeZ / c)
		end
		local cell = tonumber(a.cell)
		if not cell then
			for _, c in ipairs({ 4, 8, 16, 32 }) do
				cell = c
				if cellsFor(c) <= 16000 then
					break
				end
			end
		end
		cell = math.clamp(cell, 4, 32)
		if cellsFor(cell) > 16000 then
			error("Area terlalu besar (maks 16000 sel). Perkecil 'size' atau buat per bagian dengan 'center' berbeda dan 'seed' sama.", 0)
		end

		local M = type(a.materials) == "table" and a.materials or {}
		local mLow = mat(M.low, Enum.Material.Sand)
		local mMid = mat(M.mid, Enum.Material.Grass)
		local mHigh = mat(M.high, Enum.Material.Rock)
		local mPeak = mat(M.peak, shape == "mountains" and Enum.Material.Snow or Enum.Material.Rock)
		local mUnder = mat(M.under, Enum.Material.Ground)

		local half = math.max(sizeX, sizeZ) / 2
		local function noise(x, z)
			local n, amplitude, freq, norm = 0, 1, 1, 0
			for _ = 1, 3 do
				n += math.noise(x / scale * freq + seed * 17.31, z / scale * freq + seed * 5.17, seed * 0.37) * amplitude
				norm += amplitude
				amplitude *= 0.5
				freq *= 2
			end
			return (n / norm) * 2
		end
		local function heightAt(x, z)
			local n = noise(x, z)
			local h
			if shape == "flat" then
				h = n * amp * 0.1
			elseif shape == "plains" then
				h = n * amp * 0.3
			elseif shape == "mountains" then
				h = amp * math.sign(n) * (math.abs(n) ^ 0.8) * 1.6
			elseif shape == "island" then
				local dx, dz = x - center.X, z - center.Z
				local d = math.sqrt(dx * dx + dz * dz) / (half * 0.9)
				local fall = math.clamp(1 - d * d, 0, 1)
				h = amp * (0.4 + n * 0.6) * fall - (1 - fall) * amp * 0.6
			else
				h = n * amp
			end
			if flatR > 0 then
				local dx, dz = x - center.X, z - center.Z
				local t = math.clamp(math.sqrt(dx * dx + dz * dz) / flatR, 0, 1)
				h *= t * t * (3 - 2 * t)
			end
			return base + h
		end

		if a.clear_area == true then
			terrain:FillBlock(
				CFrame.new(center.X, base, center.Z),
				Vector3.new(sizeX, amp * 4 + depth * 2 + 64, sizeZ),
				Enum.Material.Air
			)
		end

		local x0, z0 = center.X - sizeX / 2, center.Z - sizeZ / 2
		local nx, nz = math.ceil(sizeX / cell), math.ceil(sizeZ / cell)
		local minH, maxH, wcount, done = math.huge, -math.huge, 0, 0
		for i = 0, nx - 1 do
			for j = 0, nz - 1 do
				local x, z = x0 + (i + 0.5) * cell, z0 + (j + 0.5) * cell
				local h = heightAt(x, z)
				local hE, hW = heightAt(x + cell, z), heightAt(x - cell, z)
				local hN, hS = heightAt(x, z + cell), heightAt(x, z - cell)
				local slope = math.max(math.abs(hE - hW), math.abs(hN - hS)) / (2 * cell)
				minH, maxH = math.min(minH, h), math.max(maxH, h)
				local bottom = math.min(h, hE, hW, hN, hS) - depth
				local surface
				if water and h <= water + 2.5 then
					surface = mLow
				elseif slope > rockSlope then
					surface = mHigh
				elseif h - base > amp * 0.8 then
					surface = mPeak
				elseif h - base > amp * 0.55 then
					surface = mHigh
				else
					surface = mMid
				end
				local topLayer = math.min(4, h - bottom)
				if h - topLayer - bottom > 0.5 then
					local ub = bottom
					local ut = h - topLayer
					terrain:FillBlock(CFrame.new(x, (ub + ut) / 2, z), Vector3.new(cell, ut - ub, cell), slope > rockSlope and mHigh or mUnder)
				end
				terrain:FillBlock(CFrame.new(x, h - topLayer / 2, z), Vector3.new(cell, topLayer, cell), surface)
				if water and h < water then
					wcount += 1
					terrain:FillBlock(CFrame.new(x, (h + water) / 2, z), Vector3.new(cell, water - h, cell), Enum.Material.Water)
				end
				done += 1
				if done % 250 == 0 then
					task.wait()
				end
			end
		end
		return {
			cells = nx * nz,
			cell = cell,
			area = { sizeX, sizeZ },
			height_min = r2(minH),
			height_max = r2(maxH),
			water_cells = wcount,
			warning = workspace:FindFirstChild("Baseplate") and "Ada Baseplate: hapus atau turunkan agar tidak menutupi terrain." or nil,
		}
	end

	------------------------------------------------------------ bangunan lengkap
	function H.build_building(a)
		local parent = need(a.parent)
		local pos = v3(a.position)
		if not pos then
			error("'position' [x,y,z] (tengah footprint di permukaan tanah) wajib", 0)
		end
		local sz = type(a.size) == "table" and a.size or {}
		local W = tonumber(sz[1]) or 24
		local D = tonumber(sz[2]) or W
		if W < 12 or D < 12 then
			error("'size' [lebar, dalam] minimal 12x12 stud", 0)
		end
		local floors = math.clamp(math.floor(tonumber(a.floors) or 1), 1, 10)
		local FH = math.clamp(tonumber(a.floor_height) or 12, 9, 24)
		local T = math.clamp(tonumber(a.wall_thickness) or 1, 0.5, 4)
		local S = 1
		local base = CFrame.new(pos) * CFrame.Angles(0, math.rad(tonumber(a.yaw) or 0), 0)
		local cWall = col(a.wall_color, Color3.fromRGB(226, 215, 190))
		local cRoof = col(a.roof_color, Color3.fromRGB(150, 70, 60))
		local cTrim = col(a.trim_color, Color3.fromRGB(110, 90, 70))
		local cFloor = col(a.floor_color, Color3.fromRGB(140, 110, 80))
		local mWall = mat(a.wall_material, Enum.Material.Plaster)
		local mRoof = mat(a.roof_material, Enum.Material.Slate)
		local mFloor = mat(a.floor_material, Enum.Material.WoodPlanks)
		local mTrim = mat(a.trim_material, Enum.Material.Wood)
		local roof = a.roof or "gable"
		if roof ~= "gable" and roof ~= "flat" and roof ~= "none" then
			error("roof harus gable, flat, atau none", 0)
		end
		local ov = math.clamp(tonumber(a.roof_overhang) or 1.5, 0, 4)
		local warn = {}

		local model = Instance.new("Model")
		model.Name = a.name or "Building"
		local count = 0
		local function box(name, cx, cy, cz, sx, sy, sz2, color, material)
			if sx < 0.05 or sy < 0.05 or sz2 < 0.05 then
				return nil
			end
			count += 1
			local p = Instance.new("Part")
			p.Name = name
			p.Anchored = true
			p.Size = Vector3.new(sx, sy, sz2)
			p.CFrame = base * CFrame.new(cx, cy, cz)
			p.Color = color
			p.Material = material
			p.Parent = model
			return p
		end

		local function slab(name, y, hole)
			if not hole then
				box(name, 0, y - S / 2, 0, W, S, D, cFloor, mFloor)
				return
			end
			local hx0, hx1, hz0, hz1 = hole[1], hole[2], hole[3], hole[4]
			box(name .. "_L", (-W / 2 + hx0) / 2, y - S / 2, 0, hx0 + W / 2, S, D, cFloor, mFloor)
			box(name .. "_R", (hx1 + W / 2) / 2, y - S / 2, 0, W / 2 - hx1, S, D, cFloor, mFloor)
			box(name .. "_B", (hx0 + hx1) / 2, y - S / 2, (hz1 + D / 2) / 2, hx1 - hx0, S, D / 2 - hz1, cFloor, mFloor)
			box(name .. "_F", (hx0 + hx1) / 2, y - S / 2, (-D / 2 + hz0) / 2, hx1 - hx0, S, hz0 + D / 2, cFloor, mFloor)
		end

		local function wallRun(name, axis, fixed, length, y0, height, openings)
			table.sort(openings, function(p, q)
				return p.c < q.c
			end)
			local half = length / 2
			local cursor, n = -half, 0
			local function piece(a0, a1, b0, b1)
				if a1 - a0 < 0.05 or b1 - b0 < 0.05 then
					return
				end
				n += 1
				local ca, cb = (a0 + a1) / 2, y0 + (b0 + b1) / 2
				if axis == "x" then
					box(name .. "_" .. n, ca, cb, fixed, a1 - a0, b1 - b0, T, cWall, mWall)
				else
					box(name .. "_" .. n, fixed, cb, ca, T, b1 - b0, a1 - a0, cWall, mWall)
				end
			end
			for _, o in ipairs(openings) do
				local o0, o1 = math.max(-half, o.c - o.w / 2), math.min(half, o.c + o.w / 2)
				piece(cursor, o0, 0, height)
				piece(o0, o1, 0, o.y0)
				piece(o0, o1, o.y0 + o.h, height)
				cursor = math.max(cursor, o1)
				if o.glass then
					local cb, oc = y0 + o.y0 + o.h / 2, (o0 + o1) / 2
					local pane
					if axis == "x" then
						pane = box(name .. "_glass", oc, cb, fixed, o1 - o0, o.h, 0.2, Color3.fromRGB(170, 205, 230), Enum.Material.Glass)
					else
						pane = box(name .. "_glass", fixed, cb, oc, 0.2, o.h, o1 - o0, Color3.fromRGB(170, 205, 230), Enum.Material.Glass)
					end
					if pane then
						pane.Transparency = 0.5
					end
				end
			end
			piece(cursor, half, 0, height)
		end

		local wallH = FH - S
		local sides = {
			front = { axis = "x", fixed = -(D / 2 - T / 2), length = W },
			back = { axis = "x", fixed = D / 2 - T / 2, length = W },
			left = { axis = "z", fixed = -(W / 2 - T / 2), length = D - 2 * T },
			right = { axis = "z", fixed = W / 2 - T / 2, length = D - 2 * T },
		}
		local doorSide = a.door_side or "front"
		if not sides[doorSide] then
			error("door_side harus front, back, left, atau right", 0)
		end
		local doorW = math.clamp(tonumber(a.door_width) or 4, 3, 12)
		local doorH = math.clamp(tonumber(a.door_height) or 7, 6, wallH - 1)
		local dLen = sides[doorSide].length
		local doorC = math.clamp(tonumber(a.door_offset) or 0, -(dLen / 2 - doorW / 2 - T), dLen / 2 - doorW / 2 - T)
		local winW = tonumber(a.window_width) or 4
		local winH = math.clamp(tonumber(a.window_height) or 4, 2, wallH - 3)
		local winSill = math.clamp(tonumber(a.window_sill) or 3.5, 1, wallH - winH - 1)
		local useWindows = a.windows ~= false

		-- tangga dalam (hanya jika > 1 lantai)
		local stairs = floors > 1 and a.stairs ~= false
		local nSteps = math.ceil(FH / 1)
		local depth, sw = 1.5, 4
		local run = (nSteps - 1) * depth
		local xs = -W / 2 + T + 1
		if stairs and (W - 2 * T) < run + 6 then
			stairs = false
			table.insert(warn, ("tangga dalam dilewati: lebar harus >= %d stud untuk %d lantai tinggi %d"):format(math.ceil(run + 6 + 2 * T), floors, FH))
		end
		local function stairZ(level)
			local sign = (level % 2 == 1) and 1 or -1
			if doorSide == "back" then
				sign = -sign
			end
			return sign * (D / 2 - T - sw / 2 - 0.5)
		end

		for f = 1, floors do
			local Y = (f - 1) * FH
			local hole
			if f >= 2 and stairs then
				local zp = stairZ(f - 1)
				hole = { xs, xs + run, zp - sw / 2, zp + sw / 2 }
			end
			slab(f == 1 and "Foundation" or ("Floor" .. f), Y, hole)

			for _, sideName in ipairs({ "front", "back", "left", "right" }) do
				local s = sides[sideName]
				local len = s.length
				local ops = {}
				if f == 1 and sideName == doorSide then
					table.insert(ops, { c = doorC, w = doorW, y0 = 0, h = doorH })
				end
				if useWindows then
					local nWin = math.clamp(math.floor(tonumber(a.windows_per_wall) or (len / 10)), 0, 8)
					for k = 1, nWin do
						local c = -len / 2 + len * (k - 0.5) / nWin
						local clash = math.abs(c) > len / 2 - winW / 2 - T
						for _, o in ipairs(ops) do
							if math.abs(c - o.c) < (winW + o.w) / 2 + 1.5 then
								clash = true
							end
						end
						if not clash then
							table.insert(ops, { c = c, w = winW, y0 = winSill, h = winH, glass = true })
						end
					end
				end
				wallRun(("Wall%d_%s"):format(f, sideName), s.axis, s.fixed, len, Y, wallH, ops)
			end

			if stairs and f < floors then
				local zp = stairZ(f)
				local hStep = FH / nSteps
				for k = 1, nSteps - 1 do
					box(("Stair%d_%d"):format(f, k), xs + (k - 0.5) * depth, Y + k * hStep / 2, zp, depth, k * hStep, sw, cTrim, mFloor)
				end
			end

			if a.lights ~= false then
				local lamp = box("Lamp" .. f, 0, Y + wallH - 0.2, 0, 2, 0.4, 2, Color3.fromRGB(255, 244, 214), Enum.Material.Neon)
				if lamp then
					lamp.CanCollide = false
					local light = Instance.new("PointLight")
					light.Range = math.clamp(math.max(W, D) * 0.8, 12, 40)
					light.Brightness = 1.2
					light.Color = Color3.fromRGB(255, 232, 190)
					light.Parent = lamp
				end
			end
		end

		-- tiang sudut
		local postH = floors * FH - S
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz2 in ipairs({ -1, 1 }) do
				box("CornerPost", sx * (W / 2 - T / 2), postH / 2, sz2 * (D / 2 - T / 2), T + 0.4, postH, T + 0.4, cTrim, mTrim)
			end
		end

		-- atap
		local Ht = floors * FH
		if roof ~= "none" then
			box("RoofSlab", 0, Ht - S / 2, 0, W + 2 * ov, S, D + 2 * ov, cRoof, mRoof)
		end
		if roof == "flat" and a.parapet ~= false then
			box("Parapet_F", 0, Ht + 0.75, -(D / 2 - T / 2), W, 1.5, T, cTrim, mTrim)
			box("Parapet_B", 0, Ht + 0.75, D / 2 - T / 2, W, 1.5, T, cTrim, mTrim)
			box("Parapet_L", -(W / 2 - T / 2), Ht + 0.75, 0, T, 1.5, D - 2 * T, cTrim, mTrim)
			box("Parapet_R", W / 2 - T / 2, Ht + 0.75, 0, T, 1.5, D - 2 * T, cTrim, mTrim)
		elseif roof == "gable" then
			local rh = math.clamp(tonumber(a.roof_height) or W * 0.3, 4, W)
			local halfW = W / 2 + ov
			local ang = math.atan2(rh, halfW)
			local slen = math.sqrt(halfW * halfW + rh * rh)
			local cx = (halfW / slen) * (slen / 2) + math.sin(ang) * 0.5
			local cy = Ht + rh - math.sin(ang) * (slen / 2) + math.cos(ang) * 0.5
			local zlen = D + 2 * ov
			local r = box("RoofR", cx, cy, 0, slen + 1, 1, zlen, cRoof, mRoof)
			if r then
				r.CFrame = base * CFrame.new(cx, cy, 0) * CFrame.Angles(0, 0, -ang)
			end
			local l = box("RoofL", -cx, cy, 0, slen + 1, 1, zlen, cRoof, mRoof)
			if l then
				l.CFrame = base * CFrame.new(-cx, cy, 0) * CFrame.Angles(0, 0, ang)
			end
			local layers = 10
			for i = 0, layers - 1 do
				local hw = math.min(W / 2, halfW * (1 - (i + 1) / layers))
				if hw * 2 >= 0.1 then
					local ly = Ht + (i + 0.5) * rh / layers
					box("Gable_F" .. i, 0, ly, -(D / 2 - T / 2), hw * 2, rh / layers, T, cWall, mWall)
					box("Gable_B" .. i, 0, ly, D / 2 - T / 2, hw * 2, rh / layers, T, cWall, mWall)
				end
			end
		end

		model.PrimaryPart = model:FindFirstChild("Foundation")
		model.Parent = parent
		local mn, mx = boundsOf(model)
		local doorLocal = ({
			front = Vector3.new(doorC, 0, -D / 2),
			back = Vector3.new(doorC, 0, D / 2),
			left = Vector3.new(-W / 2, 0, doorC),
			right = Vector3.new(W / 2, 0, doorC),
		})[doorSide]
		return {
			path = pathOf(model),
			parts = count,
			size = mn and arr(mx - mn) or nil,
			floors = floors,
			door_world = arr((base * CFrame.new(doorLocal)).Position),
			warnings = warn,
		}
	end

	------------------------------------------------------------ UI deklaratif
	local UI_THEMES = {
		dark = { panel = "#1D212B", panel2 = "#272C38", stroke = "#343B4B", accent = "#4C8DFF", accent2 = "#2FD27A", danger = "#FF5C5C", text = "#F2F4F8", sub = "#9AA3B2", font = "GothamMedium", bold = "GothamBold", radius = 10, strokeThickness = 1 },
		light = { panel = "#FFFFFF", panel2 = "#EAEFF7", stroke = "#D5DCE8", accent = "#3A6FF2", accent2 = "#22B573", danger = "#E5484D", text = "#1B2130", sub = "#6B7589", font = "GothamMedium", bold = "GothamBold", radius = 10, strokeThickness = 1 },
		cartoon = { panel = "#FFFFFF", panel2 = "#FFE7A8", stroke = "#2B2B3A", accent = "#FF7A3D", accent2 = "#3DDC84", danger = "#FF4D6D", text = "#2B2B3A", sub = "#7A6F5A", font = "FredokaOne", bold = "FredokaOne", radius = 16, strokeThickness = 3 },
		neon = { panel = "#150C24", panel2 = "#21123A", stroke = "#B026FF", accent = "#00E5FF", accent2 = "#FF2E97", danger = "#FF3860", text = "#F5ECFF", sub = "#A794C8", font = "GothamMedium", bold = "Michroma", radius = 6, strokeThickness = 2 },
	}

	local UI_CLASS = {
		Panel = "Frame", Button = "TextButton", Label = "TextLabel", Image = "ImageLabel", Input = "TextBox",
		Bar = "Frame", Scroll = "ScrollingFrame", List = "Frame", Grid = "Frame", Row = "Frame", Column = "Frame",
	}

	local function fontOf(name)
		local ok, f = pcall(function()
			return Enum.Font[name]
		end)
		return ok and f or Enum.Font.GothamMedium
	end

	local function addCorner(inst, r)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, r)
		c.Parent = inst
	end

	local function addStroke(inst, color, thick)
		local s = Instance.new("UIStroke")
		s.Color = color
		s.Thickness = thick
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Parent = inst
	end

	local function addPadding(inst, p)
		local u = Instance.new("UIPadding")
		u.PaddingTop, u.PaddingBottom, u.PaddingLeft, u.PaddingRight = UDim.new(0, p), UDim.new(0, p), UDim.new(0, p), UDim.new(0, p)
		u.Parent = inst
	end

	local function buildUi(spec, parent, th, state, depth, index)
		state.n += 1
		if state.n > 300 then
			error("Terlalu banyak elemen UI dalam satu panggilan (maks 300)", 0)
		end
		if depth > 8 then
			error("UI terlalu dalam (maks 8 level)", 0)
		end
		if type(spec) ~= "table" then
			error("setiap elemen UI harus berupa objek", 0)
		end
		local kind = spec.type or "Frame"
		local class = UI_CLASS[kind] or kind
		local okI, inst = pcall(Instance.new, class)
		if not okI or not inst:IsA("GuiObject") then
			error("type/class UI tidak valid: " .. tostring(kind), 0)
		end
		inst.Name = spec.name or kind
		inst.BorderSizePixel = 0
		inst.LayoutOrder = index
		local radius = tonumber(spec.corner)
		local layout = spec.layout

		if kind == "Panel" then
			inst.BackgroundColor3 = col(th.panel)
			inst.Size = UDim2.fromScale(1, 1)
			addCorner(inst, radius or th.radius)
			addStroke(inst, col(th.stroke), th.strokeThickness)
			layout = layout or { dir = "vertical", gap = 8, padding = 12 }
		elseif kind == "Button" then
			local v = spec.variant or "primary"
			local bg = ({ primary = th.accent, secondary = th.panel2, danger = th.danger, success = th.accent2 })[v]
			inst.AutoButtonColor = true
			inst.Size = UDim2.fromOffset(160, 44)
			inst.Font = fontOf(th.bold)
			inst.TextSize = 18
			if v == "ghost" then
				inst.BackgroundTransparency = 1
				inst.TextColor3 = col(th.text)
				addStroke(inst, col(th.stroke), th.strokeThickness)
			else
				inst.BackgroundColor3 = col(bg or th.accent)
				inst.TextColor3 = (v == "secondary") and col(th.text) or Color3.new(1, 1, 1)
			end
			addCorner(inst, radius or th.radius)
		elseif kind == "Label" then
			inst.BackgroundTransparency = 1
			inst.Size = UDim2.new(1, 0, 0, 24)
			inst.Font = fontOf(th.font)
			inst.TextSize = 18
			inst.TextColor3 = col(th.text)
			inst.TextXAlignment = Enum.TextXAlignment.Left
			inst.TextWrapped = true
			if spec.style == "title" then
				inst.Font = fontOf(th.bold)
				inst.TextSize = 28
				inst.Size = UDim2.new(1, 0, 0, 36)
			elseif spec.style == "subtitle" then
				inst.TextSize = 14
				inst.TextColor3 = col(th.sub)
			end
		elseif kind == "Input" then
			inst.BackgroundColor3 = col(th.panel2)
			inst.Size = UDim2.new(1, 0, 0, 40)
			inst.Font = fontOf(th.font)
			inst.TextSize = 16
			inst.TextColor3 = col(th.text)
			inst.PlaceholderColor3 = col(th.sub)
			inst.ClearTextOnFocus = false
			inst.TextXAlignment = Enum.TextXAlignment.Left
			addCorner(inst, radius or math.max(4, th.radius - 2))
			addStroke(inst, col(th.stroke), 1)
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
			pad.Parent = inst
		elseif kind == "Bar" then
			inst.BackgroundColor3 = col(th.panel2)
			inst.Size = UDim2.new(1, 0, 0, 14)
			addCorner(inst, 999)
			local fill = Instance.new("Frame")
			fill.Name = "Fill"
			fill.BorderSizePixel = 0
			fill.BackgroundColor3 = col(spec.color, col(th.accent))
			fill.Size = UDim2.fromScale(math.clamp(tonumber(spec.value) or 1, 0, 1), 1)
			addCorner(fill, 999)
			fill.Parent = inst
		elseif kind == "Image" then
			inst.BackgroundTransparency = 1
			inst.Size = UDim2.fromOffset(64, 64)
		elseif kind == "Scroll" then
			inst.BackgroundTransparency = 1
			inst.Size = UDim2.fromScale(1, 1)
			inst.ScrollBarThickness = 6
			inst.AutomaticCanvasSize = Enum.AutomaticSize.Y
			inst.CanvasSize = UDim2.new()
			layout = layout or { dir = "vertical", gap = 8 }
		elseif kind == "Row" then
			inst.BackgroundTransparency = 1
			inst.Size = UDim2.new(1, 0, 0, 44)
			layout = layout or { dir = "horizontal", gap = 8 }
		elseif kind == "Column" or kind == "List" then
			inst.BackgroundTransparency = 1
			inst.Size = UDim2.new(1, 0, 0, 0)
			inst.AutomaticSize = Enum.AutomaticSize.Y
			layout = layout or { dir = "vertical", gap = 8 }
		elseif kind == "Grid" then
			inst.BackgroundTransparency = 1
			inst.Size = UDim2.new(1, 0, 0, 0)
			inst.AutomaticSize = Enum.AutomaticSize.Y
			local g = Instance.new("UIGridLayout")
			local cellSz = type(spec.cell) == "table" and spec.cell or { 100, 100 }
			g.CellSize = UDim2.fromOffset(cellSz[1] or 100, cellSz[2] or 100)
			g.CellPadding = UDim2.fromOffset(tonumber(spec.gap) or 8, tonumber(spec.gap) or 8)
			g.SortOrder = Enum.SortOrder.LayoutOrder
			g.Parent = inst
		end

		if spec.text ~= nil then
			pcall(function()
				inst.Text = tostring(spec.text)
			end)
		end
		if type(layout) == "table" then
			local ll = Instance.new("UIListLayout")
			ll.FillDirection = (layout.dir == "horizontal") and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
			ll.Padding = UDim.new(0, tonumber(layout.gap) or 8)
			ll.SortOrder = Enum.SortOrder.LayoutOrder
			if layout.h then
				pcall(function()
					ll.HorizontalAlignment = Enum.HorizontalAlignment[layout.h]
				end)
			end
			if layout.v then
				pcall(function()
					ll.VerticalAlignment = Enum.VerticalAlignment[layout.v]
				end)
			end
			ll.Parent = inst
			if tonumber(layout.padding) then
				addPadding(inst, tonumber(layout.padding))
			end
		end
		if tonumber(spec.aspect) then
			local ar = Instance.new("UIAspectRatioConstraint")
			ar.AspectRatio = tonumber(spec.aspect)
			ar.Parent = inst
		end
		if type(spec.max_size) == "table" or type(spec.min_size) == "table" then
			local sc = Instance.new("UISizeConstraint")
			if type(spec.max_size) == "table" then
				sc.MaxSize = Vector2.new(spec.max_size[1], spec.max_size[2])
			end
			if type(spec.min_size) == "table" then
				sc.MinSize = Vector2.new(spec.min_size[1], spec.min_size[2])
			end
			sc.Parent = inst
		end

		setProps(inst, spec.props)
		for i, child in ipairs(spec.children or {}) do
			buildUi(child, inst, th, state, depth + 1, i)
		end
		inst.Parent = parent
		return inst
	end

	function H.build_ui(a)
		local themeName = a.theme or "dark"
		local th = UI_THEMES[themeName]
		if not th then
			error("theme harus: dark, light, cartoon, atau neon", 0)
		end
		if type(a.spec) ~= "table" then
			error("parameter 'spec' (objek atau array elemen UI) wajib diisi", 0)
		end
		local parent = need(a.parent or "StarterGui")
		local gui = Instance.new("ScreenGui")
		gui.Name = a.name or "MainUI"
		gui.ResetOnSpawn = a.reset_on_spawn == true
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.IgnoreGuiInset = a.ignore_inset == true
		if tonumber(a.display_order) then
			gui.DisplayOrder = tonumber(a.display_order)
		end
		local nodes = (a.spec[1] ~= nil) and a.spec or { a.spec }
		local state = { n = 0 }
		for i, node in ipairs(nodes) do
			buildUi(node, gui, th, state, 1, i)
		end
		gui.Parent = parent
		return { path = pathOf(gui), elements = state.n, theme = themeName }
	end

	------------------------------------------------------------ asset importer
	local SUSPICIOUS = {
		{ "require%s*%(%s*%d+", "require(ID) memuat modul dari asset lain" },
		{ "loadstring", "loadstring" },
		{ "getfenv", "getfenv" },
		{ "setfenv", "setfenv" },
		{ "HttpService", "HttpService" },
		{ "MarketplaceService", "MarketplaceService" },
		{ "TeleportService", "TeleportService" },
		{ "InsertService", "InsertService" },
	}

	function H.search_assets(a)
		local q = tostring(a.query or "")
		if q == "" then
			error("parameter 'query' wajib diisi", 0)
		end
		local page = math.max(0, math.floor(tonumber(a.page) or 1) - 1)
		local ok, res = pcall(function()
			return InsertService:GetFreeModels(q, page)
		end)
		if not ok then
			error("Pencarian Toolbox tidak tersedia di Studio ini: " .. tostring(res) .. ". Minta user memberi asset ID dari Creator Store.", 0)
		end
		local first = type(res) == "table" and (res[1] or res) or {}
		local list = type(first.Results) == "table" and first.Results or {}
		local out = {}
		for i, r in ipairs(list) do
			if i > 15 then
				break
			end
			table.insert(out, { name = r.Name, asset_id = r.AssetId, creator = r.CreatorName })
		end
		return {
			count = #out,
			results = out,
			note = "Model gratis bisa berisi script berbahaya. insert_asset membuang semua script secara default.",
		}
	end

	function H.insert_asset(a)
		local id = tonumber(a.asset_id)
		if not id then
			error("asset_id harus angka", 0)
		end
		local parent = need(a.parent or "Workspace")
		local ok, wrapper = pcall(InsertService.LoadAsset, InsertService, id)
		if not ok then
			error(("Gagal memuat asset %d: %s (pastikan asset itu Model dan boleh dipakai)"):format(id, tostring(wrapper)), 0)
		end
		local removeScripts = a.remove_scripts ~= false
		local scripts, flagged = {}, {}
		for _, d in ipairs(wrapper:GetDescendants()) do
			if d:IsA("LuaSourceContainer") then
				table.insert(scripts, d)
				local src = ""
				pcall(function()
					src = d.Source
				end)
				for _, pat in ipairs(SUSPICIOUS) do
					if src:find(pat[1]) then
						table.insert(flagged, d.Name .. ": " .. pat[2])
					end
				end
			end
		end
		if removeScripts then
			for _, s in ipairs(scripts) do
				s:Destroy()
			end
		end

		local kids = wrapper:GetChildren()
		local result
		if a.group == false then
			for _, c in ipairs(kids) do
				c.Parent = parent
			end
			wrapper:Destroy()
			return { inserted = #kids, scripts_removed = removeScripts and #scripts or 0, flagged = flagged }
		end
		if #kids == 1 and kids[1]:IsA("PVInstance") then
			result = kids[1]
			result.Parent = parent
			wrapper:Destroy()
		else
			result = wrapper
			result.Name = "Asset_" .. id
			result.Parent = parent
		end
		if a.name then
			result.Name = a.name
		end
		if not result:IsA("PVInstance") then
			return { path = pathOf(result), scripts_removed = removeScripts and #scripts or 0, flagged = flagged }
		end
		if a.anchor ~= false then
			for _, d in ipairs(result:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Anchored = true
				end
			end
			if result:IsA("BasePart") then
				result.Anchored = true
			end
		end
		local factor = tonumber(a.scale)
		if factor and factor > 0 and factor <= 50 then
			if result:IsA("Model") then
				result:ScaleTo(result:GetScale() * factor)
			else
				scaleParts(result, factor)
			end
		end
		local pos = v3(a.position)
		if pos then
			result:PivotTo(CFrame.new(pos) * CFrame.Angles(0, math.rad(tonumber(a.yaw) or 0), 0))
		end
		local snapped
		if a.snap_to_ground == true then
			local sok, dy = pcall(snapToGround, result, a)
			snapped = sok and r2(dy) or nil
		end
		local mn, mx = boundsOf(result)
		return {
			path = pathOf(result),
			size = mn and arr(mx - mn) or nil,
			scripts_removed = removeScripts and #scripts or 0,
			scripts_kept = removeScripts and 0 or #scripts,
			flagged = flagged,
			snapped_dy = snapped,
		}
	end

	function H.import_mesh(a)
		local id = tonumber(a.mesh_id)
		if not id then
			error("mesh_id harus angka", 0)
		end
		local parent = need(a.parent or "Workspace")
		local ok, mp = pcall(function()
			return InsertService:CreateMeshPartAsync("rbxassetid://" .. id, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Automatic)
		end)
		if not ok then
			error("Gagal import mesh: " .. tostring(mp) .. " (pastikan asset mesh boleh dipakai)", 0)
		end
		mp.Name = a.name or ("Mesh_" .. id)
		mp.Anchored = a.anchored ~= false
		local tex = tonumber(a.texture_id)
		if tex then
			mp.TextureID = "rbxassetid://" .. tex
		end
		local size = v3(a.size)
		if size then
			mp.Size = size
		end
		local pos = v3(a.position)
		if pos then
			mp.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(tonumber(a.yaw) or 0), 0)
		end
		mp.Parent = parent
		return { path = pathOf(mp), size = arr(mp.Size) }
	end

	function H.apply_texture(a)
		local inst = need(a.path)
		if not inst:IsA("BasePart") then
			error("path harus BasePart atau MeshPart", 0)
		end
		local id = tonumber(a.texture_id)
		if not id then
			error("texture_id harus angka", 0)
		end
		local kind = a.kind or "Texture"
		if kind ~= "Decal" and kind ~= "Texture" then
			error("kind harus Decal atau Texture", 0)
		end
		local made = {}
		for _, faceName in ipairs(a.faces or { "Top" }) do
			local okF, face = pcall(function()
				return Enum.NormalId[faceName]
			end)
			if not okF or not face then
				error("face tidak valid: " .. tostring(faceName) .. " (Top, Bottom, Front, Back, Left, Right)", 0)
			end
			local d = Instance.new(kind)
			d.Face = face
			d.Texture = "rbxassetid://" .. id
			d.Transparency = tonumber(a.transparency) or 0
			if kind == "Texture" then
				local tile = tonumber(a.studs_per_tile) or 8
				d.StudsPerTileU = tile
				d.StudsPerTileV = tile
			end
			d.Parent = inst
			table.insert(made, faceName)
		end
		return { path = pathOf(inst), applied = made }
	end

	for _, n in ipairs({
		"notes", "lighting_preset", "terrain_generate", "build_building", "build_path", "build_stairs",
		"array", "snap_to_ground", "bulk_set", "build_ui", "insert_asset", "import_mesh", "apply_texture",
	}) do
		MUTATING[n] = true
	end
end

------------------------------------------------------------------ API LLM
local COMMANDS = {
	"ping", "get_tree", "find", "get_properties", "set_properties", "create", "delete", "clone",
	"move", "get_script", "edit_script", "set_script", "create_script", "get_output", "run_code",
	"batch", "get_selection", "set_selection", "insert_asset",
	"get_bounds", "layout_map", "check_issues", "scale_model", "pivot_to", "raycast_down", "terrain", "scatter", "focus",
	"list_skills", "load_skill", "notes", "style_presets", "lighting_preset", "terrain_generate", "build_building",
	"build_path", "build_stairs", "array", "snap_to_ground", "bulk_set", "build_ui", "search_assets",
	"import_mesh", "apply_texture",
}

local TOOLS = {
	{
		type = "function",
		["function"] = {
			name = "studio",
			description = "Jalankan satu perintah di Roblox Studio user. Lihat tabel command di instruksi sistem.",
			parameters = {
				type = "object",
				properties = {
					command = { type = "string", enum = COMMANDS },
					args = { type = "object", description = "Argumen perintah sesuai tabel command." },
				},
				required = { "command" },
			},
		},
	},
}

local TEXT_RULES = [[

## Cara memanggil Studio (mode teks)
Untuk menjalankan perintah, balas HANYA dengan satu blok seperti ini, tanpa teks lain:
```json
{"command": "get_tree", "args": {"path": "Workspace", "depth": 2}}
```
Hasilnya dikirim kembali sebagai pesan "HASIL:". Satu blok per balasan. Jika tugas selesai, jawab biasa tanpa blok json.
]]

local function buildSystemPrompt()
	return SYSTEM_PROMPT .. (cfg.textMode and TEXT_RULES or "")
end

local function headerValue(headers, name)
	for k, v in pairs(headers or {}) do
		if tostring(k):lower() == name then
			return v
		end
	end
	return nil
end

local function isRetryableStatus(code)
	return code == 408 or code == 409 or code == 425 or code == 429 or (code >= 500 and code <= 599)
end

local function statusHint(code)
	if code == 401 or code == 403 then
		return " (cek API key)"
	elseif code == 402 then
		return " (cek saldo/kuota akun API)"
	elseif code == 404 then
		return " (cek API URL dan nama model)"
	end
	return ""
end

-- Satu percobaan. Mengembalikan (berhasil, hasil_atau_pesan_error, bolehDiulang, retryAfterDetik)
local function callApiOnce(messages)
	local body = { model = cfg.model, messages = messages }
	if not cfg.textMode then
		body.tools = TOOLS
		body.tool_choice = "auto"
	end
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = cfg.url,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = "Bearer " .. cfg.key,
			},
			Body = HttpService:JSONEncode(body),
		})
	end)
	if not ok then
		local text = tostring(res)
		local retryable = true
		if text:find("HttpService is not allowed") or text:find("Http requests are not enabled") then
			text ..= "\nIzinkan akses HTTP untuk plugin ini."
			retryable = false
		end
		return false, "Gagal menghubungi API: " .. text, retryable
	end
	if not res.Success then
		return false,
			("API error %d%s: %s"):format(res.StatusCode, statusHint(res.StatusCode), res.Body:sub(1, 300)),
			isRetryableStatus(res.StatusCode),
			tonumber(headerValue(res.Headers, "retry-after"))
	end
	local okD, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not okD or type(data) ~= "table" then
		return false, "Respons API bukan JSON valid: " .. res.Body:sub(1, 200), true
	end
	local msg = type(data.choices) == "table" and type(data.choices[1]) == "table" and data.choices[1].message
	if type(msg) ~= "table" then
		local detail = data.error
		if detail ~= nil then
			local okE, enc = pcall(HttpService.JSONEncode, HttpService, detail)
			detail = okE and enc or tostring(detail)
		else
			detail = res.Body:sub(1, 200)
		end
		return false, "Respons API tidak berisi pesan: " .. tostring(detail), true
	end
	local hasText = type(msg.content) == "string" and msg.content:match("%S") ~= nil
	local hasCalls = type(msg.tool_calls) == "table" and #msg.tool_calls > 0
	if not hasText and not hasCalls then
		return false, "Respons API kosong", true
	end
	return true, msg
end

-- hooks: { log = function(text), status = function(text), cancelled = function() -> bool }
local function callApi(messages, hooks)
	local attempts = 1 + math.max(0, cfg.maxRetries or 0)
	local lastErr = "Gagal"
	local tried = 0
	for attempt = 1, attempts do
		tried += 1
		local ok, result, retryable, retryAfter = callApiOnce(messages)
		if ok then
			return result
		end
		lastErr = result
		if not retryable or attempt == attempts then
			break
		end
		local delay = math.min(2 ^ attempt, 30) + math.random()
		if retryAfter then
			delay = math.clamp(retryAfter, 1, 60)
		end
		hooks.log(("%s\nMencoba lagi dalam %d detik (%d/%d)..."):format(lastErr, math.ceil(delay), attempt, attempts - 1))
		hooks.status("API bermasalah, menunggu untuk mencoba lagi...")
		for _ = 1, math.ceil(delay * 2) do
			if hooks.cancelled() then
				error("Dihentikan.", 0)
			end
			task.wait(0.5)
		end
	end
	if tried > 1 then
		lastErr ..= ("\n(Sudah mencoba %d kali. Ketik 'lanjut' untuk mencoba lagi.)"):format(tried)
	end
	error(lastErr, 0)
end

local function parseTextCall(content)
	local inner = content:match("```json%s*(.-)%s*```") or content:match("```%s*(%b{})%s*```")
	if not inner then
		return nil
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, inner)
	if ok and type(data) == "table" and data.command then
		return data
	end
	return nil
end

local function short(v)
	local ok, s = pcall(HttpService.JSONEncode, HttpService, v)
	s = ok and s or "?"
	if #s > 110 then
		s = s:sub(1, 110) .. "..."
	end
	return s
end

local function withContext(text)
	local extra = {}
	local okS, sel = pcall(H.get_selection)
	if okS and #sel > 0 then
		local paths = {}
		for i, s in ipairs(sel) do
			if i > 10 then
				break
			end
			table.insert(paths, s.path .. " (" .. s.class .. ")")
		end
		table.insert(extra, "Seleksi di Explorer: " .. table.concat(paths, ", "))
	end
	local okA, active = pcall(function()
		return StudioService.ActiveScript
	end)
	if okA and active then
		table.insert(extra, "Script yang sedang dibuka: " .. pathOf(active))
	end
	local okN, nv = pcall(function()
		return game:GetService("ServerStorage"):FindFirstChild("AI_Notes")
	end)
	if okN and nv and nv.Value ~= "" then
		table.insert(extra, "Catatan proyek (notes):\n" .. nv.Value:sub(1, 1500))
	end
	if #extra == 0 then
		return text
	end
	return text .. "\n\n[Konteks Studio]\n" .. table.concat(extra, "\n")
end

------------------------------------------------------------------ UI
local studioTheme = settings().Studio
local themed = {}
local SG = Enum.StudioStyleGuideColor

local function theme(inst, prop, guide)
	table.insert(themed, { inst, prop, guide })
	inst[prop] = studioTheme.Theme:GetColor(guide)
end

local function new(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		local ok, err = pcall(function()
			inst[k] = v
		end)
		if not ok then
			warn(("[AI Agent] properti dilewati: %s.%s (%s)"):format(class, tostring(k), tostring(err)))
		end
	end
	inst.Parent = parent
	return inst
end

local widget = plugin:CreateDockWidgetPluginGui(
	"AIAgentChat",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 420, 620, 320, 320)
)
widget.Title = "AI Agent"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

studioTheme.ThemeChanged:Connect(function()
	for i = #themed, 1, -1 do
		local t = themed[i]
		if t[1]:IsDescendantOf(widget) then
			t[1][t[2]] = studioTheme.Theme:GetColor(t[3])
		else
			table.remove(themed, i)
		end
	end
end)

local function button(parent, text, size, pos, accent)
	local b = new("TextButton", {
		Text = text, Size = size, Position = pos, BorderSizePixel = 0,
		Font = Enum.Font.SourceSansSemibold, TextSize = 14,
	}, parent)
	theme(b, "BackgroundColor3", accent and SG.DialogMainButton or SG.Button)
	theme(b, "TextColor3", accent and SG.DialogMainButtonText or SG.ButtonText)
	new("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
	return b
end

local function styleInput(box)
	theme(box, "BackgroundColor3", SG.InputFieldBackground)
	theme(box, "TextColor3", SG.MainText)
	local stroke = new("UIStroke", { Thickness = 1 }, box)
	theme(stroke, "Color", SG.InputFieldBorder)
	new("UICorner", { CornerRadius = UDim.new(0, 4) }, box)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
		PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
	}, box)
end

local FOOT = 118
local root = new("Frame", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, widget)
theme(root, "BackgroundColor3", SG.MainBackground)

-- Bilah atas
local top = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BorderSizePixel = 0 }, root)
theme(top, "BackgroundColor3", SG.Titlebar)
local title = new("TextLabel", {
	BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -170, 1, 0),
	Text = "AI Agent", Font = Enum.Font.SourceSansBold, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left,
}, top)
theme(title, "TextColor3", SG.MainText)
local resetBtn = button(top, "Baru", UDim2.fromOffset(60, 22), UDim2.new(1, -140, 0, 5), false)
local settingsBtn = button(top, "Setelan", UDim2.fromOffset(70, 22), UDim2.new(1, -74, 0, 5), false)

-- Area chat
local chat = new("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 1, -(32 + FOOT)),
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 8,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollingDirection = Enum.ScrollingDirection.Y,
}, root)
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, chat)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 12),
}, chat)

-- Footer
local footer = new("Frame", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1),
	Size = UDim2.new(1, 0, 0, FOOT), BorderSizePixel = 0,
}, root)
theme(footer, "BackgroundColor3", SG.MainBackground)
local statusLabel = new("TextLabel", {
	BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 2), Size = UDim2.new(1, -16, 0, 16),
	Text = "", Font = Enum.Font.SourceSans, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
}, footer)
theme(statusLabel, "TextColor3", SG.SubText)
local input = new("TextBox", {
	Position = UDim2.fromOffset(8, 20), Size = UDim2.new(1, -16, 0, 64), Text = "",
	PlaceholderText = "Tulis tugas untuk AI...", ClearTextOnFocus = false, MultiLine = true,
	TextWrapped = true, Font = Enum.Font.SourceSans, TextSize = 14, BorderSizePixel = 0,
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, footer)
styleInput(input)
local sendBtn = button(footer, "Kirim", UDim2.fromOffset(90, 26), UDim2.new(1, -98, 0, 88), true)

-- Pesan
local msgOrder = 0
local function setStatus(text)
	statusLabel.Text = text
end

local function scrollDown()
	task.defer(function()
		RunService.Heartbeat:Wait()
		chat.CanvasPosition = Vector2.new(0, math.max(0, chat.AbsoluteCanvasSize.Y))
	end)
end

local function addMessage(kind, text)
	msgOrder += 1
	local row = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = msgOrder,
	}, chat)
	local isUser = kind == "user"
	local bubble = new("TextLabel", {
		AnchorPoint = Vector2.new(isUser and 1 or 0, 0),
		Position = UDim2.new(isUser and 1 or 0, 0, 0, 0),
		Size = UDim2.new(kind == "tool" and 1 or 0.92, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, Text = text, TextWrapped = true, RichText = false,
		TextSelectable = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		Font = kind == "tool" and Enum.Font.Code or Enum.Font.SourceSans,
		TextSize = kind == "tool" and 12 or 14, BorderSizePixel = 0,
	}, row)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
		PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
	}, bubble)
	if kind == "user" then
		theme(bubble, "BackgroundColor3", SG.DialogMainButton)
		theme(bubble, "TextColor3", SG.DialogMainButtonText)
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, bubble)
	elseif kind == "assistant" then
		theme(bubble, "BackgroundColor3", SG.InputFieldBackground)
		theme(bubble, "TextColor3", SG.MainText)
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, bubble)
		local stroke = new("UIStroke", { Thickness = 1 }, bubble)
		theme(stroke, "Color", SG.InputFieldBorder)
	elseif kind == "error" then
		bubble.BackgroundTransparency = 1
		theme(bubble, "TextColor3", SG.ErrorText)
	else
		bubble.BackgroundTransparency = 1
		theme(bubble, "TextColor3", SG.SubText)
	end
	scrollDown()
end

-- Panel pengaturan
local panel = new("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1), Visible = false, BorderSizePixel = 0, ZIndex = 10, Active = true,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6,
}, root)
theme(panel, "BackgroundColor3", SG.MainBackground)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, panel)
new("UIPadding", { PaddingTop = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, panel)

local pOrder = 0
local function panelLabel(text)
	pOrder += 1
	local l = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), Text = text, ZIndex = 11,
		Font = Enum.Font.SourceSansSemibold, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = pOrder,
	}, panel)
	theme(l, "TextColor3", SG.MainText)
end

local function panelField(text)
	panelLabel(text)
	pOrder += 1
	local box = new("TextBox", {
		Size = UDim2.new(1, 0, 0, 28), Text = "", ClearTextOnFocus = false, ZIndex = 11,
		Font = Enum.Font.SourceSans, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd, BorderSizePixel = 0, LayoutOrder = pOrder,
	}, panel)
	styleInput(box)
	return box
end

local urlBox = panelField("API URL (OpenAI-compatible /chat/completions)")
local keyBox = panelField("API Key")
local modelBox = panelField("Nama model")
local stepsBox = panelField("Maksimal langkah per tugas")
local retryBox = panelField("Maksimal retry saat API error (0 = mati)")

pOrder += 1
local modeBtn = button(panel, "", UDim2.new(1, 0, 0, 28), UDim2.new(), false)
modeBtn.ZIndex = 11
modeBtn.LayoutOrder = pOrder

pOrder += 1
local skillBtn = button(panel, "", UDim2.new(1, 0, 0, 28), UDim2.new(), false)
skillBtn.ZIndex = 11
skillBtn.LayoutOrder = pOrder

pOrder += 1
local btnRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = pOrder, ZIndex = 11 }, panel)
local saveBtn = button(btnRow, "Simpan", UDim2.new(0.5, -3, 1, 0), UDim2.new(), true)
local closeBtn = button(btnRow, "Tutup", UDim2.new(0.5, -3, 1, 0), UDim2.new(0.5, 3, 0, 0), false)
saveBtn.ZIndex = 11
closeBtn.ZIndex = 11

pOrder += 1
local note = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), TextWrapped = true, ZIndex = 11,
	Text = "Mode teks: aktifkan jika API/model tidak mendukung tool calling.\nSkill GitHub butuh izin HTTP ke raw.githubusercontent.com.\nAPI key disimpan lokal di pengaturan plugin ini.",
	Font = Enum.Font.SourceSans, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top, LayoutOrder = pOrder,
}, panel)
theme(note, "TextColor3", SG.SubText)

local keyReal = cfg.key
local function mask(s)
	return s == "" and "" or string.rep("*", math.min(#s, 24))
end
keyBox.Focused:Connect(function()
	keyBox.Text = keyReal
end)
keyBox.FocusLost:Connect(function()
	keyReal = keyBox.Text
	keyBox.Text = mask(keyReal)
end)

local function refreshModeButton()
	modeBtn.Text = "Mode teks (tanpa tool calling): " .. (cfg.textMode and "AKTIF" or "mati")
	skillBtn.Text = "Skill roblox-brain dari GitHub: " .. (cfg.skillsOnline ~= false and "AKTIF" or "mati (ringkasan bawaan)")
end
modeBtn.Activated:Connect(function()
	cfg.textMode = not cfg.textMode
	refreshModeButton()
end)
skillBtn.Activated:Connect(function()
	cfg.skillsOnline = not (cfg.skillsOnline ~= false)
	refreshModeButton()
end)

local function trim(s)
	return (s:match("^%s*(.-)%s*$"))
end

local function showPanel(visible)
	if visible then
		urlBox.Text = cfg.url
		keyReal = cfg.key
		keyBox.Text = mask(keyReal)
		modelBox.Text = cfg.model
		stepsBox.Text = tostring(cfg.maxSteps)
		retryBox.Text = tostring(cfg.maxRetries)
		refreshModeButton()
	end
	panel.Visible = visible
end

saveBtn.Activated:Connect(function()
	if keyBox:IsFocused() then
		keyReal = keyBox.Text
	end
	cfg.url = trim(urlBox.Text)
	cfg.key = trim(keyReal)
	cfg.model = trim(modelBox.Text)
	cfg.maxSteps = math.clamp(math.floor(tonumber(stepsBox.Text) or 25), 1, 60)
	cfg.maxRetries = math.clamp(math.floor(tonumber(retryBox.Text) or 4), 0, 10)
	saveCfg()
	showPanel(false)
	if not cfg.url:match("^https://") then
		addMessage("error", "API URL harus diawali https://")
	end
end)
closeBtn.Activated:Connect(function()
	cfg.textMode = plugin:GetSetting("cfg_textMode") == true
	cfg.skillsOnline = plugin:GetSetting("cfg_skillsOnline") ~= false
	showPanel(false)
end)
settingsBtn.Activated:Connect(function()
	showPanel(true)
end)

------------------------------------------------------------------ AGENT
local messages = {}
local busy = false
local cancelled = false
local resumable = false

local function updateSendButton()
	sendBtn.Text = busy and "Stop" or "Kirim"
end

local function resetConversation()
	messages = {}
	resumable = false
	for _, c in ipairs(chat:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	msgOrder = 0
end

local retryHooks = {
	log = function(text)
		addMessage("tool", text)
	end,
	status = setStatus,
	cancelled = function()
		return cancelled
	end,
}

------------------------------------------------------------------ KETAHANAN API (resume, riwayat, konteks)
local MAX_HISTORY_CHARS = 200000

local function cutUtf8(s, n)
	if #s <= n then
		return s
	end
	local cut = n
	while cut > 0 do
		local b = s:byte(cut + 1)
		if b and b >= 128 and b < 192 then
			cut -= 1
		else
			break
		end
	end
	return s:sub(1, cut)
end

-- Setiap assistant.tool_calls harus punya balasan tool; kalau tidak, API menolak (400).
local function sanitizeHistory()
	local i = 1
	while i <= #messages do
		local m = messages[i]
		if m.role == "assistant" and type(m.tool_calls) == "table" and #m.tool_calls > 0 then
			local answered = {}
			local j = i + 1
			while j <= #messages and messages[j].role == "tool" do
				answered[messages[j].tool_call_id] = true
				j += 1
			end
			local missing = {}
			for _, c in ipairs(m.tool_calls) do
				if c.id and not answered[c.id] then
					table.insert(missing, {
						role = "tool",
						tool_call_id = c.id,
						content = '{"ok":false,"error":"dibatalkan sebelum dijalankan"}',
					})
				end
			end
			for k, extra in ipairs(missing) do
				table.insert(messages, j + k - 1, extra)
			end
			i = j + #missing
		else
			i += 1
		end
	end
end

local function historySize()
	local n = 0
	for _, m in ipairs(messages) do
		n += (type(m.content) == "string") and #m.content or 0
		if m.tool_calls then
			n += 300
		end
	end
	return n
end

-- Ringkas hasil tool lama supaya konteks muat; pesan terbaru dibiarkan utuh.
local function compactHistory(keepLast, maxLen)
	local saved = 0
	for i = 1, #messages - keepLast do
		local m = messages[i]
		if m.role == "tool" and type(m.content) == "string" and #m.content > maxLen then
			saved += #m.content - maxLen
			m.content = cutUtf8(m.content, maxLen) .. "...[dipotong untuk menghemat konteks]"
		end
	end
	return saved
end

local function looksLikeOverflow(text)
	local t = text:lower()
	return t:find("context length", 1, true) ~= nil
		or t:find("context_length", 1, true) ~= nil
		or t:find("maximum context", 1, true) ~= nil
		or t:find("too many tokens", 1, true) ~= nil
		or t:find("too long", 1, true) ~= nil
		or t:find("request too large", 1, true) ~= nil
		or t:find("api error 413", 1, true) ~= nil
end

-- Satu langkah ke model: memperbaiki riwayat, meringkas bila terlalu panjang, retry sudah ada di callApi.
local function requestModel()
	sanitizeHistory()
	if historySize() > MAX_HISTORY_CHARS then
		local saved = compactHistory(8, 400)
		if saved > 0 then
			addMessage("tool", ("Riwayat panjang: hasil tool lama diringkas (hemat %d karakter)."):format(saved))
		end
	end
	local function attempt()
		local payload = { { role = "system", content = buildSystemPrompt() } }
		for _, m in ipairs(messages) do
			table.insert(payload, m)
		end
		return pcall(callApi, payload, retryHooks)
	end
	local ok, res = attempt()
	if not ok and looksLikeOverflow(tostring(res)) then
		local saved = compactHistory(4, 200)
		if saved > 0 then
			addMessage("tool", "Konteks penuh: meringkas hasil tool lama lalu mencoba lagi tanpa mengulang dari awal...")
			ok, res = attempt()
		end
	end
	return ok, res
end

local function runAgent(userText, resume)
	resumable = false
	if resume then
		if #messages == 0 then
			addMessage("tool", "Tidak ada pekerjaan yang bisa dilanjutkan.")
			return
		end
		addMessage("tool", "Melanjutkan dari langkah terakhir (riwayat dipertahankan)...")
	else
		table.insert(messages, { role = "user", content = withContext(userText) })
	end
	for step = 1, cfg.maxSteps do
		if cancelled then
			addMessage("tool", "Dihentikan. Tekan Kirim (kolom kosong) untuk melanjutkan dari sini.")
			resumable = true
			return
		end
		setStatus(("Menunggu model... (langkah %d)"):format(step))
		local ok, msg = requestModel()
		if not ok then
			local text = tostring(msg)
			if text:lower():find("tool") then
				text ..= "\nSepertinya model ini tidak mendukung tool calling. Aktifkan Mode teks di Setelan."
			end
			if text == "Dihentikan." then
				text ..= " Tekan Kirim (kolom kosong) untuk melanjutkan."
			else
				text ..= "\nProgres tersimpan. Tekan Kirim (kolom kosong) atau ketik 'lanjut' untuk melanjutkan dari langkah ini tanpa mengulang dari awal."
			end
			resumable = true
			addMessage("error", text)
			return
		end
		local content = type(msg.content) == "string" and msg.content or ""

		if cfg.textMode then
			table.insert(messages, { role = "assistant", content = content })
			local call = parseTextCall(content)
			if not call then
				addMessage("assistant", content ~= "" and content or "(kosong)")
				return
			end
			local prose = trim((content:gsub("```.-```", "")))
			if prose ~= "" then
				addMessage("assistant", prose)
			end
			addMessage("tool", "> " .. tostring(call.command) .. " " .. short(call.args or {}))
			setStatus("Menjalankan " .. tostring(call.command) .. "...")
			local success, result = runTool(call.command, call.args or {})
			if not success then
				addMessage("error", tostring(call.command) .. " gagal: " .. result)
			end
			table.insert(messages, { role = "user", content = "HASIL:\n" .. result })
		else
			local calls = msg.tool_calls
			local hasCalls = type(calls) == "table" and #calls > 0
			local entry = { role = "assistant", content = content }
			if hasCalls then
				entry.tool_calls = calls
			end
			table.insert(messages, entry)
			if content ~= "" then
				addMessage("assistant", content)
			end
			if not hasCalls then
				if content == "" then
					addMessage("assistant", "(kosong)")
				end
				return
			end
			for _, call in ipairs(calls) do
				local fn = call["function"] or {}
				local okP, params = pcall(HttpService.JSONDecode, HttpService, fn.arguments or "{}")
				local result
				if okP and type(params) == "table" then
					local command = params.command
					local args = type(params.args) == "table" and params.args or {}
					addMessage("tool", "> " .. tostring(command) .. " " .. short(args))
					setStatus("Menjalankan " .. tostring(command) .. "...")
					local success
					success, result = runTool(command, args)
					if not success then
						addMessage("error", tostring(command) .. " gagal: " .. result)
					end
				else
					result = HttpService:JSONEncode({ ok = false, error = "arguments bukan JSON valid" })
				end
				table.insert(messages, { role = "tool", tool_call_id = call.id, content = result })
			end
		end
	end
	resumable = true
	addMessage("tool", "Batas langkah tercapai. Tekan Kirim (kolom kosong) atau ketik 'lanjut' untuk meneruskan dari sini.")
end

local function onSend()
	if busy then
		cancelled = true
		setStatus("Menghentikan setelah langkah ini...")
		return
	end
	local text = trim(input.Text)
	local lower = text:lower()
	local wantsResume = resumable
		and (text == "" or lower == "lanjut" or lower == "retry" or lower == "ulang" or lower == "coba lagi")
	if text == "" and not wantsResume then
		return
	end
	if cfg.key == "" or cfg.model == "" then
		addMessage("error", "Isi API key dan nama model di Setelan dulu.")
		showPanel(true)
		return
	end
	input.Text = ""
	if text ~= "" then
		addMessage("user", text)
	end
	busy, cancelled = true, false
	updateSendButton()
	task.spawn(function()
		local ok, err
		if wantsResume then
			ok, err = pcall(runAgent, nil, true)
		else
			ok, err = pcall(runAgent, text, false)
		end
		if not ok then
			addMessage("error", tostring(err))
		end
		busy = false
		setStatus("")
		updateSendButton()
	end)
end

sendBtn.Activated:Connect(onSend)
resetBtn.Activated:Connect(function()
	if busy then
		cancelled = true
	end
	resetConversation()
	addMessage("assistant", "Percakapan baru. Apa yang mau dikerjakan?")
end)

------------------------------------------------------------------ TOOLBAR
local toolbar = plugin:CreateToolbar("AI Agent")
local toggle = toolbar:CreateButton("AIAgentChat", "Buka/tutup chat AI Agent", "", "AI Agent")
toggle.ClickableWhenViewportHidden = true
toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggle:SetActive(widget.Enabled)
end)
toggle:SetActive(widget.Enabled)

addMessage(
	"assistant",
	"Halo! Atur API key dan model di Setelan, lalu tulis tugasmu. Semua perubahan yang kubuat bisa dibatalkan dengan Ctrl+Z. Kalau API error saya coba lagi otomatis; jika tetap gagal, tekan Kirim dengan kolom kosong untuk melanjutkan dari langkah terakhir."
)

print("[AI Agent] plugin dimuat")
