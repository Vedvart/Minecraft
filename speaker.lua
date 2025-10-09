-- speaker_client_stream.lua  (DEBUG+LOG; 1-tick controls; watchdog force-start)
local PROTOCOL = "ccaudio_sync_v1"
local DEBUG = true
local LOG_PATH = "/speaker.log"

-- Low-latency tuning
local CHUNK_REQUEST_INTERVAL = 0.10  -- seconds
local PREBUFFER_TARGET = 1           -- start once 1 chunk exists
local IDLE_WAIT = 0.02               -- seconds
local FORCE_START_BUF = 32           -- if ≥ this many chunks buffered, force start
local FORCE_START_MS  = 3000         -- or if waiting > this long since PREP, force start

-- ===== Utilities =====
local function now_ms() return os.epoch("utc") end
local function t() return ("%d"):format(now_ms() % 1000000) end

local native = term.native()
local function log_line(s)
  local old = term.current()
  term.redirect(native); print(s); term.redirect(old)
  local fh = fs.open(LOG_PATH, "a"); if fh then fh.writeLine(s); fh.close() end
end
local function log(...) if DEBUG then log_line(("[%s][CLIENT] "):format(t()) .. table.concat({...}," ")) end end

-- Tiny “pull with timeout”
local function pull_with_timeout(filter, timeout)
  local timer = os.startTimer(timeout or 0)
  while true do
    local e, p1, p2, p3 = os.pullEvent()
    if e == "timer" and p1 == timer then return nil end
    if not filter or e == filter then return e, p1, p2, p3 end
  end
end

-- Open modem
for _, s in ipairs(peripheral.getNames()) do
  if peripheral.getType(s) == "modem" and not rednet.isOpen(s) then rednet.open(s) end
end
assert(rednet.isOpen(), "No modem open")

local speaker = peripheral.find("speaker"); assert(speaker, "No speaker")
local dfpwm = require("cc.audio.dfpwm")

-- ===== Session =====
local sess = nil
local function send(to, msg) if to then rednet.send(to, msg, PROTOCOL) end end
local function ack(to, cmd, extra) local m={cmd=cmd,id=os.getComputerID()}; if extra then for k,v in pairs(extra) do m[k]=v end end; send(to,m) end
local function hard_stop_audio() if speaker.stop then pcall(function() speaker.stop() end) end; os.queueEvent("speaker_audio_empty") end

local function begin_session(sid, controller_id, start_ms, volume)
  sess = {
    sid=sid, controller_id=controller_id, start_ms=tonumber(start_ms) or now_ms(),
    volume=tonumber(volume) or 1.0, buffer={}, next_seq=1, ended=false, total=nil,
    paused=false, last_nack_time=0, player_task=nil, prep_ms=now_ms(), started=false,
  }
end

-- ===== Player =====
local function buf_len()
  local c=0; for _ in pairs(sess.buffer) do c=c+1 end; return c
end

local function player_loop()
  log("player_loop enter; start_ms=", tostring(sess.start_ms))

  -- Arm until start time OR watchdog trips
  while sess do
    if now_ms() + 1 >= sess.start_ms and (sess.buffer[sess.next_seq] ~= nil) then break end
    -- Watchdog: if we’ve been waiting a while or have lots buffered, force start
    if (now_ms() - (sess.prep_ms or now_ms())) > FORCE_START_MS or buf_len() >= FORCE_START_BUF then
      if now_ms() < sess.start_ms then log("WATCHDOG: force start (buf=", tostring(buf_len()), ")"); end
      sess.start_ms = now_ms() - 1
      break
    end
    pull_with_timeout(nil, 0.01)
  end
  if not sess then return end

  log("starting playback; next_seq=", tostring(sess.next_seq))
  sess.started = true
  local decoder = dfpwm.make_decoder()

  while sess and (not sess.ended or (sess.total and sess.next_seq <= sess.total)) do
    if sess.paused then
      pull_with_timeout("rednet_message", 0.1)
    else
      local data = sess.buffer[sess.next_seq]
      if data then
        local decoded = decoder(data)
        while not speaker.playAudio(decoded, sess.volume) do
          local e = { os.pullEvent() }
          if e[1] == "speaker_audio_empty" then
          elseif not sess or sess.paused then break end
        end
        if not sess or sess.paused then goto cont end
        sess.buffer[sess.next_seq] = nil
        sess.next_seq = sess.next_seq + 1
        if sess.next_seq % 2048 == 0 then log("played up to seq=", tostring(sess.next_seq-1)) end
      else
        local nowc = os.clock()
        if nowc - (sess.last_nack_time or 0) >= CHUNK_REQUEST_INTERVAL then
          send(sess.controller_id, { cmd="NACK", sid=sess.sid, seq=sess.next_seq })
          sess.last_nack_time = nowc
          log("NACK seq=", tostring(sess.next_seq))
        end
        pull_with_timeout("rednet_message", IDLE_WAIT)
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
    sess.player_task = coroutine.create(player_loop)
    log("player_task created")
  end
end
local function pump_player()
  if sess and sess.player_task and coroutine.status(sess.player_task) == "suspended" then
    local ok, err = coroutine.resume(sess.player_task)
    if not ok then log("player_task error: ", tostring(err)) end
  end
end

print("Speaker client ready (DEBUG+LOG). See "..LOG_PATH)

-- ===== Main =====
while true do
  pump_player()
  local sender, msg, proto = rednet.receive(PROTOCOL, 0.05)
  pump_player()

  if not sender or proto ~= PROTOCOL or type(msg) ~= "table" then goto cont end

  if msg.cmd == "PREP" then
    log("PREP sid=", tostring(msg.sid), " start_ms=", tostring(msg.start_epoch_ms), " vol=", tostring(msg.volume))
    begin_session(msg.sid, sender, msg.start_epoch_ms, msg.volume or 1.0)
    ack(sender, "READY", { sid = msg.sid })
    ensure_player_running()

  elseif msg.cmd == "CHUNK" then
    if sess and msg.sid == sess.sid and type(msg.seq) == "number" and type(msg.data) == "string" then
      sess.buffer[msg.seq] = msg.data
      if (msg.seq & 0xff) == 0 or msg.seq <= 16 then
        log("CHUNK seq=", tostring(msg.seq), " buf≈", tostring(buf_len()))
      end
    end

  elseif msg.cmd == "END" then
    if sess and msg.sid == sess.sid then
      sess.ended = true; sess.total = tonumber(msg.total)
      if msg.start_epoch_ms then sess.start_ms = tonumber(msg.start_epoch_ms) end
      log("END total=", tostring(sess.total), " start_ms=", tostring(sess.start_ms))
      ensure_player_running()
    end

  elseif msg.cmd == "PAUSE" and sess and msg.sid == sess.sid then
    log("PAUSE"); sess.paused = true; hard_stop_audio(); ack(sender,"PAUSED",{sid=sess.sid,seq=sess.next_seq})

  elseif msg.cmd == "RESUME" and sess and msg.sid == sess.sid then
    log("RESUME at seq=", tostring(sess.next_seq)); sess.paused=false; os.queueEvent("speaker_audio_empty"); ack(sender,"RESUMED",{sid=sess.sid,seq=sess.next_seq})

  elseif msg.cmd == "STOP" then
    log("STOP"); hard_stop_audio(); sess = nil; ack(sender,"STOPPED")
  end

  ::cont::
end
