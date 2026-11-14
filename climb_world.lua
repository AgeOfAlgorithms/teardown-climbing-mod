-- Climbing: the world side (included by main.lua). Finds what can be climbed and describes it as plain data:
--   LADDERS: a straight climb axis A (unit, up-ish) from a foot F, `len` m long, with N (unit, perpendicular to A, from
--     the rungs toward the climber), R = A x N (the climber's right) and fwd = the way the climber faces (horizontal);
--     rungs every RUNG m along A from F. Sources: <location tags="ladder=<length>[,<lean>]"> (yaw-only rotation: its
--     local -z is the way the climber faces; the axis = up tilted by `lean` deg toward that way) and anything tagged
--     `ladder` (a body or a shape: its own longest box axis is the climb axis, its thinnest the depth; the climber is on
--     the side the axis leans away from, or on each open side of an upright one). Steeper than MAX_LEAN from vertical:
--     ignored (a slope you walk). The top exit: free floor beyond the top (forward), else behind it, found by rays.
--   CLIMBABLE: shapes / bodies tagged `climbable` (optional value: m/s), and <location tags="climbable=<w>,<h>">
--     patches (pos = the patch's bottom centre on the surface, local -z into it, w m sideways, h m up): anything a ray
--     hits inside a patch is climbable. Faces steeper than MAX_LEAN from vertical only.
-- Globals only (an included file's locals are invisible to main.lua and the other modules).

-- ------------------------------------------------------------------ tunables (shared)
RUNG = 0.3                 -- m between rungs, along the axis (hand / foot targets)
STANDOFF = 0.42            -- m from the rung line / the surface to the climber's body axis
MAX_LEAN = 45              -- deg from vertical: a ladder or face leaning more than this is a slope, not climbed
SURF_SPEED = 1.6           -- m/s on a climbable surface (a tag value climbable=<m/s> overrides)
ANYWALL_SPEED = 1.3        -- m/s on any other wall in Spiderman mode
CL_ANYWALL = false         -- Spiderman mode (the host's option savegame.mod.anywall, climbServerUpdate): every static wall climbable
LADDER_LAYER = 4           -- collision layer of ladder shapes: players leave it out of their mask (no snagging on rungs)
RESCAN_NEW = 0.25          -- s: look for new tagged ladders (spawned ones) this often
RESCAN_ALL = 2.0           -- s: rebuild every tagged ladder (moved, broken)

CL_UP = Vec(0, 1, 0)

function clHoriz(v)
	local h = Vec(v[1], 0, v[3])
	local l = VecLength(h)
	if l < 1e-6 then return Vec(0, 0, 0), 0 end
	return VecScale(h, 1 / l), l
end

function clClamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

function clNums(s)
	local out = {}
	for x in string.gmatch(s or "", "[^,%s]+") do out[#out + 1] = tonumber(x) end
	return out
end

-- one ray for the mod: physical shapes only, not the player p (0: none), not `rej` (a body handle, or {shape = h}),
-- not the ladders' own shapes (LADDER_LAYER: a ladder's rails are no ledge to mantle onto, its rungs no wall)
-- the collision mask every ray of the mod uses: all layers but LADDER_LAYER and those in climbing.raymask (another mod's
-- own layers its players' rays must not see: Humans vs Clickers' hit boxes 128 and model parts 32 - with them a
-- clicker's headroom ray hit its own torso). Built bit by bit (Lua 5.1 has no bit operators; a raymask holding 4 isn't
-- taken off twice). Refreshed on the host (climbServerUpdate) and on every client (climbClientTick): the key is synced
function clRayMask(extra)
	extra = math.floor(tonumber(extra) or 0)
	local skip = 0
	for b = 0, 7 do
		local bit = 2 ^ b
		if bit == LADDER_LAYER or math.floor(extra / bit) % 2 == 1 then skip = skip + bit end
	end
	return 255 - skip
end
CL_RAYMASK = 255 - LADDER_LAYER

CL_STEPS = {}                -- the climbers' steps (climb_move.lua setStep): every ray of the mod skips them
function clRejectSteps()
	for _, b in ipairs(CL_STEPS) do QueryRejectBody(b) end
end

function clRay(p, origin, dir, dist, radius, rej)
	QueryRequire("physical")
	QueryCollisionMask(CL_RAYMASK)
	clRejectSteps()
	if p and p ~= 0 then QueryRejectPlayer(p) end
	if type(rej) == "table" then QueryRejectShape(rej.shape)
	elseif rej and rej ~= 0 then QueryRejectBody(rej) end
	return QueryRaycast(origin, dir, dist, radius or 0)
end

-- ------------------------------------------------------------------ ladders
-- a ladder from its foot, axis and outward normal
function clMakeLadder(src, h, F, A, N, len, w)
	local R = VecCross(A, N)
	local fwd = clHoriz(VecScale(N, -1))
	local L = {src = src, h = h or 0, F = VecCopy(F), A = VecCopy(A), N = VecCopy(N), R = R, fwd = fwd, len = len,
		w = w or 0.8, lean = math.deg(math.acos(clClamp(A[2], -1, 1)))}
	L.lat = math.max(0.55, L.w * 0.5 + 0.15)
	return L
end

-- (o goes out HORIZONTALLY - N's level part, cos(lean) long: along N itself the climber of a leaning ladder hung
-- o * sin(lean) above the rungs, "floating on top of the rungs" at 45 deg, the user, 2026-11-07; an upright ladder's
-- N is level anyway)
local function clLevelN(L) return Vec(L.N[1], 0, L.N[3]) end

function clLadderPoint(L, s, o, lat)
	return VecAdd(VecAdd(VecAdd(L.F, VecScale(L.A, s)), VecScale(clLevelN(L), o or 0)), VecScale(L.R, lat or 0))
end

-- a point in ladder coordinates (the inverse of clLadderPoint): s along the axis from the foot, o out toward the
-- climber (level), lat to the right
function clLadderLocal(L, p)
	local d = VecSub(p, L.F)
	local lat = VecDot(d, L.R)
	d = VecSub(d, VecScale(L.R, lat))
	local s = d[2] / math.max(L.A[2], 0.2)
	local nl = clLevelN(L)
	local n2 = math.max(VecDot(nl, nl), 0.04)
	return s, VecDot(VecSub(d, VecScale(L.A, s)), nl) / n2, lat
end

-- the axis parameter at which the climber's FEET are at height y
function clSAtFeetY(L, y)
	return (y - L.F[2]) / math.max(L.A[2], 0.2)                -- (the climber's offset is level: clLadderPoint)
end

-- ------------------------------------------------------------------ the way off the top (ladders and surfaces)
-- The nearest spot to stand on around `centre` (the top of a ladder's rung line / of a climbable face): rings 0.35 ..
-- EXIT_RING m out in 8 directions (`dirs` = how many of them: 8 all round, 5 the front half), a floor from EXIT_BELOW
-- below `refY` to EXIT_ABOVE above it, firm under the whole foot (4 more rays), EXIT_CLEAR m free above it. The way
-- there: the highest thing between `from` (the climber's feet) and the spot (a rail, a lip, at most EXIT_OVER above the
-- spot's floor) - the climber is lifted over it, at most EXIT_LIFT above `from`. Returns {spot = floor point, y = floor y, lift = height to cross at,
-- dist} or nil (nowhere to stand: the climber holds at the top).
EXIT_RING, EXIT_BELOW, EXIT_ABOVE, EXIT_CLEAR, EXIT_LIFT, EXIT_OVER = 1.2, 1.3, 0.6, 1.8, 3.0, 1.3
function clFindExit(p, centre, refY, fwd, from, dirs, rej)
	local right = Vec(-fwd[3], 0, fwd[1])
	local D = {}
	local s2 = math.sqrt(0.5)
	local all = {{fwd, 0}, {VecAdd(VecScale(fwd, s2), VecScale(right, s2)), 0.05}, {VecSub(VecScale(fwd, s2), VecScale(right, s2)), 0.05},
		{right, 0.08}, {VecScale(right, -1), 0.08},
		{VecSub(VecScale(right, s2), VecScale(fwd, s2)), 0.12}, {VecSub(VecScale(right, -s2), VecScale(fwd, s2)), 0.12}, {VecScale(fwd, -1), 0.1}}
	for i = 1, (dirs or 8) do D[i] = all[i] end
	local top = refY + EXIT_ABOVE
	for _, r in ipairs({0.35, 0.6, 0.9, EXIT_RING}) do
		local best, bscore = nil, 1e9
		for _, d in ipairs(D) do
			local q = VecAdd(centre, VecScale(d[1], r))
			local o = Vec(q[1], top + 0.15, q[3])
			local hit, dd, n = clRay(p, o, Vec(0, -1, 0), EXIT_ABOVE + EXIT_BELOW + 0.15, 0, rej)
			local fy = o[2] - dd
			if hit and dd > 0.02 and n[2] > 0.7 and fy >= refY - EXIT_BELOW then
				local firm = true
				for _, f in ipairs({{0.16, 0}, {-0.16, 0}, {0, 0.16}, {0, -0.16}}) do
					local fo = Vec(q[1] + f[1], fy + 0.3, q[3] + f[2])
					local h2, d2 = clRay(p, fo, Vec(0, -1, 0), 0.45, 0, rej)
					if not h2 or math.abs((fo[2] - d2) - fy) > 0.12 then firm = false; break end
				end
				if firm and not clRay(p, Vec(q[1], fy + 0.35, q[3]), Vec(0, 1, 0), EXIT_CLEAR - 0.35, 0.28, rej) then
					-- the way there: the highest surface under the path, sampled every 0.1 m (a thin rail), from EXIT_OVER
					-- above the spot's floor down (under any ceiling over it); anything taller in the way: not this spot
					local lift, blocked = fy, false
					local ns = math.max(2, math.ceil(VecLength(Vec(q[1] - from[1], 0, q[3] - from[3])) / 0.1))
					for k = 0, ns do
						local t = k / ns
						local mo = Vec(from[1] + (q[1] - from[1]) * t, fy + EXIT_OVER, from[3] + (q[3] - from[3]) * t)
						local h3, d3 = clRay(p, mo, Vec(0, -1, 0), mo[2] - (refY - EXIT_BELOW), 0, rej)
						if h3 and d3 <= 0.02 then blocked = true; break end
						if h3 and mo[2] - d3 > lift then lift = mo[2] - d3 end
					end
					if blocked then lift = 1e9 end
					if lift - from[2] <= EXIT_LIFT and r + d[2] < bscore then
						best, bscore = {spot = Vec(q[1], fy, q[3]), y = fy, lift = lift + 0.06, dist = r}, r + d[2]
					end
				end
			end
		end
		if best then return best end
	end
	return nil
end

-- the way off a ladder's top: L.top (the spot), L.topY, L.lift, L.sTop (where the climb hands over to it), L.sMax
function clFindTop(L)
	local top = clLadderPoint(L, L.len, 0, 0)
	local from = clLadderPoint(L, L.len, STANDOFF, 0)
	local ex = clFindExit(0, top, top[2], L.fwd, from, 8, L.rej)
	if ex then
		L.top, L.topY, L.lift = ex.spot, ex.y, ex.lift
		L.sTop = clClamp(clSAtFeetY(L, ex.y - 0.15), 0, L.len)       -- (a floor above the top: climb to the top, then lift)
		L.sMax = L.sTop
		return true
	end
	L.top, L.topY, L.lift, L.sTop = nil, nil, nil, nil
	L.sMax = math.max(0, L.len - 1.4)          -- (nowhere to stand at the top: hold with the hands at the top)
	return false
end

-- <location tags="ladder=<length>[,<lean>]"> -> a ladder (or nil, reason)
function clLadderFromLocation(loc)
	local v = clNums(GetTagValue(loc, "ladder"))
	local len, lean = v[1], v[2] or 0
	if not len or len < 0.5 then return nil, "length" end
	if math.abs(lean) > MAX_LEAN then return nil, "shallow" end
	local t = GetLocationTransform(loc)
	local fwd = clHoriz(TransformToParentVec(t, Vec(0, 0, -1)))
	local a = math.rad(lean)
	local A = VecAdd(VecScale(CL_UP, math.cos(a)), VecScale(fwd, math.sin(a)))
	local N = VecAdd(VecScale(fwd, -math.cos(a)), VecScale(CL_UP, math.sin(a)))
	return clMakeLadder("loc", 0, t.pos, A, N, len, tonumber(v[3]) or 0.8)
end

-- the oriented box of a shape (its own voxel grid): centre, its 3 world axes, half extents (m)
function clShapeBox(sh)
	local t = GetShapeWorldTransform(sh)
	local x, y, z, sc = GetShapeSize(sh)
	if not x or x <= 0 then return nil end
	if not sc or sc <= 0 then sc = 0.1 end
	local he = {x * sc / 2, y * sc / 2, z * sc / 2}
	local c = TransformToParentPoint(t, Vec(he[1], he[2], he[3]))
	return c, {TransformToParentVec(t, Vec(1, 0, 0)), TransformToParentVec(t, Vec(0, 1, 0)), TransformToParentVec(t, Vec(0, 0, 1))}, he
end

-- a body's box: its one shape's own box, or (several shapes) the box of all of them in the body's frame
function clBodyBox(b)
	local shapes = GetBodyShapes(b) or {}
	if #shapes == 1 then return clShapeBox(shapes[1]) end
	if #shapes == 0 then return nil end
	local bt = GetBodyTransform(b)
	local mn, mx = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
	for _, sh in ipairs(shapes) do
		local st = GetShapeWorldTransform(sh)
		local x, y, z, sc = GetShapeSize(sh)
		if x and x > 0 then
			sc = (sc and sc > 0) and sc or 0.1
			for _, c in ipairs({{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 0}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1}}) do
				local w = TransformToParentPoint(st, Vec(c[1] * x * sc, c[2] * y * sc, c[3] * z * sc))
				local l = TransformToLocalPoint(bt, w)
				for i = 1, 3 do mn[i] = math.min(mn[i], l[i]); mx[i] = math.max(mx[i], l[i]) end
			end
		end
	end
	if mn[1] > mx[1] then return nil end
	local he = {(mx[1] - mn[1]) / 2, (mx[2] - mn[2]) / 2, (mx[3] - mn[3]) / 2}
	local c = TransformToParentPoint(bt, Vec((mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2, (mn[3] + mx[3]) / 2))
	return c, {TransformToParentVec(bt, Vec(1, 0, 0)), TransformToParentVec(bt, Vec(0, 1, 0)), TransformToParentVec(bt, Vec(0, 0, 1))}, he
end

-- a box -> its ladder frame: axis A (longest, pointing up), depth axis D (thinnest), length, width; or nil, reason
function clBoxLadderAxes(c, ax, he)
	local k = 1
	for i = 2, 3 do if he[i] > he[k] then k = i end end
	local A = VecCopy(ax[k])
	if A[2] < 0 then A = VecScale(A, -1) end
	if A[2] < math.cos(math.rad(MAX_LEAN)) - 1e-3 then return nil, "shallow" end
	local o = {}
	for i = 1, 3 do if i ~= k then o[#o + 1] = i end end
	local di, wi = o[1], o[2]
	if he[wi] < he[di] then di, wi = wi, di end
	return A, ax[di], he[k] * 2, he[wi] * 2, he[di] * 2, VecSub(c, VecScale(A, he[k]))
end

-- a tagged ladder body / shape -> a list of ladders (one per climbable side); rejectBody: what rays skip (clRay's rej)
function clLaddersFromBox(src, h, rejectBody, c, ax, he)
	local A, D, len, w, depth, F = clBoxLadderAxes(c, ax, he)
	if not A then return {}, D end
	if len < 0.6 or depth > 0.6 or w > 2.5 then return {}, "shape" end
	local lh, lean = clHoriz(A)
	local sides = {}
	if lean > 0.05 then                                 -- leaning: the climber is on the side it leans away from
		sides[1] = VecDot(D, lh) < 0 and D or VecScale(D, -1)
	else                                               -- upright: each open side
		local mid = VecAdd(F, VecScale(A, math.min(len * 0.5, 1.2)))
		for _, s in ipairs({D, VecScale(D, -1)}) do
			if not clRay(0, VecAdd(mid, VecScale(s, depth * 0.5 + 0.02)), s, 0.7, 0.05, rejectBody) then sides[#sides + 1] = s end
		end
	end
	local out = {}
	for _, N in ipairs(sides) do
		local L = clMakeLadder(src, h, F, A, N, len, w)
		L.rej = rejectBody
		out[#out + 1] = L
	end
	return out
end

-- ------------------------------------------------------------------ climbable surfaces
-- <location tags="climbable=<w>,<h>">
function clPatchFromLocation(loc)
	local v = clNums(GetTagValue(loc, "climbable"))
	local w, h = v[1], v[2]
	if not w or not h or w <= 0 or h <= 0 then return nil end
	return {t = GetLocationTransform(loc), w = w, h = h, speed = tonumber(v[3]) or SURF_SPEED}
end

function clInPatch(P, point)
	local l = TransformToLocalPoint(P.t, point)
	return math.abs(l[1]) <= P.w * 0.5 + 0.05 and l[2] >= -0.15 and l[2] <= P.h + 0.15 and l[3] >= -1.2 and l[3] <= 0.6
end

local function speedOf(v)
	local s = tonumber(v)
	if not s or s <= 0 then return SURF_SPEED end
	return clClamp(s, 0.3, 4)
end

-- a ray hit (shape, point): the climbing speed if it is climbable, else nil; second value true = only climbable through
-- Spiderman mode (any static wall: not a loose / moving body, a vehicle or a door - those are dynamic)
function clClimbable(shape, point, patches)
	if shape and shape ~= 0 then
		if HasTag(shape, "climbable") then return speedOf(GetTagValue(shape, "climbable")) end
		local b = GetShapeBody(shape)
		if b ~= 0 and HasTag(b, "climbable") then return speedOf(GetTagValue(b, "climbable")) end
	end
	for _, P in ipairs(patches or {}) do
		if clInPatch(P, point) then return P.speed end
	end
	if CL_ANYWALL and shape and shape ~= 0 then
		local b = GetShapeBody(shape)
		if b ~= 0 and not IsBodyDynamic(b) then return ANYWALL_SPEED, true end
	end
	return nil
end

-- steep enough to climb (not a floor or a gentle slope you walk)?
function clSteep(n)
	return math.abs(n[2]) <= math.cos(math.rad(90 - MAX_LEAN)) + 0.02
end

-- ------------------------------------------------------------------ discovery (server)
CW = {ladders = {}, patches = {}, known = {}, newT = 0, allT = 0, seq = 0, rejected = 0, passable = {}}

-- shapes of a location ladder's own model (thin, along the axis, on the rung line) go on LADDER_LAYER
local function passLocationModel(L)
	local a = clLadderPoint(L, 0, 0, 0)
	local b = clLadderPoint(L, L.len, 0, 0)
	local mn = Vec(math.min(a[1], b[1]) - 0.6, math.min(a[2], b[2]) - 0.2, math.min(a[3], b[3]) - 0.6)
	local mx = Vec(math.max(a[1], b[1]) + 0.6, math.max(a[2], b[2]) + 1.4, math.max(a[3], b[3]) + 0.6)
	for _, sh in ipairs(QueryAabbShapes(mn, mx) or {}) do
		local c, ax, he = clShapeBox(sh)
		if c then
			local A, D, len, w, depth = clBoxLadderAxes(c, ax, he)
			if A and math.abs(VecDot(A, L.A)) > 0.95 and depth <= 0.5 and w <= 1.4 and len >= L.len * 0.5 then
				local _, o, lat = clLadderLocal(L, c)
				if math.abs(o) < 0.35 and math.abs(lat) < 0.35 then
					SetShapeCollisionFilter(sh, LADDER_LAYER, 255)
					CW.passable[sh] = true
				end
			end
		end
	end
end

local function passShapes(shapes)
	for _, sh in ipairs(shapes) do
		SetShapeCollisionFilter(sh, LADDER_LAYER, 255)
		CW.passable[sh] = true
	end
end

-- a tagged ladder handle -> its ladders (pinning a loose one: a spawned ladder would topple)
local function buildTagged(h, isBody)
	local c, ax, he, rej, shapes
	if isBody then
		if IsBodyDynamic(h) then SetBodyDynamic(h, false) end
		c, ax, he = clBodyBox(h)
		rej, shapes = h, GetBodyShapes(h) or {}
	else
		local b = GetShapeBody(h)
		if b ~= 0 and IsBodyDynamic(b) then SetBodyDynamic(b, false) end
		c, ax, he = clShapeBox(h)
		rej, shapes = {shape = h}, {h}
	end
	if not c then return {} end
	local out, why = clLaddersFromBox(isBody and "body" or "shape", h, rej, c, ax, he)
	if #out == 0 then CW.rejected = CW.rejected + 1 end
	for _, L in ipairs(out) do clFindTop(L) end
	if #out > 0 then passShapes(shapes) end
	return out
end

local function rebuild()
	local list = {}
	for _, L in ipairs(CW.fixed) do list[#list + 1] = L end
	for h, k in pairs(CW.known) do
		if IsHandleValid(h) then
			k.ladders = buildTagged(h, k.body)
			for _, L in ipairs(k.ladders) do list[#list + 1] = L end
		else
			CW.known[h] = nil
		end
	end
	local sig = {}
	for i, L in ipairs(list) do
		L.id = i
		sig[i] = string.format("%.2f,%.2f,%.2f,%.3f,%.3f,%.2f,%s", L.F[1], L.F[2], L.F[3], L.A[1], L.A[3], L.len, tostring(L.topY))
	end
	CW.ladders = list
	sig = table.concat(sig, ";")
	local changed = sig ~= CW.sig
	CW.sig = sig
	if changed then CW.seq = CW.seq + 1 end
	return changed
end

local function scanNew()
	local found = false
	for _, b in ipairs(FindBodies("ladder", true) or {}) do
		if not CW.known[b] then CW.known[b] = {body = true}; found = true end
	end
	for _, sh in ipairs(FindShapes("ladder", true) or {}) do
		local b = GetShapeBody(sh)
		if not CW.known[sh] and not (b ~= 0 and HasTag(b, "ladder")) then CW.known[sh] = {body = false}; found = true end
	end
	return found
end

function clWorldInit()
	CW.fixed, CW.patches, CW.known, CW.passable, CW.rejected = {}, {}, {}, {}, 0
	for _, loc in ipairs(FindLocations("ladder", true) or {}) do
		local L = clLadderFromLocation(loc)
		if L then
			clFindTop(L)
			passLocationModel(L)
			CW.fixed[#CW.fixed + 1] = L
		else
			CW.rejected = CW.rejected + 1
		end
	end
	for _, loc in ipairs(FindLocations("climbable", true) or {}) do
		local P = clPatchFromLocation(loc)
		if P then CW.patches[#CW.patches + 1] = P end
	end
	scanNew()
	rebuild()
	CW.newT, CW.allT = RESCAN_NEW, RESCAN_ALL
end

-- server.update: new tagged ladders now and then; everything again more rarely. True when the list changed (so the
-- clients' copy is only sent then).
function clWorldUpdate(dt)
	CW.newT = CW.newT - dt
	CW.allT = CW.allT - dt
	if CW.newT <= 0 then
		CW.newT = RESCAN_NEW
		if scanNew() then return rebuild() end
	end
	if CW.allT <= 0 then
		CW.allT = RESCAN_ALL
		return rebuild()
	end
	return false
end

-- the nearest ladder whose climbing strip holds `feet` (pad > 0: a looser zone): L, s, o, lat
LAD_FRONT, LAD_BACK, LAD_BELOW, LAD_ABOVE = 0.9, 0.3, 0.6, 0.3
function clLadderAt(ladders, feet, pad)
	pad = pad or 0
	local best, bs, bo, bl, bd = nil, 0, 0, 0, 1e9
	for _, L in ipairs(ladders) do
		local dx, dz = feet[1] - L.F[1], feet[3] - L.F[3]
		if dx * dx + dz * dz <= (L.len + 2) * (L.len + 2) then
			local s, o, lat = clLadderLocal(L, feet)
			if s >= -LAD_BELOW - pad and s <= L.len + LAD_ABOVE + pad and math.abs(lat) <= L.lat + pad
				and o >= -LAD_BACK - pad and o <= LAD_FRONT + pad then
				local d = math.abs(lat) + math.abs(o - STANDOFF)
				if d < bd then best, bs, bo, bl, bd = L, s, o, lat, d end
			end
		end
	end
	return best, bs, bo, bl
end

-- a ladder whose top exit `feet` stands at (within `r` m of it, on its floor): E climbs down it
function clLadderTopAt(ladders, feet, r)
	r = r or 0.9
	for _, L in ipairs(ladders) do
		if L.top and math.abs(feet[2] - L.topY) < 0.4 then
			local dx, dz = feet[1] - L.top[1], feet[3] - L.top[3]
			if dx * dx + dz * dz <= r * r then return L end
		end
	end
	return nil
end

-- the plain-data copy of a ladder for `shared` (clients: animation, hints)
function clLadderData(L)
	return {F = VecCopy(L.F), A = VecCopy(L.A), N = VecCopy(L.N), R = VecCopy(L.R), fwd = VecCopy(L.fwd), len = L.len,
		lat = L.lat, top = L.top and VecCopy(L.top) or nil, topY = L.topY, sTop = L.sTop, sMax = L.sMax}
end
