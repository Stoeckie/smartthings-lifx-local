"""LIFX (local) driver: commands against a fake bulb. A command the bulb did not do is tried again."""
import os
import lupa.lua53 as lua53

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src")

HARNESS = r'''
local function capmock(path)
  return setmetatable({}, {
    __index = function(t, k) local v = capmock(path .. "." .. k); rawset(t, k, v); return v end,
    __call = function(_, a) return { path = path, arg = a } end })
end
local caps = capmock("cap")
for _, c in ipairs({ "switch", "switchLevel", "colorControl", "colorTemperature", "refresh" }) do caps[c].ID = c end
caps.switch.commands.on.NAME = "on"
caps.switch.commands.off.NAME = "off"
caps.switchLevel.commands.setLevel.NAME = "setLevel"
caps.colorControl.commands.setColor.NAME = "setColor"
caps.colorControl.commands.setHue.NAME = "setHue"
caps.colorControl.commands.setSaturation.NAME = "setSaturation"
caps.colorTemperature.commands.setColorTemperature.NAME = "setColorTemperature"
caps.refresh.commands.refresh.NAME = "refresh"
package.loaded["st.capabilities"] = caps
package.loaded["st.driver"] = function(name, tmpl) DRIVER = tmpl; tmpl.run = function() end; return tmpl end
LOG = {}
local function keep(level) return function(m) LOG[#LOG + 1] = level .. " " .. tostring(m) end end
package.loaded["log"] = { info = keep("I"), warn = keep("W"), error = keep("E"), debug = function() end }
package.loaded["st.json"] = { encode = function(x) return tostring(x) end, decode = function() return {} end }
CLOCK = 1794900000.0          -- every sleep and every unanswered request moves this clock
package.loaded["cosock"] = { socket = { gettime = function() return CLOCK end,
  sleep = function(s) CLOCK = CLOCK + s end, udp = function() error("no network in tests") end } }
os.time = (function(orig) return function(t) if t then return orig(t) end return math.floor(CLOCK) end end)(os.time)
DEVICES = {}
DRIVER_OBJ = { environment_info = { hub_ipv4 = "192.168.2.8" }, get_devices = function() return DEVICES end }
function NEW()
  local d = { id = "lamp", label = "Lamp", device_network_id = "lifx-D073D5011A7B", preferences = {},
              fields = { ip = "192.168.2.53" }, events = {}, health = "online" }
  function d:get_field(k) local v = self.fields[k]; if v == nil then return end; return v end -- like the hub: no value at all
  function d:set_field(k, v) self.fields[k] = v end
  function d:emit_event(e) self.events[#self.events + 1] = e end
  function d:online() self.health = "online" end
  function d:offline() self.health = "offline" end
  function d:supports_capability() return true end
  d.thread = { call_with_delay = function() end, call_on_schedule = function() return 1 end, cancel_timer = function() end }
  DEVICES[#DEVICES + 1] = d
  return d
end
'''

BULB = r'''
local lifx = require "lifx"
T = lifx.T
-- deaf: the bulb answers nothing for this many requests; lost: this many commands never reach it;
-- noack: this many commands are done but their acknowledgement gets lost
BULB = { power = 65535, hue = 0, sat = 0, bri = 13107, kelvin = 2524, deaf = 0, lost = 0, noack = 0, commands = 0, reads = 0 }
lifx.discover = function() return {} end
lifx.request = function(ip, mac, t, payload, expect)
  if t == T.LightGet then BULB.reads = BULB.reads + 1 else BULB.commands = BULB.commands + 1 end
  if BULB.deaf > 0 then BULB.deaf = BULB.deaf - 1; CLOCK = CLOCK + 2.4; return nil, "timeout" end
  if t == T.LightGet then
    return { payload = string.pack("<I2I2I2I2i2I2c32", BULB.hue, BULB.sat, BULB.bri, BULB.kelvin, 0, BULB.power, "Lamp")
      .. string.rep("\0", 8) }
  end
  if BULB.lost > 0 then BULB.lost = BULB.lost - 1; CLOCK = CLOCK + 2.4; return nil, "timeout" end
  if t == T.LightSetColor then
    local _, h, s, b, k = string.unpack("<BI2I2I2I2", payload)
    BULB.hue, BULB.sat, BULB.bri, BULB.kelvin = h, s, b, k
  elseif t == T.LightSetPower then
    BULB.power = string.unpack("<I2", payload)
  end
  if BULB.noack > 0 then BULB.noack = BULB.noack - 1; CLOCK = CLOCK + 2.4; return nil, "timeout" end
  return { payload = "" }
end
DEV = NEW()
function LEVEL(l) T0 = CLOCK; DRIVER.capability_handlers.switchLevel.setLevel(DRIVER_OBJ, DEV, { args = { level = l } }); return CLOCK - T0 end
function OFF() DRIVER.capability_handlers.switch.off(DRIVER_OBJ, DEV, {}) end
function SHOWN(path)
  local v
  for _, e in ipairs(DEV.events) do if e.path == path then v = e.arg end end
  return v
end
function WARNINGS() local n = 0; for _, m in ipairs(LOG) do if m:sub(1, 8) == "W [lifx]" then n = n + 1 end end; return n end
'''


