-- CraftPlan 2.0 — "План по руде": squeeze all skill out of one ore. Only orange and yellow crafts count (green is
-- left out — too much ore per point). Ore is mined as much as needed; the plan says how much. Yellow (and the
-- leftover green) crafts count with a 85% margin, as prospecting: the plan reaches its skill with CONF, not on average.
-- "Используя всё из сумок" (on by default): bags, bank and the reagent storage go in, including other materials
-- of recipes that also need this ore; off — pure ore, the stock is ignored.
-- "До следующей руды" (off by default): each profession stops at the skill where a later ore starts giving
-- orange crafts; "Дальше:" under the plan names that ore.
-- The mined veins also drop stone, gems, crystals (Data/VeinData.lua) — they go into the plan as free by-products.
-- After that, what is left from the bags and the mined veins (stone, gems) goes into any recipe that still
-- gives skill, green included, down to grey — no extra prospecting for them; those crafts are shown green.
-- A tab of the panel ("План по руде", after "Просеивание"), shown with mining and blacksmithing, jewelcrafting or
-- engineering: all ore on the left (normal — gives skill; grey — gives none; red — skill too low), the plan of the
-- selected one on the right.
-- The tab itself is drawn by UI/OrePlan.lua (CP.DrawOrePlan); this file is the calculation and the stacks.
local CP = CraftPlan

local ORES = CP.ORES -- ore in display order (Core.lua)
local STONE = CP.STONE -- stone that comes out of the same veins (rough .. dense); outer-world ores have none
local ORE_SET = {}
for _, id in ipairs(ORES) do ORE_SET[id] = true end
function CP.IsOre(id) return id and ORE_SET[id] or false end

----------------------------------------------------------------------------------------------
-- Calculation
-- Memo until CP.DropCache (skill, learned recipes, trainer data and bags can change only through it):
-- the candidate recipe list, Derive(O, false) per ore and NextCap per ore. Shared — not changed by readers.
local allMemo, deriveMemo, capMemo = nil, {}, {}
CP.OnDrop(function() allMemo, deriveMemo, capMemo = nil, {}, {} end)

