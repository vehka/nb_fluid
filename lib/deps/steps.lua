-- steps.lua: turn a declarative step spec into a shell command.
--
-- A step spec is one of
--   { pkg = "name" | { apt = "...", pacman = "...", dnf = "..." },
--     recommends = false }
--   { pipx = "package" }
--   { url = "...", dest = "path", sha256 = "...", extract = "dir" }
--   { ugens = "url", into = "folder", sha256 = "..." }
--   { cmd = "shell", priv = true, label = "..." }
--
-- build() returns { label, cmd, progress, priv, hint } or nil, reason.
--
-- A step with `remove = true` undoes what the same step installs: removes
-- the package, the pipx tool, the downloaded file or the UGen folder.
-- derive_removal() writes those steps for a recipe.

local req = ...
local platform = req("platform")
local ugens = req("ugens")
local q = platform.shell_quote

local M = {}

local function expand(p, s)
  return (s:gsub("^~/", p.home .. "/"):gsub("%$HOME", p.home))
end
M.expand = expand

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function pkg_names(spec, p)
  local pkgs = spec.pkg
  if type(pkgs) == "table" and pkgs[1] == nil then pkgs = pkgs[p.pm] end
  if type(pkgs) == "string" then pkgs = { pkgs } end
  return pkgs
end

local builders = {}

function builders.pkg(spec, p)
  if not p.pm then
    return nil, "no supported package manager found"
  end
  local pkgs = pkg_names(spec, p)
  if not pkgs then
    return nil, "no " .. p.pm .. " package listed"
  end
  local list = table.concat(pkgs, " ")
  local cmd, progress
  if p.pm == "apt" then
    -- status lines go to stdout, where the runner reads them from the log
    cmd = "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
      .. " && DEBIAN_FRONTEND=noninteractive apt-get install -y"
      .. (spec.recommends == false and " --no-install-recommends" or "")
      .. " -o APT::Status-Fd=1 " .. list
    progress = "apt"
  elseif p.pm == "pacman" then
    cmd = "pacman -S --needed --noconfirm " .. list
  elseif p.pm == "dnf" then
    cmd = "dnf install -y " .. list
  end
  local manual = ({
    apt = "apt install ", pacman = "pacman -S ", dnf = "dnf install ",
  })[p.pm] .. (spec.recommends == false and p.pm == "apt"
    and "--no-install-recommends " or "") .. list
  return { label = p.pm .. ": " .. list, cmd = cmd, priv = true,
           progress = progress, manual = manual }
end

function builders.pipx(spec, p)
  return { label = "pipx: " .. spec.pipx, cmd = "pipx install " .. spec.pipx }
end

-- "{arch}" in a URL becomes the machine name (armv7l, aarch64, x86_64);
-- sha256 may be one checksum or a table of them by arch. A table without
-- this arch means there is no download for it.
local function resolve(spec, p, url)
  local sum = spec.sha256
  if type(sum) == "table" then
    sum = sum[p.arch]
    if not sum then return nil, "no download for " .. tostring(p.arch) end
  end
  return (url:gsub("{arch}", p.arch or "")), sum
end

