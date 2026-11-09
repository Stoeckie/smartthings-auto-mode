"""Auto Mode driver: change / routine window / manual timer / reset / local time."""
import os, calendar
import lupa.lua53 as lua53

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")

HARNESS = r'''
local function capmock(path)
  return setmetatable({}, {
    __index = function(t, k)
      if k == "NAME" then return path:match("([^.]+)$") end
      local v = capmock(path .. "." .. k); rawset(t, k, v); return v end,
    __call = function(_, a) return { path = path, arg = a } end })
end
local caps = capmock("cap")
caps["silvervalley08660.autoMode"].ID = "autoMode"
caps["silvervalley08660.autoZones"].ID = "autoZones"
caps["silvervalley08660.autoSignal"].ID = "autoSignal"
caps.refresh.ID = "refresh"
package.loaded["st.capabilities"] = caps
package.loaded["st.driver"] = function(name, tmpl)
  DRIVER = tmpl
  tmpl.get_devices = function() return DEVICES end
  tmpl.try_create_device = function(_, info) CREATED[#CREATED + 1] = info end
  tmpl.run = function() end
  return tmpl
end
package.loaded["log"] = { info = function() end, warn = function() end, error = function() end, debug = function() end }
package.loaded["st.json"] = { encode = function(x) return tostring(x) end, decode = function() return {} end }
NOW = 1794132000
os.time = (function(orig) return function(t) if t then return orig(t) end return NOW end end)(os.time)
DEVICES, CREATED, TIMERS = {}, {}, {}
function NEW(info)
  local d = { id = info.id, label = info.label, device_network_id = info.dni, preferences = info.prefs or {},
              parent_assigned_child_key = info.key, fields = {}, events = {} }
  function d:get_field(k) local v = self.fields[k]; if v == nil then return end; return v end -- like the hub: no value at all
  function d:set_field(k, v) self.fields[k] = v end
  function d:emit_event(e) self.events[#self.events + 1] = e; self.last = self.last or {}; self.last[e.path] = e.arg end
  function d:online() end
  function d:supports_capability(c) return true end
  function d:get_parent_device() return HUB end
  d.thread = { call_with_delay = function(_, s, fn) TIMERS[#TIMERS + 1] = { at = NOW + s, fn = fn }; return #TIMERS end,
               cancel_timer = function(_, t) if TIMERS[t] then TIMERS[t].fn = nil end end }
  DEVICES[#DEVICES + 1] = d
  return d
end
function RUN_TIMERS()
  for _, t in ipairs(TIMERS) do if t.fn and t.at <= NOW then local f = t.fn; t.fn = nil; f() end end
end
'''

def setup():
    lua = lua53.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{SRC}/?.lua;" .. package.path')
    lua.execute(HARNESS)
    lua.execute(f'dofile("{SRC}/init.lua")')
    return lua

def cmd(lua, mode):
    lua.execute(f'DRIVER.capability_handlers.autoMode.setMode(nil, Z, {{ args = {{ mode = "{mode}" }} }})')

def last(lua, attr):
    return lua.eval(f'Z.last["cap.silvervalley08660.autoMode.{attr}"]')

def test_zone_flow():
    lua = setup()
    lua.execute('HUB = NEW({ id = "h", dni = "automode-hub", prefs = { zones = "Keuken licht, Verwarming slaapkamer", timeZone = "CET" } })')
    lua.execute('DRIVER.lifecycle_handlers.init(DRIVER, HUB)')
    created = lua.eval('CREATED')
    names = [created[i].label for i in range(1, len(created) + 1)]
    profiles = [created[i].profile for i in range(1, len(created) + 1)]
    assert names == ["Keuken licht", "Verwarming slaapkamer"]
    assert profiles == ["automode-zone", "automode-zone-heat"]
    lua.execute('Z = NEW({ id = "z", label = "Keuken licht", key = "zone:keuken licht", prefs = { manualMinutes = 120, busySeconds = 120 } })')
    lua.execute('DRIVER.lifecycle_handlers.init(DRIVER, Z)')
    assert last(lua, "mode") == "auto"
    # a routine acts: its own changes inside the window are ignored
    cmd(lua, "routine")
    lua.execute('NOW = NOW + 60')
    cmd(lua, "change")
    assert last(lua, "mode") == "auto"
    # after the window a change is manual; 2026-11-08 10:00:00 UTC + 60 + 130 s -> until 13:03 CET
    lua.execute('NOW = NOW + 130')
    cmd(lua, "change")
    assert last(lua, "mode") == "manual"
    assert last(lua, "until") == "13:03"
    # another manual change starts the time again
    lua.execute('NOW = NOW + 1800')
    cmd(lua, "change")
    assert last(lua, "until") == "13:33"
    lua.execute('NOW = NOW + 7199; RUN_TIMERS()')
    assert last(lua, "mode") == "manual"
    lua.execute('NOW = NOW + 2; RUN_TIMERS()')
    lua.execute('RUN_TIMERS()')
    assert last(lua, "mode") == "auto"
    # reset (mode change): automatic and the routine window is open
    cmd(lua, "manual")
    assert last(lua, "mode") == "manual"
    cmd(lua, "reset")
    assert last(lua, "mode") == "auto"
    cmd(lua, "change")
    assert last(lua, "mode") == "auto"

