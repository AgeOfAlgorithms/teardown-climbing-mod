-- Climbing: the host's side (included by main.lua). Every player, server.update (60 Hz):
--   LADDER (Dread Keep's movement.lua, made any-angle): grab with W while facing it (on the ground, in a jump, from
--     the water), E at it (whichever way you face; at the top: swing onto it), or step off the floor at its top into
--     its strip. On it: W / S along the axis, nothing = hang still, A / D alone slide off sideways, JUMP pushes off,
--     CROUCH (or E) lets go; at the top over onto the floor there, at the foot S steps off. The climber follows the
--     mod's path (m.pos) by VELOCITY (drive: the path's own speed + a gentle pull back onto it), at STANDOFF in front
--     of the rung line and centred on it sideways (both eased in at SNAP_MAX from where you grab). A teleport only
--     to lift a grounded climber off the floor at the foot (the engine's grounded controller cancels an upward
--     velocity there) or when something held them DRIVE_SNAP off the path. (It was a teleport every update: the
--     first-person eye moved in 60 Hz steps and the view shook - the user: "it wobbles so fast I see triple images".)
--   SURFACE (anything `climbable`): grab with W (or E) facing it; it holds where you grab it and you move over it:
--     W / S up / down, A / D sideways. Each update a few short rays from the body toward the surface give the points
--     and normals: the body follows its shape (bumps, curves, angles) at STANDOFF along the smoothed normal. A
--     non-climbable voxel in the way or no climbable hit ahead = an edge: up off the top = onto the nearest spot to
--     stand beyond it, over a rail between (by position, clFindExit; none: hold at the top), down to a floor = step
--     off, sideways = stop (held SIDE_SLIP s: slide off).
--   OVER THE TOP (ladders and surfaces): lifted clear, carried across, set down standing on the nearest firm spot with
--     1.8 m free above it (rings up to 1.2 m out, up to 0.6 m above the top); nowhere to stand: hold at the top.
--   MANTLE (Warehouse Ring's mantle.lua: Wraith Hunt's / Humans vs Clickers' / Tall Order's, verified in-game, with
--     a vault over thin rails; + Dread Keep's reach from the last floor): walk or jump into a ledge MANTLE_MIN_RISE..
--     MANTLE_MAX_RISE above your feet and you pull yourself up and over. Not near ladders. CROUCH: no mantle.
-- Registry (host): climbing.off (everything stands down), climbing.nomantle (no free mantling: ladders and surfaces
--   still pull you over their tops), climbing.block.<p> (that player can't climb now), climbing.reach.<p> (metres:
--   that player's mantle reach, no reach cap), climbing.raymask (layers all the mod's rays skip). Published:
--   climbing.on.<p>, climbing.present (synced).
-- shared.climb = {n = seq, p = {[player] = state}} for the clients (whole table: nested shared writes unverified);
-- shared.climbL = {n = seq, list = {ladder data}} for the hints; shared.climbOff while off.

-- ------------------------------------------------------------------ tunables
CLIMB_UP, CLIMB_DOWN = 2.4, 2.8     -- m/s along a ladder's axis
LAD_FACE = 70                       -- deg: look within this of a ladder's facing to grab it with W
USE_PAD = 0.5                       -- m: E grabs a ladder from a little farther
SNAP_MAX = 1.2                      -- m/s: easing onto the climbing line
TOP_AT = 0.15
TOP_RISE, TOP_SPEED, TOP_MAX_T = 3.0, 2.5, 3.0  -- over the top: m/s up, m/s across, s at most (then set down there)
JUMP_BACK, JUMP_UP = 3.2, 3.0
SIDE_OFF = 2.4                      -- m/s sideways when sliding off
SIDE_HOLD = 0.12                    -- s of A / D alone (ladder) before you slide off
SIDE_SLIP = 0.5                     -- s of A / D held at a surface's side edge before you slide off
REGRAB = 0.5                        -- s after leaving before any grab
ABOVE_T = 0.6                       -- s after standing on the top floor that stepping into the strip still catches
NEAR_PAD = 0.4                      -- m around a ladder's strip where no mantle is tried
KNOCK = 0.9                         -- m: the engine moved a climber this far from where we put them: they let go
DRIVE_GAIN = 10                     -- 1/s: the velocity drive's pull back onto the path (gentle: no frame-to-frame swing)
DRIVE_SNAP = 0.3                    -- m off the path (held by something): placed back by position
-- surfaces
PROBE_Y = 1.2                       -- m above the feet: the body probe (chest)
HAND_Y = 1.75                       -- m: the hands' probe (past the top: over it)
LEAD = 0.25                         -- m ahead of the body that must still be climbable
SURF_GRAB = 0.95                    -- m from the chest a climbable face can be grabbed
SURF_SNAP = 2.0                     -- m/s: easing in onto the standoff
SURF_SNAP_OUT = 12.0                -- m/s: out, clear of a bump
NORM_EASE = 8                       -- 1/s: the facing follows the surface's normal
CLEAR = 0.4                         -- m: the body's clearance from anything in front of it (bumps, a sloped face)
-- mantle (Warehouse Ring)
MANTLE_MIN_RISE, MANTLE_MIN_RISE_GROUND, MANTLE_MAX_RISE = 0.35, 0.55, 1.4
MANTLE_MAX_REACH = 1.95             -- m above the floor you last stood on
MANTLE_RISE_LOW, MANTLE_RISE_LIMIT = 0.6, 1.8   -- knee .. head height: what the host's option (options.lua, savegame.mod.mantleheight) allows

-- the mantle height in use: the host's option within MANTLE_RISE_LOW .. MANTLE_RISE_LIMIT; unset = MANTLE_MAX_RISE
function clMantleRise()
	local h = GetFloat("savegame.mod.mantleheight")
	if not h or h <= 0 then return MANTLE_MAX_RISE end
	-- (+ 2 cm: a ledge exactly as high as the setting counts - a 0.6 m ledge measured 0.6000001 was refused at 0.6)
	return math.max(MANTLE_RISE_LOW, math.min(h, MANTLE_RISE_LIMIT)) + 0.02
end
MANTLE_REACH = 0.75
MANTLE_CONE = 45                    -- deg: mantle only moving within this of the facing (the ledge searched straight ahead)
MANTLE_MAX_FALL = 14
MANTLE_UP_TIME, MANTLE_UP_PER_M, MANTLE_OVER_SPEED = 0.16, 0.18, 3.0
VAULT_LAND = 0.6
GROUND_SCAN_EVERY = 3

-- ------------------------------------------------------------------ input: the ONE place keys are read (a TEST
-- copy replaces this function; the release never has test keys)
function climbKey(p, k) return InputDown(k, p) end

-- ------------------------------------------------------------------ helpers
CM = {st = {}, seq = 0, t = 0, maskT = 0, wasOff = false, dirty = false}

local function flying(p)
	local ok, f = pcall(GetPlayerParam, "flyMode", p)
	return ok and f == true
end

local function playerFwd(p)
	return (clHoriz(TransformToParentVec(GetPlayerTransform(p), Vec(0, 0, -1))))
end

local function wishDir(p, k)
	local tr = GetPlayerTransform(p)
	local fwd = TransformToParentVec(tr, Vec(0, 0, -1))
	local right = TransformToParentVec(tr, Vec(1, 0, 0))
	local w = Vec(0, 0, 0)
	if k.up then w = VecAdd(w, fwd) end
	if k.down then w = VecSub(w, fwd) end
	if k.right then w = VecAdd(w, right) end
	if k.left then w = VecSub(w, right) end
	w[2] = 0
	if VecLength(w) > 0.1 then return VecNormalize(w) end
	return nil
end

local function stateOf(p)
	local m = CM.st[p]
	if not m then
		m = {cool = 0, scan = 0, k = {}, jumpWas = false, useWas = false, on = false, t = 0, groundT = -10}
		CM.st[p] = m
	end
	return m
end

local function readKeys(p, m, typing)
	local k = m.k
	if typing then
		k.up, k.down, k.left, k.right, k.crouch, k.jumpNew, k.useNew = false, false, false, false, false, false, false
		m.jumpWas, m.useWas = false, false
		return k
	end
	k.up, k.down = climbKey(p, "up"), climbKey(p, "down")
	k.left, k.right = climbKey(p, "left"), climbKey(p, "right")
	k.crouch = climbKey(p, "crouch")
	local j = climbKey(p, "jump")
	k.jumpNew = j and not m.jumpWas            -- (our own edges: InputPressed can fall between updates)
	m.jumpWas = j
	local e = climbKey(p, "interact")
	k.useNew = e and not m.useWas
	m.useWas = e
	return k
end

local function setOn(p, m, on)
	if m.on ~= on then
		m.on = on
		SetBool("climbing.on." .. p, on, true)
	end
end

local function publish()
	local t = {}
	for p, m in pairs(CM.st) do if m.pub then t[p] = m.pub end end
	CM.seq = CM.seq + 1
	shared.climb = {n = CM.seq, p = t}
	CM.dirty = false
end

local function setPub(m, pub)
	if pub then
		CM.seq = CM.seq + 1
		pub.n = CM.seq
	end
	m.pub = pub
	CM.dirty = true
end

local function publishLadders()
	local list = {}
	for i, L in ipairs(CW.ladders) do list[i] = clLadderData(L) end
	shared.climbL = {n = CW.seq, list = list}
end

-- by POSITION (teleport, velocity zeroed), keeping the view
local function place(p, m, pos)
	local t = GetPlayerTransformWithPitch(p)
	SetPlayerTransformWithPitch(Transform(pos, t.rot), p)
	SetPlayerVelocity(Vec(0, 0, 0), p)
	m.pos = VecCopy(pos)
	if m.dr then m.dr.feet = nil end                             -- (the drive's last step: not a step, a jump)
end

-- along the path by VELOCITY (server.update only - the one writer of a climber's motion): the engine moves the
-- player itself, so the eye glides (a teleport every update showed it in steps). `pos` is where the feet should be
-- after this update; m.pos where they should be now.
-- The engine's own change to the velocity over a step (gravity, buoyancy, air steering) is learned from the last
-- step (how far the feet really went vs the velocity set) and cancelled, so the climber does not sag off the path.
local function drive(p, m, pos, dt, feet, noGroundSnap)
	local from = m.pos or feet
	local err = VecSub(from, feet)
	if VecLength(err) > DRIVE_SNAP or (not noGroundSnap and IsPlayerGrounded(p) and pos[2] > feet[2] + 0.002) then
		return place(p, m, pos)
	end
	local dr = m.dr
	if dr and dr.feet then
		local got = VecSub(VecScale(VecSub(feet, dr.feet), 1 / dt), dr.v)
		if VecLength(got) < 0.5 then dr.drift = VecLerp(dr.drift, got, 0.3) end  -- (more: blocked by something, not drift)
	elseif not dr then
		dr = {drift = Vec(0, 0, 0)}
		m.dr = dr
	end                                                          -- (no last step - after a hold on a step: drift kept)
	local v = VecSub(VecAdd(VecScale(VecSub(pos, from), 1 / dt), VecScale(err, DRIVE_GAIN)), dr.drift)
	SetPlayerVelocity(v, p)
	dr.feet, dr.v = VecCopy(feet), v
	m.pos = VecCopy(pos)
end

-- a still climber stands on a STEP: a small invisible static body under the feet, spawned by the host (so every machine
-- has it) while the climber holds still on a ladder or surface, or is blocked by another climber; gone while they move
-- (the velocity drive) and when they let go. In multiplayer gravity sagged a still climber wherever their player is
-- simulated off the host (the client "kept falling", the host hanging fell to the foot on the client's screen, the user,
-- 2026-11-07); standing on something is what every machine already gets right. (Fly mode did that and more: it ignored
-- the drive - a slideshow -, its keys flew the player off the rungs, and the camera tilted the body until it "broke into
-- a thousand pieces" when looking away and down; DisablePlayerInput froze mouse look.) The mod's own rays skip the steps
-- (tag climbstep: clRay, the limbs' grip rays).
STEP_HALF = 0.3                     -- m: the step's half width (0.6 x 0.1 x 0.6 m, its top 1 cm under the feet)
local function setStep(p, m, feet)
	if feet then
		if m.step and IsHandleValid(m.step) then return end
		m.step = nil
		local xml = string.format("<body tags='climbstep'><voxbox tags='invisible unbreakable climbstep' size='6 1 6' " ..
			"pos='%.2f -0.11 %.2f' material='unphysical'/></body>", -STEP_HALF, -STEP_HALF)
		for _, e in ipairs(Spawn(xml, Transform(feet), true) or {}) do
			if GetEntityType(e) == "body" then m.step = e end
		end
	elseif m.step then
		if IsHandleValid(m.step) then Delete(m.step) end
		m.step = nil
	end
end
SETTLED = 0.03                      -- m: a climber this close to where the drive wants them has arrived (then the step)
GRAVITY_G = 10                      -- m/s2: the drive's drift when a climber leaves a step (it learns the rest)

BODY_R, BODY_H = 0.9, 1.95          -- m: another player's body blocks a move closer than this sideways and vertically -
                                    -- before the engine's own player collision touches (two 1.8 m capsules): with 1.75 the
                                    -- bodies collided first, the drive pressed on and its catch-up teleport put the climber
                                    -- inside the other, pushed out above them (the user, 2026-11-07)
-- would moving the climber's feet from `from` to `to` take them into another player's body (that lies ahead)? Climbers
-- don't pass each other on a narrow ladder (the user, 2026-11-07), nor climb through someone standing at its foot
function clBodyBlocked(p, from, to)
	local mv = VecSub(to, from)
	if VecLength(mv) < 1e-6 then return false end
	for _, q in ipairs(GetAllPlayers() or {}) do
		if q ~= p and IsPlayerValid(q) and GetPlayerHealth(q) > 0 then
			local qp = GetPlayerTransform(q).pos
			local d = VecSub(qp, to)
			if math.abs(d[2]) < BODY_H and VecLength(Vec(d[1], 0, d[3])) < BODY_R and VecDot(VecSub(qp, from), mv) > 0 then
				return true
			end
		end
	end
	return false
end

local function release(p, m, cool, vel)
	setStep(p, m, nil)
	m.mode, m.L, m.l, m.pos, m.dr = nil, nil, nil, nil, nil
	m.cool = cool or REGRAB
	SetPlayerVelocity(vel or Vec(0, 0, 0), p)
	setPub(m, nil)
end

local function knocked(m, feet)
	return m.pos ~= nil and VecLength(VecSub(feet, m.pos)) > KNOCK
end

-- ------------------------------------------------------------------ ladder
local function ladderPub(m, kind)
	local d = clLadderData(m.L)
	d.k, d.g = kind, m.g
	d.dur = kind == "top" and 0.55 or 0
	setPub(m, d)
end

-- a new grab: its number (clients: a grab sound, fresh limb state)
local function newGrab(m)
	CM.grabs = (CM.grabs or 0) + 1
	m.g = CM.grabs
end

local function startLadder(p, m, L, s, o, lat, fromAbove)
	newGrab(m)
	m.mode, m.L, m.sideT, m.moving = "ladder", L, 0, false
	m.s = clClamp(s, 0, L.sMax)
	m.o, m.lat = o, lat
	m.pos = nil
	m.blockUp = fromAbove
	ladderPub(m, "ladder")
end

local function tryLadder(p, m, k, feet, v, grounded)
	local L, s, o, lat = clLadderAt(CW.ladders, feet, 0)
	if k.useNew then                                              -- E at a ladder: whichever way you face
		local U, us, uo, ul = clLadderAt(CW.ladders, feet, USE_PAD)
		L, s, o, lat = U or L, U and us or s, U and uo or o, U and ul or lat
		local TL = clLadderTopAt(CW.ladders, feet)                -- (standing at a top exit: that ladder, down)
		if TL then L, s, o, lat = TL, TL.sTop, STANDOFF, 0 end
		if not L then return false end
		k.useNew = false                                          -- (this press grabbed: it must not also let go)
		local fromAbove = L.top ~= nil and s >= L.sTop - 0.5
		if fromAbove then s, o, lat = math.max(0, L.sTop - 1.1), STANDOFF, 0 end
		local pos = clLadderPoint(L, clClamp(s, 0, L.sMax), math.max(o, STANDOFF * 0.5), lat)
		SetPlayerTransform(Transform(pos, QuatLookAt(pos, VecAdd(pos, L.fwd))), p)   -- (turned to the rungs)
		SetPlayerVelocity(Vec(0, 0, 0), p)
		startLadder(p, m, L, s, math.max(o, STANDOFF * 0.5), lat, fromAbove)
		return true
	end
	if not L then return false end
	local top = L.sTop or L.sMax
	if k.up and s < top - 0.4 then
		if VecDot(playerFwd(p), L.fwd) < math.cos(math.rad(LAD_FACE)) then return false end
		startLadder(p, m, L, s, o, lat, false)
		return true
	end
	-- stepped off the top floor into the strip (a hatch, a loft edge): catch the ladder below you
	if L.top and not grounded and s >= L.sTop - 1.0 and v[2] < 0.5 and m.groundY and m.groundY >= L.topY - 0.3
		and feet[2] <= m.groundY - 0.03 and m.t - m.groundT < ABOVE_T then
		startLadder(p, m, L, math.min(s, L.sTop - 0.1), o, lat, true)
		return true
	end
	return false
end

-- over the top, by POSITION (never a velocity fling, never a half-done mantle): up to the height that clears the way
-- (ex.lift: the floor, or a rail / lip between), across to the spot, set down on it, let go standing still
TOP_CLEAR = 0.15                    -- m over the lift height while carried across (the body never catches the rim)

local function topDur(m, ex, from)
	local up = math.max(0, ex.lift + TOP_CLEAR - from[2])
	local across = VecLength(Vec(ex.spot[1] - from[1], 0, ex.spot[3] - from[3]))
	local down = math.max(0, ex.lift + TOP_CLEAR - ex.y)
	return up / TOP_RISE + across / TOP_SPEED + down / TOP_RISE + 0.1
end

local function startTop(p, m, feet)
	local L = m.L
	m.ex = {spot = L.top, y = L.topY, lift = L.lift or (L.topY + 0.06)}
	m.mode, m.phase, m.tt, m.moving = "top", 1, 0, true
	ladderPub(m, "top")
	m.pub.dur = topDur(m, m.ex, m.pos or feet)
end

local function startSurfaceTop(p, m, ex, edge, dir)
	m.ex = ex
	m.mode, m.phase, m.tt, m.moving, m.L = "top", 1, 0, true, nil
	newGrab(m)
	setPub(m, {k = "top", g = m.g, dur = topDur(m, ex, m.pos), edge = VecCopy(edge), dir = VecCopy(dir)})
end

local function driveTop(p, m, feet, dt)
	local ex = m.ex
	local ty = math.max(ex.lift, ex.y + 0.06) + TOP_CLEAR
	local ground = ex.y + 0.02
	local pos = m.pos or feet
	m.tt = m.tt + dt
	local d = Vec(ex.spot[1] - pos[1], 0, ex.spot[3] - pos[3])
	local dist = VecLength(d)
	if m.tt > TOP_MAX_T then                                         -- stuck: set down on the spot (the one placement)
		place(p, m, Vec(ex.spot[1], ground, ex.spot[3]))
		return release(p, m, REGRAB + 0.2, Vec(0, 0, 0))
	end
	-- all by VELOCITY (drive), as the climb: up clear of the rim, across, down onto the floor, let go standing still
	-- (teleports - every update, then the final set-down - shook the view hard over the top: the user, 2026-11-07)
	if m.phase == 1 then
		if pos[2] >= ty - 0.01 then m.phase = 2
		else return drive(p, m, Vec(pos[1], math.min(ty, pos[2] + TOP_RISE * dt), pos[3]), dt, feet, true) end
	end
	if m.phase == 2 then
		if dist < 0.03 then m.phase = 3
		else
			local step = math.min(dist, TOP_SPEED * dt)
			return drive(p, m, Vec(pos[1] + d[1] / math.max(dist, 1e-6) * step, ty, pos[3] + d[3] / math.max(dist, 1e-6) * step),
				dt, feet, true)
		end
	end
	if pos[2] <= ground + 0.005 or (IsPlayerGrounded(p) and feet[2] <= ground + 0.08) then
		return release(p, m, REGRAB + 0.2, Vec(0, 0, 0))
	end
	drive(p, m, Vec(ex.spot[1], math.max(ground, pos[2] - TOP_RISE * dt), ex.spot[3]), dt, feet, true)
end

local function driveLadder(p, m, k, feet, dt)
	local L = m.L
	if knocked(m, feet) then return release(p, m, REGRAB, nil) end
	if k.crouch or k.useNew then return release(p, m, REGRAB + 0.3, Vec(0, -0.5, 0)) end
	if k.jumpNew then
		return release(p, m, REGRAB, VecAdd(VecScale(L.fwd, -JUMP_BACK), Vec(0, JUMP_UP, 0)))
	end
	if not k.up then m.blockUp = false end
	local up = k.up and not m.blockUp
	local down = k.down and not k.up
	if (k.left ~= k.right) and not k.up and not k.down then          -- A / D alone: slide off sideways
		m.sideT = m.sideT + dt
		if m.sideT >= SIDE_HOLD then
			local w = wishDir(p, k) or L.R
			return release(p, m, REGRAB, Vec(w[1] * SIDE_OFF, 0, w[3] * SIDE_OFF))
		end
	else
		m.sideT = 0
	end
	local s = m.s
	if up then
		if L.sTop and s >= L.sTop - 1e-3 then return startTop(p, m, feet) end
		s = math.min(L.sMax, s + CLIMB_UP * dt)
	elseif down then
		if s - CLIMB_DOWN * dt <= 0 then                                -- at the foot: step off backwards
			local foot = clLadderPoint(L, 0, STANDOFF, m.lat)
			place(p, m, Vec(foot[1], L.F[2] + 0.02, foot[3]))
			return release(p, m, REGRAB, VecScale(L.fwd, -1.0))
		end
		s = s - CLIMB_DOWN * dt
	end
	local blocked = false
	if (up or down) and clBodyBlocked(p, feet, clLadderPoint(L, s, m.o, m.lat)) then   -- (someone in the way)
		s, up, down, blocked = m.s, false, false, true
	end
	m.s = s
	m.moving = up or down
	m.o = m.o + clClamp(STANDOFF - m.o, -SNAP_MAX * dt, SNAP_MAX * dt)
	m.lat = m.lat + clClamp(-m.lat, -SNAP_MAX * dt, SNAP_MAX * dt)
	local want = clLadderPoint(L, s, m.o, m.lat)
	-- still (no movement key, or blocked) and arrived: stand on a step (setStep); else the drive
	if (blocked or not (k.up or k.down or k.left or k.right)) and VecLength(VecSub(want, feet)) < SETTLED then
		setStep(p, m, feet)
		m.pos = VecCopy(want)                                   -- (the path point: the feet rest within SETTLED of it -
		                                                        --  from the feet the first move took that gap in a frame)
		m.dr = {drift = Vec(0, -GRAVITY_G * dt, 0)}             -- (moving again: the drive starts from gravity's pull)
		return
	end
	setStep(p, m, nil)
	drive(p, m, want, dt, feet)
end

-- ------------------------------------------------------------------ surfaces
-- a ray from `from` along `dir`: the hit if it is climbable and steep, else nil (a non-climbable voxel first: nil)
local function surfRay(p, from, dir, dist)
	local hit, d, n, sh = clRay(p, from, dir, dist, 0)
	if not hit then return nil end
	local pt = VecAdd(from, VecScale(dir, d))
	local sp, free = clClimbable(sh, pt, CW.patches)
	if not sp or not clSteep(n) then return nil end
	return pt, n, sp, free
end

-- a few rays toward the surface around `c` (a point at the body axis); count, mean point, mean normal, speed
local function surfSample(p, c, n, u, r, spread)
	local cnt, sum, nsum, sp = 0, Vec(0, 0, 0), Vec(0, 0, 0), nil
	local offs = spread and {{0, 0}, {0.22, 0}, {-0.22, 0}, {0, 0.2}, {0, -0.2}} or {{0, 0}, {0, 0.12}, {0, -0.12}}
	local into = VecScale(n, -1)
	for _, o in ipairs(offs) do
		local q = VecAdd(VecAdd(c, VecScale(u, o[1])), VecScale(r, o[2]))
		local pt, hn, s = surfRay(p, VecAdd(q, VecScale(n, 0.3)), into, 0.3 + STANDOFF + 0.55)
		if pt then
			cnt = cnt + 1
			sum = VecAdd(sum, pt)
			nsum = VecAdd(nsum, hn)
			sp = sp or s
		end
	end
	if cnt == 0 then return 0 end
	return cnt, VecScale(sum, 1 / cnt), VecNormalize(nsum), sp
end

local function surfFrame(n)
	local r = VecNormalize(VecCross(Vec(0, 1, 0), n))
	local u = VecCross(n, r)
	return u, r
end

local function surfPub(m)
	setPub(m, {k = "surface", g = m.g, nrm = VecCopy(m.n), sp = m.speed, wall = m.free == true})
	m.pubN = VecCopy(m.n)
end

local function trySurface(p, m, k, feet)
	if not (k.up or k.useNew) then return false end
	local dir = playerFwd(p)
	local chest = VecAdd(feet, Vec(0, PROBE_Y, 0))
	local pt, n, sp, free = surfRay(p, chest, dir, SURF_GRAB)
	if not pt then return false end
	if VecDot(dir, n) > -0.5 then return false end              -- (facing it: within 60 deg)
	-- Spiderman mode, a wall that is not tagged climbable: grabbed only in the air (a jump, a fall, swimming) or with
	-- interact - walking along a street must not stick you to every wall - and only a wall that reaches past the hands
	-- (a low one is mantled, not climbed)
	if free then
		if IsPlayerGrounded(p) and not k.useNew then return false end
		if not surfRay(p, VecAdd(feet, Vec(0, HAND_Y, 0)), dir, SURF_GRAB + 0.3) then return false end
	end
	k.useNew = false
	newGrab(m)
	m.mode, m.n, m.speed, m.sideT, m.blockT, m.moving, m.free = "surface", n, sp, 0, 0, false, free
	m.pos = VecCopy(feet)
	surfPub(m)
	return true
end

-- how far out along n the body axis must stay: CLEAR in front of the most protruding thing (climbable or not: a stone
-- bump too) over the body's height and width - rays from just behind the axis toward the surface; nil if nothing
local function clearance(p, feet, n, r)
	local best = nil
	local into = VecScale(n, -1)
	for _, h in ipairs({0.01, 0.45, 0.8, 1.15, 1.5, 1.8}) do      -- (from the soles: the climber is moved, not placed)
		for _, w in ipairs({-0.4, 0, 0.4}) do
			local o = VecAdd(VecAdd(feet, Vec(0, h, 0)), VecAdd(VecScale(r, w), VecScale(n, 0.3)))
			local hit, d = clRay(p, o, into, 0.3 + STANDOFF + 0.4, 0)
			if hit then
				local out = 0.3 - d + CLEAR                        -- (along n, relative to the axis)
				if not best or out > best then best = out end
			end
		end
	end
	return best
end

local function driveSurface(p, m, k, feet, dt)
	if knocked(m, feet) then return release(p, m, REGRAB, nil) end
	if k.crouch or k.useNew then return release(p, m, REGRAB + 0.3, Vec(0, -0.5, 0)) end
	local n = m.n
	if k.jumpNew then
		local h = clHoriz(n)
		return release(p, m, REGRAB, VecAdd(VecScale(h, JUMP_BACK), Vec(0, JUMP_UP, 0)))
	end
	local u, r = surfFrame(n)
	local my = (k.up and 1 or 0) - (k.down and 1 or 0)
	local mx = (k.right and 1 or 0) - (k.left and 1 or 0)
	local pos = m.pos
	-- down onto a floor: step off
	if my < 0 then
		local hit, d, fn = clRay(p, VecAdd(pos, Vec(0, 0.3, 0)), Vec(0, -1, 0), 0.38 + m.speed * dt, 0)
		if hit and fn[2] > 0.7 then
			place(p, m, Vec(pos[1], pos[2] + 0.3 - d + 0.02, pos[3]))
			return release(p, m, REGRAB, VecScale(clHoriz(n), 1.0))
		end
	end
	-- up past the top (no climbable at the hands, three rays): onto the nearest spot to stand beyond the edge (a rail
	-- between is stepped over); none: hold there (a few tries a second)
	m.exitT = (m.exitT or 0) - dt
	if my > 0 and m.exitT <= 0 and surfSample(p, VecAdd(pos, Vec(0, HAND_Y, 0)), n, u, r, false) == 0 then
		m.exitT = 0.25
		local dir = clHoriz(VecScale(n, -1))
		local edge = VecAdd(pos, VecScale(dir, STANDOFF))
		local ex = clFindExit(p, edge, pos[2] + 1.5, dir, pos, 5, nil)
		if ex then return startSurfaceTop(p, m, ex, Vec(edge[1], ex.y, edge[3]), dir) end
	end
	local body = VecAdd(pos, Vec(0, PROBE_Y, 0))
	local function ok(mv)                                            -- the leading edge in direction mv still climbable?
		local step = VecScale(mv, m.speed * dt)
		local cnt = surfSample(p, VecAdd(VecAdd(body, step), VecScale(mv, LEAD)), n, mv, VecCross(mv, n), false)
		return cnt > 0, step
	end
	local moved = nil
	local sideOk = mx == 0 or (ok(VecScale(r, mx)))
	if my ~= 0 or mx ~= 0 then
		local mv = VecNormalize(VecAdd(VecScale(u, my), VecScale(r, mx)))
		local good, step = ok(mv)
		if good then moved = step
		elseif my ~= 0 and mx ~= 0 then                             -- one way blocked: try each alone
			local g1, s1 = ok(VecScale(u, my))
			local g2, s2 = ok(VecScale(r, mx))
			moved = (g1 and s1) or (g2 and s2) or nil
		end
	end
	local blocked = moved ~= nil and clBodyBlocked(p, pos, VecAdd(pos, moved))
	if blocked then moved = nil end                                       -- (someone in the way)
	if sideOk then
		m.blockT = 0
	else                                                             -- at a side edge: stop there; held: slide off
		m.blockT = m.blockT + dt
		if my == 0 and m.blockT >= SIDE_SLIP then
			return release(p, m, REGRAB, VecScale(r, mx * SIDE_OFF))
		end
	end
	local new = moved and VecAdd(pos, moved) or VecCopy(pos)
	-- re-seat on the surface where we are now: the facing follows its normal, the body its standoff
	local cnt, spt, snrm, sp = surfSample(p, VecAdd(new, Vec(0, PROBE_Y, 0)), n, u, r, true)
	if cnt == 0 then
		if moved then                                                -- (moved off it: stay where we were)
			new = VecCopy(pos)
			cnt, spt, snrm, sp = surfSample(p, VecAdd(new, Vec(0, PROBE_Y, 0)), n, u, r, true)
		end
		if cnt == 0 then return release(p, m, REGRAB, Vec(0, -0.5, 0)) end   -- (the surface is gone: fall)
		moved = nil
	end
	m.speed = sp or m.speed
	m.n = VecNormalize(VecAdd(n, VecScale(VecSub(snrm, n), math.min(1, NORM_EASE * dt))))
	local want = VecAdd(spt, VecScale(m.n, STANDOFF))
	local off = VecDot(VecSub(want, VecAdd(new, Vec(0, PROBE_Y, 0))), m.n)
	local clr = clearance(p, new, m.n, r)
	if clr and clr > off then off = clr end
	new = VecAdd(new, VecScale(m.n, clClamp(off, -SURF_SNAP * dt, SURF_SNAP_OUT * dt)))
	m.moving = moved ~= nil
	if (blocked or (my == 0 and mx == 0)) and VecLength(VecSub(new, feet)) < SETTLED then   -- (still: a step, driveLadder)
		setStep(p, m, feet)
		m.pos = VecCopy(new)                                    -- (the path point, as in driveLadder)
		m.dr = {drift = Vec(0, -GRAVITY_G * dt, 0)}             -- (moving again: the drive starts from gravity's pull)
	else
		setStep(p, m, nil)
		drive(p, m, new, dt, feet)
	end
	if VecDot(m.n, m.pubN or n) < 0.996 then surfPub(m) end           -- (clients: the facing, ~5 deg steps)
end

-- ------------------------------------------------------------------ mantle (Warehouse Ring's mantle.lua)
-- a grab-able ledge in direction dir within reach? {top, dist, thin, vault, rise, over, spot, edge} or nil
function clFindLedge(p, feet, dir, grounded, reach)
	local best = nil
	local h = 0.25
	while h <= reach - 0.02 do
		local hit, d, n = clRay(p, VecAdd(feet, Vec(0, h, 0)), dir, MANTLE_REACH, 0.12)
		if hit and math.abs(n[2]) < 0.75 and (not best or d < best) then best = d end
		h = h + 0.25
	end
	if not best then return nil end
	local face = best + 0.12
	local above = reach + 0.7
	local top, tp = nil, nil
	for _, past in ipairs({0.08, 0.18, 0.3}) do                 -- (the highest edge just past the face: a rail behind a net)
		local q = VecAdd(feet, VecAdd(VecScale(dir, face + past), Vec(0, above, 0)))
		local hit, d, n = clRay(p, q, Vec(0, -1, 0), above - 0.1, 0)
		if hit and d >= 0.05 and n[2] >= 0.6 then
			local y = q[2] - d
			if y - feet[2] <= reach and (not top or y > top + 0.05) then top, tp = y, q end
		end
	end
	if not top then return nil end
	local rise = top - feet[2]
	if rise < (grounded and MANTLE_MIN_RISE_GROUND or MANTLE_MIN_RISE) then return nil end
	local tp2 = VecAdd(tp, VecScale(dir, 0.45))
	local hit2, d2 = clRay(p, tp2, Vec(0, -1, 0), above + 0.3, 0)
	local thin = not (hit2 and math.abs((tp2[2] - d2) - top) < 0.2)
	local over = thin and face + 0.12 or face + 0.45
	local vault = false
	if thin then
		local far = VecAdd(Vec(feet[1], top + 0.3, feet[3]), VecScale(dir, face + VAULT_LAND))
		local hf, df = clRay(p, far, Vec(0, -1, 0), 3.0, 0)
		if hf and df > 0.4 then
			local floor = VecAdd(far, Vec(0, 0.3 - df, 0))
			if not clRay(p, VecAdd(floor, Vec(0, 0.3, 0)), Vec(0, 1, 0), 1.5, 0.2) then
				vault, over = true, face + VAULT_LAND
			end
		end
	end
	if clRay(p, VecAdd(feet, Vec(0, 1.75, 0)), Vec(0, 1, 0), rise + 0.15, 0.2) then return nil end
	for _, hh in ipairs({0.35, 1.0, 1.65}) do
		if clRay(p, Vec(feet[1], top + hh, feet[3]), dir, over + 0.1, 0.15) then return nil end
	end
	local spot = VecAdd(Vec(feet[1], top, feet[3]), VecScale(dir, over))
	if clRay(p, VecAdd(spot, Vec(0, 0.3, 0)), Vec(0, 1, 0), 1.5, 0.2) then return nil end
	local edge = VecAdd(Vec(feet[1], top, feet[3]), VecScale(dir, face))
	return {top = top, dist = best, thin = thin, vault = vault, rise = rise, over = over, spot = spot, edge = edge}
end

function startMantle(p, m, l, dir)
	newGrab(m)
	m.mode, m.phase, m.mt, m.dir, m.l, m.L, m.pos = "mantle", 1, 0, dir, l, nil, nil
	setPub(m, {k = "mantle", g = m.g, dur = MANTLE_UP_TIME + MANTLE_UP_PER_M * l.rise + 0.22, edge = VecCopy(l.edge), dir = VecCopy(dir), vault = l.vault})
end

local function driveMantle(p, m, k, feet, dt)
	local l = m.l
	m.mt = m.mt + dt
	local dir = m.dir
	if k.crouch then return release(p, m, 0.4, Vec(0, 0, 0)) end
	if m.phase == 1 then
		local T = MANTLE_UP_TIME + MANTLE_UP_PER_M * l.rise
		local target = l.top + 0.07
		if feet[2] >= target - 0.02 then
			m.phase, m.mt = 2, 0
		elseif m.mt > T + 0.3 then
			return release(p, m, 0.5, Vec(0, 0, 0))                    -- blocked: let go
		else
			local vy = (target - feet[2]) / math.max(T - m.mt, dt * 2)
			vy = clClamp(vy, 1.5, 9)
			SetPlayerVelocity(VecAdd(VecScale(dir, 0.5), Vec(0, vy, 0)), p)
			return
		end
	end
	local rem = VecDot(VecSub(l.spot, feet), dir)
	if rem < 0.04 or m.mt > 0.45 then
		return release(p, m, 0.2, VecScale(dir, l.vault and 1.6 or l.thin and 0 or 1.2))
	end
	local sp = math.min(MANTLE_OVER_SPEED, rem / 0.07)
	local vy = feet[2] < l.top + 0.02 and 1.2 or 0.3
	if l.vault then vy = feet[2] < l.top + 0.12 and 1.6 or 0.2 end
	SetPlayerVelocity(VecAdd(VecScale(dir, sp), Vec(0, vy, 0)), p)
end

local function tryMantle(p, m, k, feet, v, grounded)
	local dir, wished = wishDir(p, k), true
	if not dir then
		wished = false
		local hv = Vec(v[1], 0, v[3])
		if VecLength(hv) > 1.0 then dir = VecNormalize(hv) end
	end
	if not dir or v[2] <= -MANTLE_MAX_FALL then return end
	-- only forward: moving within MANTLE_CONE of where the player faces, and the ledge looked for straight ahead (holding
	-- S into one behind mantled backwards; with 60 deg and the search along the move, a strafe or a diagonal took ledges
	-- at the side - the user, 2026-11-07: "mantling should only work in the forward direction, say 45 degree cone")
	local face = TransformToParentVec(GetPlayerTransform(p), Vec(0, 0, -1))
	face[2] = 0
	if VecLength(face) < 0.1 then return end
	face = VecNormalize(face)
	if VecDot(face, dir) < math.cos(math.rad(MANTLE_CONE)) - 0.001 then return end   -- (W+A: exactly 45)
	dir = face
	local into = VecDot(Vec(v[1], 0, v[3]), dir)
	local pushing = (wished and (not grounded or k.up)) or (not grounded and into > 0.5)
	if not pushing then return end
	if grounded then
		m.scan = m.scan - 1
		if m.scan > 0 then return end
		m.scan = GROUND_SCAN_EVERY
	end
	if clLadderAt(CW.ladders, feet, NEAR_PAD) then return end
	-- climbing.reach.<p> (another mod's: a taller player-controlled body, Humans vs Clickers' 3.6 m clicker grabs at 2.6 m):
	-- that player's reach in place of MANTLE_MAX_RISE, and no MANTLE_MAX_REACH cap (its big jump catches ledges ~6 m
	-- up); the headroom and room checks stay human-sized (its engine collision is a human capsule)
	local reach = GetFloat("climbing.reach." .. p)
	local own = reach and reach > 0
	-- (the host's mantle height option raises or lowers the reach, and the cap over the last floor by as much)
	local rise = CM.rise or MANTLE_MAX_RISE
	local l = clFindLedge(p, feet, dir, grounded, own and reach or rise)
	if l and not own and not grounded and m.groundY and l.top - m.groundY > MANTLE_MAX_REACH + rise - MANTLE_MAX_RISE then l = nil end
	if l then startMantle(p, m, l, dir) end
end

-- ------------------------------------------------------------------ the players' collision mask: no rungs
local function passMask(p)
	if not next(CW.passable) then return end
	local ok, mask = pcall(GetPlayerParam, "CollisionMask", p)
	mask = ok and tonumber(mask) or nil
	if mask and math.floor(mask / LADDER_LAYER) % 2 == 1 then SetPlayerParam("CollisionMask", mask - LADDER_LAYER, p) end
end

-- ------------------------------------------------------------------ callbacks
function climbServerInit()
	CM.st, CM.seq, CM.t, CM.maskT, CM.wasOff = {}, 0, 0, 0, false
	clWorldInit()
	shared.climb = {n = 0, p = {}}
	publishLadders()
	shared.climbOff = false
	-- climbing.present: this mod runs (synced; kept set, also while climbing.off is: a game mode with its own mantle
	-- polls it - another mod's init may run before or after this one)
	SetBool("climbing.present", true, true)
	CM.presentT = 0
end

function climbServerUpdate(dt)
	CM.t = CM.t + dt
	CL_RAYMASK = clRayMask(GetInt("climbing.raymask"))
	CL_STEPS = FindBodies("climbstep", true) or {}
	for _, p in ipairs(GetRemovedPlayers() or {}) do
		if CM.st[p] then CM.st[p] = nil; CM.dirty = true end
		SetBool("climbing.on." .. p, false, true)
	end
	if GetBool("climbing.off") then
		if not CM.wasOff then
			CM.wasOff = true
			for p, m in pairs(CM.st) do
				if m.mode then release(p, m, REGRAB, nil) end
				setOn(p, m, false)
			end
			shared.climbOff = true
			publish()
		end
		return
	end
	if CM.wasOff then CM.wasOff = false; shared.climbOff = false end
	if clWorldUpdate(dt) then publishLadders() end
	CM.maskT = CM.maskT - dt
	local doMask = CM.maskT <= 0
	if doMask then CM.maskT = 0.25 end
	local noMantle = GetBool("climbing.nomantle")
	CL_ANYWALL = GetBool("savegame.mod.anywall") and not GetBool("climbing.noanywall")
	CM.rise = clMantleRise()
	for _, p in ipairs(GetAllPlayers() or {}) do
		local m = stateOf(p)
		m.cool = m.cool - dt
		m.t = m.t + dt
		if doMask then passMask(p) end
		if GetPlayerHealth(p) <= 0 or GetPlayerVehicle(p) ~= 0 or (flying(p) and not m.fly) or GetBool("climbing.block." .. p) then
			if m.mode then release(p, m, REGRAB, nil) end
			m.jumpWas, m.useWas = false, false
		else
			local typing = GetBool("proxchat.typing." .. p)
			local k = readKeys(p, m, typing)
			local feet = GetPlayerTransform(p).pos
			local grounded = IsPlayerGrounded(p)
			if grounded then m.groundY, m.groundT = feet[2], m.t end
			if m.mode == "ladder" then driveLadder(p, m, k, feet, dt)
			elseif m.mode == "top" then driveTop(p, m, feet, dt)
			elseif m.mode == "surface" then driveSurface(p, m, k, feet, dt)
			elseif m.mode == "mantle" then driveMantle(p, m, k, feet, dt)
			elseif not typing and m.cool <= 0 and not k.crouch then
				local v = GetPlayerVelocity(p)
				if not tryLadder(p, m, k, feet, v, grounded) and not trySurface(p, m, k, feet) and not noMantle then
					tryMantle(p, m, k, feet, v, grounded)
				end
			end
		end
		if m.mode ~= "ladder" and m.mode ~= "surface" then setStep(p, m, nil) end
		setOn(p, m, m.mode ~= nil)
	end
	climbHoldStill()
	if CM.dirty then publish() end
end

-- the engine's own walking must not drag a climber (W walks you into the ladder / wall between our placements): its
-- walking speed is 0 while on a ladder or a surface. The param holds for one frame (Dread Keep: set it every frame),
-- so set from server.update AND server.tick, and never touched otherwise (a game mode's own speed stays).
-- (server.tick) a climber on a ladder, a surface or going over the top: no walking (still: a step, setStep)
function climbHoldStill()
	for p, m in pairs(CM.st) do
		if m.mode == "ladder" or m.mode == "surface" or m.mode == "top" then SetPlayerParam("walkingSpeed", 0, p) end
	end
end

function climbServerTick(dt)
	CM.presentT = (CM.presentT or 0) - dt
	if CM.presentT <= 0 then
		CM.presentT = 1
		SetBool("climbing.present", true, true)
	end
	if not CM.wasOff then climbHoldStill() end
end

-- is player p climbing / mantling now (host)?
function climbMode(p)
	local m = CM.st[p]
	return m and m.mode or nil
end
