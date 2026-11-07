# Clamber: API for maps and mods

Clamber (Climbing, Ladders & Mantling) is a global mod: ladders, climbable walls (vines, nets, trellises, rock faces) and mantling onto ledges, on
any map. A map only **marks** what can be climbed, with tags and locations; the mod does the rest.

**Multiplayer.** Everything works for every player in a session. The host runs the climbing for all players
(grabbing, moving, getting off, mantling); every player's machine animates every climber (hands and feet on the rungs,
the body on the wall). Nothing in a map has to do anything for multiplayer. Settings for other mods are registry keys
on the host (below).

## Ladders

A ladder is a straight climb axis with rungs every **0.3 m**. It can stand upright or lean up to **45 degrees** from
vertical (a ship's ladder at 60-75 degrees from the floor, a ladder leaning on a wall); anything shallower is a slope
you walk up. There are three ways to make one.

### 1. The spawn menu

**Climbing > Ladder 3 m**: a 3 m wooden ladder. Lean it against a wall or stand it anywhere; it is pinned where it
lands.

### 2. A location in your map (exact)

```xml
<location tags="ladder=4" pos="12.0 0.0 -3.5" rot="0 90 0"/>
<location tags="ladder=6,15" pos="0.0 0.0 0.0" rot="0 180 0"/>
```

- `ladder=<length>[,<lean>]`: length in metres along the ladder; lean in degrees from vertical (default 0), the top
  away from the climber.
- `pos` = the foot of the rung line (the rungs are counted from it, every 0.3 m).
- `rot`: a turn about the vertical axis only. The location's local **-z is the way the climber faces** (toward the
  rungs).
- Your ladder's model is separate: place your own `<vox>` (or none: an invisible ladder on a wall). If the model is its
  own thin shape on the rung line, Climbing makes it passable (collision layer 4, so the climber doesn't snag on the
  rungs). A ladder that is part of a big shape keeps its collision.

### 3. A tag on any body or shape (quick)

```xml
<body tags="ladder"><vox file="MOD/vox/my_ladder.vox"/></body>
```

- The shape's own box gives the ladder: its **longest** axis is the climb axis, its **thinnest** the depth.
- The climber stands on the side the ladder leans away from, or on either open side of an upright one.
- Tagged ladders are found while the game runs too (spawned ones within 0.25 s; moved or broken ones are rebuilt every
  2 s). A dynamic tagged body is pinned static.

### Getting on and off (the same for all three)

- Walk into the ladder with forward, or press interact at it. At its top, interact climbs down onto it.
- Forward / back climb. Left / right step off sideways. Jump jumps off backwards. Crouch lets go.
- At the top the climber goes over onto the floor beyond the top (or behind it, for a ladder against a ledge). With no
  floor there, they hold at the top.
- The hint bar at the bottom of the screen shows each player's own bound keys (or gamepad icons).

## Climbable surfaces

Anything a player can move over freely in every direction, sticking where they grab it:

```xml
<body tags="climbable"><vox file="MOD/vox/vines.vox"/></body>        <!-- default speed 1.6 m/s -->
<body tags="climbable=1.0"><vox file="MOD/vox/rock.vox"/></body>     <!-- slower: 1.0 m/s -->
<location tags="climbable=2,4.5" pos="54 -2 -1" rot="0 0 0"/>        <!-- an invisible patch on a wall -->
```

- `climbable` on a body or shape: every face of it within 45 degrees of vertical. An optional value is the speed in m/s.
- `climbable=<w>,<h>` on a location: an invisible patch on whatever surface is there, `w` m wide and `h` m high.
  `pos` = the patch's bottom centre on the surface; its local -z points into the surface. Good for a rope ladder or a
  boarding net drawn into a wall, or a cliff.
- Players grab with forward (or interact) facing it, climb with the movement keys, go over the top at its upper edge,
  jump off or let go with crouch. A swimmer can grab a patch that reaches into the water (a net down a ship's side).

## Mantling

No setup: walking or jumping into a ledge pulls the player up onto it, if the ledge is 0.35-1.4 m above their feet
(0.55 m from standing on the ground), within reach of the last floor they stood on (1.95 m), straight ahead (moving
within 45 degrees of the way they face), and there is room on top. Crouch: no mantle. Thin rails are vaulted over.

## Settings for other mods (registry, host)

Set these from a **server** script. Keys the clients read must be set with `sync = true` (the third argument of
`SetBool` / `SetInt` / `SetFloat`).

| key | type | what it does |
|---|---|---|
| `climbing.off` | bool | the whole mod stands down; climbers let go. For a game mode with its own movement. |
| `climbing.nomantle` | bool | no free mantling; ladders and surfaces still pull players over their tops. |
| `climbing.block.<player>` | bool | that player can't climb or mantle now (knocked down, carried, trapped...). |
| `climbing.reach.<player>` | float, m | that player's mantle reach in place of 1.4 m, without the 1.95 m cap. For a taller player-controlled body with a human collision capsule. Unset or 0: the default. |
| `climbing.raymask` | int | collision layers all of Climbing's rays skip, on top of layer 4 (e.g. 160 = layers 128 + 32: a mod's own hit boxes and model parts). Read on every machine: set it with sync. |

Published by Climbing:

| key | type | what it is |
|---|---|---|
| `climbing.on.<player>` | bool, synced | true while that player is on a ladder or surface, or mantling |
| `climbing.present` | bool, synced | true while Climbing runs (re-set every second, also while `climbing.off` is set): a mode with its own mantle can stand down while it is there |

```lua
-- a game mode with its own movement
function server.init()
	SetBool("climbing.off", true, true)
end

-- or: use Climbing when it is there, your own mantle when it isn't (another mod's init may run after yours: poll)
function server.tick(dt)
	ownMantle = not GetBool("climbing.present")
end

-- a downed player can't climb
SetBool("climbing.block." .. p, true)
```

## Things to know

- Climbing takes collision layer **4** out of every player's collision mask (so ladder models don't snag the climber).
  A mod that sets players' `CollisionMask` should leave layer 4 out too, or the two keep overwriting each other.
- Rung spacing is 0.3 m from the ladder's foot. A model with other spacing gets the hands between its rungs.
- Climbing down a vine wall from its top (grabbing a surface from above) isn't supported; ladders work from the top.
