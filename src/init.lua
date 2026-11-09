-- Stoeckie Auto Mode: one "Automation" device per zone (Automatic or Manual).
--
-- Routines that automate a zone get two extra lines in the app:
--   condition  "<zone> is Automatic"         (so they pause while someone operates the zone by hand)
--   action     "<zone>: Routine is acting"   (so the changes they cause are not taken for manual ones)
-- A hidden rule per zone signals every change of one of the zone's devices (and button presses). A change
-- only counts as the routine's own when that device starts changing within seconds after "Routine is acting"
-- (see START/CONT below); otherwise the zone turns Manual for the set
-- number of minutes (each new manual change starts that time again) and then back to Automatic by itself.
-- A routine can also wake up on "<zone> becomes Automatic" to put things right again after a manual period.
-- "Reset" (sent by a hidden rule when the location mode changes) makes the zone Automatic and opens the
-- routine window, so the mode's own routines and scenes are not taken for manual changes.

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local emitq = require "emitq"  -- only changed values go to the hub (see emitq.lua)

local BUILD = "2026-11-09f"
local automode = capabilities["silvervalley08660.autoMode"]
local autosignal = capabilities["silvervalley08660.autoSignal"]
local autozones = capabilities["silvervalley08660.autoZones"]
local HUB_DNI = "automode-hub"

-- local time -------------------------------------------------------------------------------------------
local function days_in_month(y, m)
  local d = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if m == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then return 29 end
  return d[m]
end
-- weekday 0 = Sunday, from a UTC time table
local function utc(y, m, d, h) return os.time({ year = y, month = m, day = d, hour = h or 0 }) - (os.time(os.date("!*t", 0)) - 0) end
local function wday(y, m, d) return tonumber(os.date("!%w", utc(y, m, d, 12))) end
local function last_sunday(y, m)
  local d = days_in_month(y, m)
  return d - wday(y, m, d)
end
local function nth_sunday(y, m, n)
  local first = 1 + ((7 - wday(y, m, 1)) % 7)
  return first + 7 * (n - 1)
end
local ZONES = {
  CET = { std = 1, eu = true }, GMT = { std = 0, eu = true }, EET = { std = 2, eu = true },
  ET = { std = -5, us = true }, CT = { std = -6, us = true }, MT = { std = -7, us = true }, PT = { std = -8, us = true },
  UTC = { std = 0 },
}
local M = {}
--- offset in hours for a UTC time
function M.offset(tz, t)
  local z = ZONES[tz] or ZONES.CET
  local y = tonumber(os.date("!%Y", t))
  if z.eu then
    local s = utc(y, 3, last_sunday(y, 3), 1)
    local e = utc(y, 10, last_sunday(y, 10), 1)
    return z.std + ((t >= s and t < e) and 1 or 0)
  elseif z.us then
    local s = utc(y, 3, nth_sunday(y, 3, 2), 2 - z.std)        -- 2:00 standard time
    local e = utc(y, 11, nth_sunday(y, 11, 1), 2 - (z.std + 1)) -- 2:00 daylight time
    return z.std + ((t >= s and t < e) and 1 or 0)
  end
  return z.std
end
function M.clock(tz, t)
  return os.date("!%H:%M", t + M.offset(tz, t) * 3600)
end

-- zone devices -----------------------------------------------------------------------------------------
local busy = {}   -- device.id -> os.time() until which changes are the routine's own (zone wide "change")
local acted = {}  -- device.id -> os.time() of the last "Routine is acting"
local claims = {} -- device.id -> { [source] = until } changes of one device that belong to that routine

-- Per device signals ("light:<id>", "shade:<id>", "heat:<id>", "button:<id>"): a change only belongs to the
-- routine when the device starts changing within START seconds after "Routine is acting"; its follow-up
-- events (level after switch, a window that keeps moving) count as long as they come within CONT seconds
-- of each other. Everything else, also shortly after a routine, is manual. A button press is always manual.
local START = { light = 10, heat = 15, shade = 15 }
local CONT = { light = 8, heat = 45, shade = 45 }   -- a roof window reported "opening" and its position 30 s later
M.START, M.CONT = START, CONT
local timers = {} -- device.id -> timer

