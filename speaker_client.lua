-- speaker_client_stream.lua
-- Listens for a network "session", buffers .dfpwm chunks, and plays them in sync.
-- Works with controller_stream.lua (below).

local PROTOCOL = "ccaudio_sync_v1"
local CHUNK_REQUEST_INTERVAL = 0.25 -- seconds between NACKs for the same missing seq
local PREBUFFER_TARGET = 10         -- number of chunks to have before starting (if time allows)

-- Open any modem
local function openAnyModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end

openAnyModem()
assert(rednet.isOpen(), "No modem found/opened. Attach/open a (wired) modem.")

-- Speaker + decoder
local speaker = peripheral.find("speaker")
assert(speaker, "No speaker attached to this computer.")
local dfpwm = require("cc.audio.dfpwm")

-- Current session state
local sess = nil
-- sess = {
--   sid=..., controller_id=..., start_ms=..., volume=..., total=nil or number,
--   buffer = { [seq]=string }, next_seq=1, last_nack_time=0, ended=false
-- }

local function reset_session()
  sess = nil
end

local function begin_session(sid, controller_id, start_ms, volume)
  sess = {
    sid = sid,
    controller_id = controller_id,
    start_ms = start_ms,
    volume = tonumber(volume) or 1.0,
    buffer = {},
    next_seq = 1,
    last_nack_time = 0,
    ended = false,
    total = nil,
  }
end

local function send(to, tbl)
  if to then rednet.send(to, tbl, PROTOCOL) end
end

local function acknowledge(sender, cmd, extra)
  local t = { cmd = cmd, id = os.getComputerID() }
  if extra then for k,v in pairs(extra) do t[k]=v end end
  send(sender, t)
end

local function time_ms() return os.epoch("utc") end

local function wait_until(ms)
  while time_ms() < ms do
    sleep(0.01)
  end
end

local function play_current_session()
  if not sess then return end

  -- Optional prebuffer if we have time
  local deadline = sess.start_ms
  while time_ms() + 20 < deadline do
    local have = 0
    for _ in pairs(sess.buffer) do have = have + 1 end
    if have >= PREBUFFER_TARGET then break end
    sleep(0.02)
  end

  -- Align start
  wait_until(sess.start_ms)

  local decoder = dfpwm.make_decoder()
  local volume = sess.volume
  local next_seq = sess.next_seq

  while sess and next_seq and (not sess.ended or (sess.total and next_seq <= sess.total)) do
    local data = sess.buffer[next_seq]
    if data then
      -- decode and play this chunk
      local decoded = decoder(data)

      -- Feed speaker; wait for buffer to free
      while not speaker.playAudio(decoded, volume) do
        local ev = { os.pullEvent() }
        if ev[1] == "speaker_audio_empty" then
          -- try again
        elseif not sess then
          return
        end
      end

      -- free memory for this chunk
      sess.buffer[next_seq] = nil
      next_seq = next_seq + 1
      sess.next_seq = next_seq
    else
      -- Missing the next chunk – request retransmit periodically
      local now = os.clock()
      if now - (sess.last_nack_time or 0) >= CHUNK_REQUEST_INTERVAL then
        send(sess.controller_id, { cmd = "NACK", sid = sess.sid, seq = next_seq })
        sess.last_nack_time = now
      end
      -- Also yield so incoming packets can arrive
      os.pullEventTimeout("rednet_message", 0.1)
    end
  end

  -- Done
  acknowledge(sess.controller_id, "RESULT", { ok = true, info = "Done" })
  reset_session()
end

print("Speaker client (stream) ready. Waiting for controller…")

-- Event loop
while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto ~= PROTOCOL then goto continue end
  if type(msg) ~= "table" then goto continue end

  if msg.cmd == "PING" then
    acknowledge(sender, "PONG", { label = os.getComputerLabel() })

  elseif msg.cmd == "STOP" then
    -- Clear current session and nudge audio loop
    reset_session()
    os.queueEvent("speaker_audio_empty")
    acknowledge(sender, "STOPPED")

  elseif msg.cmd == "PREP" then
    -- Start a new session (discard any previous)
    -- fields: sid, start_epoch_ms, volume
    reset_session()
    begin_session(msg.sid, sender, assert(tonumber(msg.start_epoch_ms), "bad start"), msg.volume or 1.0)
    print(("Session %s prepared; start at %d"):format(tostring(msg.sid), sess.start_ms))
    acknowledge(sender, "READY", { sid = msg.sid })

  elseif msg.cmd == "CHUNK" then
    if sess and msg.sid == sess.sid and type(msg.seq) == "number" and type(msg.data) == "string" then
      -- store chunk
      sess.buffer[msg.seq] = msg.data
    end

  elseif msg.cmd == "END" then
    if sess and msg.sid == sess.sid then
      sess.ended = true
      sess.total = tonumber(msg.total)
      -- Kick off playback if not already running (spawn lightweight task)
      -- We'll just run it inline here if we're not yet started.
      -- If already started, loop above will naturally finish when total reached.
      if sess.next_seq == 1 then
        -- Start the playback loop in this thread
        play_current_session()
      end
    end

  elseif msg.cmd == "PLAY_NOW" then
    -- Optional override to start immediately (rarely needed)
    if sess and msg.sid == sess.sid then
      sess.start_ms = time_ms()
      play_current_session()
    end
  end

  ::continue::
end
