-- Called before nb_fluid is deleted, by modhousekeeper or the mod menu:
-- stops and removes the service, and whatever else nb_fluid installed.
-- Returns function(on_done), on_done(ok); see setup.uninstall.

local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
return dofile(dir .. "/setup.lua").uninstall
