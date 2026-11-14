-- Climbing: every machine's side (included by main.lua). For every climber in shared.climb:
--   POSE (client.postUpdate: the only callback where bone work takes, after data/script/playerbody.lua's locomotion -
--     Echo Hunt's crawl, verified in-game): a base clip from the game's set through the locomotion's override hook
--     (game.override.animation.<p> + .weight), the character's root turned to face the ladder / surface (after the
--     locomotion set it to the camera's yaw), a small sway on the chest, then IK every frame: hands on rungs, feet on rungs,
--     in the real rhythm - right hand + left foot move together, then left hand + right foot - the phase driven by
--     the climber's own progress (rungs climbed on a ladder; distance moved, up AND sideways, on a surface), so it
--     keeps pace with the speed and stands still when they hang still. Ladders: exact rung targets (RUNG along the
--     axis, any angle). Surfaces: each limb's next grip is a ray onto the surface ahead of it, planted there until
--     its next move. Mantling and the pull over a ladder's top: the game's jump-landing clip (proven), hands on the edge.
--   SOUND: rung steps / grips in the rhythm, a grab, a landing (registerVolume false: AI hearing ignores them).
--   FIRST PERSON (yourself; no own body is drawn): the mantle's dip only. On a ladder or a surface the eye just
--     follows the climb (the bob + roll in the rhythm - 3 cm / 1.2 deg at ~4-8 Hz - is gone: with the old per-update
--     teleport it made the view shake, "triple images").
--   HINTS: at a ladder, and the keys while climbing.

-- ------------------------------------------------------------------ tunables
CLIMB_CLIP, CLIMB_W = "jump_loop", 1.0      -- the base pose under the IK (a first guess: try others in-game)
MANTLE_CLIP = "jump_land"                   -- reads as a pull-up (picked in-game for Tall Order)
HAND_BASE, FOOT_BASE = 5, 0                 -- rungs above the feet the hands / feet hold (hands 1.5-1.8 m)
HAND_LAT, FOOT_LAT = 0.19, 0.13             -- m from the middle
HAND_OUT, FOOT_OUT = 0.04, 0.10             -- m out from the rung line (the hand wraps the rung; the ankle behind it)
LIFT = 0.12                                 -- m a moving hand / foot comes off the ladder
SURF_HAND_Y, SURF_FOOT_Y = 1.62, 0.18       -- surfaces: grip heights above the feet, along the surface's up
SURF_LEAD = 0.6                             -- m ahead (the way you move) a new grip is picked: two rungs' worth
PITCH_W = 0.0                               -- and pitched onto its slope: OFF since the first play test (a 9.5 deg funnel
                                            --  ladder showed the body beside the ladder - the pitch through RotateBone
                                            --  is the likely cause; the IK still puts hands / feet on the tilted rungs)
SWAY = 3                                    -- deg of chest roll in the rhythm
IK_HISTORY = 0.0
STILL_SPEED = 0.15                          -- m/s: slower than this is hanging still (the limbs settle on rungs)
STEP_VOL, GRAB_VOL, LAND_VOL = 0.45, 0.55, 0.5

CA = {A = {}, snd = {}, me = 0}

-- the limbs, paired diagonally: o = the half of the cycle they move in
CA_LIMBS = {
	{"shoulder_r", "hand_r", 1, 0, true},
	{"leg_upper_l", "foot_l", -1, 0, false},
	{"shoulder_l", "hand_l", -1, 1, true},
	{"leg_upper_r", "foot_r", 1, 1, false},
}

local function smooth(x) return x * x * (3 - 2 * x) end

local function snd(h, pos, vol, pitch)
	if h and pos then PlaySound(h, pos, vol, false, pitch or 1) end
end

local function feetOf(p)
	if not IsPlayerValid(p) then return nil end
	return GetPlayerTransform(p).pos
end

local function surfFrameC(n)
	local r = VecNormalize(VecCross(Vec(0, 1, 0), n))
	return VecCross(n, r), r
end

function climbClientInit()
	CA.A = {}
	CA.snd = {
		wood = LoadSound("wood/step0.ogg"),        -- (numbered series: each play picks one)
		creak = LoadSound("wood/hit-s0.ogg"),
		leaf = LoadSound("foliage/hit-s0.ogg"),
		grab = LoadSound("grab0.ogg"),
		land = LoadSound("wood/land0.ogg"),
	}
	CA.wallSnd = {}                                -- (Spiderman mode: a step sound per wall material, loaded when first heard)
end

-- the game's material -> its sound folder (data/snd/<folder>/step0..)
local WALL_SND = {masonry = "masonry", hardmasonry = "masonry", rock = "masonry", plaster = "masonry", dirt = "dirt",
	wood = "wood", metal = "metal", hardmetal = "metal", heavymetal = "metal", glass = "glass", plastic = "plastic",
	ice = "ice", foliage = "foliage"}

-- Spiderman mode: the step sound of the wall in front of the hands (a ray into it, its material), masonry if unknown
local function wallSound(p, hand, n)
	QueryRequire("physical")
	QueryCollisionMask(CL_RAYMASK)
	clRejectSteps()
	QueryRejectPlayer(p)
	local from = VecAdd(hand, VecScale(n, 0.3))
	local hit, d, _, sh = QueryRaycast(from, VecScale(n, -1), 1.5, 0)
	local folder = "masonry"
	if hit and sh ~= 0 then
		folder = WALL_SND[GetShapeMaterialAtPosition(sh, VecAdd(from, VecScale(n, -d - 0.02))) or ""] or folder
	end
	CA.wallSnd[folder] = CA.wallSnd[folder] or LoadSound(folder .. "/step0.ogg")
	return CA.wallSnd[folder]
end

-- ------------------------------------------------------------------ per frame: progress, sounds, camera
function climbClientTick(dt)
	CL_RAYMASK = clRayMask(GetInt("climbing.raymask"))       -- (synced by the mod that sets it)
	CL_STEPS = FindBodies("climbstep", true) or {}            -- (the host's steps: the grip rays skip them)
	local P = (shared.climb or {}).p or {}
	for p, d in pairs(P) do
		local a = CA.A[p]
		local feet = feetOf(p)
		if feet then
			if not a or a.g ~= d.g then
				a = {g = d.g, k = d.k, tk = GetTime(), feet = VecCopy(feet), dist = 0, stepAt = 0, r = 0, stillT = 0,
					mdir = Vec(0, 1, 0), grips = {}, j = {}, n = d.nrm and VecCopy(d.nrm) or nil, on = false}
				CA.A[p] = a
				snd(CA.snd.grab, VecAdd(feet, Vec(0, 1.5, 0)), GRAB_VOL, 0.9 + math.random() * 0.2)
			end
			if a.k ~= d.k then a.k, a.tk = d.k, GetTime() end
			a.live, a.d = true, d
			local delta = VecSub(feet, a.feet)
			local moved = VecLength(delta)
			if moved > 0.5 then moved = 0 end                   -- (a teleport, not a climb)
			a.feet = VecCopy(feet)
			if moved > STILL_SPEED * dt then                     -- (a speed: the velocity drive settles by a few mm)
				a.stillT = 0
				a.mdir = VecNormalize(VecAdd(VecScale(a.mdir, 0.7), VecScale(delta, 0.3 / moved)))
			else
				a.stillT = a.stillT + dt
			end
			a.still = a.stillT > 0.12
			if d.k == "ladder" then
				local s = clLadderLocal(d, feet)
				a.r = s / RUNG
				local beat = math.floor(a.r / 2)                -- (each diagonal pair's plant: every two rungs)
				if beat ~= a.beat then
					if a.beat then
						local hand = VecAdd(feet, Vec(0, 1.4, 0))
						snd(CA.snd.wood, hand, STEP_VOL, 0.85 + math.random() * 0.25)
						a.steps = (a.steps or 0) + 1
						if a.steps % 3 == 0 then snd(CA.snd.creak, hand, STEP_VOL * 0.5, 0.55 + math.random() * 0.15) end
					end
					a.beat = beat
				end
			elseif d.k == "surface" then
				a.dist = a.dist + moved
				a.r = a.dist / RUNG
				if d.nrm then a.n = VecNormalize(VecAdd(a.n or d.nrm, VecScale(VecSub(d.nrm, a.n or d.nrm), math.min(1, dt * 10)))) end
				if a.dist - a.stepAt >= 2 * RUNG then
					a.stepAt = a.dist
					local hand = VecAdd(feet, Vec(0, 1.4, 0))
					snd(d.wall and a.n and wallSound(p, hand, a.n) or CA.snd.leaf, hand, STEP_VOL, 0.85 + math.random() * 0.3)
				end
			end
		end
	end
	for p, a in pairs(CA.A) do
		if a.live and not P[p] then
			a.live = false
			if a.k == "mantle" or a.k == "top" then snd(CA.snd.land, feetOf(p), LAND_VOL) end
		end
	end
	-- first person: your own camera
	local me = GetLocalPlayer()
	CA.me = me
	local d, a = P[me], CA.A[me]
	if d and a then
		if d.k == "mantle" or d.k == "top" then
			local k = clClamp((GetTime() - a.tk) / math.max(d.dur or 0.5, 0.2), 0, 1)
			local s = math.sin(math.pi * k)
			-- no camera move of our own over the top / in a mantle: the roll swung the view both ways, the dip
			-- snapped back when the move ended before its timing ("camera shakes", the user, 2026-11-07); the
			-- body's own smooth path is the motion
			local _ = s
		end
	end
end

-- ------------------------------------------------------------------ the pose
-- one world rotation q applied to a bone about its own pivot (RotateBone is additive in the bone's frame)
local function rotateBoneWorld(anim, bone, q, w, B)
	B = B or GetBoneWorldTransform(anim, bone)
	if not B or not B.rot then return end
	local r = B.rot
	local inv = Quat(-r[1], -r[2], -r[3], r[4])
	RotateBone(anim, bone, QuatRotateQuat(QuatRotateQuat(inv, q), r), w)
end

-- face `face` (the way to look: toward the rungs / into the surface): the WHOLE character's root turned to it. The
-- game's locomotion (data/script/player_locomotion.lua) sets the animator's root to the camera's yaw every frame; this
-- used to twist only the pelvis by the difference - up to 180 deg looking away from the ladder - with the IK solved on
-- the half-turned body: it "spasmed" and broke apart when the camera turned away (the user, 2026-11-07). Now the root
-- faces the ladder after the locomotion (client.postUpdate), the bones follow it; the chest's sway in the new frame (its
-- transform carried over from the old root). The pitch onto a ladder's slope stays off (PITCH_W).
local function turnBody(anim, p, face, bodyUp, sway)
	local ff = clHoriz(face)
	local at = GetAnimatorTransform(anim)
	if not at or not at.pos or VecLength(ff) < 0.1 then return Quat() end
	-- (turned by the camera's yaw -> the ladder's, from whatever rotation the locomotion gave it: the character's model
	-- faces the other way to QuatLookAt's -z - a root set by QuatLookAt hung the climber with his back to the rungs)
	local pf = clHoriz(TransformToParentVec(GetPlayerTransform(p), Vec(0, 0, -1)))
	local yaw = math.deg(math.atan2(VecCross(pf, ff)[2], VecDot(pf, ff)))
	local root = Transform(at.pos, QuatRotateQuat(QuatAxisAngle(Vec(0, 1, 0), yaw), at.rot))
	local C = GetBoneWorldTransform(anim, "chest")
	SetAnimatorTransform(anim, root)
	if C and C.rot and sway ~= 0 then
		local r = at.rot                                            -- (the chest under the new root: root * old^-1 * chest)
		local after = Transform(C.pos, QuatRotateQuat(root.rot, QuatRotateQuat(Quat(-r[1], -r[2], -r[3], r[4]), C.rot)))
		local axis = TransformToLocalVec(after, ff)
		RotateBone(anim, "chest", QuatAxisAngle(axis, sway), 1)
	end
	return Quat()
end

local function ik(anim, limb, pos, rot, w)
	SetAnimatorTransformIK(anim, limb[1], limb[2], Transform(pos, rot), w, IK_HISTORY, false, true)
end

-- where limb i is in the cycle: k (cycle), f (0..1: moving while f < 0.5)
local function cycle(r, o)
	local u = (r - o) / 2
	local k = math.floor(u)
	return k, u - k
end

local function poseLadder(anim, p, d, a, dt)
	local face = VecScale(d.N, -1)
	local q = turnBody(anim, p, face, d.A, SWAY * math.sin(math.pi * a.r) * (a.still and 0 or 1))
	local rot = QuatLookAt(Vec(0, 0, 0), face)
	local jmax = math.floor((d.len - 0.05) / RUNG)
	for i, L in ipairs(CA_LIMBS) do
		local base = L[5] and HAND_BASE or FOOT_BASE
		local k, f = cycle(a.r, L[4])
		local j, lift
		if f < 0.5 then
			j, lift = 2 * k + L[4] + base + 2 * smooth(f / 0.5), math.sin(math.pi * f / 0.5)
		else
			j, lift = 2 * k + 2 + L[4] + base, 0
		end
		if a.still then                                         -- stopped mid-move: the limb finishes on a rung
			j = math.floor((j - L[4] - base) / 2 + 0.5) * 2 + L[4] + base
			lift = 0
		end
		a.j[i] = a.j[i] and a.j[i] + (j - a.j[i]) * math.min(1, dt * (a.still and 10 or 45)) or j
		local jj = a.j[i]
		local pos
		if L[5] and d.top and jj > jmax + 0.5 then              -- above the last rung: the hand on the top floor
			pos = VecAdd(clLadderPoint(d, d.len, 0, L[3] * HAND_LAT), VecScale(d.fwd, 0.2))
			pos[2] = d.topY + 0.04
		else
			jj = clClamp(jj, 0, jmax)
			pos = clLadderPoint(d, jj * RUNG + (L[5] and 0.02 or 0.06), (L[5] and HAND_OUT or FOOT_OUT) + lift * LIFT,
				L[3] * (L[5] and HAND_LAT or FOOT_LAT))
		end
		ik(anim, L, pos, rot, 1)
	end
end

-- a limb's next grip on a surface: up / out from the body by its home, ahead the way you move, a ray onto it
local function surfGrip(p, feet, n, limb, lead, mdir)
	local u, r = surfFrameC(n)
	local home = VecAdd(VecAdd(feet, VecScale(u, limb[5] and SURF_HAND_Y or SURF_FOOT_Y)),
		VecScale(r, limb[3] * (limb[5] and HAND_LAT or FOOT_LAT)))
	if lead > 0 then
		local md = VecSub(mdir, VecScale(n, VecDot(mdir, n)))      -- (in the surface's plane)
		if VecLength(md) > 0.1 then home = VecAdd(home, VecScale(VecNormalize(md), lead)) end
	end
	QueryRequire("physical")
	QueryCollisionMask(CL_RAYMASK)                                -- (climbing.raymask: climb_world.lua clRayMask)
	clRejectSteps()
	QueryRejectPlayer(p)
	local from = VecAdd(home, VecScale(n, 0.5))
	local hit, dist = QueryRaycast(from, VecScale(n, -1), 2.0, 0)
	if hit then return VecAdd(VecAdd(from, VecScale(n, -dist)), VecScale(n, limb[5] and 0.03 or 0.07)) end
	return VecSub(home, VecScale(n, STANDOFF))
end

local function poseSurface(anim, p, d, a, dt)
	local n = a.n or d.nrm
	if not n then return end
	local face = VecScale(n, -1)
	local u = surfFrameC(n)
	turnBody(anim, p, face, u, SWAY * math.sin(math.pi * a.r) * (a.still and 0 or 1))
	local rot = QuatLookAt(Vec(0, 0, 0), face)
	for i, L in ipairs(CA_LIMBS) do
		local g = a.grips[i]
		local k, f = cycle(a.r, L[4])
		if not g then
			local at = surfGrip(p, a.feet, n, L, 0, a.mdir)
			g = {k = k, from = at, to = at, cur = at}
			a.grips[i] = g
		elseif k ~= g.k then                                     -- this limb's next move: pick its next grip
			g.k = k
			g.from = g.cur
			g.to = surfGrip(p, a.feet, n, L, SURF_LEAD, a.mdir)
		end
		local pos
		if f < 0.5 and not a.still then
			local e = smooth(f / 0.5)
			pos = VecAdd(VecAdd(g.from, VecScale(VecSub(g.to, g.from), e)), VecScale(n, math.sin(math.pi * f / 0.5) * LIFT))
		else
			pos = g.to
		end
		g.cur = VecAdd(g.cur, VecScale(VecSub(pos, g.cur), math.min(1, dt * 18)))
		ik(anim, L, g.cur, rot, 1)
	end
end

local function poseEdge(anim, d, k)
	local edge, dir = d.edge, d.dir
	if d.k == "top" and d.top then
		edge = Vec(d.F[1] + d.A[1] * d.len, d.topY, d.F[3] + d.A[3] * d.len)
		dir = d.fwd
	end
	if not edge or not dir then return end
	local w = k < 0.6 and 1 or math.max(0, (1 - k) / 0.4)
	if w <= 0 then return end
	local right = VecNormalize(VecCross(Vec(dir[1], 0, dir[3]), Vec(0, 1, 0)))
	local e = Vec(edge[1], edge[2] + 0.04, edge[3])
	local rot = QuatLookAt(Vec(0, 0, 0), Vec(dir[1], 0, dir[3]))
	ik(anim, CA_LIMBS[3], VecAdd(e, VecScale(right, -0.26)), rot, w)
	ik(anim, CA_LIMBS[1], VecAdd(e, VecScale(right, 0.26)), rot, w)
end

-- client.postUpdate: every climber's pose on this machine
function climbClientPostUpdate(dt)
	dt = dt or (1 / 60)
	local P = (shared.climb or {}).p or {}
	local me = GetLocalPlayer()
	local fp = not GetBool("game.thirdperson")
	for p, d in pairs(P) do
		local a = CA.A[p]
		if a and IsPlayerValid(p) then
			local clip, w = CLIMB_CLIP, CLIMB_W
			local k = 0
			if d.k == "mantle" or d.k == "top" then
				k = clClamp((GetTime() - a.tk) / math.max(d.dur or 0.5, 0.2), 0, 1)
				clip, w = MANTLE_CLIP, k < 0.8 and 1 or math.max(0, (1 - k) / 0.2)
			end
			SetString("game.override.animation." .. p, clip)
			SetFloat("game.override.animation." .. p .. ".weight", w)
			a.on = true
			local anim = GetPlayerAnimator(p)
			if anim and anim ~= 0 and not (p == me and fp) then
				if d.k == "ladder" then poseLadder(anim, p, d, a, dt)
				elseif d.k == "surface" then poseSurface(anim, p, d, a, dt)
				else poseEdge(anim, d, k) end
			end
		end
	end
	for p, a in pairs(CA.A) do
		if a.on and not P[p] then
			a.on = false
			SetString("game.override.animation." .. p, "")
			SetFloat("game.override.animation." .. p .. ".weight", 0)
		end
		if not P[p] and not a.live then CA.A[p] = nil end
	end
end

-- ------------------------------------------------------------------ hints
-- A short bar at the bottom centre (the game's own hint-bar layout: key icon + text pairs, regular.ttf). The keys are
-- the player's OWN bindings, never names written here: on a keyboard read from the game's keymap
-- (options.input.keymap.<action>, what its controls page shows; GetKeyByAction is "only for internal usage" in a
-- mod) and drawn as key caps; on a gamepad the game's input-icon markup [[player:<action>;iconsize=..]] (as its
-- spawn menu's gamepad hints). HINT_MARKUP = true uses the markup for the keyboard too (does the engine draw the
-- bound key for it? unverified: the TEST copy shows both rows).
HINT_SIZE, HINT_FONT, HINT_Y = 34, 25, 118      -- key cap px, text px, px above the bottom edge
HINT_MARKUP = false
CL_PAD_ICON = {up = "gamepad_left_stick", down = "gamepad_left_stick", left = "gamepad_left_stick", right = "gamepad_left_stick"}

-- the label of the key bound to `action` (upper case), "" if unbound
function climbKeyName(action)
	local k = GetString("options.input.keymap." .. action)
	if k == "" then return "" end
	return string.upper(k)
end

-- one icon for a list of actions: {markup = string} or {caps = {labels}}
function climbKeyIcon(actions, markup)
	if markup then
		local seen, parts = {}, {}
		for _, a in ipairs(actions) do
			local name = (LastInputDevice() == 2 and CL_PAD_ICON[a]) or a
			if not seen[name] then
				seen[name] = true
				parts[#parts + 1] = "[[player:" .. name .. ";iconsize=" .. HINT_SIZE .. "," .. HINT_SIZE .. "]]"
			end
		end
		return {markup = table.concat(parts, " ")}
	end
	local caps = {}
	for _, a in ipairs(actions) do
		local n = climbKeyName(a)
		if n ~= "" then caps[#caps + 1] = n end
	end
	return {caps = caps}
end

-- the hint for player `me`: a list of {keys = {actions}, txt = text}, or nil
function climbHint(me)
	if shared.climbOff or GetPlayerHealth(me) <= 0 or GetBool("proxchat.typing." .. me) then return nil end
	local d = ((shared.climb or {}).p or {})[me]
	if d then
		if d.k == "ladder" then
			return {{keys = {"up", "down"}, txt = "Climb"}, {keys = {"left", "right"}, txt = "Step off"},
				{keys = {"jump"}, txt = "Jump off"}, {keys = {"crouch"}, txt = "Let go"}}
		elseif d.k == "surface" then
			return {{keys = {"up", "left", "down", "right"}, txt = "Climb"}, {keys = {"jump"}, txt = "Jump off"}, {keys = {"crouch"}, txt = "Let go"}}
		end
		return nil
	end
	local feet = GetPlayerTransform(me).pos
	local list = ((shared.climbL or {}).list) or {}
	if clLadderTopAt(list, feet) then return {{keys = {"interact"}, txt = "Climb down"}} end
	local L, s = clLadderAt(list, feet, 0.5)
	if L then
		if L.top and s >= (L.sTop or L.len) - 0.5 then return {{keys = {"interact"}, txt = "Climb down"}} end
		return {{keys = {"interact", "up"}, txt = "Climb"}}       -- (one entry: "E Climb  W Climb (walk into it)" said it twice)
	end
	return nil
end

local function capW(label)
	UiFont("bold.ttf", math.floor(HINT_SIZE * 0.55))
	local w = UiGetTextSize(label)
	return math.max(HINT_SIZE, w + 14)
end

local function iconW(ic)
	if ic.markup then
		UiFont("regular.ttf", HINT_FONT)
		return (UiGetTextSize(ic.markup))
	end
	local w = 0
	for i, c in ipairs(ic.caps) do w = w + capW(c) + (i > 1 and 4 or 0) end
	return w
end

local function drawIcon(ic)
	if ic.markup then
		UiFont("regular.ttf", HINT_FONT)
		UiColor(1, 1, 1, 1)
		UiText(ic.markup)
		return
	end
	-- the cursor is at the left end of the line, on its vertical middle (the action text is drawn "left middle"). Each
	-- cap sets its own alignment: a rect follows UiAlign too, so the cap is drawn "left middle" (centred on the line)
	-- and its letter "center middle" at the cap's centre. (It used to lift the cursor half a cap as if the rect were
	-- drawn "left top" - with the inherited "left middle" the cap rose by half its height and the letter sat on its
	-- bottom edge.)
	UiPush()
	for _, c in ipairs(ic.caps) do
		local w = capW(c)
		UiPush()
			UiAlign("left middle")
			UiColor(1, 1, 1, 0.92)
			UiRoundedRect(w, HINT_SIZE, 6)
			UiTranslate(w / 2, 0)
			UiAlign("center middle")
			UiColor(0.05, 0.05, 0.05, 1)
			UiFont("bold.ttf", math.floor(HINT_SIZE * 0.55))
			UiText(c)
		UiPop()
		UiTranslate(w + 4, 0)
	end
	UiPop()
end

-- draws the hint bar centred at the current position
function climbDrawHintBar(items, markup)
	local icons, widths, total = {}, {}, 0
	for i, it in ipairs(items) do
		icons[i] = climbKeyIcon(it.keys, markup)
		UiFont("regular.ttf", HINT_FONT)
		local tw = UiGetTextSize(it.txt)
		widths[i] = {iconW(icons[i]), tw}
		total = total + widths[i][1] + 8 + tw + (i > 1 and 34 or 0)
	end
	UiPush()
		UiAlign("left middle")
		UiTranslate(-total / 2, 0)
		for i, it in ipairs(items) do
			if i > 1 then UiTranslate(34, 0) end
			drawIcon(icons[i])
			UiTranslate(widths[i][1] + 8, 0)
			UiFont("regular.ttf", HINT_FONT)
			UiTextShadow(0, 0, 0, 0.8, 1.5)
			UiColor(1, 1, 1, 0.85)
			UiText(it.txt)
			UiTranslate(widths[i][2], 0)
		end
	UiPop()
end

function climbClientDraw()
	local items = climbHint(GetLocalPlayer())
	if items then
		UiPush()
		UiTranslate(UiCenter(), UiHeight() - HINT_Y)
		climbDrawHintBar(items, HINT_MARKUP or LastInputDevice() == 2)
		UiPop()
	end
end
