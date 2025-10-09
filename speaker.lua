-- speaker_client_stream.lua  (1-tick control)
-- Fast-reacting streaming client with instant pause via speaker.stop().

local PROTOCOL = "ccaudio_sync_v1"
local CHUNK_REQUEST_INTERVAL = 0.10 -- quicker re-requests
local PREBUFFER_TARGET = 1          -- start once we have 1 chunk
local IDLE_WAIT = 0.02              -- small wait when missing a chunk

-- Open any modem
local function openAnyModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end
openAnyModem(); assert(rednet.isOpen(), "No modem open")

-- Find speaker + decoder
local speaker = peripheral.find("speaker")
assert(speaker, "No speaker attached")
local dfpwm = require("cc.audio.dfpwm")

-- Session state
local sess = nil
-- sess = { sid, controller_id, start_ms, volume, buffer[seq]=data, next_seq, ended, total, paused, last_nack_time }

local function reset_session() sess = nil end
local function begin_session(sid, controller_id, start_ms, volume)
  sess = {
    sid=sid, controller_id=controller_id,
    start_ms=tonumber(start_ms) or 0, volume=tonumber(volume) or 1.0,
    buffer={}, next_seq=1, ended=false, total=nil, paused=false,
    last_nack_time=0
  }
end

local function send(to, msg) if to then rednet.send(to, msg, PROTOCOL) end end
local function ack(to, cmd, extra)
  local t={cmd=cmd, id=os.getComputerID()}; if extra then for k,v in pairs(extra) do t[k]=v end end
  send(to, t)
end

local function now_ms() return os.epoch("utc") end
local function wait_until(ms) while now_ms() < ms do sleep(0.005) end end

local function hard_stop_audio()
  if speaker.stop then pcall(function() speaker.stop() end) end
  os.queueEvent("speaker_audio_empty") -- nudge any waiters
end

local function play_loop()
  -- Minimal prebuffer & start alignment (1 tick arm by controller)
  while sess and (now_ms() + 1 < sess.start_ms) do sleep(0.005) end
  -- Also ensure at least one chunk available if time already reached
  while sess and now_ms() >= sess.start_ms do
    local have = sess.buffer[sess.next_seq] ~= nil
    if have then break end
    os.pullEventTimeout("rednet_message", IDLE_WAIT)
  end

  local decoder = dfpwm.make_decoder()

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
          elseif not sess or sess.paused then break end
        end
        if not sess or sess.paused then goto cont end
        sess.buffer[sess.next_seq] = nil
        sess.next_seq = sess.next_seq + 1
      else
        local nowc = os.clock()
        if nowc - (sess.last_nack_time or 0) >= CHUNK_REQUEST_INTERVAL then
          send(sess.controller_id, { cmd="NACK", sid=sess.sid, seq=sess.next_seq })
          sess.last_nack_time = nowc
        end
        os.pullEventTimeout("rednet_message", IDLE_WAIT)
      end
    end
    ::cont::
  end

  if sess then ack(sess.controller_id, "RESULT", { ok=true, info="Done" }) end
  reset_session()
end

print("Speaker client ready (1-tick controls).")

-- Main listener
while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto ~= PROTOCOL or type(msg) ~= "table" then goto cont end

  if msg.cmd == "PING" then
    ack(sender, "PONG", { label=os.getComputerLabel() })

  elseif msg.cmd == "PREP" then
    reset_session()
    begin_session(msg.sid, sender, msg.start_epoch_ms, msg.volume or 1.0)
    ack(sender, "READY", { sid=msg.sid })

  elseif msg.cmd == "CHUNK" then
    if sess and msg.sid==sess.sid and type(msg.seq)=="number" and type(msg.data)=="string" then
      sess.buffer[msg.seq] = msg.data
    end

  elseif msg.cmd == "END" then
    if sess and msg.sid==sess.sid then
      sess.ended = true; sess.total = tonumber(msg.total)
      if msg.start_epoch_ms then sess.start_ms = tonumber(msg.start_epoch_ms) end
      play_loop()
    end

  elseif msg.cmd == "PAUSE" then
    if sess and msg.sid==sess.sid then
      sess.paused = true
      hard_stop_audio() -- immediate; clears speaker buffer
      ack(sender, "PAUSED", { sid=sess.sid, seq=sess.next_seq })
    end

  elseif msg.cmd == "RESUME" then
    if sess and msg.sid==sess.sid then
      sess.paused = false -- resume immediately next tick
      os.queueEvent("speaker_audio_empty")
      ack(sender, "RESUMED", { sid=sess.sid, seq=sess.next_seq })
    end

  elseif msg.cmd == "STOP" then
    hard_stop_audio(); reset_session(); ack(sender, "STOPPED")
  end

  ::cont::
end
