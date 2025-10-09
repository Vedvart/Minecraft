-- speaker.lua (full, with fixes)

local PROTOCOL = "ccsync_audio_v1"
local CACHE_DIR = "/music_cache"
local CACHE_FILE = fs.combine(CACHE_DIR, "track.dfpwm")

local spk = peripheral.find("speaker")
if not spk then error("No speaker attached.") end

local modem = peripheral.find("modem")
if not modem then error("No modem attached.") end
local modemName = peripheral.getName(modem)
if not rednet.isOpen(modemName) then rednet.open(modemName) end

local dfpwm = require("cc.audio.dfpwm")

local playing=false
local playThread=nil
local wantStop=false
local currentOffset=0

local function now() return os.epoch("utc") end
local function safeStop() pcall(function() spk.stop() end); wantStop=true; playing=false; playThread=nil end
local function roundDownToChunk(b, chunk) return math.floor(b/chunk)*chunk end

local function makePlayer(startEpoch, offsetBytes)
  return coroutine.create(function()
    local chunkSize=16*1024
    local fh=fs.open(CACHE_FILE,"rb"); if not fh then return end
    local seek=roundDownToChunk(offsetBytes or 0, chunkSize)
    fh.seek("set", seek); currentOffset=seek
    local decoder=dfpwm.make_decoder()
    while now() < (startEpoch or now()) do os.pullEvent("timer") end
    playing=true; wantStop=false
    while not wantStop do
      local enc=fh.read(chunkSize); if not enc then break end
      currentOffset=currentOffset + #enc
      local buf=decoder(enc)
      while not spk.playAudio(buf) do
        local ev={os.pullEvent()}
        if ev[1]=="speaker_audio_empty" then
        elseif ev[1]=="rednet_message" then
          local _,msg,proto=ev[2],ev[3],ev[4]
          if proto==PROTOCOL and type(msg)=="table" then
            if msg.type=="pause" or msg.type=="restart" then safeStop(); fh.close(); return end
          end
        elseif ev[1]=="terminate" then fh.close(); return end
        if wantStop then fh.close(); return end
      end
      local e={os.pullEventRaw()}
      if e[1]=="rednet_message" then
        local _,msg,proto=e[2],e[3],e[4]
        if proto==PROTOCOL and type(msg)=="table" then
          if msg.type=="pause" or msg.type=="restart" then safeStop(); fh.close(); return end
        end
      elseif e[1]=="terminate" then fh.close(); return end
    end
    fh.close(); playing=false
  end)
end

local function announce() rednet.broadcast({type="speaker_here"}, PROTOCOL) end

local function handleCache()
  if not fs.exists(CACHE_DIR) then fs.makeDir(CACHE_DIR) end
  local name,expectSize,written,fh=nil,nil,0,nil
  local timerId=nil
  while true do
    local ev={os.pullEvent()}
    if ev[1]=="rednet_message" then
      local id,msg,proto=ev[2],ev[3],ev[4]
      if proto==PROTOCOL and type(msg)=="table" then
        if msg.type=="cache_begin" then
          name=msg.name or "track.dfpwm"; expectSize=msg.size
          if fh then fh.close() end
          if fs.exists(CACHE_FILE) then fs.delete(CACHE_FILE) end
          fh=fs.open(CACHE_FILE,"wb"); written=0
          if timerId then os.cancelTimer(timerId) end; timerId=os.startTimer(10)
        elseif msg.type=="cache_chunk" and fh then
          fh.write(msg.data); written=written + #msg.data
          if timerId then os.cancelTimer(timerId) end; timerId=os.startTimer(10)
        elseif msg.type=="cache_end" and fh then
          fh.close(); fh=nil
          if expectSize and fs.getSize(CACHE_FILE)==expectSize then
            rednet.send(id, {type="cache_ok"}, PROTOCOL)
          else
            if fs.exists(CACHE_FILE) then fs.delete(CACHE_FILE) end
          end
          timerId=nil
        elseif msg.type=="play" then
          safeStop(); local startAt=msg.start_at or now(); local off=msg.offset or 0
          playThread=makePlayer(startAt, off); if playThread then coroutine.resume(playThread) end
        elseif msg.type=="pause" then
          safeStop()
        elseif msg.type=="restart" then
          safeStop(); local startAt=msg.start_at or now()
          playThread=makePlayer(startAt, 0); if playThread then coroutine.resume(playThread) end
        end
      end
    elseif ev[1]=="timer" and timerId and ev[2]==timerId then
      if fh then fh.close(); fh=nil end; timerId=nil
    elseif ev[1]=="terminate" then if fh then fh.close() end; return end
  end
end

local function announcer() while true do announce(); os.sleep(2) end end
announce(); parallel.waitForAny(announcer, handleCache)
