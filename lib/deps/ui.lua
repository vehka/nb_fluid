-- ui.lua: draw a session on the 128x64 screen and handle its keys/encoders.

local M = {}

local function trim(s, w)
  if util and util.trim_string_to_width then
    return util.trim_string_to_width(s, w)
  end
  return s
end

local function text(x, y, s, level, right)
  screen.level(level)
  screen.move(x, y)
  if right then screen.text_right(s) else screen.text(s) end
end

local function header(session, title)
  text(0, 8, trim(string.upper(session.deps.name) .. "  " .. title, 127), 4)
end

local function footer(left, right)
  if left then text(0, 61, left, 4) end
  if right then text(127, 61, right, 15, true) end
end

local function bar(x, y, w, h, frac, spin)
  screen.level(4)
  screen.rect(x + 0.5, y + 0.5, w - 1, h - 1)
  screen.stroke()
  screen.level(15)
  if frac then
    screen.rect(x + 1, y + 1, math.max(0, (w - 2) * frac), h - 2)
  else
    -- no percentage available: bounce a block along the bar
    local block = 16
    local pos = (spin or 0) * 3 % (2 * (w - 2 - block))
    if pos > w - 2 - block then pos = 2 * (w - 2 - block) - pos end
    screen.rect(x + 1 + pos, y + 1, block, h - 2)
  end
  screen.fill()
end

-- All items are installed (or removed) together with one K3; E2 only moves
-- the highlight, to show each item's reason on the bottom line.
local function draw_review(s)
  local removing = s.mode == "uninstall"
  local n = #s.items
  header(s, (removing and "remove " or "install ") .. n
    .. (n == 1 and " item" or " items"))
  local first = math.max(1, math.min(s.sel - 1, n - 2))
  for row = 0, 2 do
    local item = s.items[first + row]
    if item then
      local y = 20 + row * 9
      local level = (n > 1 and item == s.items[s.sel]) and 15 or 8
      local mark = item.blocked and "!" or (removing and "-" or "+")
      text(0, y, mark .. " " .. trim(item.spec.label or item.spec.id, 90), level)
      if item.spec.size then text(127, y, item.spec.size, level, true) end
    end
  end
  local sel = s.items[s.sel]
  text(0, 51, trim(sel.blocked or (not removing and sel.spec.why) or "", 127), 4)
  local verb = removing and "K3 remove" or "K3 install"
  footer("K2 cancel", n > 1 and verb .. " all" or verb)
end

