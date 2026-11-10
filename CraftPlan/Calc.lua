-- CraftPlan 2.0 — calculation: recipes from the table, stacks, material tree with reservation, skill gain.
-- db.goal = { stacks = { { list = { { sk, name, n } }, add = { [item] = count }, time } }, edit = index }
local CP = CraftPlan
local DB = CP.DB

----------------------------------------------------------------------------------------------
-- Profession recipes from the CraftPlanRouteData table:
-- "spell|name|yellow|grey|with profession|product|count|reagent*qty;...|cooldown"
-- (the "with profession" field is not used). Each profession is parsed once; its source strings are then dropped.
local parsed = {}
function CP.Recipes(sk)
	if parsed[sk] then return parsed[sk] end
	local list, by = {}, {}
	for _, line in ipairs(CraftPlanRouteData and CraftPlanRouteData[sk] or {}) do
		local spell, name, y, g, _, item, made, reag, cd = strsplit("|", line)
		local rec = { sk = sk, spell = tonumber(spell), name = name, y = tonumber(y) or 0, g = tonumber(g) or 0,
			item = tonumber(item) or 0, made = tonumber(made) or 1, cd = (cd == "1"), reag = {} }
		for id, c in (reag or ""):gmatch("(%d+)%*(%d+)") do rec.reag[#rec.reag + 1] = { id = tonumber(id), count = tonumber(c) } end
		list[#list + 1] = rec
		by[name] = by[name] or rec
	end
	list.by = by
	parsed[sk] = list
	if CraftPlanRouteData then CraftPlanRouteData[sk] = nil end -- nothing else reads it: free the strings
	return list
end
function CP.FindRec(sk, name)
	return CP.Recipes(sk).by[name]
end

-- Skill the recipe is learned at (from the trainer), or nil
function CP.LearnReq(sk, name)
	local l = DB().learn and DB().learn[sk] and DB().learn[sk][name]
	if l and l.req then return l.req end
	local prof = CP.SKILL_NAME[sk]
	local item = prof and CP.RecipeItem and CP.RecipeItem(prof, name)
	return item and CP.BookReq(item, prof) or nil
end

-- Who makes an item: a recipe of your professions. Several recipes make it — a learned one; among them the one that
-- still gives skill (skill below grey), then the one you have materials for, then the lower yellow threshold.
-- -> { rec, prof, known, skill, can, why } (why — short reason when there was a choice)
-- The item -> recipes index is static (the recipe table never changes) and built once per session;
-- the choice depends on skill, learned recipes and bags, so it is cached per item until CP.DropCache.
local prodIndex -- [item] = { { rec, prof }, ... } in CP.SKILL_ID order
local prodCache = {} -- [item] = chosen producer or false
CP.OnDrop(function() prodCache = {} end)
local function ProdIndex()
	if prodIndex then return prodIndex end
	prodIndex = {}
	for prof, sk in pairs(CP.SKILL_ID) do
		for _, rec in ipairs(CP.Recipes(sk)) do
			if rec.item > 0 then
				local t = prodIndex[rec.item]
				if not t then t = {}; prodIndex[rec.item] = t end
				t[#t + 1] = { rec = rec, prof = prof }
			end
		end
	end
	return prodIndex
end
function CP.Producer(id)
	if not id then return nil end
	local hit = prodCache[id]
	if hit ~= nil then return hit or nil end
	local cands = ProdIndex()[id]
	local best, bKnown, bSkill, bCan, n = nil, false, false, false, 0
	if cands then
		local lines = CP.SkillLines()
		for _, c in ipairs(cands) do
			local L = lines[c.prof]
			if L then
				n = n + 1
				local rec = c.rec
				local known = CP.KnownRecipe(c.prof, rec.name) and true or false
				local skill = L.rank < rec.g and L.rank < L.max
				local can = true
				for _, rg in ipairs(rec.reag) do if CP.Have(rg.id) < rg.count then can = false break end end
				-- order: learned, still gives skill, have materials, lower yellow threshold; the first one wins a tie
				local better = not best
				if not better then
					if known ~= bKnown then better = known
					elseif skill ~= bSkill then better = skill
					elseif can ~= bCan then better = can
					else better = rec.y < best.rec.y end
				end
				if better then best, bKnown, bSkill, bCan = c, known, skill, can end
			end
		end
	end
	if not best then
		prodCache[id] = false
		return nil
	end
	local pr = { rec = best.rec, prof = best.prof, known = bKnown or nil, skill = bSkill, can = bCan }
	if n > 1 then
		local why = {}
		why[#why + 1] = bKnown and "изучен" or "не изучен"
		if bSkill then why[#why + 1] = "ещё даёт навык" end
		if bCan then why[#why + 1] = "материалы есть" end
		pr.why = "из " .. n .. ": " .. table.concat(why, ", ")
	end
	prodCache[id] = pr
	return pr
end

----------------------------------------------------------------------------------------------
-- Stacks
function CP.Goal()
	local db = DB()
	db.goal = db.goal or {}
	local g = db.goal
	g.stacks = g.stacks or {}
	-- before 0.12.15: the "current stack" list/add becomes a regular stack
	if g.list or g.add then
		local has = g.add and next(g.add)
		for _, e in ipairs(g.list or {}) do if e.n > 0 then has = true end end
		if has then g.stacks[#g.stacks + 1] = { list = g.list or {}, add = g.add or {}, time = time() } end
		g.list, g.add = nil, nil
	end
	for _, st in ipairs(g.stacks) do st.list, st.add = st.list or {}, st.add or {} end
	if g.edit and not g.stacks[g.edit] then g.edit = nil end
	return g
end

-- Crafting order found by CP.Compute: [stack entry e] = index (recipes too early to learn go last)
local craftOrder = setmetatable({}, { __mode = "k" })
-- Recipes the stacks never reach the learn skill for: [stack entry e] = learn skill
CP.early = setmetatable({}, { __mode = "k" })

-- Stack entries present in the recipe table: { e, rec, prof, req }
-- Sorted the way they are crafted (CP.Compute); until it runs — by yellow threshold, learn skill, name.
-- The same order is used for stock reservation, the materials table and the schema.
function CP.Entries(st)
	local out = {}
	for _, e in ipairs(st.list) do
		local rec = e.n > 0 and CP.FindRec(e.sk, e.name)
		if rec then out[#out + 1] = { e = e, rec = rec, prof = CP.SKILL_NAME[e.sk], req = CP.LearnReq(e.sk, rec.name) or 0 } end
	end
	table.sort(out, function(a, b)
		local ia, ib = craftOrder[a.e], craftOrder[b.e]
		if ia and ib and ia ~= ib then return ia < ib end
		if a.rec.y ~= b.rec.y then return a.rec.y < b.rec.y end
		if a.req ~= b.req then return a.req < b.req end
		return a.rec.name < b.rec.name
	end)
	return out
end

-- Stack order by skill: the earliest learn skill of its recipes (otherwise the yellow threshold).
-- Cached with its inverse (stack index -> place) until CP.DropCache; the returned list is shared — don't change it.
local stackOrder, stackNum
CP.OnDrop(function() stackOrder, stackNum = nil, nil end)
function CP.StackOrder()
	if stackOrder then return stackOrder end
	local g, order, keys = CP.Goal(), {}, {}
	for si, st in ipairs(g.stacks) do
		local k = 9999
		for _, x in ipairs(CP.Entries(st)) do k = math.min(k, CP.LearnReq(x.rec.sk, x.rec.name) or x.rec.y) end
		order[#order + 1] = si
		keys[si] = k
	end
	table.sort(order, function(a, b)
		if keys[a] ~= keys[b] then return keys[a] < keys[b] end
		return a < b
	end)
	stackOrder, stackNum = order, {}
	for k, x in ipairs(order) do stackNum[x] = k end
	return order
end
function CP.StackNum(si)
	CP.StackOrder()
	return stackNum[si] or si
end
-- Stacks that take part in everything (calculation, materials, bar, crafting watcher). A switched off stack
-- (st.off) keeps its tile and number but is left out. Cached until CP.DropCache; shared list — don't change it.
local activeOrder
CP.OnDrop(function() activeOrder = nil end)
function CP.ActiveOrder()
	if activeOrder then return activeOrder end
	local g, out = CP.Goal(), {}
	for _, si in ipairs(CP.StackOrder()) do
		if not g.stacks[si].off then out[#out + 1] = si end
	end
	activeOrder = out
	return out
end
function CP.ToggleStackOff(si)
	local g = CP.Goal()
	local st = g.stacks[si]
	if not st or g.edit then return end
	st.off = (not st.off) or nil
	CP.sel[si] = nil
	CP.Changed()
end

-- Tree of one stack. stock is the shared supply (stacks reserve their share in order).
-- nodes[id] = { id, gross, made, short, have, parents = { [key] = count }, kids = { id } }
local function BuildStack(si, st, stock)
	local t = { nodes = {}, ord = {}, ents = CP.Entries(st), si = si }
	local function Node(id)
		local n = t.nodes[id]
		if not n then
			n = { id = id, gross = 0, made = 0, short = 0, parents = {}, kids = {}, kidSet = {} }
			t.nodes[id] = n
			t.ord[#t.ord + 1] = id
		end
		return n
	end
	local function Need(id, amt, parent, depth)
		local n = Node(id)
		n.gross = n.gross + amt
		n.parents[parent] = (n.parents[parent] or 0) + amt
		if stock[id] == nil then stock[id] = CP.Have(id) end
		local use = math.min(stock[id], amt)
		stock[id] = stock[id] - use
		local left = amt - use
		if left <= 0 then return end
		local pr = CP.Producer(id)
		if pr and depth < 6 and not n.busy then
			local made = pr.rec.made or 1
			local times = math.ceil(left / made)
			n.made = n.made + times * made
			n.prod = pr
			n.busy = true
			for _, rg in ipairs(pr.rec.reag) do
				if not n.kidSet[rg.id] then n.kidSet[rg.id] = true; n.kids[#n.kids + 1] = rg.id end
				Need(rg.id, rg.count * times, "i" .. id, depth + 1)
			end
			n.busy = nil
			stock[id] = stock[id] + times * made - left -- surplus from "several per craft"
		else
			n.short = n.short + left
		end
	end
	for i, x in ipairs(t.ents) do
		x.key = "s" .. si .. "r" .. i
		for _, rg in ipairs(x.rec.reag) do Need(rg.id, rg.count * x.e.n, x.key, 1) end
	end
	-- materials added to the stack manually
	for id, n in pairs(st.add) do
		if n > 0 then Need(id, n, "s" .. si .. "add", 1) end
	end
	for _, id in ipairs(t.ord) do t.nodes[id].have = CP.Have(id) end
	return t
end

-- Skill gain parts with a 85% margin (as prospecting). q = { o = orange crafts (exact), y/g = expected yellow/green,
-- ym/gm = yellow/green attempts, yl/gl = their chances }. Each attempt gives +1 with its chance: the distribution of
-- the points (Poisson binomial) -> the points reached with CONF. -> { o, y, g, t, ym, gm, ey, eg }: y/g — 85% per zone,
-- t = o + 85% of yellow and green together, ey/eg — expected. Cached in q (its lists only grow)
local function Low85(lists)
	local d, n = { [0] = 1 }, 0
	for _, l in ipairs(lists) do
		for _, p in ipairs(l) do
			n = n + 1
			d[n] = 0
			for k = n, 1, -1 do d[k] = d[k] * (1 - p) + d[k - 1] * p end
			d[0] = d[0] * (1 - p)
		end
	end
	local tail = 0
	for k = n, 0, -1 do
		tail = tail + d[k]
		if tail >= CP.CONF - 1e-9 then return k end
	end
	return 0
end
function CP.RoundGain(q)
	if not q then return { o = 0, y = 0, g = 0, t = 0, ym = 0, gm = 0, ey = 0, eg = 0 } end
	local yl, gl = q.yl or {}, q.gl or {}
	local c = q.rg
	if c and c.ny == #yl and c.ng == #gl then return c end
	local y, g = Low85({ yl }), Low85({ gl })
	c = { o = q.o, y = y, g = g, t = q.o + Low85({ yl, gl }), ym = q.ym or 0, gm = q.gm or 0, ey = q.y or 0, eg = q.g or 0,
		ny = #yl, ng = #gl }
	q.rg = c
	return c
end

-- Gain parts for display: { text, color, tip }: "+25" orange (exact), "+0-1" yellow and green (85% - max:
-- max = attempts in that zone, if each gives +1)
CP.GAIN_COLOR = { o = { 1, 0.5, 0.25 }, y = { 1, 1, 0 }, g = { 0.25, 0.75, 0.25 } }
local function Avg(v) return math.floor(v * 10 + 0.5) / 10 end
function CP.GainParts(q)
	local rg = CP.RoundGain(q)
	local out = {}
	if rg.o > 0 then out[#out + 1] = { text = "+" .. rg.o, color = CP.GAIN_COLOR.o, tip = "точно: оранжевые создания" } end
	if rg.ym > 0 then
		out[#out + 1] = { text = "+" .. rg.y .. (rg.ym > rg.y and ("-" .. rg.ym) or ""), color = CP.GAIN_COLOR.y,
			tip = "жёлтые: 85% - " .. rg.y .. ", в среднем " .. Avg(rg.ey) .. ", максимум " .. rg.ym }
	end
	if rg.gm > 0 then
		out[#out + 1] = { text = "+" .. rg.g .. (rg.gm > rg.g and ("-" .. rg.gm) or ""), color = CP.GAIN_COLOR.g,
			tip = "зелёные: 85% - " .. rg.g .. ", в среднем " .. Avg(rg.eg) .. ", максимум " .. rg.gm }
	end
	return out
end
-- The same as one colored string ("|cff...+25|r |cff...+6-7|r")
function CP.GainString(q)
	local t = {}
	for _, p in ipairs(CP.GainParts(q)) do
		t[#t + 1] = string.format("|cff%02x%02x%02x%s|r", p.color[1] * 255, p.color[2] * 255, p.color[3] * 255, p.text)
	end
	return table.concat(t, " ")
end

-- All stacks: trees[si] is the stack tree, gain[si][profession] = { o, y, g } (see CP.RoundGain).
-- Crafts are the stack recipes (N times) and the intermediates the tree has to craft (settings, bars — they give
-- skill too, in their own profession). Greedy over all stacks at once: each step takes a craft that can already be
-- learned at the GUARANTEED skill (exact +1 only). Yellow/green chance only drops as skill grows, while an orange
-- craft gives +1 whenever it is done below its yellow threshold — so a yellow/green craft goes first if the oranges
-- of its profession still fit under their thresholds afterwards (earliest threshold first); otherwise the orange
-- (lower yellow threshold first). Among yellow/green: those you have materials for first, then the higher chance.
-- Yellow/green give the expected gain: chance (grey - skill) / (grey - yellow). What is never learnable stays
-- "too early": last, no gain.
local stacksWith -- CP.StacksWith map, dropped together with "computed"
local computed -- cached until the next change (CP.Changed): tooltips and the bar call this often
local merged -- CP.MergedAll of "computed"
CP.OnDrop(function() computed, stacksWith, merged = nil, nil, nil end)
local function ByYellow(a, b) return a.rec.y < b.rec.y end
function CP.Compute()
	if computed then return computed end
	local g = CP.Goal()
	local lines = CP.SkillLines()
	local order = CP.ActiveOrder()
	-- pass 1: trees in the current order — which intermediates must be crafted
	local stock, trees = {}, {}
	for _, si in ipairs(order) do trees[si] = BuildStack(si, g.stacks[si], stock) end
	local todo, gain = {}, {}
	for _, si in ipairs(order) do
		gain[si] = {}
		for _, x in ipairs(trees[si].ents) do
			local known = CP.KnownRecipe(x.prof, x.rec.name)
			todo[#todo + 1] = { si = si, e = x.e, rec = x.rec, prof = x.prof, rem = x.e.n, n = x.e.n, req = known and 0 or x.req }
		end
		for _, id in ipairs(trees[si].ord) do
			local n = trees[si].nodes[id]
			local pr = n.prod
			if n.made > 0 and pr and lines[pr.prof] then
				local k = math.ceil(n.made / (pr.rec.made or 1))
				todo[#todo + 1] = { si = si, rec = pr.rec, prof = pr.prof, rem = k, n = k, mid = true,
					req = pr.known and 0 or (CP.LearnReq(pr.rec.sk, pr.rec.name) or 0) }
			end
		end
	end
	for _, c in ipairs(todo) do
		c.can = true -- have the materials for one craft right now
		for _, rg in ipairs(c.rec.reag) do if CP.Have(rg.id) < rg.count then c.can = false break end end
	end
	local rank = {} -- expected skill per profession (oranges +1, yellow/green by chance)
	local function Chance(c)
		local L = lines[c.prof]
		local r = rank[c.prof] or L.rank
		return r, math.floor(r + 1e-9), CP.ChanceAt(c.rec, r, L.max)
	end
	local newOrder = setmetatable({}, { __mode = "k" })
	local log, span, egain = {}, {}, {} -- crafts in order; per stack recipe: skill range and gain
	CP.early = setmetatable({}, { __mode = "k" })
	local seq = 0
	-- How much skill a profession can still gain before its pending oranges stop fitting under their yellow
	-- thresholds: oranges by threshold, the k-th of them is crafted at skill r + k - 1 and must stay below y.
	-- byY is todo sorted by yellow threshold once (the order inside one threshold doesn't change the minimum)
	local byY = {}
	for i, c in ipairs(todo) do byY[i] = c end
	table.sort(byY, ByYellow)
	local function Slack(prof)
		local L = lines[prof]
		local r = rank[prof] or L.rank
		local rk = math.floor(r + 1e-9)
		local cap = rk -- unlearned recipes count once the expected skill reaches their requirement
		local cum, m = 0, math.huge
		for _, c in ipairs(byY) do
			if c.rem > 0 and c.prof == prof and c.req <= cap and rk < c.rec.y then
				cum = cum + c.rem
				m = math.min(m, c.rec.y - (r + cum - 1))
			end
		end
		return m
	end
	-- gain of one craft into a sum { o, y, g, ym, gm }: orange only below the yellow threshold; yellow/green also
	-- count attempts (ym, gm): the max if each gives +1
	local function AddGain(q, rk, ch, y, mid)
		if rk < y then q.o = q.o + 1
		elseif ch > 0 and rk < mid then q.y = q.y + ch; q.ym = q.ym + 1; q.yl[#q.yl + 1] = ch
		elseif ch > 0 then q.g = q.g + ch; q.gm = q.gm + 1; q.gl[#q.gl + 1] = ch end
	end
	local slack = {} -- per step: [profession] = Slack(profession), filled on demand
	for _ = 1, 20000 do
		-- best candidate and its sort key (b1..b5), compared field by field
		local best, b1, b2, b3, b4, b5
		wipe(slack)
		for i, c in ipairs(todo) do
			local L = lines[c.prof]
			if c.rem > 0 and L and c.req <= math.floor((rank[c.prof] or L.rank) + 1e-9) then
				local _, rk, ch = Chance(c)
				local k1, k2, k3, k4, k5
				if rk < c.rec.y then
					k1, k2, k3, k4, k5 = 1, c.rec.y, 0, i, 0
				else
					if ch > 0 and slack[c.prof] == nil then slack[c.prof] = Slack(c.prof) end
					local first = ch > 0 and ch < slack[c.prof] - 1e-9
					k1, k2, k3, k4, k5 = first and 0 or 2, c.can and 0 or 1, -ch, c.rec.y, i
				end
				local better = not best
				if not better then
					if k1 ~= b1 then better = k1 < b1
					elseif k2 ~= b2 then better = k2 < b2
					elseif k3 ~= b3 then better = k3 < b3
					elseif k4 ~= b4 then better = k4 < b4
					else better = k5 < b5 end
				end
				if better then best, b1, b2, b3, b4, b5 = c, k1, k2, k3, k4, k5 end
			end
		end
		if not best then break end
		local c, L = best, lines[best.prof]
		local r, rk, ch = Chance(c)
		c.rem = c.rem - 1
		if c.e and not newOrder[c.e] then seq = seq + 1; newOrder[c.e] = seq end
		local to = (c.mid and ch <= 0) and r or math.min(L.max, r + ch)
		log[#log + 1] = { si = c.si, e = c.e, rec = c.rec, prof = c.prof, mid = c.mid, from = r, to = to }
		if c.e then -- skill range of a stack recipe: first craft .. last craft
			local sp = span[c.e]
			if sp then sp.to = to else span[c.e] = { from = r, to = to } end
		end
		if not (c.mid and ch <= 0) then -- a grey intermediate (e.g. smelting) gives nothing
			local gg = gain[c.si][c.prof]
			if not gg then gg = { o = 0, y = 0, g = 0, ym = 0, gm = 0, yl = {}, gl = {} }; gain[c.si][c.prof] = gg end
			local ge = c.e and egain[c.e]
			if c.e and not ge then ge = { o = 0, y = 0, g = 0, ym = 0, gm = 0, yl = {}, gl = {} }; egain[c.e] = ge end
			local mid = math.floor((c.rec.y + c.rec.g) / 2)
			AddGain(gg, rk, ch, c.rec.y, mid)
			if ge then AddGain(ge, rk, ch, c.rec.y, mid) end
			rank[c.prof] = to
		end
	end
	for _, c in ipairs(todo) do
		if c.e and not c.mid and c.rem == c.n then
			CP.early[c.e] = c.req
			seq = seq + 1
			newOrder[c.e] = 100000 + seq
		end
	end
	craftOrder = newOrder
	-- pass 2: trees again in crafting order (stock is handed out in that order)
	stock, trees = {}, {}
	for _, si in ipairs(order) do trees[si] = BuildStack(si, g.stacks[si], stock) end
	computed = { trees = trees, gain = gain, order = order, lines = lines, log = log, span = span, egain = egain }
	return computed
end

-- Crafting steps from the log: consecutive crafts of one recipe = one step. ok(l) filters log entries;
-- grey intermediates (no gain) are skipped
function CP.Steps(data, ok)
	local out = {}
	for _, l in ipairs(data.log or {}) do
		if not (l.mid and l.to <= l.from) and (not ok or ok(l)) then
			local last = out[#out]
			if last and last.rec == l.rec and last.si == l.si then
				last.n = last.n + 1
				last.to = l.to
			else
				out[#out + 1] = { si = l.si, e = l.e, rec = l.rec, prof = l.prof, mid = l.mid, n = 1, from = l.from, to = l.to }
			end
		end
	end
	return out
end

-- All stacks merged: CP.Merge(data.trees, data.order) of the current CP.Compute(), cached until CP.DropCache
-- (shared — don't change it)
function CP.MergedAll()
	local data = CP.Compute()
	if not (merged and merged.data == data) then merged = { data = data, tree = CP.Merge(data.trees, data.order) } end
	return merged.tree
end

-- Merge the trees of several stacks (for the panel: selected or all)
function CP.Merge(trees, list)
	local out = { nodes = {}, ord = {}, ents = {} }
	for _, si in ipairs(list) do
		local t = trees[si]
		if t then
			for _, x in ipairs(t.ents) do out.ents[#out.ents + 1] = x end
			for _, id in ipairs(t.ord) do
				local a = t.nodes[id]
				local n = out.nodes[id]
				if not n then
					n = { id = id, gross = 0, made = 0, short = 0, have = a.have, parents = {}, kids = {}, kidSet = {} }
					out.nodes[id] = n
					out.ord[#out.ord + 1] = id
				end
				n.gross, n.made, n.short = n.gross + a.gross, n.made + a.made, n.short + a.short
				n.prod = n.prod or a.prod
				for k, v in pairs(a.parents) do n.parents[k] = (n.parents[k] or 0) + v end
				for _, k in ipairs(a.kids) do
					if not n.kidSet[k] then n.kidSet[k] = true; n.kids[#n.kids + 1] = k end
				end
			end
		end
	end
	return out
end

-- How many kinds and pieces are missing
function CP.Shortage(t)
	local kinds, pieces = 0, 0
	for _, id in ipairs(t.ord) do
		local n = t.nodes[id]
		if n.short > 0 then kinds, pieces = kinds + 1, pieces + n.short end
	end
	return kinds, pieces
end

----------------------------------------------------------------------------------------------
-- Stack editing. Selection (ui) is per session only: CP.sel = { [index] = true }
CP.sel = {}
function CP.Editing()
	local g = CP.Goal()
	return g.edit and g.stacks[g.edit] or nil, g.edit
end
local function Copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = Copy(x) end
	return c
end
-- Stacks crafted out while another stack was being edited: removed after Save/Cancel ([stack] = true)
local doneLater = {}
local function RemoveDoneLater()
	for st in pairs(doneLater) do
		doneLater[st] = nil
		local left = false
		for _, x in ipairs(st.list) do if x.n > 0 then left = true end end
		local i = not left and CP.IndexOf(st)
		if i then
			CP.RemoveStack(i)
			CP.Print("стек создан целиком.")
		end
	end
end
-- Edit snapshot: CP.snap is a copy of the edited stack before the edit (nil for a new stack), CP.snapOf the live
-- stack — by reference, so it survives index shifts and Cancel leaves the other stacks (crafting progress) alone
function CP.BeginEdit(si)
	local g = CP.Goal()
	if g.edit or not g.stacks[si] then return end
	CP.snap, CP.snapOf, CP.prevSel = Copy(g.stacks[si]), g.stacks[si], CP.sel
	g.edit = si
	CP.sel = { [si] = true }
	CP.Changed()
end
function CP.NewStack()
	local g = CP.Goal()
	if g.edit then return end
	local st = { list = {}, add = {}, time = time() }
	CP.snap, CP.snapOf, CP.prevSel = nil, st, CP.sel
	g.stacks[#g.stacks + 1] = st
	g.edit = #g.stacks
	CP.sel = { [g.edit] = true }
	CP.Changed()
end
-- the stack content (recipes and materials) is the same as before editing
local function SameContent(a, b)
	if not (a and b) or #a.list ~= #b.list then return false end
	for i, e in ipairs(a.list) do
		local f = b.list[i]
		if e.sk ~= f.sk or e.name ~= f.name or e.n ~= f.n then return false end
	end
	for k, v in pairs(a.add) do if b.add[k] ~= v then return false end end
	for k, v in pairs(b.add) do if a.add[k] ~= v then return false end end
	return true
end
function CP.SaveEdit()
	local g = CP.Goal()
	local st = g.edit and g.stacks[g.edit]
	-- a stack made by "План по руде" stops being one after any real change (crafting progress does not count)
	if st and st.orePlan and not SameContent(st, CP.snap) then st.orePlan = nil end
	g.edit = nil
	CP.sel, CP.prevSel, CP.snap, CP.snapOf = CP.prevSel or {}, nil, nil, nil
	if st then -- empty stacks are not kept
		local any = next(st.add) ~= nil
		for _, e in ipairs(st.list) do if e.n > 0 then any = true end end
		if not any then CP.RemoveStack(CP.IndexOf(st)) end
	end
	RemoveDoneLater()
	CP.Changed()
end
function CP.CancelEdit()
	local g = CP.Goal()
	local i = CP.snapOf and CP.IndexOf(CP.snapOf)
	if i then
		if CP.snap then g.stacks[i] = CP.snap else table.remove(g.stacks, i) end -- a new stack is dropped
	end
	g.edit = nil
	CP.sel, CP.prevSel, CP.snap, CP.snapOf = CP.prevSel or {}, nil, nil, nil
	RemoveDoneLater()
	CP.Changed()
end
function CP.IndexOf(st)
	for i, x in ipairs(CP.Goal().stacks) do if x == st then return i end end
end
function CP.RemoveStack(si)
	if not si then return end
	local g = CP.Goal()
	table.remove(g.stacks, si)
	if g.edit == si then g.edit = nil elseif g.edit and g.edit > si then g.edit = g.edit - 1 end
	CP.sel = {}
end
-- How many times the recipe is in the stack being edited (0 if not, or no edit in progress)
function CP.CountIn(sk, name)
	local st = CP.Editing()
	for _, e in ipairs(st and st.list or {}) do
		if e.sk == sk and e.name == name then return e.n end
	end
	return 0
end
-- Which stacks contain the recipe: "Стек 1, Стек 3" or nil
-- Built once after each change (map "skill:name" -> text): the profession/trainer rows ask for every
-- visible row on every window update, so this must be a plain lookup (cache declared above, near "computed")
function CP.StacksWith(sk, name)
	if not stacksWith then
		local g, map = CP.Goal(), {}
		for _, si in ipairs(CP.ActiveOrder()) do
			local seen = {}
			for _, e in ipairs(g.stacks[si].list or {}) do
				local key = e.sk .. ":" .. e.name
				if e.n > 0 and not seen[key] then
					seen[key] = true
					map[key] = (map[key] and (map[key] .. ", ") or "") .. "Стек " .. CP.StackNum(si)
				end
			end
		end
		stacksWith = map
	end
	return stacksWith[sk .. ":" .. name]
end
-- Remove the recipe from the stack being edited entirely
function CP.RemoveFromEdit(sk, name)
	local st = CP.Editing()
	for k, e in ipairs(st and st.list or {}) do
		if e.sk == sk and e.name == name then
			table.remove(st.list, k)
			CP.Changed(0)
			return
		end
	end
end
-- Add/remove a recipe in the stack being edited
function CP.Bump(sk, name, d)
	local st = CP.Editing()
	if not st then
		CP.Print("сначала «Создать стек» или карандаш на стеке (вкладка «План»).")
		return
	end
	for k, e in ipairs(st.list) do
		if e.sk == sk and e.name == name then
			e.n = e.n + d
			if e.n <= 0 then table.remove(st.list, k) end
			CP.ChangedSettle()
			return math.max(e.n, 0)
		end
	end
	if d > 0 then
		st.list[#st.list + 1] = { sk = sk, name = name, n = d }
		CP.ChangedSettle()
		return d
	end
	return 0
end
-- Material into the stack being edited
function CP.AddMat(id, d)
	local st = CP.Editing()
	if not st then
		CP.Print("сначала «Создать стек» или карандаш на стеке (вкладка «План»).")
		return
	end
	local v = (st.add[id] or 0) + d
	st.add[id] = (v > 0) and v or nil
	CP.Changed()
end
-- Recipe by name in your professions (for trainer/vendor buttons, Shift+click)
function CP.FindByName(prof, name)
	if prof and CP.SKILL_ID[prof] then
		local rec = CP.FindRec(CP.SKILL_ID[prof], name)
		if rec then return rec end
	end
	local lines = CP.SkillLines()
	local best
	for p, sk in pairs(CP.SKILL_ID) do
		local rec = CP.FindRec(sk, name)
		if rec and (not best or (lines[p] and not lines[CP.SKILL_NAME[best.sk]])) then best = rec end
	end
	return best
end

-- Crafted a recipe: minus 1 in the first stack (in order) with this recipe; a fully crafted stack is removed
-- (while a stack is being edited — after Save/Cancel)
local craftNames -- [recipe name] = true for stack entries with n > 0; dropped in CP.DropCache
CP.OnDrop(function() craftNames = nil end)
local function InAnyStack(spell)
	if not craftNames then
		craftNames = {}
		for _, st in ipairs(CP.Goal().stacks) do
			if not st.off then
				for _, e in ipairs(st.list) do if e.n > 0 then craftNames[e.name] = true end end
			end
		end
	end
	return craftNames[spell]
end
local watch = CreateFrame("Frame")
watch:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
watch:SetScript("OnEvent", function(_, _, unit, spell)
	if unit ~= "player" or not spell or not CraftPlanDB or not CraftPlanDB.goal then return end
	if not InAnyStack(spell) then return end
	local g = CP.Goal()
	for _, si in ipairs(CP.ActiveOrder()) do
		local st = g.stacks[si]
		for _, e in ipairs(st.list) do
			if e.name == spell and e.n > 0 then
				e.n = e.n - 1
				local left = false
				for _, x in ipairs(st.list) do if x.n > 0 then left = true end end
				if not left and g.edit ~= si then
					if g.edit then
						doneLater[st] = true
					else
						CP.RemoveStack(si)
						CP.Print("стек создан целиком.")
					end
				end
				CP.Changed()
				CP.ChangedLater(1.5)
				return
			end
		end
	end
end)