-- recipes of your professions: learned, or learnable at the trainer (at the skill it is learned at)
local function Candidates(lines)
	if allMemo then return allMemo end
	local all = {}
	for prof, sk in pairs(CP.SKILL_ID) do
		if lines[prof] then
			for _, rec in ipairs(CP.Recipes(sk)) do
				if rec.reag[1] then
					local known = CP.KnownRecipe(prof, rec.name) and true or false
					local li = not known and CP.LearnInfo(sk, prof, rec.name)
					if known or (li and li.at) then
						all[#all + 1] = { rec = rec, prof = prof, sk = sk, known = known, req = known and 0 or (CP.LearnReq(sk, rec.name) or 0) }
					end
				end
			end
		end
	end
	allMemo = all
	return all
end

-- what can be made of ore O: the recipe set R and what it is built from
local function DoDerive(O, useStock)
	local lines = CP.SkillLines()
	-- prospecting: only a jeweler with the spell and enough skill for this ore
	local gemPer, gemSt = {}, {}
	local pdata = CP.ProspectData and CP.ProspectData(O)
	if pdata and CP.CanProspect() and CP.JewelRank() >= CP.ProspectReq(O) then
		for _, g in ipairs(pdata) do gemPer[g[1]] = g[2] / 100 * g[5]; gemSt[g[1]] = CP.DropStat(g) end
	end
	local all = Candidates(lines)
	-- what comes from this ore: the ore, gems of its prospecting and everything made only of them;
	-- with the stock also recipes whose other materials you already have (as many as they last)
	local ok, extra, R, inR = { [O] = true }, {}, {}, {}
	for gem in pairs(gemPer) do ok[gem] = true end
	-- by-products: gems of prospecting and the vein stone — free, but only as many as there are (the stone is not made)
	local byprod = {}
	for gem in pairs(gemPer) do byprod[gem] = true end
	if STONE[O] then ok[STONE[O]] = true; byprod[STONE[O]] = true end
	-- what the veins drop along with the ore (stone, gems, crystals): comes with every mined ore (Data/VeinData.lua)
	local vein = CP.VeinBase and CP.VeinBase(O)
	if vein then for id in pairs(vein.drops) do ok[id] = true; byprod[id] = true end end
	local grow = true
	while grow do
		grow = false
		for _, c in ipairs(all) do
			if not inR[c] then
				local some, every = false, true
				for _, g in ipairs(c.rec.reag) do
					if ok[g.id] then some = true
					elseif not (useStock and CP.Have(g.id) > 0) then every = false break end
				end
				if some and every then
					inR[c] = true
					R[#R + 1] = c
					for _, g in ipairs(c.rec.reag) do if not ok[g.id] then extra[g.id] = true end end
					if c.rec.item > 0 and not ok[c.rec.item] then ok[c.rec.item] = true; extra[c.rec.item] = nil end
					grow = true
				end
			end
		end
	end
	return { lines = lines, gemPer = gemPer, gemSt = gemSt, ok = ok, extra = extra, R = R, byprod = byprod, vein = vein }
end
-- without the stock the result does not depend on bags: memoized per ore
local function Derive(O, useStock)
	if useStock then return DoDerive(O, true) end
	local d = deriveMemo[O]
	if not d then d = DoDerive(O, false); deriveMemo[O] = d end
	return d
end

-- "До следующей руды": per profession, the skill where a later ore starts giving orange crafts.
-- start is the current skill of every profession (the same within one drop), so the result is memoized per ore.
local function NextCap(O, start)
	local m = capMemo[O]
	if m then return m[1], m[2] end
	local cap, nextOre = {}, {}
	local after = false
	for _, N in ipairs(ORES) do
		if after then
			local found = {}
			for _, c in ipairs(Derive(N, false).R) do
				local p = c.prof
				if not nextOre[p] then
					local from = math.max(c.known and 0 or c.req, math.floor(start[p] + 1e-9))
					if from < c.rec.y then found[p] = math.min(found[p] or from, from) end
				end
			end
			for p, at in pairs(found) do nextOre[p], cap[p] = N, at end
		end
		if N == O then after = true end
	end
	capMemo[O] = { cap, nextOre }
	return cap, nextOre
end

local KIND_LETTER = { optimal = "o", medium = "y" }
local function OrePlan(O, off, useStock, toNext)
	local D = Derive(O, useStock)
	local lines, gemPer, gemSt, ok, extra, R, byprod, vein = D.lines, D.gemPer, D.gemSt, D.ok, D.extra, D.R, D.byprod, D.vein
	local rank, start = {}, {}
	for prof, L in pairs(lines) do rank[prof], start[prof] = L.rank, L.rank end
	local function Stock(id) return useStock and CP.Have(id) or 0 end
	local cap, nextOre = {}, {}
	if toNext then cap, nextOre = NextCap(O, start) end
	local prodOf = {}
	for _, c in ipairs(R) do
		local it = c.rec.item
		if it > 0 and (not prodOf[it] or (c.known and not prodOf[it].known)) then prodOf[it] = c end
	end
	-- orange ("o") and yellow up to the midpoint of yellow..grey ("y") count; everything else is "x"
	local function Kind(c)
		local k = math.floor(rank[c.prof] + 1e-9)
		if k >= lines[c.prof].max or (cap[c.prof] and k >= cap[c.prof]) then return "x" end
		return KIND_LETTER[CP.KindAt(c.rec.y, c.rec.g, k)] or "x"
	end
	-- skill-up chance at the current (floored) skill; 0 at the profession max, at grey or when grey <= yellow
	local function Ch(c)
		return CP.ChanceAt(c.rec, math.floor(rank[c.prof] + 1e-9), lines[c.prof].max)
	end
	local function Usable(c) return c.known or rank[c.prof] >= c.req end
	local pool = {}
	for id in pairs(ok) do pool[id] = Stock(id) end
	for id in pairs(extra) do pool[id] = Stock(id) end
	local mined, prospects, smelt, log, learn = 0, 0, 0, {}, {}
	-- with the stock: the other stacks (all but this ore's own plan stacks) take their share of the stock first,
	-- and the ore they lack is mined together with the plan (its veins drop by-products too)
	local stackOre, stackUse = 0, 0
	if useStock then
		local data, g = CP.Compute(), CP.Goal()
		for _, si in ipairs(data.order) do
			local st, t = g.stacks[si], data.trees[si]
			if t and not (st and st.orePlan and st.orePlan.ore == O) then
				for id, n in pairs(t.nodes) do
					local use = n.gross - n.made - n.short
					if use > 0 and pool[id] then pool[id] = math.max(0, pool[id] - use) end
				end
				local n = t.nodes[O]
				if n then stackOre, stackUse = stackOre + n.short, stackUse + n.gross end
			end
		end
		mined = stackOre
	end
	-- price in ore: ore and bars always by ore (stock is ore too), gems from stock — free (already there or dropped along the way)
	local function Cost(id, n, depth)
		if id == O then return n end
		if extra[id] or (byprod[id] and not gemPer[id]) then return (pool[id] or 0) >= n - 1e-9 and 0 or 1e9 end
		local free = gemPer[id] and math.min(pool[id] or 0, n) or 0
		local left = n - free
		if left <= 0 then return 0 end
		if gemPer[id] then return left * 5 / gemPer[id] end
		local pr = prodOf[id]
		if not pr or depth > 4 then return 1e9 end
		local t = math.ceil(left / (pr.rec.made or 1))
		local s = 0
		for _, g in ipairs(pr.rec.reag) do s = s + Cost(g.id, g.count * t, depth + 1) end
		return s
	end
	-- green: chance down to grey (only for the leftover gems, see below)
	local function ChToGrey(c)
		local k = math.floor(rank[c.prof] + 1e-9)
		if k >= c.rec.g or (cap[c.prof] and k >= cap[c.prof]) then return 0 end
		return Ch(c)
	end
	-- skill with a 85% margin (as prospecting): per profession the chance of every whole skill, dist[prof][k];
	-- a craft moves each skill k by its own chance at k, and the plan goes by the skill reached with CONF
	-- (rank = the highest k with P(skill >= k) >= CONF), so it crafts and mines more than for the average
	local CONF = 0.85
	local dist = {}
	for prof in pairs(lines) do dist[prof] = { [math.floor(rank[prof] + 1e-9)] = 1 } end
	local function ChAtK(c, k, green)
		local mx = lines[c.prof].max
		if k >= mx or (cap[c.prof] and k >= cap[c.prof]) then return 0 end
		if not green and not KIND_LETTER[CP.KindAt(c.rec.y, c.rec.g, k)] then return 0 end
		return CP.ChanceAt(c.rec, k, mx)
	end
	-- one craft of c over a skill distribution d -> the new distribution and its skill with CONF
	local function Step(c, d, green)
		local nd, keys = {}, {}
		for k, v in pairs(d) do
			local p = ChAtK(c, k, green)
			nd[k] = (nd[k] or 0) + v * (1 - p)
			if p > 0 then nd[k + 1] = (nd[k + 1] or 0) + v * p end
		end
		for k in pairs(nd) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return a > b end)
		local tail, r = 0, keys[#keys]
		for _, k in ipairs(keys) do
			tail = tail + nd[k]
			if tail >= CONF - 1e-9 then r = k break end
		end
		return nd, r
	end
	-- crafts of c in a row for +1 skill with CONF (nil — not within 500)
	local function CraftsFor1(c, green)
		local d, r0 = dist[c.prof], math.floor(rank[c.prof] + 1e-9)
		for i = 1, 500 do
			local r
			d, r = Step(c, d, green)
			if r > r0 then return i end
		end
	end
	local function Craft(c, mid, green)
		local ch = green and ChToGrey(c) or (Kind(c) ~= "x" and Ch(c) or 0)
		if not c.known then learn[c] = true end
		local from = rank[c.prof]
		if ch > 0 then
			local nd, r = Step(c, dist[c.prof], green)
			dist[c.prof] = nd
			rank[c.prof] = math.max(rank[c.prof], r)
		end
		log[#log + 1] = { c = c, mid = mid, from = from, to = rank[c.prof], gain = ch, green = green }
	end
	local used = {} -- how much of each by-product was taken (the bags and vein drops are taken first)
	local veinGot = {} -- by-products the mined veins gave (85%, CP.Low85 over all the mined veins)
	local gemGot = {} -- gems all the plan's prospects gave (85%)
	local function Take(id, n, depth)
		local free = math.min(pool[id] or 0, n)
		pool[id] = (pool[id] or 0) - free
		if byprod[id] then used[id] = (used[id] or 0) + free end
		local left = n - free
		if left <= 1e-9 then return end
		if id == O then
			mined = mined + left
			if vein then -- the mined veins drop the rest too (on average veins, 85% of what they drop)
				local nodes = mined / vein.per
				for d, st in pairs(vein.dropSt) do
					local got = CP.Low85(nodes, st)
					pool[d] = (pool[d] or 0) + got - (veinGot[d] or 0)
					veinGot[d] = got
				end
			end
			return
		end
		if gemPer[id] then
			while left > 1e-9 and prospects < 5000 do
				Take(O, 5, depth + 1)
				prospects = prospects + 1
				for gem, st in pairs(gemSt) do
					local got = CP.Low85(prospects, st)
					pool[gem] = (pool[gem] or 0) + got - (gemGot[gem] or 0)
					gemGot[gem] = got
				end
				local f = math.min(pool[id], left)
				pool[id], left = pool[id] - f, left - f
			end
			return
		end
		local pr = prodOf[id]
		if not pr or depth > 6 then return end
		local made = pr.rec.made or 1
		for _ = 1, math.ceil(left / made) do
			for _, g in ipairs(pr.rec.reag) do Take(g.id, g.count, depth + 1) end
			if #pr.rec.reag == 1 and pr.rec.reag[1].id == O then smelt = smelt + pr.rec.reag[1].count end
			Craft(pr, true)
			pool[id] = (pool[id] or 0) + made
		end
		local f = math.min(pool[id], left)
		pool[id] = pool[id] - f
	end
	for _ = 1, 3000 do
		local best, bs
		for _, c in ipairs(R) do
			if not off[c.prof] and Usable(c) and Kind(c) ~= "x" then
				local raw = 0
				for _, g in ipairs(c.rec.reag) do raw = raw + Cost(g.id, g.count, 0) end
				if raw < 1e8 then
					local sc = Ch(c) / math.max(0.05, raw)
					if not best or sc > bs + 1e-12 or (math.abs(sc - bs) < 1e-12 and c.rec.y < best.rec.y) then best, bs = c, sc end
				end
			end
		end
		if not best then break end
		-- the recipe in a row until it gives +1 with CONF (no "+0-1" steps)
		local r0 = math.floor(rank[best.prof] + 1e-9)
		for _ = 1, 500 do
			for _, g in ipairs(best.rec.reag) do Take(g.id, g.count, 0) end
			Craft(best, false)
			if math.floor(rank[best.prof] + 1e-9) > r0 or Kind(best) == "x" then break end
		end
	end
	-- then what is left from the BAGS and from the mined VEINS (stone, gems — not what the plan's prospecting gives):
	-- into recipes that still give any skill, green too, down to grey. No new mining or prospecting for them
	local function Free(id) return math.min(pool[id] or 0, math.max(0, Stock(id) + (veinGot[id] or 0) - (used[id] or 0))) end
	for _ = 1, 3000 do
		local best, bs
		for _, c in ipairs(R) do
			if not off[c.prof] and Usable(c) then
				local gems, enough, raw = false, true, 0
				for _, g in ipairs(c.rec.reag) do
					if byprod[g.id] then
						gems = true
						if Free(g.id) < g.count - 1e-9 then enough = false break end
					else
						raw = raw + Cost(g.id, g.count, 0)
					end
				end
				local ch = gems and enough and raw < 1e8 and ChToGrey(c) or 0
				-- only when the leftovers last for +1 with CONF
				if ch > 0 then
					local need, n = CraftsFor1(c, true), math.huge
					for _, g in ipairs(c.rec.reag) do
						if byprod[g.id] then n = math.min(n, math.floor(Free(g.id) / g.count + 1e-9)) end
					end
					if not need or n < need then ch = 0 end
				end
				if ch > 0 then
					local sc = ch / math.max(0.05, raw)
					if not best or sc > bs + 1e-12 then best, bs = c, sc end
				end
			end
		end
		if not best then break end
		for _ = 1, CraftsFor1(best, true) do
			for _, g in ipairs(best.rec.reag) do Take(g.id, g.count, 0) end
			Craft(best, false, true)
		end
	end
	-- recipes for the leftovers that only lack OTHER materials (e.g. Точило стихий: dense stone + elemental earth):
	-- how many crafts the leftovers allow while they still give skill, and what is missing for them
	local blocked = {}
	for _, c in ipairs(Candidates(lines)) do
		if lines[c.prof] and not off[c.prof] and Usable(c) then
			local n, ext = math.huge, false
			for _, g in ipairs(c.rec.reag) do
				if byprod[g.id] then n = math.min(n, math.floor(Free(g.id) / g.count + 1e-9))
				elseif ok[g.id] then n = 0 break -- needs the ore or what is made of it: not a leftover recipe
				else ext = true end
			end
			if ext and n ~= math.huge and n >= 1 then
				local save, k = rank[c.prof], 0
				while k < n and ChToGrey(c) > 0 do
					rank[c.prof] = math.min(lines[c.prof].max, rank[c.prof] + Ch(c))
					k = k + 1
				end
				local gain = rank[c.prof] - save
				rank[c.prof] = save
				if k >= 1 then
					local miss = {}
					for _, g in ipairs(c.rec.reag) do
						if not byprod[g.id] then
							local have = pool[g.id] ~= nil and pool[g.id] or Stock(g.id)
							local m = g.count * k - math.floor(have + 1e-9)
							if m > 0 then miss[#miss + 1] = { id = g.id, n = m } end
						end
					end
					if miss[1] then blocked[#blocked + 1] = { c = c, n = k, gain = gain, miss = miss } end
				end
			end
		end
	end
	table.sort(blocked, function(a, b) return a.gain > b.gain end)
	-- per recipe: by profession, in the order of the first craft; skill from the first to the last craft
	-- (the green part of the leftover gems is a separate line)
	local steps, byC = {}, {}
	for _, l in ipairs(log) do
		if not (l.mid and l.gain <= 0) then
			local key = l.green and ("g" .. tostring(l.c)) or l.c
			local s = byC[key]
			if s then s.n, s.to = s.n + 1, l.to
			else s = { c = l.c, mid = l.mid, green = l.green, n = 1, from = l.from, to = l.to, i = #steps + 1 }; byC[key] = s; steps[#steps + 1] = s end
		end
	end
	table.sort(steps, function(a, b)
		if a.c.prof ~= b.c.prof then return a.c.prof < b.c.prof end
		return a.i < b.i
	end)
	local profs, seen = {}, {}
	for _, c in ipairs(R) do
		local p = c.prof
		if not seen[p] and (off[p] or math.floor(rank[p] + 1e-9) > math.floor(start[p] + 1e-9)) then seen[p] = true; profs[#profs + 1] = p end
	end
	table.sort(profs)
	local left = {}
	for gem in pairs(byprod) do
		if (pool[gem] or 0) >= 1 then left[#left + 1] = { id = gem, n = math.floor(pool[gem]) } end
	end
	table.sort(left, function(a, b) return a.n > b.n end)
	local anyUsable = false
	for _, c in ipairs(R) do if Usable(c) then anyUsable = true break end end
	return { ore = O, steps = steps, anyUsable = anyUsable, start = start, rank = rank, profs = profs, learn = learn, left = left,
		mined = mined, used = Stock(O) - (pool[O] or 0) + mined, have = Stock(O), prospects = prospects, smelt = smelt,
		veins = vein and mined > 0 and CP.Tries85(mined, vein.st) or nil,
		canProspect = next(gemPer) ~= nil, cap = cap, nextOre = nextOre, blocked = blocked, stackOre = stackOre, stackUse = stackUse }
end

-- cached until the next change (dropped before any redraw)
local cache = {}
CP.OnDrop(function() cache = {} end)
function CP.OrePlan(O, off, useStock, toNext)
	local keys = {}
	for p in pairs(off) do keys[#keys + 1] = p end
	table.sort(keys)
	local key = O .. (useStock and "+" or "-") .. (toNext and ">" or "") .. table.concat(keys, ",")
	if not cache[key] then cache[key] = OrePlan(O, off, useStock, toNext) end
	return cache[key]
end

----------------------------------------------------------------------------------------------
-- Tab availability (the tab is drawn by UI/OrePlan.lua)
local USERS = { "Кузнечное дело", "Ювелирное дело", "Инженерное дело" }
function CP.HasOrePlanTab()
	local lines = CP.SkillLines()
	if not lines["Горное дело"] then return false end
	for _, p in ipairs(USERS) do if lines[p] then return true end end
	return false
end

-- recipes of a plan as stack entries (intermediates are left to the material tree)
local function PlanList(P, sk)
	local list, idx = {}, {}
	for _, s in ipairs(P.steps) do
		if not s.mid and (not sk or s.c.sk == sk) then
			local k = s.c.sk .. "|" .. s.c.rec.name
			if idx[k] then idx[k].n = idx[k].n + s.n
			else idx[k] = { sk = s.c.sk, name = s.c.rec.name, n = s.n }; list[#list + 1] = idx[k] end
		end
	end
	return list
end
-- "Пересчитать" for a stack made by the ore plan: the same ore and settings, current bags and skill
function CP.RecalcOreStack(si)
	local g = CP.Goal()
	local st = g.stacks[si]
	local info = st and st.orePlan
	if not info or g.edit then return end
	local off = {} -- every profession except the stack's ones (a profession learned later does not get in)
	for p in pairs(CP.SkillLines()) do if not (info.only or {})[p] then off[p] = true end end
	local list = PlanList(OrePlan(info.ore, off, info.stock, info.toNext), info.prof and CP.SKILL_ID[info.prof])
	if not list[1] then
		CP.Print("с руды «" .. CP.ItemName(info.ore) .. "» навыка больше не получить — стек оставлен как есть.")
		return
	end
	st.list, st.add = list, {}
	CP.Changed()
	CP.Print("стек пересчитан по плану руды «" .. CP.ItemName(info.ore) .. "».")
end

-- a stack made by the plan no longer matches the plan for the current bags and skill (recipes or counts differ);
-- the tile then highlights "Пересчитать". Memoized until CP.DropCache
local staleMemo = {}
CP.OnDrop(function() staleMemo = {} end)
function CP.OreStackStale(si)
	local hit = staleMemo[si]
	if hit ~= nil then return hit end
	local g = CP.Goal()
	local st = g.stacks[si]
	local info = st and st.orePlan
	local stale = false
	if info and not g.edit then
		local off = {}
		for p in pairs(CP.SkillLines()) do if not (info.only or {})[p] then off[p] = true end end
		local list = PlanList(OrePlan(info.ore, off, info.stock, info.toNext), info.prof and CP.SKILL_ID[info.prof])
		if list[1] then
			local want, cur = {}, {}
			for _, e in ipairs(list) do want[e.sk .. "|" .. e.name] = e.n end
			for _, e in ipairs(st.list) do
				if e.n > 0 then local k = e.sk .. "|" .. e.name; cur[k] = (cur[k] or 0) + e.n end
			end
			for k, n in pairs(want) do if cur[k] ~= n then stale = true break end end
			if not stale then for k in pairs(cur) do if not want[k] then stale = true break end end end
		end
	end
	staleMemo[si] = stale
	return stale
end

-- one stack with the plan's recipes (intermediates are left to the material tree)
function CP.OrePlanToStack(P)
	local g = CP.Goal()
	if g.edit then CP.Print("сначала сохраните или отмените правку стека.") return end
	if not PlanList(P)[1] then return end
	-- one stack per profession. Each remembers the ore, all professions of the plan (only those ticked), its own
	-- profession and the stock setting: "Пересчитать" rebuilds the same joint plan from the current bags and skill
	-- and takes this profession's part of it
	local only, profs = {}, {}
	for _, s in ipairs(P.steps) do
		if not s.mid and not only[s.c.prof] then only[s.c.prof] = true; profs[#profs + 1] = s.c.prof end
	end
	table.sort(profs)
	CP.sel = {}
	for _, prof in ipairs(profs) do
		local list = PlanList(P, CP.SKILL_ID[prof])
		if list[1] then
			g.stacks[#g.stacks + 1] = { list = list, add = {}, time = time(),
				orePlan = { ore = P.ore, only = CopyTable(only), prof = prof, stock = CP.orePlanStock ~= false, toNext = CP.orePlanNext == true } }
			CP.sel[#g.stacks] = true
		end
	end
	CP.sub = "mat"
	CP.Changed()
	CP.Print("стеки из плана по руде: " .. CP.ItemName(P.ore) .. " (" .. table.concat(profs, ", ") .. ").")
end
