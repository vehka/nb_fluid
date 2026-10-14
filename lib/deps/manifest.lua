-- manifest.lua: what this library installed, and how to take it out again.
--
-- One file per Deps dir (manifest.lua), a Lua table:
--   { order = { "sox", ... },
--     deps = { sox = { label = "SoX", at = 1760000000, restart = false,
--                      steps = { { pkg = "sox", remove = true } } } } }
-- Only dependencies an install session put in place are listed, so
-- uninstalling never removes something that was there before. The removal
-- steps are stored as data, so uninstalling needs neither the script's
-- dependency specs nor the script itself.

local M = {}
M.__index = M

local function serialize(v, indent)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t ~= "table" then return "nil" end
  indent = indent or ""
  local inner = indent .. "  "
  local parts = {}
  local n = #v
  for i = 1, n do parts[#parts + 1] = inner .. serialize(v[i], inner) end
  local keys = {}
  for k in pairs(v) do
    if not (math.type(k) == "integer" and k >= 1 and k <= n) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k
      or ("[" .. serialize(k) .. "]")
    parts[#parts + 1] = inner .. key .. " = " .. serialize(v[k], inner)
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
end
M.serialize = serialize

function M.open(dir)
  local self = setmetatable({ path = dir .. "/manifest.lua", dir = dir }, M)
  self:load()
  return self
end

function M:load()
  self.data = { order = {}, deps = {} }
  local chunk = loadfile(self.path, "t", {})
  if not chunk then return end
  local ok, data = pcall(chunk)
  if ok and type(data) == "table" then
    self.data.order = type(data.order) == "table" and data.order or {}
    self.data.deps = type(data.deps) == "table" and data.deps or {}
  end
end

function M:save()
  if #self.data.order == 0 then
    os.remove(self.path)
    return
  end
  os.execute("mkdir -p '" .. self.dir:gsub("'", "'\\''") .. "'")
  local tmp = self.path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write("-- written by norns-deps: what was installed, and how to remove it\n")
  f:write("return " .. serialize(self.data) .. "\n")
  f:close()
  os.rename(tmp, self.path)
end

function M:get(id)
  return self.data.deps[id]
end

-- installed ids, oldest first
function M:ids()
  local out = {}
  for _, id in ipairs(self.data.order) do out[#out + 1] = id end
  return out
end

function M:record(id, entry)
  if not self.data.deps[id] then
    self.data.order[#self.data.order + 1] = id
  end
  self.data.deps[id] = entry
  self:save()
end

function M:forget(id)
  if not self.data.deps[id] then return end
  self.data.deps[id] = nil
  for i, v in ipairs(self.data.order) do
    if v == id then table.remove(self.data.order, i) break end
  end
  self:save()
end

return M
