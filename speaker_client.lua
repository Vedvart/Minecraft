-- speaker_client_stream.lua
-- Streaming client with PAUSE/RESUME, slight prebuffer tweak for tighter sync.

local PROTOCOL = "ccaudio_sync_v1"
local CHUNK_REQUEST_INTERVAL = 0.25
local PREBUFFER_TARGET = 14 -- a bit more prebuffer helps sync on busy nets

local function openAnyModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end

openAnyModem()
assert(rednet.isOpen(), "No modem found/opened. Attach/open a (wired) modem.")

local speaker = peripheral.find("speaker")
assert(speaker, "No speaker attached to this computer.")
local dfpwm = require("cc.audio.dfpwm")

local sess = nil
local function reset_session() sess = nil end
local function begin_session(sid, controller_id, start_ms, volume)
  sess = {
    sid=sid, controller_id=controller_id,
    start_ms=assert(tonumber(start_ms), "bad start"),
    volume=tonumber(volume) or 1.0,
    buffer={}, next_seq=1, paused=false, last_nack_time=0,
    ended=false, total=nil,
  }
end

local function send(to, tbl) if to then rednet.send(to, tbl, PROTOCOL) end end
local function ack(sender, cmd, extra)
  local t={cmd=cmd,id=os.getComputerID()}; if extra then for k,v in pairs(extra) do t[k]=v end end
  send(sender,t)
end

local function time_ms() return os.epoch("utc") end
local function wait_until(ms) while os.epoch("utc") < ms do sleep(0.005) end end

local function play_loop()
  -- Optional prebuffer until start time (helps even more if controller starts early)
  while sess and time_ms() + 50 < sess.start_ms do
    local have = 0; for _ in pairs(sess.buffer) do have = have + 1 end
    if have >= PREBUFFER_TARGET then break end
    sleep(0.02)
  end

  wait_until(sess.start_ms)

  local decoder = dfpwm.make_decoder()
  while sess and (not sess.ended or (sess.total and sess.next_seq <= sess.total)) do
    if sess.paused then
      -- pause: just wait for commands
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
        if not sess or sess.paused then goto continue end
        sess.buffer[sess.next_seq] = nil
        sess.next_seq = sess.next_seq + 1
      else
        local now = os.clock()
        if now - (sess.last_nack_time or 0) >= CHUNK_REQUEST_INTERVAL then
          send(sess.controller_id, { cmd="NACK", sid=sess.sid, seq=sess.next_seq })
          sess.last_nack_time = now
        end
        os.pullEventTimeout("rednet_message", 0.1)
      end
    end
    ::continue::
  end
  if sess then ack(sess.controller_id, "RESULT", { ok=true, info="Done" }) end
  reset_session()
end

print("Speaker client (stream) ready. Waiting for controller…")

while true do
  local sender, msg, proto = rednet.receive(PROTOCOL)
  if proto ~= PROTOCOL or type(msg) ~= "table" then goto cont end

  if msg.cmd == "PING" then
    ack(sender,"PONG",{label=os.getComputerLabel()})

  elseif msg.cmd == "STOP" then
    reset_session(); os.queueEvent("speaker_audio_empty"); ack(sender,"STOPPED")

  elseif msg.cmd == "PREP" then
    reset_session()
    begin_session(msg.sid, sender, msg.start_epoch_ms, msg.volume or 1.0)
    ack(sender,"READY",{sid=msg.sid})

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
      os.queueEvent("speaker_audio_empty")
      ack(sender,"PAUSED",{sid=sess.sid,seq=sess.next_seq})
    end

  elseif msg.cmd == "RESUME" then
    if sess and msg.sid==sess.sid then
      sess.paused = false
      if msg.start_epoch_ms then wait_until(tonumber(msg.start_epoch_ms)) end
      os.queueEvent("speaker_audio_empty")
      ack(sender,"RESUMED",{sid=sess.sid,seq=sess.next_seq})
    end
  end
  ::cont::
end
