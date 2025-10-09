-- speaker_client_stream.lua  (DEBUG build; 1-tick controls, player starts on PREP)
-- Prints detailed logs so we can trace start/stream/play states.

local PROTOCOL = "ccaudio_sync_v1"
local DEBUG = true

-- Low-latency tuning
local CHUNK_REQUEST_INTERVAL = 0.10  -- seconds between NACKs for missing next chunk
local PREBUFFER_TARGET = 1           -- start once at least 1 chunk is available
local IDLE_WAIT = 0.02               -- how long to wait while missing a chunk

-- ===== Utilities =====
local function now_ms() return os.epoch("utc") end
local function t() return ("%d"):format(now_ms() % 1000000) end
local function log(...) if DEBUG then print(("[%s][CLIENT] "):format(t()) .. table.concat({...}," ")) end end

local function openAnyModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end

openAnyModem()
assert(rednet.isOpen(), "No modem open")

local speaker = peripheral.find("speaker")
assert(speaker, "No speaker attached")
local dfpwm = require("cc.audio.dfpwm")

-- ===== Session State =====
local sess = nil
-- sess = {
--   sid, controller_id, start_ms, volume,
--   buffer[seq]=data, next_seq, ended, total, paused, last_nack_time,
--   player_task (coroutine)
-- }

local function send(to, msg) if to then rednet.send(to, msg, PROTOCOL) end end
local function ack(to, cmd, extra)
  local m = { cmd = cmd, id = os.getComputerID() }
  if extra then for k,v in pairs(extra) do m[k]=v end end
  send(to, m)
end

local function hard_stop_audio()
  if speaker.stop then pcall(function() speaker.stop() end) end
  os.queueEvent("speaker_audio_empty")
end

local function begin_session(sid, controller_id, start_ms, volume)
  sess = {
    sid = sid, controller_id = controller_id,
    start_ms = tonumber(start_ms) or now_ms(),
    volume = tonumber(volume) or 1.0,
    buffer = {}, next_seq = 1, ended = false, total = nil, paused = false,
    last_nack_time = 0, player_task = nil,
  }
end

-- ===== Player Loop =====
local function player_loop()
  log("player_loop enter; start_ms=", tostring(sess.start_ms))
  local decoder = dfpwm.make_decoder()

  -- Arm until start time and minimal buffer present
  while sess and now_ms() + 1 < sess.start_ms do
    os.pullEventTimeout("rednet_message", 0.01)
  end
  -- Ensure at least 1 chunk available once start time arrives
  while sess and now_ms() >= sess.start_ms do
    if sess.buffer[sess.next_seq] then break end
    os.pullEventTimeout("rednet_message", IDLE_WAIT)
  end
  if not sess then return end
  log("starting playback; next_seq=", tostring(sess.next_seq))

  local warned_full = false
  while sess and (not sess.ended or (sess.total and sess.next_seq <= sess.total)) do
    if sess.paused then
      os.pullEvent("rednet_message")
    else
      local data = sess.buffer[sess.next_seq]
      if data then
        local decoded = decoder(data)
        while not speaker.playAudio(decoded, sess.volume) do
          local ev = { os.pullEvent() }
          if ev[1] == "speaker_audio_empty" then
            if warned_full then log("speaker drain ok"); warned_full = false end
          elseif not sess or sess.paused then break end
        end
        if not sess or sess.paused then goto cont end
        sess.buffer[sess.next_seq] = nil
        sess.next_seq = sess.next_seq + 1
      else
        -- Missing next chunk -> NACK quickly
        local nowc = os.clock()
        if nowc - (sess.last_nack_time or 0) >= CHUNK_REQUEST_INTERVAL then
          send(sess.controller_id, { cmd="NACK", sid=sess.sid, seq=sess.next_seq })
          sess.last_nack_time = nowc
          log("NACK seq=", tostring(sess.next_seq))
        end
        os.pullEventTimeout("rednet_message", IDLE_WAIT)
      end
    end
    ::cont::
  end

  if sess then
    log("playback finished at seq=", tostring(sess.next_seq-1), " total=", tostring(sess.total))
    ack(sess.controller_id, "RESULT", { ok=true, info="Done" })
  end
end

local function ensure_player_running()
  if not sess then return end
  if not sess.player_task or coroutine.status(sess.player_task) == "dead" then
    sess.player_task = coroutine.create(function() player_loop() end)
    log("player_task created")
  end
end

local function pump_player()
  if sess and sess.player_task and coroutine.status(sess.player_task) == "suspended" then
    local ok, err = coroutine.resume(sess.player_task)
    if not ok then log("player_task error: ", tostring(err)) end
  end
end

print("Speaker client ready (DEBUG).")

-- ===== Main listener =====
while true do
  -- keep the player moving between messages
  pump_player()

  local sender, msg, proto = rednet.receive(PROTOCOL, 0.05) -- short timeout so we can pump even if idle
  pump_player()

  if not sender then goto cont end
  if proto ~= PROTOCOL or type(msg) ~= "table" then goto cont end

  if msg.cmd == "PING" then
    ack(sender, "PONG", { label = os.getComputerLabel() })

  elseif msg.cmd == "PREP" then
    log("PREP sid=", tostring(msg.sid), " start_ms=", tostring(msg.start_epoch_ms), " vol=", tostring(msg.volume))
    begin_session(msg.sid, sender, msg.start_epoch_ms, msg.volume or 1.0)
    ack(sender, "READY", { sid = msg.sid })
    ensure_player_running()

  elseif msg.cmd == "CHUNK" then
    if sess and msg.sid == sess.sid and type(msg.seq) == "number" and type(msg.data) == "string" then
      sess.buffer[msg.seq] = msg.data
      if msg.seq % 500 == 0 or msg.seq < 10 then
        local bl = 0; for _ in pairs(sess.buffer) do bl = bl + 1 end
        log("CHUNK seq=", tostring(msg.seq), " buffer_len≈", tostring(bl))
      end
    end

  elseif msg.cmd == "END" then
    if sess and msg.sid == sess.sid then
      sess.ended = true
      sess.total = tonumber(msg.total)
      if msg.start_epoch_ms then sess.start_ms = tonumber(msg.start_epoch_ms) end
      log("END total=", tostring(sess.total), " start_ms=", tostring(sess.start_ms))
      ensure_player_running()
    end

  elseif msg.cmd == "PAUSE" then
    if sess and msg.sid == sess.sid then
      log("PAUSE")
      sess.paused = true
      hard_stop_audio()
      ack(sender, "PAUSED", { sid = sess.sid, seq = sess.next_seq })
    end

  elseif msg.cmd == "RESUME" then
    if sess and msg.sid == sess.sid then
      log("RESUME at seq=", tostring(sess.next_seq))
      sess.paused = false
      os.queueEvent("speaker_audio_empty")
      ack(sender, "RESUMED", { sid = sess.sid, seq = sess.next_seq })
    end

  elseif msg.cmd == "STOP" then
    log("STOP")
    hard_stop_audio()
    sess = nil
    ack(sender, "STOPPED")
  end

  ::cont::
end
