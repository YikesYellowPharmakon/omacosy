-- Put Ghostty's real cursor on the hovered file so cursor shaders can follow it.
-- Yazi draws its own highlight and leaves the terminal cursor hidden.
-- This file is sync-only: ya.sync() is plugin-only and aborts startup if called here.

local spot = { x = 1, y = 1, ok = false, n = 0 }

local redraw_current = Current.redraw
function Current:redraw()
	local drawn = redraw_current(self)
	local placed = pcall(function()
		local folder = self._folder
		local row = folder.cursor - folder.offset
		if folder.hovered and row >= 0 and row < self._area.h then
			spot.x = self._area.x + 2
			spot.y = self._area.y + row + 1
			spot.ok = true
		else
			spot.ok = false
		end
	end)
	if not placed then
		spot.ok = false
	end
	return drawn
end

local function follow()
	spot.n = spot.n + 1
	local n = spot.n
	local layer = tostring(cx.layer)
	ya.async(function()
		ya.sleep(0.04)
		if spot.n ~= n or not spot.ok or layer ~= "mgr" then
			return
		end
		local tty = io.open("/dev/tty", "w")
		if not tty then
			return
		end
		tty:write(string.format("\27[%d;%dH\27[6 q\27[?25h", spot.y, spot.x))
		tty:flush()
		tty:close()
	end)
end

ps.sub("hover", follow)
ps.sub("cd", follow)
