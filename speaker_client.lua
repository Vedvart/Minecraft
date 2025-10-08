-- speaker_client_stream.lua  (with PAUSE/RESUME)
-- Listens for a network "session", buffers .dfpwm chunks, and plays them in sync.
-- Works with jukebox_monitor.lua (controller UI) or controller_stream.lua.

local PROTOCOL = "ccaudio_sync_v1"
local CHUNK_REQUEST_INTERVAL = 0.25 -- seconds between NACKs for same missing seq
local PREBUFFER_TARGET = 10         -- target chunks before start if time allows

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

-- Session state
local sess = nil
-- sess = {
--   sid=..., controller_id=..., start_ms=..., volume=...,
--   buffer = { [seq]=string }, next_seq=1, paused=false, last_nack_time=0,
--   ended=false, total=nil
-- }

local function reset_session() sess = nil end

local function begin_session(sid, controller_id, start_ms, volume)
  sess = {
    sid = sid, controller_id = controller_id,
    start_ms = assert(tonumber(start_ms), "bad start"),
    volume = tonumber(volume) or 1.0,
    buffer = {},
    next_seq = 1,
    paused = false,
    last_nack_time = 0,
    ended = false,
    total = nil,
  }
end

local function send(to, tbl) if to then rednet.send(to, tbl, PROTOCOL) end end
local function ack(sender, cmd, extra)
  local t = { cmd = cmd, id = os.getComputerID() }
  if extra then for k,v in pairs(extra) do t[k]=v end end
  send(sender, t)
end

local function time_ms() return os.epoch("utc") end
local function wait_until(ms) while time_ms() < ms do sleep(0.01) end end

local function play_loop()
  local decoder = dfpwm.make_decoder()
  while sess and (not sess.ended or (sess.total and sess.next_seq <= sess.total)) do
    if sess.paused then
      -- While paused, just wait for unpause or stop
      os.pullEvent("rednet_message") -- wake on any network activity
    else
      local data = sess.buffer[sess.next_seq]
      if data then
        local decoded = decoder(data)
        while not speaker.playAudio(decoded, sess.volume) do
          local ev = { os.pullEvent() }
          if ev[1] == "speaker_audio_empty" then
            -- retry
          elseif not sess or sess.paused then
            break
          end
        end
        if not sess or sess.paused then goto continue end
        sess.buffer[sess.next_seq] = nil
        sess.next_seq = sess.next_seq + 1
      else
        -- Missing chunk: request retransmit periodically
        local now = os.clock()
        if now - (sess.last_nack_time or 0) >= CHUNK_REQUEST_INTERVAL then
          send(sess.controller_id, { cmd = "NACK", sid = sess.sid, seq = sess.next_seq })
          sess.last_nack_time = now
        end
        os.pullEventTimeout("rednet_message", 0.1)
      end
    end
    ::continue::
  end
  if sess then ack(sess.controller_id, "RESULT", { ok = true, info = "Done" }) end
  reset_session()
end

print("Speaker client (stream) ready. Waiting for controller…")

while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto ~= PROTOCOL or type(msg) ~= "table" then goto continue end

  if msg.cmd == "PING" then
    ack(sender, "PONG", { label = os.getComputerLabel() })

  elseif msg.cmd == "STOP" then
    reset_session()
    os.queueEvent("speaker_audio_empty")
    ack(sender, "STOPPED")

  elseif msg.cmd == "PREP" then
    reset_session()
    begin_session(msg.sid, sender, msg.start_epoch_ms, msg.volume or 1.0)
    ack(sender, "READY", { sid = msg.sid })

  elseif msg.cmd == "CHUNK" then
    if sess and msg.sid == sess.sid and type(msg.seq) == "number" and type(msg.data) == "string" then
      sess.buffer[msg.seq] = msg.data
    end

  elseif msg.cmd == "END" then
    if sess and msg.sid == sess.sid then
      sess.ended = true
      sess.total = tonumber(msg.total)
      -- Start countdown to the scheduled start, then play
      if msg.start_epoch_ms then sess.start_ms = tonumber(msg.start_epoch_ms) end
      wait_until(sess.start_ms)
      play_loop()
    end

  elseif msg.cmd == "PAUSE" then
    if sess and msg.sid == sess.sid then
      sess.paused = true
      os.queueEvent("speaker_audio_empty") -- nudge any waits
      ack(sender, "PAUSED", { sid = sess.sid, seq = sess.next_seq })
    end

  elseif msg.cmd == "RESUME" then
    if sess and msg.sid == sess.sid then
      sess.paused = false
      -- Optional: re-align on a given resume start time
      if msg.start_epoch_ms then wait_until(tonumber(msg.start_epoch_ms)) end
      os.queueEvent("speaker_audio_empty")
      ack(sender, "RESUMED", { sid = sess.sid, seq = sess.next_seq })
    end

  end
  ::continue::
end