def setup():
    lua = lua53.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{SRC}/?.lua;" .. package.path')
    lua.execute(HARNESS)
    lua.execute(f'dofile("{SRC}/init.lua")')
    lua.execute(BULB)
    lua.execute('DRIVER._lifx.poll(DRIVER_OBJ, DEV)')      # the driver knows the bulb: on, 20 %
    assert lua.eval('SHOWN("cap.switchLevel.level")') == 20
    return lua, lua.globals()


def test_command_done_at_once():
    lua, g = setup()
    secs = g.LEVEL(100)
    assert g.SHOWN("cap.switchLevel.level") == 100 and lua.eval('BULB.bri') == 65535
    assert lua.eval('BULB.commands') == 1 and secs < 1 and g.WARNINGS() == 0


def test_command_that_never_reached_the_bulb_is_sent_again():
    # 17-11-2026: with 17 bulbs commanded at once a bulb sometimes misses the packets. The command was lost
    # then (the lamp stayed at its old level) and nothing was tried again.
    lua, g = setup()
    lua.execute('BULB.lost = 1')
    secs = g.LEVEL(100)
    assert lua.eval('BULB.bri') == 65535 and g.SHOWN("cap.switchLevel.level") == 100
    assert lua.eval('BULB.commands') == 2 and g.WARNINGS() == 1
    assert secs < 6, secs                               # shown within seconds, not at the next poll (30 s)


def test_bulb_that_is_away_for_some_seconds():
    lua, g = setup()
    lua.execute('BULB.deaf = 4')                        # command, read-back, command, read-back: no answer
    secs = g.LEVEL(100)
    assert lua.eval('BULB.bri') == 65535 and g.SHOWN("cap.switchLevel.level") == 100
    assert lua.eval('BULB.commands') == 3
    assert 10 < secs < 16, secs
    assert lua.eval('DEV.health') == "online"           # a few seconds without an answer is not offline


def test_bulb_that_stays_away_gives_up_after_four_tries():
    lua, g = setup()
    lua.execute('BULB.deaf = 1000')
    secs = g.LEVEL(100)
    assert lua.eval('BULB.commands') == 4 and lua.eval('BULB.bri') == 13107
    assert g.SHOWN("cap.switchLevel.level") == 20       # still what the bulb last reported itself
    assert secs < 35, secs
    lua.execute('BULB.deaf = 0')
    assert g.LEVEL(100) < 1                             # the next command works as usual
    assert g.SHOWN("cap.switchLevel.level") == 100


def test_lost_acknowledgement_is_not_a_reason_to_send_again():
    lua, g = setup()
    lua.execute('BULB.noack = 1')
    g.LEVEL(100)
    assert lua.eval('BULB.commands') == 1 and g.SHOWN("cap.switchLevel.level") == 100


def test_level_switches_a_bulb_that_is_off_on_also_when_packets_get_lost():
    lua, g = setup()
    g.OFF()
    assert lua.eval('BULB.power') == 0
    lua.execute('BULB.lost = 2; BULB.commands = 0')
    g.LEVEL(60)
    assert lua.eval('BULB.power') == 65535 and g.SHOWN("cap.switchLevel.level") == 60
    assert lua.eval('BULB.commands') == 4               # color twice lost and sent again, then power


LIMIT = r'''
CLOCK = 0
OPEN, MAXOPEN = 0, 0
local function wait(s) local untl = CLOCK + s; while CLOCK < untl do coroutine.yield() end end
package.loaded["cosock"] = { socket = {
  gettime = function() return CLOCK end,
  sleep = wait,
  udp = function()
    OPEN = OPEN + 1; if OPEN > MAXOPEN then MAXOPEN = OPEN end
    return { setsockname = function() end, sendto = function() return true end,
             settimeout = function(self, t) self.t = t end,
             receivefrom = function(self) wait(self.t); return nil end,   -- a bulb that never answers
             close = function() OPEN = OPEN - 1 end }
  end } }
package.loaded["lifx"] = nil
lifx = require "lifx"
function RUN(n)
  local cos, done = {}, 0
  for i = 1, n do cos[i] = coroutine.create(function() lifx.request("192.168.2." .. i, nil, 101, "", 107, 0.8, 1) end) end
  while done < n do
    done = 0
    for i = 1, n do
      if coroutine.status(cos[i]) ~= "dead" then assert(coroutine.resume(cos[i])) else done = done + 1 end
    end
    CLOCK = CLOCK + 0.05
  end
  return MAXOPEN, lifx.in_flight(), CLOCK
end
'''


def test_at_most_four_exchanges_at_once():
    lua = lua53.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{SRC}/?.lua;" .. package.path')
    lua.execute(LIMIT)
    most, left, took = lua.eval('RUN(17)')
    assert most == 4          # 17 bulbs commanded at once: never more than 4 sockets open
    assert left == 0          # every slot is given back
    assert took < 5           # 17 x 0.8 s in groups of 4: about 3.6 s


def test_a_stuck_count_never_blocks_a_lamp():
    lua = lua53.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{SRC}/?.lua;" .. package.path')
    lua.execute(LIMIT)
    lua.execute('for i = 1, 4 do lifx.acquire() end')    # four slots taken and never given back
    waited = lua.eval('(function() local w; local co = coroutine.create(function() w = lifx.acquire() end); '
                      'while coroutine.status(co) ~= "dead" do assert(coroutine.resume(co)); CLOCK = CLOCK + 0.05 end; return w end)()')
    assert 4.9 <= waited <= 5.1
