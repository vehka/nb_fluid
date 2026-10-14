-- ugens.lua: find UGen plugins and class files where SuperCollider looks.
--
-- sclang refuses to compile when the same class is defined twice, and
-- scsynth warns about duplicate plugins. This is easy to cause by installing
-- a UGen pack by hand and from a script. We look for the same file name in
-- more than one place under the directories sclang searches.

local req = ...
local platform = req("platform")
local q = platform.shell_quote

local M = {}

local function sclang_include_paths(home)
  local paths = {}
  local f = io.open(home .. "/.config/SuperCollider/sclang_conf.yaml", "r")
  if not f then return paths end
  local inside
  for line in f:lines() do
    if line:match("^%S") then inside = line:match("^includePaths:") ~= nil end
    local path = inside and line:match("^%s*%-%s*(.-)%s*$")
    if path then paths[#paths + 1] = path end
  end
  f:close()
  return paths
end

function M.user_dir(p)
  return p.home .. "/.local/share/SuperCollider/Extensions"
end

local function extension_dirs(p)
  return {
    M.user_dir(p),
    "/usr/local/share/SuperCollider/Extensions",
    "/usr/share/SuperCollider/Extensions",
  }
end

-- where scsynth loads plugins (*.so, *.scx) from
function M.plugin_roots(p)
  local roots = extension_dirs(p)
  roots[#roots + 1] = "/usr/local/lib/SuperCollider/plugins"
  roots[#roots + 1] = "/usr/lib/SuperCollider/plugins"
  return roots
end

-- where sclang compiles class files from; on norns the include paths cover
-- all of dust
function M.class_roots(p)
  local roots = extension_dirs(p)
  for _, path in ipairs(sclang_include_paths(p.home)) do
    roots[#roots + 1] = path
  end
  return roots
end

function M.is_plugin(name)
  return name:match("%.so$") ~= nil or name:match("%.scx$") ~= nil
end

-- the directories that matter for a file of this name
function M.roots_for(p, name)
  return M.is_plugin(name) and M.plugin_roots(p) or M.class_roots(p)
end

function M.roots(p)
  local roots, seen = {}, {}
  for _, list in ipairs { M.plugin_roots(p), M.class_roots(p) } do
    for _, root in ipairs(list) do
      if not seen[root] then
        seen[root] = true
        roots[#roots + 1] = root
      end
    end
  end
  return roots
end

local function under(path, roots)
  for _, root in ipairs(roots) do
    if path:sub(1, #root + 1) == root .. "/" then return true end
  end
  return false
end

-- find(1) tests for plugin and class files
M.FIND_NAMES = "-name '*.so' -o -name '*.scx' -o -name '[A-Z]*.sc'"

-- { ["MiPlaits.so"] = { "/a/MiPlaits.so", "/b/MiPlaits.so" }, ... }
-- Only names found in more than one place. `names` limits the search.
function M.duplicates(p, names)
  local dirs = {}
  for _, root in ipairs(M.roots(p)) do
    if platform.run("test -d " .. q(root)) then dirs[#dirs + 1] = q(root) end
  end
  if #dirs == 0 then return {} end

  local found, seen = {}, {}
  local out = platform.capture(
    "find " .. table.concat(dirs, " ")
    .. " \\( " .. M.FIND_NAMES .. " \\)"
    .. " -not -path '*/.git/*' -type f")
  for path in out:gmatch("[^\n]+") do
    local name = path:match("([^/]+)$")
    if not seen[path] and under(path, M.roots_for(p, name)) then
      seen[path] = true
      found[name] = found[name] or {}
      table.insert(found[name], path)
    end
  end

  local dups = {}
  for name, paths in pairs(found) do
    local wanted = true
    if names then
      wanted = false
      for _, n in ipairs(names) do if n == name then wanted = true end end
    end
    if wanted and #paths > 1 then dups[name] = paths end
  end
  return dups
end

-- is a named plugin/class file installed where SuperCollider finds it?
-- A name without an extension is a plugin: "MiPlaits" finds MiPlaits.so
-- (or .scx).
function M.installed(p, name)
  local names = { name }
  if not name:find(".", 1, true) then names = { name .. ".so", name .. ".scx" } end
  local roots, tests = {}, {}
  for _, root in ipairs(M.roots_for(p, names[1])) do roots[#roots + 1] = q(root) end
  for _, n in ipairs(names) do tests[#tests + 1] = "-name " .. q(n) end
  local out = platform.capture("find " .. table.concat(roots, " ")
    .. " \\( " .. table.concat(tests, " -o ") .. " \\)"
    .. " -type f 2>/dev/null | head -n 1")
  return out ~= ""
end

return M