def test_local_time():
    lua = setup()
    clock = lua.eval('DRIVER._auto.clock')
    t = calendar.timegm((2026, 11, 8, 10, 0, 0))
    assert clock("CET", t) == "11:00"
    t = calendar.timegm((2026, 7, 1, 12, 0, 0))
    assert clock("CET", t) == "14:00" and clock("PT", t) == "05:00" and clock("GMT", t) == "13:00"
    t = calendar.timegm((2026, 3, 29, 0, 59, 0))   # just before EU summer time
    assert clock("CET", t) == "01:59"
    t = calendar.timegm((2026, 3, 29, 1, 0, 0))
    assert clock("CET", t) == "03:00"

def sig(lua, src):
    lua.execute(f'DRIVER.capability_handlers.autoSignal.signal(nil, Z, {{ args = {{ source = "{src}" }} }})')

def test_signals_right_after_routine():
    lua = setup()
    lua.execute('HUB = NEW({ id = "h", dni = "automode-hub", prefs = { zones = "", timeZone = "CET" } })')
    lua.execute('Z = NEW({ id = "z", label = "Keuken", key = "zone:keuken", prefs = { manualMinutes = 120, busySeconds = 120 } })')
    lua.execute('DRIVER.lifecycle_handlers.init(DRIVER, Z)')
    cmd(lua, "routine")
    lua.execute('NOW = NOW + 2'); sig(lua, "light:A")      # the routine switches lamp A
    lua.execute('NOW = NOW + 3'); sig(lua, "light:A")      # and its level follows
    assert last(lua, "mode") == "auto"
    lua.execute('NOW = NOW + 20'); sig(lua, "light:A")     # someone dims it 25 s after the routine
    assert last(lua, "mode") == "manual"
    cmd(lua, "auto"); cmd(lua, "routine")
    lua.execute('NOW = NOW + 30'); sig(lua, "light:B")     # a lamp the routine did not touch, 30 s later
    assert last(lua, "mode") == "manual"
    cmd(lua, "auto"); cmd(lua, "routine")
    for _ in range(6):                                      # a window keeps moving for a minute
        lua.execute('NOW = NOW + 10'); sig(lua, "shade:W")
    assert last(lua, "mode") == "auto"
    lua.execute('NOW = NOW + 60'); sig(lua, "shade:W")     # moved again later: by hand
    assert last(lua, "mode") == "manual"
    cmd(lua, "auto"); cmd(lua, "routine")
    lua.execute('NOW = NOW + 1'); sig(lua, "button:K")     # a button is always manual
    assert last(lua, "mode") == "manual"


def test_hold_until_switched_on():
    """Manual for (minutes) 0: Manual until switched on; no timer and no reset by a mode change."""
    lua = setup()
    lua.execute('HUB = NEW({ id = "h", dni = "automode-hub", prefs = { zones = "Zonweringen", timeZone = "CET" } })')
    lua.execute('DRIVER.lifecycle_handlers.init(DRIVER, HUB)')
    assert lua.eval('CREATED[1].profile') == "automode-zone-hold"
    lua.execute('Z = NEW({ id = "z", label = "Zonweringen", key = "zone:zonweringen", prefs = { manualMinutes = 0, busySeconds = 120 } })')
    lua.execute('DRIVER.lifecycle_handlers.init(DRIVER, Z)')
    cmd(lua, "change")
    assert last(lua, "mode") == "manual" and last(lua, "until") == "until switched on"
    lua.execute('for i = 1, 30 do NOW = NOW + 3600; RUN_TIMERS() end')
    assert last(lua, "mode") == "manual"
    cmd(lua, "reset")
    assert last(lua, "mode") == "manual"
    lua.execute('DRIVER.lifecycle_handlers.init(DRIVER, Z)')    # driver restart keeps it
    assert last(lua, "mode") == "manual" and last(lua, "until") == "until switched on"
    cmd(lua, "auto")
    assert last(lua, "mode") == "auto"


def test_renamed_zone_no_duplicate():
    """A zone renamed in the app (old key, new label) does not get a second device at the next start."""
    lua = setup()
    lua.execute('HUB = NEW({ id = "h", dni = "automode-hub", prefs = { zones = "", timeZone = "CET" } })')
    lua.execute('Z = NEW({ id = "z", label = "Gang licht", key = "zone:gang en wc licht", prefs = {} })')
    lua.execute('Z.parent_device_id = "h"')
    lua.execute('DRIVER.lifecycle_handlers.init(DRIVER, HUB)')
    assert lua.eval('#CREATED') == 0


def test_late_level_report_is_routine():
    """A Hue lamp reports its end level a minute after the routine: not manual. A level change without
    a routine, or after the window, is manual."""
    lua = setup()
    lua.execute('Z = NEW({ id = "z", label = "Gang", key = "zone:gang", prefs = { manualMinutes = 120, busySeconds = 120 } })')
    lua.execute('DRIVER.lifecycle_handlers.init(DRIVER, Z)')
    def sig(src):
        lua.execute(f'DRIVER.capability_handlers.autoSignal.signal(nil, Z, {{ args = {{ source = "{src}" }} }})')
    cmd(lua, "routine")
    lua.execute('NOW = NOW + 1')
    sig("light:Hal Trap Licht")
    sig("level:Hal Trap Licht")
    lua.execute('NOW = NOW + 60')
    sig("level:Hal Trap Licht")
    assert last(lua, "mode") == "auto"
    lua.execute('NOW = NOW + 120')
    sig("level:Hal Trap Licht")
    assert last(lua, "mode") == "manual"
