-- Clamber's options (Mod Manager). In multiplayer the host's setting counts for everyone.
-- savegame.mod.mantleheight (float, metres): the highest ledge a player pulls themselves onto; unset = 1.4 (the
-- default), from 0.6 (knee height) up to 1.8 (head height). climb_move.lua reads it (clMantleRise).
-- savegame.mod.anywall (bool): Spiderman mode, every static wall climbable (climb_world.lua clClimbable).

local HEIGHTS = {0.6, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8}
local NOTES = {"knee", "", "waist", "", "chest (default)", "", "head"}

function draw()
	local h = GetFloat("savegame.mod.mantleheight")
	local cur = 5                                             -- (unset: the default, 1.4)
	if h > 0 then
		cur = 1
		for i, v in ipairs(HEIGHTS) do
			if h >= v - 0.01 then cur = i end
		end
	end
	UiTranslate(UiCenter(), 200)
	UiAlign("center middle")
	UiFont("bold.ttf", 48)
	UiText("Clamber")
	UiTranslate(0, 100)
	UiFont("regular.ttf", 28)
	UiText("Mantle height: the highest ledge you pull yourself onto")
	UiTranslate(0, 70)
	for i, v in ipairs(HEIGHTS) do
		UiPush()
		UiTranslate((i - (#HEIGHTS + 1) / 2) * 150, 0)
		if i == cur then UiColor(0.75, 0.9, 1) else UiColor(0.55, 0.55, 0.55) end
		UiFont("bold.ttf", 32)
		if UiTextButton(string.format("%.1f m", v), 130, 50) then SetFloat("savegame.mod.mantleheight", v) end
		UiTranslate(0, 42)
		UiFont("regular.ttf", 20)
		UiText(NOTES[i])
		UiPop()
	end
	UiTranslate(0, 120)
	UiFont("regular.ttf", 22)
	UiColor(0.7, 0.7, 0.7)
	UiText("Measured from your feet.")
	-- Spiderman mode (savegame.mod.anywall): every wall climbable, not only ladders and what a map marks
	UiTranslate(0, 90)
	UiColor(1, 1, 1)
	UiFont("regular.ttf", 28)
	UiText("Spiderman mode: climb any wall")
	UiTranslate(0, 60)
	local on = GetBool("savegame.mod.anywall")
	for i, label in ipairs({"Off", "On"}) do
		UiPush()
		UiTranslate((i - 1.5) * 170, 0)
		if (i == 2) == on then UiColor(0.75, 0.9, 1) else UiColor(0.55, 0.55, 0.55) end
		UiFont("bold.ttf", 32)
		if UiTextButton(label, 150, 50) then SetBool("savegame.mod.anywall", i == 2) end
		UiPop()
	end
	UiTranslate(0, 55)
	UiFont("regular.ttf", 22)
	UiColor(0.7, 0.7, 0.7)
	UiText("Jump at a wall (or press interact at it) to grab it. Loose objects, vehicles and doors are never climbed.")
	UiTranslate(0, 50)
	UiText("In multiplayer the host's settings count for everyone.")
	UiTranslate(0, 80)
	UiColor(1, 1, 1)
	UiFont("bold.ttf", 32)
	if UiTextButton("Close", 200, 50) then Menu() end
end