local function draw_running(s)
  header(s, string.format("%d/%d", s.idx, #s.queue))
  local e = s.current
  text(0, 21, trim(e.item.spec.label or e.item.spec.id, 127), 15)
  text(0, 31, trim(e.step.label, 127), 8)
  bar(0, 36, 128, 7, s.progress, s.spin)
  local lines = s:log_tail(1)
  text(0, 53, trim(s.message or lines[1] or "", 127), 4)
  footer(nil, "K2 cancel")
end

local function draw_failed(s)
  header(s, "failed")
  text(0, 18, trim(s.failed.step.label .. ": " .. s.error, 127), 15)
  local lines = s:log_tail(4, s.scroll)
  for i, line in ipairs(lines) do text(0, 27 + (i - 1) * 8, trim(line, 127), 6) end
  footer("K2 close", "K3 retry")
end

-- word wrap to `cols` characters (the 128 px screen fits about 21)
local function wrap(str, cols)
  local lines, line = {}, ""
  for word in str:gmatch("%S+") do
    while #word > cols do
      if line ~= "" then lines[#lines + 1] = line line = "" end
      lines[#lines + 1] = word:sub(1, cols)
      word = word:sub(cols + 1)
    end
    if line == "" then line = word
    elseif #line + 1 + #word <= cols then line = line .. " " .. word
    else lines[#lines + 1] = line line = word end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end
M.wrap = wrap

-- the reason and the command to run by hand for each blocked item, as
-- screen lines; E2 scrolls when they don't fit
local function blocked_lines(s)
  local lines = {}
  for _, item in ipairs(s.items) do
    if item.blocked then
      for _, l in ipairs(wrap(item.spec.id .. ": " .. item.blocked, 21)) do
        lines[#lines + 1] = { l, 15 }
      end
      if item.hint then
        for _, l in ipairs(wrap(item.hint, 21)) do
          lines[#lines + 1] = { l, 6 }
        end
      end
    end
  end
  return lines
end

local function draw_blocked(s)
  header(s, "blocked")
  local lines = blocked_lines(s)
  local first = math.max(0, math.min(s.scroll or 0, #lines - 5))
  for row = 1, 5 do
    local line = lines[first + row]
    if line then text(0, 17 + (row - 1) * 8, line[1], line[2]) end
  end
  footer(#lines > 5 and "E2 scroll" or nil, "K2 close")
end

-- what happened to an item, for the done screen
local function outcome(s, item)
  if item.ok then return s.mode == "uninstall" and "removed" or "installed", 15 end
  if item.blocked then return "skipped", 6 end
  return "failed", 6
end

-- One line per item, so the steps that ran too fast to read can be checked
-- afterwards; E2 scrolls when they don't fit.
local function draw_done(s)
  local removing = s.mode == "uninstall"
  if #s.items == 0 then
    -- nothing ran: installed earlier, sclang not restarted since
    header(s, "restart needed")
    screen.level(15)
    screen.move(64, 30)
    screen.text_center("installed. restart to")
    screen.move(64, 40)
    screen.text_center("load the new UGens")
    footer("K2 later", "K3 restart")
    return
  end
  header(s, s.needs_restart and "restart needed"
    or (removing and "removed" or "done"))
  local rows = s.needs_restart and 3 or 4
  local first = math.max(0, math.min(s.scroll or 0, #s.items - rows))
  for row = 1, rows do
    local item = s.items[first + row]
    if item then
      local y = 11 + row * 9
      local status, level = outcome(s, item)
      text(0, y, trim(item.spec.label or item.spec.id, 80), level)
      text(127, y, status, level, true)
    end
  end
  if s.needs_restart then
    text(0, 51, removing and "restart to unload UGens"
      or "restart to load UGens", 15)
    footer("K2 later", "K3 restart")
  else
    footer(#s.items > rows and "E2 scroll" or nil, "K3 ok")
  end
end

local function draw_reboot(s)
  header(s, "reboot needed")
  for i, line in ipairs(wrap("JACK's files are gone, "
      .. "usually after an ssh logout. Reboot the device instead.", 21)) do
    text(0, 17 + (i - 1) * 9, line, 15)
  end
  footer("K2 later", "K3 reboot")
end

local drawers = {
  reboot = draw_reboot,
  review = draw_review, running = draw_running, failed = draw_failed,
  blocked = draw_blocked, done = draw_done,
}

function M.draw(s)
  screen.clear()
  local f = drawers[s.state]
  if f then f(s) end
  screen.update()
end

-- returns true when the session is finished and the UI should close
function M.key(s, n, z)
  if z ~= 1 then return false end
  if s.state == "review" then
    if n == 2 then s:cancel() return true end
    if n == 3 then s:confirm() end
  elseif s.state == "running" then
    if n == 2 then s:cancel() return true end
  elseif s.state == "failed" then
    if n == 2 then return true end
    if n == 3 then s:retry() end
  elseif s.state == "blocked" then
    if n == 2 or n == 3 then return true end
  elseif s.state == "reboot" then
    if n == 3 then s.deps.reboot() return true end
    if n == 2 then return true end
  elseif s.state == "done" then
    if s.needs_restart then
      if n == 3 then
        if s.deps:jack_files_missing() then
          s.state = "reboot"
        else
          s.deps.restart()
          return true
        end
      end
      if n == 2 then return true end
    elseif n >= 2 then
      return true
    end
  end
  return false
end

function M.enc(s, n, d)
  if n ~= 2 then return end
  if s.state == "review" then
    s.sel = math.max(1, math.min(#s.items, s.sel + d))
  elseif s.state == "failed" then
    s.scroll = math.max(0, s.scroll - d)
  elseif s.state == "blocked" then
    s.scroll = math.max(0, (s.scroll or 0) + d)
  elseif s.state == "done" then
    local rows = s.needs_restart and 3 or 4
    s.scroll = math.max(0, math.min(#s.items - rows, (s.scroll or 0) + d))
  end
end

return M
