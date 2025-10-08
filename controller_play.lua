-- controller_stream.lua
-- Streams a .dfpwm file from the controller's disk drive to all clients.
-- Usage:
--   controller_stream <path_on_controller> [delay_ms] [volume] [chunk_bytes]
-- Example:
--   controller_stream /disk/music/track.dfpwm 2500 0.9 8192

local PROTOCOL = "ccaudio_sync_v1"

local function openAnyModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end

local function basename(p)
  return (tostring(p):gsub("[/\\]+$", "")):match("([^/\\]+)$") or tostring(p)
end

openAnyModem()
assert(rednet.isOpen(), "No modem found/opened. Attach/open a (wired) modem.")

local args = { ... }
if #args < 1 then
  print("Usage: controller_stream <path_on_controller> [delay_ms] [volume] [chunk_bytes]")
  return
end

local path = args[1]
local delay = tonumber(args[2]) or 2500
local volume = tonumber(args[3]) or 1.0
local CHUNK = tonumber(args[4]) or 8192  -- keep under rednet payload limits

assert(fs.exists(path), "File not found: " .. path)
local fh = fs.open(path, "rb")
assert(fh, "Failed to open file")

-- Load into memory so we can handle retransmits reliably
local chunks = {}
while true do
  local data = fh.read(CHUNK)
  if not data then break end
  chunks[#chunks+1] = data
end
fh.close()

local function count(tbl) local c=0 for _ in pairs(tbl) do c=c+1 end return c end

-- Ping to see who's alive (optional)
rednet.broadcast({ cmd = "PING" }, PROTOCOL)
local clients = {}
local ping_deadline = os.startTimer(0.7)
while true do
  local e, p1, p2, p3 = os.pullEvent()
  if e == "timer" and p1 == ping_deadline then break end
  if e == "rednet_message" and p3 == PROTOCOL then
    local sender, msg = p1, p2
    if type(msg) == "table" and msg.cmd == "PONG" then
      clients[sender] = msg.label or ("#" .. tostring(sender))
    end
  end
end
print(("Clients responding: %d"):format(count(clients)))

-- Prepare a unique session id
local sid = tostring(os.epoch("utc")) .. "-" .. tostring(math.random(1000,9999))
local start_ms = os.epoch("utc") + math.max(500, delay)

-- Tell everyone to prepare (gives them the exact start time)
local prep = { cmd="PREP", sid=sid, start_epoch_ms=start_ms, volume=volume, name=basename(path) }
rednet.broadcast(prep, PROTOCOL)
print(("PREP sent for %s; start in %d ms"):format(prep.name, start_ms - os.epoch("utc")))

-- Brief window to collect READY acks (optional)
local ready_deadline = os.startTimer(0.7)
while true do
  local e, p1, p2, p3 = os.pullEvent()
  if e == "timer" and p1 == ready_deadline then break end
  if e == "rednet_message" and p3 == PROTOCOL then
    local sender, msg = p1, p2
    if type(msg) == "table" and msg.cmd == "READY" and msg.sid == sid then
      clients[sender] = clients[sender] or ("#" .. tostring(sender))
    end
  end
end

-- Stream all chunks
for i=1, #chunks do
  rednet.broadcast({ cmd="CHUNK", sid=sid, seq=i, data=chunks[i] }, PROTOCOL)
  -- tiny yield so receivers can process
  os.queueEvent("yield"); os.pullEvent()
end

-- Notify end and total count
rednet.broadcast({ cmd="END", sid=sid, total=#chunks }, PROTOCOL)
print(("END sent (%d chunks). Waiting for NACKs/results…"):format(#chunks))

-- Simple NACK/Result handling window
local finish_deadline = os.startTimer(12) -- allow time for late NACKs & playback
while true do
  local e, p1, p2, p3 = os.pullEvent()
  if e == "timer" and p1 == finish_deadline then break end
  if e == "rednet_message" and p3 == PROTOCOL then
    local sender, msg = p1, p2
    if type(msg) == "table" then
      if msg.cmd == "NACK" and msg.sid == sid and type(msg.seq) == "number" then
        local seq = msg.seq
        local data = chunks[seq]
        if data then
          rednet.send(sender, { cmd="CHUNK", sid=sid, seq=seq, data=data }, PROTOCOL)
        end
      elseif msg.cmd == "RESULT" then
        local label = clients[sender] or ("#" .. tostring(sender))
        print(("[%s] %s (%s)"):format(label, msg.ok and "OK" or "ERR", msg.info or ""))
      end
    end
  end
end

print("Stream session complete.")
