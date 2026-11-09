-- SmartThings Edge driver: LIFX (local).
-- The hub talks to the bulbs over the LIFX LAN protocol (UDP 56700): no cloud, no bridge.
--   discovery  GetService broadcast + sweep of the hub's /24, bulbs keyed by MAC (IP may change)
--   state      read from the bulb (LightGet) every poll and after every command: SmartThings only
--              shows what the bulb itself reports, never an assumed state
--   commands   sent with acknowledgement and retried (3 x 0.8 s), then confirmed with LightGet
--   offline    only after the bulb has not answered for CONN_GRACE seconds (no false alarms)
local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local cosock = require "cosock"
local lifx = require "lifx"
local emitq = require "emitq"  -- only changed values go to the hub (see emitq.lua)

local BUILD = "2026-11-09b"
local CONN_GRACE = 300
local function conn_grace(dev)
  -- setting "Offline after (minutes)": a router or network update at night takes a few minutes
  local m = tonumber(dev.preferences and dev.preferences.offlineAfter)
  if m and m >= 1 then return math.floor(m * 60) end
  return CONN_GRACE
end
local RESCAN_MIN = 60 -- at most one network scan per minute when bulbs are missing

local switch, level = capabilities.switch, capabilities.switchLevel
local color, ctemp = capabilities.colorControl, capabilities.colorTemperature

-- Connection status as a capability, so routines can notify when a bulb loses its connection.
local conn_cap = capabilities["silvervalley08660.connectionStatus"]
local drop_cap = capabilities["silvervalley08660.connectionLog"]
local function emit_conn(dev, v)
  if dev:get_field("conn_status") == v then return end
  local ok = pcall(function() dev:emit_event(conn_cap.status(v)) end)
  if ok then dev:set_field("conn_status", v) end
