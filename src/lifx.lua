-- LIFX LAN protocol (https://lan.developer.lifx.com): UDP 56700, 36 byte header, little endian.
-- Every request uses its own socket and sequence number, so a reply can never be mixed up with
-- another bulb's or another request's reply. Requests are retried; nothing is assumed to have worked
-- until the bulb answers.
local cosock = require "cosock"
local socket = cosock.socket

local M = { PORT = 56700 }

M.T = {
  GetService = 2, StateService = 3,
  GetVersion = 32, StateVersion = 33,
  Acknowledgement = 45,
  LightGet = 101, LightSetColor = 102, LightState = 107,
  LightSetPower = 117, LightStatePower = 118,
}

math.randomseed(os.time())
local SOURCE = math.random(0x10000, 0x7fffffff) -- non-zero: replies come back unicast to us
local seq = 0

local function mac_bytes(mac)
  if not mac then return string.rep("\0", 8) end
  return (mac:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) .. "\0\0"
end

local function mac_hex(b)
  return (b:gsub(".", function(c) return string.format("%02X", c:byte()) end))
end

-- Build a packet. tagged = to all bulbs (discovery); ack/res = ask for an Acknowledgement / a State reply.
function M.packet(msg_type, payload, mac, ack, res)
  payload = payload or ""
  seq = (seq + 1) % 256
  local tagged = mac == nil
  local proto = 1024 | (1 << 12) | (tagged and (1 << 13) or 0)
  local flags = (res and 1 or 0) | (ack and 2 or 0)
  local p = string.pack("<I2I2I4", 36 + #payload, proto, SOURCE)
    .. mac_bytes(mac) .. string.rep("\0", 6) .. string.pack("<BB", flags, seq)
    .. string.rep("\0", 8) .. string.pack("<I2I2", msg_type, 0) .. payload
  return p, seq
end

function M.parse(data)
  if type(data) ~= "string" or #data < 36 then return nil end
  local size, _, source = string.unpack("<I2I2I4", data, 1)
  if size ~= #data then return nil end
  return {
    source = source,
    mac = mac_hex(data:sub(9, 14)),
    seq = data:byte(24),
    type = string.unpack("<I2", data, 33),
    payload = data:sub(37),
  }
end

-- LightState payload -> table (raw 16 bit values plus label)
function M.light_state(payload)
  if #payload < 52 then return nil end
  local h, s, b, k, _, power, label = string.unpack("<I2I2I2I2i2I2c32", payload)
  return { hue = h, sat = s, bri = b, kelvin = k, power = power, label = (label:gsub("%z.*$", "")) }
end

function M.version(payload)
  if #payload < 8 then return nil end
  local vendor, product = string.unpack("<I4I4", payload)
  return { vendor = vendor, product = product }
end

-- One request/reply exchange with a bulb. expect = reply type wanted (or Acknowledgement).
-- Returns the parsed reply, or nil, "timeout".
function M.request(ip, mac, msg_type, payload, expect, timeout, tries)
  timeout, tries = timeout or 0.8, tries or 3
  for _ = 1, tries do
    local udp = socket.udp()
    udp:setsockname("*", 0)
    local pkt, s = M.packet(msg_type, payload, mac, expect == M.T.Acknowledgement, expect ~= M.T.Acknowledgement)
    local sent = pcall(function() return udp:sendto(pkt, ip, M.PORT) end)
    local deadline = socket.gettime() + timeout
    while sent and socket.gettime() < deadline do
      udp:settimeout(math.max(0.05, deadline - socket.gettime()))
      local data = udp:receivefrom()
      local m = data and M.parse(data)
      if m and m.source == SOURCE and m.seq == s and m.type == expect and (not mac or m.mac == mac) then
        udp:close()
        return m
      end
    end
    udp:close()
  end
  return nil, "timeout"
end

-- Find bulbs: GetService broadcast plus a unicast sweep of the hub's /24 (some routers drop broadcasts).
-- Returns { [MAC] = ip }.
function M.discover(prefix, window)
  local udp = socket.udp()
  udp:setsockname("*", 0)
  pcall(function() udp:setoption("broadcast", true) end)
  local pkt = M.packet(M.T.GetService, "", nil, false, true)
  pcall(function() udp:sendto(pkt, "255.255.255.255", M.PORT) end)
  if prefix then
    pcall(function() udp:sendto(pkt, prefix .. "255", M.PORT) end)
    for i = 1, 254 do pcall(function() udp:sendto(pkt, prefix .. i, M.PORT) end) end
  end
  local found = {}
  local deadline = socket.gettime() + (window or 3)
  while socket.gettime() < deadline do
    udp:settimeout(math.max(0.05, deadline - socket.gettime()))
    local data, ip = udp:receivefrom()
    local m = data and M.parse(data)
    if m and m.type == M.T.StateService and m.source == SOURCE then
      local service, port = string.unpack("<BI4", m.payload)
      if service == 1 and port == M.PORT then found[m.mac] = ip end
    end
  end
  udp:close()
  return found
end

-- Payload builders
function M.set_power(on, duration_ms)
  return string.pack("<I2I4", on and 65535 or 0, duration_ms or 0)
end

function M.set_color(st, duration_ms)
  return string.pack("<BI2I2I2I2I4", 0, st.hue, st.sat, st.bri, st.kelvin, duration_ms or 0)
end

return M
