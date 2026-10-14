-- platform.lua: what are we running on, and how can we install things?
--
-- Detects architecture, norns variant, distro package manager and the best
-- way to get root. Works under plain lua5.3 too, so it can be unit tested.

local M = {}

local PATH_EXPORT = 'PATH="$HOME/.local/bin:/usr/local/bin:$PATH"'

function M.shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- synchronous capture; norns' sidecar-backed helper when we have it
function M.capture(cmd)
  if util and util.os_capture then
    -- parentheses: only the string, not gsub's count
    return ((util.os_capture(cmd .. " 2>/dev/null", true) or "")
      :gsub("%s+$", ""))
  end
  local f = io.popen(cmd .. " 2>/dev/null")
  if not f then return "" end
  local out = f:read("a") or ""
  f:close()
  return (out:gsub("%s+$", ""))
end

function M.run(cmd)
  return os.execute(cmd .. " >/dev/null 2>&1") == true
end

-- is `name` an executable we can find (including ~/.local/bin, where pipx
-- puts things and matron's PATH often does not look)?
function M.have(name)
  return M.run(PATH_EXPORT .. "; command -v " .. M.shell_quote(name))
end

local function read_os_release()
  local info = {}
  local f = io.open("/etc/os-release", "r")
  if not f then return info end
  for line in f:lines() do
    local k, v = line:match('^([%w_]+)="?(.-)"?$')
    if k then info[k] = v end
  end
  f:close()
  return info
end

local function detect_pm(info)
  local ids = " " .. (info.ID or "") .. " " .. (info.ID_LIKE or "") .. " "
  if ids:find(" debian ") or ids:find(" ubuntu ") or ids:find(" raspbian ") then
    return "apt"
  elseif ids:find(" arch ") or ids:find(" manjaro ") then
    return "pacman"
  elseif ids:find(" fedora ") or ids:find(" rhel ") then
    return "dnf"
  end
  -- unknown distro: fall back to whatever is installed
  for _, pm in ipairs { "apt-get", "pacman", "dnf" } do
    if M.have(pm) then return pm == "apt-get" and "apt" or pm end
  end
end

local function detect_priv(desktop)
  if M.capture("id -u") == "0" then return "root" end
  if M.run("sudo -n true") then return "sudo" end
  -- a desktop session can show a graphical password prompt through polkit
  if desktop and M.have("pkexec")
      and (os.getenv("DISPLAY") or os.getenv("WAYLAND_DISPLAY")) then
    return "pkexec"
  end
end

local cached
-- overrides: fields to force (for tests)
function M.detect(overrides)
  if cached and not overrides then return cached end
  local info = read_os_release()
  local desktop = not norns
  if norns then desktop = norns.is_desktop == true end
  local p = {
    arch = M.capture("uname -m"),
    desktop = desktop,
    norns = norns and norns.is_norns or false,
    shield = norns and norns.is_shield or false,
    os_id = info.ID,
    os_name = info.PRETTY_NAME or info.NAME,
    pm = detect_pm(info),
    home = os.getenv("HOME") or "",
  }
  p.priv = detect_priv(desktop)
  for k, v in pairs(overrides or {}) do p[k] = v end
  if not overrides then cached = p end
  return p
end

-- On a device, restarting sclang and matron needs JACK's shared memory files.
-- logind can delete them (RemoveIPC) after the last ssh session of the user
-- closes; jackd keeps running, but nothing new can connect and a restart
-- ends with norns-main failed until the device is rebooted.
function M.jack_files_missing(p)
  if p.desktop then return false end
  if not (M.run("pgrep -x jackd") or M.run("pgrep -x jackdbus")) then
    return false
  end
  return not M.run("test -e /dev/shm/jack-shm-registry")
end

-- how a command that needs root is written for the log / for copy-paste
function M.manual_cmd(p, cmd)
  if p.priv == "root" then return cmd end
  return "sudo " .. cmd
end

-- the real command line, or nil when there is no way to get root
function M.wrap_priv(p, cmd)
  if p.priv == "root" then return cmd end
  local inner = "sh -c " .. M.shell_quote(cmd)
  if p.priv == "sudo" then return "sudo -n " .. inner end
  if p.priv == "pkexec" then return "pkexec " .. inner end
end

M.PATH_EXPORT = PATH_EXPORT .. "; "

return M