-- commands that download url to dest (resuming a partial file) and verify it
local function fetch(url, sum, dest)
  local part = dest .. ".part"
  local dir = dest:match("^(.*)/[^/]*$") or "."

  local dl
  if platform.have("wget") then
    dl = "wget -c -t 3 --timeout=20 --progress=dot:mega -O "
      .. q(part) .. " " .. q(url)
  elseif platform.have("curl") then
    dl = "curl -fL --retry 3 --connect-timeout 20 -C - -# -o "
      .. q(part) .. " " .. q(url)
  else
    return nil, "neither wget nor curl is installed"
  end

  local cmd = { "mkdir -p " .. q(dir), dl }
  if sum then
    cmd[#cmd + 1] = "echo " .. q(sum .. "  " .. part) .. " | sha256sum -c -"
  end
  cmd[#cmd + 1] = "mv " .. q(part) .. " " .. q(dest)
  return cmd
end

local function unpack_cmd(file, out)
  if file:match("%.zip$") then
    return "unzip -oq " .. q(file) .. " -d " .. out
  end
  return "tar -xf " .. q(file) .. " -C " .. out
end

function builders.url(spec, p, ctx)
  local url, sum = resolve(spec, p, spec.url)
  if not url then return nil, sum end
  local dest = spec.dest and expand(p, spec.dest)
    or (ctx.dir .. "/downloads/" .. basename(url))
  local cmd, err = fetch(url, sum, dest)
  if not cmd then return nil, err end
  if spec.extract then
    local out = expand(p, spec.extract)
    cmd[#cmd + 1] = "mkdir -p " .. q(out)
    cmd[#cmd + 1] = unpack_cmd(dest, q(out))
    if not spec.dest then cmd[#cmd + 1] = "rm -f " .. q(dest) end
  end
  return {
    label = spec.label or ("download " .. basename(url)),
    cmd = table.concat(cmd, " && "),
    progress = "percent",
  }
end

-- Prebuilt UGens: an archive (or a single .so/.scx/.sc) whose contents go to
-- Extensions/<into>. A file SuperCollider already finds somewhere else is
-- left out, since a second copy stops sclang compiling (classes) or makes
-- scsynth complain (plugins). Unpacked in /tmp first: on norns the download
-- directory is under dust, where sclang compiles every class file it sees.
function builders.ugens(spec, p, ctx)
  local into = spec.into
  if type(into) ~= "string" or not into:match("^[%w_][%w_.-]*$") then
    return nil, "ugens step needs `into`, a folder name"
  end
  local url, sum = resolve(spec, p, spec.ugens)
  if not url then return nil, sum end
  local file = ctx.dir .. "/downloads/" .. basename(url)
  local cmd, err = fetch(url, sum, file)
  if not cmd then return nil, err end

  local dest = ugens.user_dir(p) .. "/" .. into
  local function find_other(roots)
    local dirs = {}
    for _, root in ipairs(roots) do dirs[#dirs + 1] = q(root) end
    return "find " .. table.concat(dirs, " ") .. ' -name "$n" -type f'
      .. " -not -path " .. q(dest .. "/*") .. " -not -path '*/.git/*'"
      .. " 2>/dev/null | head -n 1"
  end
  local single = file:match("%.so$") or file:match("%.scx?$")
  local script = {
    table.concat(cmd, " && ") .. " || exit 1",
    "stage=$(mktemp -d) || exit 1",
    "trap 'rm -rf \"$stage\" \"$stage.list\"' EXIT",
    (single and ("cp " .. q(file) .. ' "$stage/"') or unpack_cmd(file, '"$stage"'))
      .. " || exit 1",
    'find "$stage" -type f \\( ' .. ugens.FIND_NAMES .. ' \\) > "$stage.list"',
    "while read -r f; do",
    '  n=${f##*/}',
    '  case "$n" in',
    "    *.sc) hit=$(" .. find_other(ugens.class_roots(p)) .. ") ;;",
    "    *) hit=$(" .. find_other(ugens.plugin_roots(p)) .. ") ;;",
    "  esac",
    '  if [ -n "$hit" ]; then',
    '    echo "skipped $n: already at $hit"',
    '    rm -f "$f"',
    "  fi",
    'done < "$stage.list"',
    "mkdir -p " .. q(dest) .. ' && cp -R "$stage"/. ' .. q(dest) .. "/ || exit 1",
    "rm -f " .. q(file),
    "echo installed in " .. q(dest),
  }
  return {
    label = spec.label or ("UGens: " .. basename(url)),
    cmd = table.concat(script, "\n"),
    progress = "percent",
  }
end

function builders.cmd(spec, p)
  return { label = spec.step_label or "run command",
           cmd = expand(p, spec.cmd), priv = spec.priv,
           progress = spec.progress }
end

-- the opposite of each builder, for `remove = true` steps
local removers = {}

function removers.pkg(spec, p)
  if not p.pm then
    return nil, "no supported package manager found"
  end
  local pkgs = pkg_names(spec, p)
  if not pkgs then
    return nil, "no " .. p.pm .. " package listed"
  end
  local list = table.concat(pkgs, " ")
  local cmd = ({
    apt = "DEBIAN_FRONTEND=noninteractive apt-get remove -y ",
    pacman = "pacman -R --noconfirm ",
    dnf = "dnf remove -y ",
  })[p.pm] .. list
  local manual = ({
    apt = "apt remove ", pacman = "pacman -R ", dnf = "dnf remove ",
  })[p.pm] .. list
  return { label = "remove " .. list, cmd = cmd, priv = true, manual = manual }
end

function removers.pipx(spec)
  return { label = "pipx: remove " .. spec.pipx,
           cmd = "pipx uninstall " .. spec.pipx }
end

function removers.ugens(spec, p)
  local into = spec.into
  if type(into) ~= "string" or not into:match("^[%w_][%w_.-]*$") then
    return nil, "ugens step needs `into`, a folder name"
  end
  local dest = ugens.user_dir(p) .. "/" .. into
  return { label = "remove UGens: " .. into, cmd = "rm -rf " .. q(dest) }
end

function removers.url(spec, p)
  if not spec.dest then
    return nil, "a download without `dest` has nothing to remove"
  end
  local dest = expand(p, spec.dest)
  return { label = "remove " .. basename(dest), cmd = "rm -f " .. q(dest) }
end

function M.build(spec, p, ctx)
  for _, kind in ipairs { "pkg", "pipx", "ugens", "url", "cmd" } do
    if spec[kind] then
      local build = builders[kind]
      if spec.remove and kind ~= "cmd" then build = removers[kind] end
      local step, err = build(spec, p, ctx)
      if not step then return nil, err end
      if step.priv then
        step.hint = platform.manual_cmd(p, step.manual or step.cmd)
        if not p.priv then
          return nil, "needs root; sudo asks for a password", step.hint
        end
        step.run = platform.wrap_priv(p, step.cmd)
      else
        step.run = step.cmd
      end
      return step
    end
  end
  return nil, "unknown step"
end

-- does a recipe's `when` table match this platform?
local function match(want, have)
  if type(want) == "table" then
    for _, v in ipairs(want) do if v == have then return true end end
    return false
  end
  return want == have
end

function M.matches(when, p)
  for k, v in pairs(when or {}) do
    if not match(v, p[k]) then return false end
  end
  return true
end

-- first recipe whose `when` matches
function M.recipe(spec, p)
  for _, recipe in ipairs(spec.install or {}) do
    if M.matches(recipe.when, p) then return recipe end
  end
end

-- removal steps for a recipe's steps, last step first. Commands and
-- extracted downloads can't be undone automatically; a dependency that
-- uses them lists its own `uninstall` steps.
function M.derive_removal(recipe)
  local out = {}
  for i = #(recipe and recipe.steps or {}), 1, -1 do
    local s = recipe.steps[i]
    if s.pkg then
      out[#out + 1] = { pkg = s.pkg, remove = true }
    elseif s.pipx then
      out[#out + 1] = { pipx = s.pipx, remove = true }
    elseif s.ugens then
      out[#out + 1] = { ugens = s.ugens, into = s.into, remove = true }
    elseif s.url and s.dest and not s.extract then
      out[#out + 1] = { url = s.url, dest = s.dest, remove = true }
    end
  end
  return out
end

-- first recipe whose `when` matches, compiled; nil, reason, hints otherwise
function M.plan(spec, p, ctx)
  for _, recipe in ipairs(spec.install or {}) do
    if M.matches(recipe.when, p) then
      local steps, hints = {}, {}
      for _, s in ipairs(recipe.steps) do
        local step, err, hint = M.build(s, p, ctx)
        if not step then return nil, err, hint end
        steps[#steps + 1] = step
      end
      return steps
    end
  end
  return nil, "no install recipe for " .. tostring(p.arch)
    .. "/" .. tostring(p.pm)
end

return M
