-- controller_play.lua
-- Usage:
--   controller_play <path_on_clients> [delay_ms] [volume]
-- Example:
--   controller_play /disk/music/track.dfpwm 2500 0.8

local PROTOCOL = "ccaudio_sync_v1"

local function openAnyModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end

openAnyModem()
assert(rednet.isOpen(), "No modem found/opened. Attach and open a (wired) modem.")

local tArgs = { ... }
if #tArgs < 1 then
  print("Usage: controller_play <path_on_clients> [delay_ms] [volume]")
  return
end

local path   = tArgs[1]
local delay  = tonumber(tArgs[2]) or 2000  -- default start 2s from now
local volume = tonumber(tArgs[3]) or 1.0

-- Optional: ping to see how many clients are alive
rednet.broadcast({ cmd = "PING" }, PROTOCOL)
local clients = {}
local ping_deadline = os.startTimer(0.7) -- short window to collect pongs
while true do
  local e, p1, p2, p3 = os.pullEvent()
  if e == "timer" and p1 == ping_deadline then
    break
  elseif e == "rednet_message" then
    local sender, msg, proto = p1, p2, p3
    if proto == PROTOCOL and type(msg) == "table" and msg.cmd == "PONG" then
      clients[sender] = msg.label or ("#" .. tostring(sender))
    end
  end
end

print(("Clients responding: %d"):format((function(t) local c=0 for _ in pairs(t) do c=c+1 end return c end)(clients)))

-- Compute the shared start time (UTC ms)
local start_epoch_ms = os.epoch("utc") + math.max(250, delay)

-- Broadcast the PLAY command
local payload = { cmd = "PLAY", path = path, start_epoch_ms = start_epoch_ms, volume = volume }
rednet.broadcast(payload, PROTOCOL)
print(("Sent PLAY for %s at %d (in %d ms, vol=%.2f)")
  :format(path, start_epoch_ms, start_epoch_ms - os.epoch("utc"), volume))

-- Collect results (optional)
local results_deadline = os.startTimer(10)
local received = 0
while true do
  local e, p1, p2, p3 = os.pullEvent()
  if e == "timer" and p1 == results_deadline then
    break
  elseif e == "rednet_message" then
    local sender, msg, proto = p1, p2, p3
    if proto == PROTOCOL and type(msg) == "table" and msg.cmd == "RESULT" then
      received = received + 1
      local label = clients[sender] or ("#" .. tostring(sender))
      print(("[%s] %s (%s)"):format(label, msg.ok and "OK" or "ERR", msg.info or ""))
    elseif proto == PROTOCOL and type(msg) == "table" and msg.cmd == "ERROR" then
      local label = clients[sender] or ("#" .. tostring(sender))
      print(("[%s] ERROR: %s"):format(label, msg.error or ""))
    end
  end
end
