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

local MUTATING = {
	set_properties = true, create = true, delete = true, clone = true, move = true,
	set_script = true, edit_script = true, create_script = true, run_code = true,
	insert_asset = true, batch = true,
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
| `insert_asset` | `asset_id`, `parent` | Sisipkan model dari Toolbox |

Semua perubahan = satu langkah Ctrl+Z. Jika sebuah perintah gagal, perubahannya dibatalkan. Pakai `batch` untuk pekerjaan multi-langkah agar atomik.

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
		text = text:sub(1, MAX_RESULT) .. "...[dipotong; persempit query atau pakai start_line/end_line]"
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

------------------------------------------------------------------ API LLM
local COMMANDS = {
	"ping", "get_tree", "find", "get_properties", "set_properties", "create", "delete", "clone",
	"move", "get_script", "edit_script", "set_script", "create_script", "get_output", "run_code",
	"batch", "get_selection", "set_selection", "insert_asset",
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

local function callApi(messages)
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
		error("Gagal menghubungi API: " .. tostring(res) .. "\nPastikan kamu mengizinkan akses HTTP untuk plugin ini.", 0)
	end
	if not res.Success then
		error(("API error %d: %s"):format(res.StatusCode, res.Body:sub(1, 500)), 0)
	end
	local okD, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not okD or type(data) ~= "table" or not data.choices or not data.choices[1] then
		error("Respons API tidak terduga: " .. res.Body:sub(1, 300), 0)
	end
	return data.choices[1].message
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
		inst[k] = v
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
local panel = new("Frame", { Size = UDim2.fromScale(1, 1), Visible = false, BorderSizePixel = 0, ZIndex = 10, Active = true }, root)
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

pOrder += 1
local modeBtn = button(panel, "", UDim2.new(1, 0, 0, 28), UDim2.new(), false)
modeBtn.ZIndex = 11
modeBtn.LayoutOrder = pOrder

pOrder += 1
local btnRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = pOrder, ZIndex = 11 }, panel)
local saveBtn = button(btnRow, "Simpan", UDim2.new(0.5, -3, 1, 0), UDim2.new(), true)
local closeBtn = button(btnRow, "Tutup", UDim2.new(0.5, -3, 1, 0), UDim2.new(0.5, 3, 0, 0), false)
saveBtn.ZIndex = 11
closeBtn.ZIndex = 11

pOrder += 1
local note = new("TextLabel", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), TextWrapped = true, ZIndex = 11,
	Text = "Mode teks: aktifkan jika API/model tidak mendukung tool calling.\nAPI key disimpan lokal di pengaturan plugin ini.",
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
end
modeBtn.Activated:Connect(function()
	cfg.textMode = not cfg.textMode
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
	saveCfg()
	showPanel(false)
	if not cfg.url:match("^https://") then
		addMessage("error", "API URL harus diawali https://")
	end
end)
closeBtn.Activated:Connect(function()
	cfg.textMode = plugin:GetSetting("cfg_textMode") == true
	showPanel(false)
end)
settingsBtn.Activated:Connect(function()
	showPanel(true)
end)

------------------------------------------------------------------ AGENT
local messages = {}
local busy = false
local cancelled = false

local function updateSendButton()
	sendBtn.Text = busy and "Stop" or "Kirim"
end

local function resetConversation()
	messages = {}
	for _, c in ipairs(chat:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	msgOrder = 0
end

local function runAgent(userText)
	table.insert(messages, { role = "user", content = withContext(userText) })
	for step = 1, cfg.maxSteps do
		if cancelled then
			addMessage("tool", "Dihentikan.")
			return
		end
		setStatus(("Menunggu model... (langkah %d)"):format(step))
		local payload = { { role = "system", content = buildSystemPrompt() } }
		for _, m in ipairs(messages) do
			table.insert(payload, m)
		end
		local ok, msg = pcall(callApi, payload)
		if not ok then
			local text = tostring(msg)
			if text:lower():find("tool") then
				text ..= "\nSepertinya model ini tidak mendukung tool calling. Aktifkan Mode teks di Setelan."
			end
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
	addMessage("tool", "Batas langkah tercapai. Ketik 'lanjut' untuk meneruskan.")
end

local function onSend()
	if busy then
		cancelled = true
		setStatus("Menghentikan setelah langkah ini...")
		return
	end
	local text = trim(input.Text)
	if text == "" then
		return
	end
	if cfg.key == "" or cfg.model == "" then
		addMessage("error", "Isi API key dan nama model di Setelan dulu.")
		showPanel(true)
		return
	end
	input.Text = ""
	addMessage("user", text)
	busy, cancelled = true, false
	updateSendButton()
	task.spawn(function()
		local ok, err = pcall(runAgent, text)
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
	"Halo! Atur API key dan model di Setelan, lalu tulis tugasmu. Semua perubahan yang kubuat bisa dibatalkan dengan Ctrl+Z."
)
