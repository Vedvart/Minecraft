-- speaker_client.lua
-- Runs on each computer that has its OWN speaker attached.
-- Expects the .dfpwm file to be accessible locally (e.g. on /disk/…).
-- Listens for controller broadcast and starts in-sync playback.

local PROTOCOL = "ccaudio_sync_v1"

-- Open any connected modem (wired or wireless)
local function openAnyModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end

openAnyModem()
assert(rednet.isOpen(), "No modem found/opened. Attach and open a (wired) modem.")

-- Find speaker
local speaker = peripheral.find("speaker")
assert(speaker, "No speaker attached to this computer.")

-- DFPWM decoder
local dfpwm = require("cc.audio.dfpwm")

-- State
local abortToken = nil   -- when set, any current playback should stop

-- Play a DFPWM file precisely at (ms-epoch) start time
local function play_file_at(path, start_epoch_ms, volume)
  volume = tonumber(volume) or 1.0
  if not fs.exists(path) then
    return false, ("File not found: " .. path)
  end

  -- Open file in binary mode
  local handle = fs.open(path, "rb")
  if not handle then
    return false, ("Failed to open: " .. path)
  end

  local thisToken = {}
  abortToken = nil -- clear old abort
  local decoder = dfpwm.make_decoder()

  -- Busy-wait (sleep) until the scheduled time
  local function wait_until(target_ms)
    while true do
      local now = os.epoch("utc")
      if now >= target_ms then return end
      local remain = target_ms - now
      -- sleep in seconds; clamp to small slices for accuracy
      sleep(math.min(0.2, math.max(0.001, remain / 1000)))
    end
  end

  wait_until(start_epoch_ms)

  -- Read/decode/play loop
  local CHUNK = 16 * 1024
  local ok = true
  while true do
    -- Allow mid-play STOP: check token between chunks
    if abortToken == thisToken then ok = false; break end

    local chunk = handle.read(CHUNK)
    if not chunk then break end

    local decoded = decoder(chunk)
    -- Feed the speaker; if its buffer is full, wait for it to free up
    while not speaker.playAudio(decoded, volume) do
      local ev = { os.pullEvent() }
      if ev[1] == "speaker_audio_empty" then
        -- try again
      elseif abortToken == thisToken then
        ok = false
        break
      end
    end
    if not ok then break end
  end

  handle.close()
  return ok, ok and "Done" or "Stopped"
end

-- Send a small ack back to the controller (optional)
local function reply(id, tbl)
  if id then rednet.send(id, tbl, PROTOCOL) end
end

print("Speaker client ready. Waiting for controller…")

-- Main message loop
while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if type(msg) == "table" and msg.cmd == "PING" then
    reply(sender, { cmd = "PONG", id = os.getComputerID(), label = os.getComputerLabel() })
  elseif type(msg) == "table" and msg.cmd == "STOP" then
    -- Signal any current playback to end
    abortToken = abortToken or {} -- if no active playback, harmless
    -- Nudge the event loop so a blocking playAudio wait can exit promptly
    os.queueEvent("speaker_audio_empty")
    reply(sender, { cmd = "STOPPED", id = os.getComputerID() })
  elseif type(msg) == "table" and msg.cmd == "PLAY" then
    -- Expected fields: path, start_epoch_ms, volume
    local path = tostring(msg.path or "")
    local start_ms = tonumber(msg.start_epoch_ms)
    local volume = tonumber(msg.volume) or 1.0

    if path == "" or not start_ms then
      reply(sender, { cmd = "ERROR", id = os.getComputerID(), error = "Bad PLAY payload" })
    else
      print(("PLAY: %s at %d (vol=%.2f)"):format(path, start_ms, volume))
      local ok, info = play_file_at(path, start_ms, volume)
      reply(sender, { cmd = "RESULT", id = os.getComputerID(), ok = ok, info = info })
    end
  end
end