end
local function fmt_secs(s)
  if s < 120 then return string.format("%d s", s) end
  if s < 7200 then return string.format("%d min", s // 60) end
  return string.format("%.1f h", s / 3600)
end
local function report_drop(dev)
  local d = dev:get_field("conn_drop")
  if type(d) ~= "table" or not d.at then return end
  dev:set_field("conn_drop", nil, { persist = true })
  local txt = string.format("%s UTC, %s: %s", os.date("!%Y-%m-%d %H:%M:%S", d.at), fmt_secs(math.max(0, os.time() - d.at)), tostring(d.reason))
  log.info("[lifx] " .. tostring(dev.label) .. " back after drop at " .. txt)
  pcall(function() dev:emit_event(drop_cap.lastDrop(txt:sub(1, 200))) end)
end

-- products without color (LIFX product ids); everything else gets the color profile
local WHITE = { [10] = true, [11] = true, [18] = true, [50] = true, [51] = true, [60] = true, [61] = true,
                [66] = true, [81] = true, [82] = true, [87] = true, [88] = true, [96] = true }
local NAMES = { [1] = "LIFX Original 1000", [3] = "LIFX Color 650", [22] = "LIFX Color 1000",
                [27] = "LIFX A19", [43] = "LIFX A19", [49] = "LIFX Mini Color", [91] = "LIFX Color", [92] = "LIFX Color" }

local function pref(dev, k, default)
  local p = dev.preferences or {}
  local v = p[k]
  if v == nil then return default end
  return v
end

local function hub_prefix(driver)
  local ip = driver.environment_info and driver.environment_info.hub_ipv4
  if not ip then
    local ok, addr = pcall(function()
      local s = cosock.socket.udp()
      s:setpeername("8.8.8.8", 53)
      local a = s:getsockname()
      s:close()
      return a
    end)
    if ok then ip = addr end
  end
  return type(ip) == "string" and ip:match("^(%d+%.%d+%.%d+%.)") or nil
end

local function mac_of(dev)
  return (dev.device_network_id or ""):match("^lifx%-(%x+)$")
end

local function address(dev)
  local fixed = pref(dev, "ipAddress", "auto")
  if type(fixed) == "string" and fixed:match("^%d+%.%d+%.%d+%.%d+$") then return fixed end
  return dev:get_field("ip")
end

-- Network scan, shared by all bulbs and rate limited. Updates the IP of every known bulb.
local last_scan = 0
local function rescan(driver, force)
  if not force and os.time() - last_scan < RESCAN_MIN then return {} end
  last_scan = os.time()
  local prefix = hub_prefix(driver)
  local found = lifx.discover(prefix, 3)
  for mac, ip in pairs(lifx.discover(prefix, 3)) do found[mac] = ip end -- second round: replies get lost
  for _, d in ipairs(driver:get_devices()) do
    local ip = found[mac_of(d) or ""]
    if ip and d:get_field("ip") ~= ip then
      log.info(string.format("[lifx] %s: address %s -> %s", d.label, tostring(d:get_field("ip")), ip))
      d:set_field("ip", ip, { persist = true })
    end
  end
  return found
end

-- state ----------------------------------------------------------------------------------

local function pct(v) return math.floor(v * 100 / 65535 + 0.5) end
local function raw(p) return math.floor(math.max(0, math.min(100, p)) * 65535 / 100 + 0.5) end

-- force: everything goes out again with state_change. Refresh does NOT use it: a forced
-- switch event runs "light turned on/off" routines on every pull-to-refresh.
local function emit_state(dev, st, force)
  local on = st.power > 0
  local lvl = math.max(1, pct(st.bri))
  local function try(ev) emitq.try(dev, ev, nil, force) end
  try(on and switch.switch.on() or switch.switch.off())
  try(level.level(lvl))
  if dev:supports_capability(color) then
    try(color.hue(pct(st.hue)))
    try(color.saturation(pct(st.sat)))
  end
  try(ctemp.colorTemperature({ value = math.max(1, st.kelvin), unit = "K" }))
end

local function mark_ok(dev)
  dev:set_field("last_ok", os.time())
  dev:set_field("conn_down_since", nil)
  if dev:get_field("is_offline") ~= false then dev:online(); dev:set_field("is_offline", false) end
  report_drop(dev)
  emit_conn(dev, "online")
end

local function mark_fail(driver, dev, reason)
  local since = dev:get_field("conn_down_since")
  if not since then
    since = os.time()
    dev:set_field("conn_down_since", since)
    if not dev:get_field("conn_drop") then
      dev:set_field("conn_drop", { at = since, reason = tostring(reason):sub(1, 120) }, { persist = true })
    end
  end
  if address(dev) == nil or os.time() - since >= 10 then rescan(driver) end
  if os.time() - since >= conn_grace(dev) and dev:get_field("is_offline") ~= true then
    log.warn(string.format("[lifx] %s: no answer for %d s (%s), offline", dev.label, os.time() - since, tostring(reason)))
    dev:offline(); dev:set_field("is_offline", true)
    emit_conn(dev, "offline")
  end
end

-- Read the real state from the bulb. Returns the state or nil.
local function read(driver, dev, force)
  local ip, mac = address(dev), mac_of(dev)
  if not ip then mark_fail(driver, dev, "no address"); return nil end
  local m, err = lifx.request(ip, mac, lifx.T.LightGet, "", lifx.T.LightState)
  local st = m and lifx.light_state(m.payload)
  if not st then mark_fail(driver, dev, err or "bad reply"); return nil end
  dev:set_field("state", st)
  mark_ok(dev)
  emit_state(dev, st, force)
  return st
end

-- Send a command with acknowledgement (retried), then read back what the bulb really did.
-- A bulb acknowledges before it has applied the change, so the read-back waits a moment and is
-- repeated once when the state does not match yet (expect = function(state) -> true when applied).
local function send(driver, dev, msg_type, payload, expect)
  local ip, mac = address(dev), mac_of(dev)
  if not ip then rescan(driver, true); ip = address(dev) end
  if not ip then mark_fail(driver, dev, "no address"); return false end
  local ack = lifx.request(ip, mac, msg_type, payload, lifx.T.Acknowledgement)
  if not ack then
    log.warn(string.format("[lifx] %s: command %d not acknowledged by %s", dev.label, msg_type, ip))
  end
  local dur = math.min(pref(dev, "transitionMs", 0), 3000) / 1000
  cosock.socket.sleep(0.3 + dur)
  local st = read(driver, dev)
  if st and expect and not expect(st) then
    cosock.socket.sleep(0.7)
    st = read(driver, dev)
    if st and not expect(st) then
      log.warn(string.format("[lifx] %s: command %d acknowledged but not applied (yet)", dev.label, msg_type))
    end
  end
  return ack ~= nil and st ~= nil
end

local function current(driver, dev)
  return dev:get_field("state") or read(driver, dev) or { hue = 0, sat = 0, bri = 65535, kelvin = 3500, power = 0 }
end

local function near(a, b) return math.abs(a - b) <= 700 or math.abs(a - b) >= 65535 - 700 end
-- the app sends the shown value again when a slider or list is opened and closed without a change: a color or
-- level the bulb already has (and it is on, when the command would switch it on) is not sent
local function same_as_now(dev, st, power_on)
  local cur = dev:get_field("state")
  if not cur then return false end
  if power_on and cur.power == 0 then return false end
  return near(cur.bri, st.bri) and near(cur.hue, st.hue) and math.abs(cur.sat - st.sat) <= 700 and cur.kelvin == st.kelvin
end
local function set_color(driver, dev, st, power_on)
  if same_as_now(dev, st, power_on) then
    log.info("[lifx] " .. dev.label .. ": already in that state, nothing sent")
    return true
  end
  local dur = pref(dev, "transitionMs", 0)
  local ok = send(driver, dev, lifx.T.LightSetColor, lifx.set_color(st, dur), function(r)
    return near(r.bri, st.bri) and (st.sat == 0 or near(r.hue, st.hue)) and math.abs(r.sat - st.sat) <= 700
  end)
  if power_on and (dev:get_field("state") or {}).power == 0 then
    ok = send(driver, dev, lifx.T.LightSetPower, lifx.set_power(true, dur), function(r) return r.power > 0 end) and ok
  end
  return ok
end

-- command handlers -------------------------------------------------------------------------

local function handle_on(driver, dev)
  send(driver, dev, lifx.T.LightSetPower, lifx.set_power(true, pref(dev, "transitionMs", 0)), function(r) return r.power > 0 end)
end

local function handle_off(driver, dev)
  send(driver, dev, lifx.T.LightSetPower, lifx.set_power(false, pref(dev, "transitionMs", 0)), function(r) return r.power == 0 end)
end

local function handle_level(driver, dev, cmd)
  local l = tonumber(cmd.args.level) or 100
  if l <= 0 then return handle_off(driver, dev) end
  local st = current(driver, dev)
  set_color(driver, dev, { hue = st.hue, sat = st.sat, bri = raw(l), kelvin = st.kelvin }, true)
end

local function handle_color(driver, dev, cmd)
  local c = cmd.args.color or {}
  local st = current(driver, dev)
  local new = { hue = st.hue, sat = st.sat, bri = st.bri, kelvin = st.kelvin }
  if c.hue ~= nil then new.hue = raw(tonumber(c.hue) or 0) end
  if c.saturation ~= nil then new.sat = raw(tonumber(c.saturation) or 0) end
  if c.level ~= nil and tonumber(c.level) then new.bri = raw(tonumber(c.level)) end
  set_color(driver, dev, new, c.switch ~= "off")
end

local function handle_hue(driver, dev, cmd)
  local st = current(driver, dev)
  set_color(driver, dev, { hue = raw(tonumber(cmd.args.hue) or 0), sat = st.sat, bri = st.bri, kelvin = st.kelvin }, false)
end

local function handle_sat(driver, dev, cmd)
  local st = current(driver, dev)
  set_color(driver, dev, { hue = st.hue, sat = raw(tonumber(cmd.args.saturation) or 0), bri = st.bri, kelvin = st.kelvin }, false)
end

local function handle_ctemp(driver, dev, cmd)
  local k = math.max(1500, math.min(9000, math.floor(tonumber(cmd.args.temperature) or 3500)))
  local st = current(driver, dev)
  set_color(driver, dev, { hue = st.hue, sat = 0, bri = st.bri, kelvin = k }, false)
end

local function handle_refresh(driver, dev)
  -- no force: only real changes are emitted, so routines do not fire on a refresh
  if not read(driver, dev) then rescan(driver, true); read(driver, dev) end
end

-- lifecycle ----------------------------------------------------------------------------------

local function schedule(driver, dev)
  local t = dev:get_field("poll_timer")
  if t then pcall(function() dev.thread:cancel_timer(t) end) end
  local every = math.max(10, pref(dev, "pollSeconds", 30))
  dev.thread:call_with_delay(math.random(1, math.min(every, 15)), function() read(driver, dev) end)
  dev:set_field("poll_timer", dev.thread:call_on_schedule(every, function() read(driver, dev) end, "lifx poll"))
end

local discovered = {}

local function device_init(driver, dev)
  dev:set_field("is_offline", nil)
  schedule(driver, dev)
end

local function device_added(driver, dev)
  local info = discovered[dev.device_network_id]
  if info and info.ip then dev:set_field("ip", info.ip, { persist = true }) end
  pcall(function() dev:emit_event(ctemp.colorTemperatureRange({ value = { minimum = 1500, maximum = 9000 }, unit = "K" })) end)
  device_init(driver, dev)
end

local function info_changed(driver, dev, _, args)
  local old = args and args.old_st_store and args.old_st_store.preferences or {}
  local p = dev.preferences or {}
  if p.pollSeconds ~= old.pollSeconds or p.ipAddress ~= old.ipAddress then
    schedule(driver, dev)
  end
end

local function device_removed(_, dev)
  emitq.forget(dev)
  local t = dev:get_field("poll_timer")
  if t then pcall(function() dev.thread:cancel_timer(t) end) end
end

local function discovery(driver, _, should_continue)
  local existing = {}
  for _, d in ipairs(driver:get_devices()) do existing[d.device_network_id] = d end
  local found = rescan(driver, true)
  local n = 0
  for mac, ip in pairs(found) do
    n = n + 1
    local dni = "lifx-" .. mac
    if not existing[dni] then
      local m = lifx.request(ip, mac, lifx.T.LightGet, "", lifx.T.LightState, 1.5, 4)
      local st = m and lifx.light_state(m.payload)
      local v = lifx.request(ip, mac, lifx.T.GetVersion, "", lifx.T.StateVersion)
      local ver = v and lifx.version(v.payload) or {}
      local name = (st and st.label ~= "" and st.label) or ("LIFX " .. mac:sub(-6))
      discovered[dni] = { ip = ip }
      log.info(string.format("[lifx] found %s (%s, product %s) at %s", name, mac, tostring(ver.product), ip))
      driver:try_create_device({
        type = "LAN",
        device_network_id = dni,
        label = name,
        profile = WHITE[ver.product or -1] and "stoeckie-lifx-white" or "stoeckie-lifx-color",
        manufacturer = "LIFX",
        model = NAMES[ver.product or -1] or ("LIFX product " .. tostring(ver.product or "?")),
        vendor_provided_label = name,
      })
    end
  end
  log.info(string.format("[lifx] discovery done, %d bulb(s) answered", n))
end

local driver = Driver("stoeckie-lifx-local", {
  discovery = discovery,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [switch.ID] = {
      [switch.commands.on.NAME] = handle_on,
      [switch.commands.off.NAME] = handle_off,
    },
    [level.ID] = {
      [level.commands.setLevel.NAME] = handle_level,
    },
    [color.ID] = {
      [color.commands.setColor.NAME] = handle_color,
      [color.commands.setHue.NAME] = handle_hue,
      [color.commands.setSaturation.NAME] = handle_sat,
    },
    [ctemp.ID] = {
      [ctemp.commands.setColorTemperature.NAME] = handle_ctemp,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },
})

log.info("[lifx] LIFX (local) driver starting, build " .. BUILD)
driver:run()
