#version 2
-- Climbing: ladders and climbable surfaces (vines, nets, rock faces) and mantling, on any map (a global mod;
-- ../../PROJECT.md is the contract). The host runs the climbing (server), every machine animates every climber.
-- Maps mark things, the mod does the rest:
--   <location tags="ladder=<length>[,<lean>]"/>, anything tagged ladder, anything tagged climbable[=<speed>],
--   <location tags="climbable=<w>,<h>"/>. Registry (host): climbing.off, climbing.nomantle, climbing.block.<p>,
--   climbing.reach.<p>, climbing.raymask; published: climbing.on.<p>, climbing.present.

#include "climb_world.lua"
#include "climb_move.lua"
#include "climb_anim.lua"

-- (test builds add their modules here)

function server.init()
	climbServerInit()
	if CLIMB_TEST then CLIMB_TEST.serverInit() end
end

function server.update(dt)
	climbServerUpdate(dt)
	if CLIMB_TEST then CLIMB_TEST.serverUpdate(dt) end
end

function server.tick(dt)
	climbServerTick(dt)
	if CLIMB_TEST then CLIMB_TEST.serverTick(dt) end
end

function client.init()
	climbClientInit()
	if CLIMB_TEST then CLIMB_TEST.clientInit() end
end

function client.tick(dt)
	climbClientTick(dt)
	if CLIMB_TEST then CLIMB_TEST.clientTick(dt) end
end

function client.postUpdate(dt)
	climbClientPostUpdate(dt)
end

function client.draw()
	climbClientDraw()
	if CLIMB_TEST then CLIMB_TEST.clientDraw() end
end
