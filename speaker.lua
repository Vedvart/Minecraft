-- speaker.lua
-- Runs on each speaker computer. Caches audio from controller, then
-- plays/pauses/restarts in tight sync using start_at (epoch ms) targets.

local PROTOCOL = "ccsync_audio_v1"
local CACHE_DIR = "/music_cache"
local CACHE_FILE = fs.combine(CACHE_DIR, "track.dfpwm")

-- Peripherals
local spk = peripheral.find("speaker")
if not spk then error("No speaker attached.") end

local modem = peripheral.find("modem")
if not modem then error("No modem attached.") end
if not peripheral.call(peripheral.getName(modem), "isOpen", 0) then
  rednet.open(peripheral.getName(modem))
end

-- decoder
local dfpwm = require("cc.audio.dfpwm")

-- State
local playing = false
local playThread = nil
local wantStop = false
local currentOffset = 0 -- byte offset into file

-- Utility
local function now() return os.epoch("utc") end

local function safeStop()
  -- Stop speaker immediately (clear buffered audio)
  pcall(function() spk.stop() end)
  wantStop = true
  playing = false
  playThread = nil
end

local function roundDownToChunk(b, chunk)
  return math.floor(b / chunk) * chunk
end

-- Playback coroutine
local function makePlayer(startEpoch, offsetBytes)
  return coroutine.create(function()
    local chunkSize = 16*1024
    local fh = fs.open(CACHE_FILE, "rb")
    if not fh then
      -- no cache, can't play
      return
    end

    -- seek to requested offset (rounded to chunk for speed/consistency)
    local seekOffset = roundDownToChunk(offsetBytes or 0, chunkSize)
    fh.seek("set", seekOffset)
    currentOffset = seekOffset

    local decoder = dfpwm.make_decoder()

    -- wait until the scheduled start moment
    while now() < (startEpoch or now()) do
      os.pullEvent("timer") -- yield lightly until the time passes
    end

    playing = true
    wantStop = false

    while not wantStop do
      local enc = fh.read(chunkSize)
      if not enc then break end
      currentOffset = currentOffset + #enc

      local buf = decoder(enc)
      -- Push to speaker, block until buffer has room
      while not spk.playAudio(buf) do
        local ev = { os.pullEvent() }
        if ev[1] == "speaker_audio_empty" then
          -- ok keep looping
        elseif ev[1] == "rednet_message" then
          -- Let control messages preempt promptly
          local from, msg, proto = ev[2], ev[3], ev[4]
          if proto == PROTOCOL and type(msg)=="table" then
            if msg.type == "pause" then
              safeStop()
              fh.close()
              return
            elseif msg.type == "restart" then
              safeStop()
              fh.close()
              -- Controller will immediately follow with a play start, so exit
              return
            end
          end
        elseif ev[1] == "terminate" then
          fh.close(); return
        end
        if wantStop then fh.close(); return end
      end

      -- Let other events in; check pause/restart quickly
      local e = { os.pullEventRaw() }
      if e[1] == "rednet_message" then
        local from, msg, proto = e[2], e[3], e[4]
        if proto == PROTOCOL and type(msg)=="table" then
          if msg.type == "pause" then
            safeStop(); fh.close(); return
          elseif msg.type == "restart" then
            safeStop(); fh.close(); return
          end
        end
      elseif e[1] == "terminate" then
        fh.close(); return
      end
    end

    fh.close()
    playing = false
  end)
end

-- Respond to controller hello so we can be discovered
local function announce()
  rednet.broadcast({type="speaker_here"}, PROTOCOL)
end

-- Handle caching
local function handleCache()
  if not fs.exists(CACHE_DIR) then fs.makeDir(CACHE_DIR) end

  local name, expectSize, written, fh = nil, nil, 0, nil
  local timerId = nil

  while true do
    local ev = { os.pullEvent() }
    if ev[1]=="rednet_message" then
      local id,msg,proto = ev[2],ev[3],ev[4]
      if proto==PROTOCOL and type(msg)=="table" then
        if msg.type=="cache_begin" then
          name = msg.name or "track.dfpwm"
          expectSize = msg.size
          if fh then fh.close() end
          if fs.exists(CACHE_FILE) then fs.delete(CACHE_FILE) end
          fh = fs.open(CACHE_FILE, "wb")
          written = 0
          -- set a guard timer in case stream stalls
          if timerId then os.cancelTimer(timerId) end
          timerId = os.startTimer(10)
        elseif msg.type=="cache_chunk" and fh then
          fh.write(msg.data)
          written = written + #msg.data
          if timerId then os.cancelTimer(timerId) end
          timerId = os.startTimer(10)
        elseif msg.type=="cache_end" and fh then
          fh.close(); fh=nil
          if expectSize and fs.getSize(CACHE_FILE)==expectSize then
            rednet.send(ev[2], {type="cache_ok"}, PROTOCOL)
          else
            -- size mismatch; drop file
            if fs.exists(CACHE_FILE) then fs.delete(CACHE_FILE) end
          end
          timerId = nil
        elseif msg.type=="play" then
          -- Stop any current playback and start fresh at scheduled time
          safeStop()
          local startAt = msg.start_at or now()
          local off = msg.offset or 0
          playThread = makePlayer(startAt, off)
          if playThread then coroutine.resume(playThread) end
        elseif msg.type=="pause" then
          safeStop()
          -- keep currentOffset so controller can roughly align on resume
        elseif msg.type=="restart" then
          safeStop()
          local startAt = msg.start_at or now()
          playThread = makePlayer(startAt, 0)
          if playThread then coroutine.resume(playThread) end
        end
      end
    elseif ev[1]=="timer" and timerId and ev[2]==timerId then
      -- cache timeout
      if fh then fh.close(); fh=nil end
      timerId = nil
    elseif ev[1]=="terminate" then
      if fh then fh.close() end
      return
    end
  end
end

-- Start
announce()
-- also re-announce periodically so late controllers see us
local function announcer()
  while true do
    announce()
    os.sleep(2)
  end
end

parallel.waitForAny(announcer, handleCache)