local function pref(dev, k, d)
  local v = tonumber(dev.preferences and dev.preferences[k])
  return v or d
end
local function tz_of(dev)
  local p = dev.get_parent_device and dev:get_parent_device()
  return (p and p.preferences and p.preferences.timeZone) or "CET"
end
local function emit(dev, ev) emitq.try(dev, ev) end
-- the on/off switch in the app: on = Automatic, off = Manual (the app shows a parameterised switch as a list)
local function emit_switch(dev, m)
  local ok, has = pcall(function() return dev:supports_capability(capabilities.switch) end)
  if ok and has then
    emit(dev, m == "auto" and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end
end
local function emit_mode(dev, m) emit(dev, automode.mode(m)); emit_switch(dev, m) end

-- what the app shows (the field can say "auto" while the cloud never got the event, e.g. right after creation)
local function shown(dev)
  local ok, v = pcall(function() return dev:get_latest_state("main", automode.ID, automode.mode.NAME) end)
  return ok and v or nil
end

local function set_auto(dev)
  if timers[dev.id] then pcall(function() dev.thread:cancel_timer(timers[dev.id]) end); timers[dev.id] = nil end
  dev:set_field("manual_until", nil, { persist = true })
  if shown(dev) ~= "auto" then
    emit_mode(dev, "auto")
    log.info("[auto] " .. tostring(dev.label) .. ": automatic")
  end
  dev:set_field("mode", "auto", { persist = true })
  emit_switch(dev, "auto")
  emit(dev, automode["until"]("-"))
end

-- "Manual for (minutes)" 0: the zone stays Manual until it is switched on (no timer). Stored as a far time.
local HOLD = 4102444800   -- 2100-01-01
local function until_text(dev, untl)
  if untl >= HOLD then return "until switched on" end
  return M.clock(tz_of(dev), untl)
end
M.HOLD = HOLD

local schedule_end
schedule_end = function(dev)
  if timers[dev.id] then pcall(function() dev.thread:cancel_timer(timers[dev.id]) end); timers[dev.id] = nil end
  local untl = tonumber((dev:get_field("manual_until")))
  if not untl then return end
  local left = untl - os.time()
  if left <= 0 then set_auto(dev); return end
  timers[dev.id] = dev.thread:call_with_delay(math.min(left, 3600), function()
    timers[dev.id] = nil
    schedule_end(dev)
  end)
end

local function set_manual(dev, why)
  local mins = math.floor(tonumber(pref(dev, "manualMinutes", 120)) or 120)
  local untl = mins <= 0 and HOLD or os.time() + mins * 60
  dev:set_field("manual_until", untl, { persist = true })
  if shown(dev) ~= "manual" then emit_mode(dev, "manual") end
  dev:set_field("mode", "manual", { persist = true })
  emit_switch(dev, "manual")
  emit(dev, automode["until"](until_text(dev, untl)))
  log.info(string.format("[auto] %s: manual %s (%s)", tostring(dev.label), until_text(dev, untl), why))
  schedule_end(dev)
end

local function routine_acts(dev, now)
  busy[dev.id] = now + pref(dev, "busySeconds", 120)
  acted[dev.id] = now
  claims[dev.id] = {}
end

local function handle_signal(_, dev, cmd)
  local src = tostring(cmd.args and cmd.args.source or "")
  local kind = src:match("^(%a+):") or "light"
  local now = os.time()
  if kind == "button" then set_manual(dev, src); return end
  local cl = claims[dev.id] or {}
  claims[dev.id] = cl
  local cap = (acted[dev.id] or 0) + pref(dev, "busySeconds", 120)
  if kind == "level" then
    -- a dimmer or a Hue lamp often reports its end level later (seen: 48 % right away, 50 % a minute later).
    -- A level change of a lamp the routine switched or dimmed is the routine's while its window is open.
    local name = src:sub(7)
    if acted[dev.id] and now <= cap and (cl["light:" .. name] or cl[src] or now - acted[dev.id] <= START.light) then
      cl[src] = cap
      return
    end
    set_manual(dev, src)
    return
  end
  local untl = cl[src]
  if untl and now <= untl and now <= cap then
    cl[src] = math.min(now + (CONT[kind] or 8), cap) -- still the routine's own movement
    return
  end
  if not untl and acted[dev.id] and now - acted[dev.id] <= (START[kind] or 10) then
    cl[src] = math.min(now + (CONT[kind] or 8), cap)
    return
  end
  set_manual(dev, src)
end

local function handle_set_mode(_, dev, cmd)
  local m = cmd.args and cmd.args.mode
  local now = os.time()
  if m == "routine" then
    routine_acts(dev, now)
  elseif m == "reset" then
    routine_acts(dev, now)
    -- a zone that stays Manual until switched on is not reset by a mode change either
    if (tonumber((dev:get_field("manual_until"))) or 0) < HOLD then set_auto(dev) end
  elseif m == "change" then
    if (busy[dev.id] or 0) >= now then return end -- the routine's own change
    set_manual(dev, "change seen")
  elseif m == "manual" then
    set_manual(dev, "set by hand")
  elseif m == "auto" then
    set_auto(dev)
  else
    log.warn("[auto] unknown mode " .. tostring(m))
  end
end

-- hub device -------------------------------------------------------------------------------------------
local function extra_of(hub)
  local v = hub:get_field("extra_zones")
  local out = {}
  if type(v) == "table" then for _, n in ipairs(v) do out[#out + 1] = tostring(n) end
  elseif type(v) == "string" then for n in v:gmatch("[^\n]+") do out[#out + 1] = n end end
  return out
end

local function zone_list(hub, driver)
  local out, seen = {}, {}
  local function add(n)
    n = tostring(n or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if n ~= "" and #n <= 40 and not seen[n:lower()] then seen[n:lower()] = true; out[#out + 1] = n end
  end
  for n in tostring((hub.preferences or {}).zones or ""):gmatch("[^,]+") do add(n) end
  for _, n in ipairs(extra_of(hub)) do add(n) end
  -- zones that already have a device always count (also when a setting or field was lost)
  if driver then
    for _, d in ipairs(driver:get_devices()) do
      local k = d.parent_assigned_child_key
      if k and k:sub(1, 5) == "zone:" and d.parent_device_id == hub.id then add(d.vendor_provided_label or d.label) end
    end
  end
  return out
end
M.zone_list = zone_list

local function is_heat(name)
  local l = name:lower()
  return l:find("verwarm") ~= nil or l:find("heat") ~= nil or l:find("thermostat") ~= nil
end
M.is_heat = is_heat

-- sun screens are only moved by hand or by a rain routine: their zone stays Manual until switched on
local function is_hold(name)
  local l = name:lower()
  return l:find("zonwering") ~= nil or l:find("screen") ~= nil or l:find("awning") ~= nil
end
M.is_hold = is_hold

local function sync_zones(driver, hub)
  local have, labels = {}, {}
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_assigned_child_key then
      have[d.parent_assigned_child_key] = true
      -- a zone that was renamed keeps its old key: its new name must not create a second device
      labels[tostring(d.label or ""):lower()] = true
      labels[tostring(d.vendor_provided_label or ""):lower()] = true
    end
  end
  local names = zone_list(hub, driver)
  for _, n in ipairs(names) do
    -- the hub refuses a child key with non-ASCII characters (e.g. "ï"): write those bytes as hex
    local key = "zone:" .. n:lower():gsub("[\128-\255]", function(c) return string.format("%02x", c:byte()) end)
    if not have[key] and not labels[n:lower()] then
      log.info("[auto] creating zone device " .. n)
      have[key] = true
      driver:try_create_device({
        type = "EDGE_CHILD", parent_device_id = hub.id, parent_assigned_child_key = key,
        label = n, profile = is_heat(n) and "automode-zone-heat" or (is_hold(n) and "automode-zone-hold" or "automode-zone"),
        manufacturer = "Stoeckie", model = "automode-zone", vendor_provided_label = n,
      })
    end
  end
  emit(hub, autozones.zones(#names > 0 and table.concat(names, ", ") or "-"))
end

local function handle_add_zone(driver, hub, cmd)
  local n = tostring(cmd.args and cmd.args.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if n == "" then return end
  local extra = extra_of(hub)
  local known = false
  for _, e in ipairs(extra) do if e:lower() == n:lower() then known = true end end
  if not known then
    extra[#extra + 1] = n
    hub:set_field("extra_zones", table.concat(extra, "\n"), { persist = true })
  end
  log.info("[auto] zone " .. n .. (known and " (known)" or " added") .. ", " .. #extra .. " extra zone(s)")
  sync_zones(driver, hub)
end

-- lifecycle --------------------------------------------------------------------------------------------
local function device_init_inner(driver, dev)
  if dev.device_network_id == HUB_DNI then
    dev:online()
    sync_zones(driver, dev)
    return
  end
  dev:online()
  local untl = tonumber((dev:get_field("manual_until")))
  if untl and untl > os.time() then
    dev:set_field("mode", "manual", { persist = true })
    emit_mode(dev, "manual")
    emit(dev, automode["until"](until_text(dev, untl)))
    schedule_end(dev)
  else
    -- always send both values once: a zone that was just created may have missed its first events
    dev:set_field("manual_until", nil, { persist = true })
    dev:set_field("mode", "auto", { persist = true })
    emit_mode(dev, "auto")
    emit(dev, automode["until"]("-"))
  end
  -- and once more a little later, for a zone that is still being created in the cloud
  pcall(function()
    dev.thread:call_with_delay(10, function()
      if shown(dev) == nil then
        local m = dev:get_field("mode") or "auto"
        emit_mode(dev, m)
        local u = tonumber((dev:get_field("manual_until")))
        emit(dev, automode["until"](u and until_text(dev, u) or "-"))
      end
    end)
  end)
end

local function device_init(driver, dev)
  local ok, err = pcall(device_init_inner, driver, dev)
  if not ok then
    log.error("[auto] init " .. tostring(dev.label) .. ": " .. tostring(err))
    emit_mode(dev, "auto")
    emit(dev, automode["until"]("-"))
  end
end

local function info_changed(driver, dev)
  if dev.device_network_id == HUB_DNI then
    sync_zones(driver, dev)
    -- the time zone may have changed: show "until" again on the zones
    for _, d in ipairs(driver:get_devices()) do
      local untl = tonumber((d:get_field("manual_until")))
      if d.parent_assigned_child_key and untl then emit(d, automode["until"](until_text(d, untl))) end
    end
  end
end

local function discovery(driver, _, should_continue)
  log.info("[auto] discovery")
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == HUB_DNI then log.info("[auto] Automation zones already exists"); return end
  end
  log.info("[auto] creating Automation zones")
  driver:try_create_device({
    type = "LAN", device_network_id = HUB_DNI, label = "Automation zones", profile = "automode-hub",
    manufacturer = "Stoeckie", model = "automode", vendor_provided_label = "Automation zones",
  })
end

-- a removed zone: its timer and bookkeeping go too
local function device_removed(_, dev)
  if timers[dev.id] then pcall(function() dev.thread:cancel_timer(timers[dev.id]) end) end
  timers[dev.id], busy[dev.id], acted[dev.id], claims[dev.id] = nil, nil, nil, nil
  emitq.forget(dev)
end

local driver = Driver("stoeckie-auto-mode", {
  discovery = discovery,
  lifecycle_handlers = { init = device_init, added = device_init, infoChanged = info_changed, removed = device_removed },
  capability_handlers = {
    [automode.ID] = { [automode.commands.setMode.NAME] = handle_set_mode },
    [autosignal.ID] = { [autosignal.commands.signal.NAME] = handle_signal },
    [autozones.ID] = { [autozones.commands.addZone.NAME] = handle_add_zone },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = function(_, dev) set_auto(dev) end,
      -- off again while Manual restarts the manual period (on purpose: "keep it manual for longer")
      [capabilities.switch.commands.off.NAME] = function(_, dev) set_manual(dev, "switched off in the app") end,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = function(drv, dev)
        if dev.device_network_id == HUB_DNI then sync_zones(drv, dev) end
      end,
    },
  },
})
driver._auto = M

log.info("[auto] Stoeckie Auto Mode driver starting, build " .. BUILD)
driver:run()
