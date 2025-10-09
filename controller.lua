-- controller.lua
-- Controller with Advanced Monitor UI and rednet coordination
-- Requirements:
--  - Advanced monitor attached
--  - Modem attached & open
--  - Disk drive with file: "disk/music/track.dfpwm"
--  - Three (or more) speaker computers running speaker.lua on same rednet

-- ==== CONFIG ====
local PROTOCOL = "ccsync_audio_v1"
local SONG_TITLE = "title"
local DISK_PATH = "disk/music/track.dfpwm"
-- CC speakers (dfpwm) effectively use ~48kHz. DFPWM packs 8 samples/byte.
local SAMPLE_RATE = 48000
local BYTES_PER_SEC = math.floor(SAMPLE_RATE / 8 + 0.5)

-- ==== PERIPHERALS / REDNET ====
local mon = peripheral.find("monitor", function(_, p) return peripheral.getType(p) == "monitor" end)
if not mon then error("No monitor attached.") end
mon.setTextScale(0.5)
mon.setBackgroundColor(colors.black)
mon.clear()
mon.setCursorPos(1,1)

local modem = peripheral.find("modem", function(_, p) return peripheral.getType(p) == "modem" and peripheral.call(p,"isWireless") ~= nil end)
if not modem then modem = peripheral.find("modem") end
if not modem then error("No modem attached.") end
if not peripheral.call(peripheral.getName(modem), "isOpen", 0) then
  rednet.open(peripheral.getName(modem))
end

-- ==== LOAD FILE & METADATA ====
local f = fs.open(DISK_PATH, "rb")
if not f then error("Could not open "..DISK_PATH) end
local sizeBytes = fs.getSize(DISK_PATH)  -- cheaper than reading whole file
f.close()

local totalSamples = sizeBytes * 8
local totalSeconds = totalSamples / SAMPLE_RATE

-- ==== SPEAKER DISCOVERY / CACHE DISTRIBUTION ====
local function center(txt, w) txt = tostring(txt); if #txt >= w then return txt end local pad = math.floor((w - #txt)/2) return string.rep(" ", pad)..txt end

local function blitBox(x, y, w, h, bg)
  mon.setBackgroundColor(bg)
  for i = 0, h-1 do
    mon.setCursorPos(x, y+i)
    mon.write(string.rep(" ", w))
  end
end

local function drawText(x, y, txt, fg, bg)
  mon.setTextColor(fg or colors.white)
  if bg then mon.setBackgroundColor(bg) end
  mon.setCursorPos(x, y)
  mon.write(txt)
end

local w,h = mon.getSize()

local ui = {
  headerY = 1,
  buttonsY = 4,
  progressY = 8,
  btnW = 12,
  btnH = 3,
  gap = 2,
  playRect = nil,
  restartRect = nil
}

local function rectContains(rect, x, y)
  return x >= rect.x and x <= rect.x+rect.w-1 and y >= rect.y and y <= rect.y+rect.h-1
end

local function drawUI(state)
  mon.setBackgroundColor(colors.black); mon.clear()
  -- Title
  drawText(1, ui.headerY, center(SONG_TITLE, w), colors.white, colors.black)

  -- Buttons: [ Play/Pause ] [ Restart ]
  local totalBtnW = ui.btnW*2 + ui.gap
  local startX = math.floor((w - totalBtnW)/2)+1
  local btnY = ui.buttonsY

  -- Play/Pause button
  blitBox(startX, btnY, ui.btnW, ui.btnH, colors.gray)
  drawText(startX + math.floor((ui.btnW- (#(state.playing and "Pause" or "Play")))/2),
           btnY + 1, state.playing and "Pause" or "Play", colors.black, colors.gray)
  ui.playRect = {x=startX, y=btnY, w=ui.btnW, h=ui.btnH}

  -- Restart button
  local rx = startX + ui.btnW + ui.gap
  blitBox(rx, btnY, ui.btnW, ui.btnH, colors.gray)
  drawText(rx + math.floor((ui.btnW- #("Restart"))/2), btnY + 1, "Restart", colors.black, colors.gray)
  ui.restartRect = {x=rx, y=btnY, w=ui.btnW, h=ui.btnH}

  -- Progress bar background
  drawText(2, ui.progressY-1, ("0:00 / %d:%02d"):format(math.floor(totalSeconds/60), math.floor(totalSeconds%60)), colors.lightGray, colors.black)
  blitBox(2, ui.progressY, w-2, 1, colors.lightGray)
  -- Foreground progress filled based on state.offsetBytes
  local frac = 0
  if state.offsetBytes and sizeBytes > 0 then
    frac = math.max(0, math.min(1, state.offsetBytes / sizeBytes))
  end
  local filled = math.max(0, math.min(w-2, math.floor((w-2) * frac)))
  if filled > 0 then
    blitBox(2, ui.progressY, filled, 1, colors.lime)
  end

  -- Current time
  local curSec = math.floor(((state.offsetBytes or 0) * 8) / SAMPLE_RATE + 0.5)
  drawText(w-10, ui.progressY-1, ("%d:%02d"):format(math.floor(curSec/60), curSec%60), colors.white, colors.black)
end

-- Track speaker list & file caching
local speakers = {}   -- [id] = true
local cached = {}     -- [id] = true when their local file is cached

local function discoverSpeakers()
  speakers = {}
  cached = {}
  rednet.broadcast({type="hello"}, PROTOCOL)
  local t = os.startTimer(0.5)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local id, msg, proto = ev[2], ev[3], ev[4]
      if proto == PROTOCOL and type(msg)=="table" and msg.type=="speaker_here" then
        speakers[id] = true
      end
    elseif ev[1] == "timer" and ev[2]==t then
      break
    end
  end
end

local function sendFileTo(id)
  -- send small framed chunks so we don't blow out buffers
  local path = DISK_PATH
  local fh = fs.open(path, "rb")
  if not fh then return false, "file open fail" end

  rednet.send(id, {type="cache_begin", name="track.dfpwm", size=sizeBytes}, PROTOCOL)

  local chunkSize = 16*1024
  local sent = 0
  while true do
    local chunk = fh.read(chunkSize)
    if not chunk then break end
    rednet.send(id, {type="cache_chunk", data=chunk}, PROTOCOL)
    sent = sent + #chunk
    -- yield to keep UI responsive
    os.sleep(0)
  end
  fh.close()
  rednet.send(id, {type="cache_end"}, PROTOCOL)

  -- wait for ack
  local ok = false
  local t = os.startTimer(5)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "rednet_message" then
      local from, msg, proto = ev[2], ev[3], ev[4]
      if from==id and proto==PROTOCOL and type(msg)=="table" and msg.type=="cache_ok" then
        ok = true; break
      end
    elseif ev[1]=="timer" and ev[2]==t then
      break
    end
  end
  return ok
end

local function ensureAllCached()
  for id,_ in pairs(speakers) do
    if not cached[id] then
      local ok = sendFileTo(id)
      cached[id] = ok or nil
    end
  end
end

-- ==== PLAYBACK STATE ====
local state = {
  playing = false,
  -- offsetBytes = current intended playback offset in file (controller-side source of truth)
  offsetBytes = 0,
  -- When playing, we advance offset by elapsed * BYTES_PER_SEC
  lastPlayEpoch = nil,  -- os.epoch("utc") when play started/resumed
}

local function now() return os.epoch("utc") end

local function clampOffset(bytes)
  if bytes < 0 then return 0 end
  if bytes > sizeBytes then return sizeBytes end
  return bytes
end

local function currentOffsetBytes()
  if not state.playing or not state.lastPlayEpoch then
    return clampOffset(state.offsetBytes)
  end
  local elapsed_ms = now() - state.lastPlayEpoch
  local adv = math.floor((elapsed_ms/1000) * BYTES_PER_SEC + 0.5)
  return clampOffset(state.offsetBytes + adv)
end

local function broadcast(msg)
  for id,_ in pairs(speakers) do
    rednet.send(id, msg, PROTOCOL)
  end
end

-- Schedule a start exactly 1 tick after the click (target ~50ms from now).
-- Using epoch time ensures all speakers align, regardless of message arrival tick.
local function scheduleStart(atEpochMs, offsetBytes)
  broadcast({type="play", start_at=atEpochMs, offset=offsetBytes})
end

local function commandPause()
  broadcast({type="pause"})
end

local function commandRestart(atEpochMs)
  broadcast({type="restart", start_at=atEpochMs})
end

-- ==== MAIN UI LOOP ====
local function updateUI()
  -- keep state.offsetBytes coherent while playing
  if state.playing then
    local co = currentOffsetBytes()
    state.offsetBytes = co
    state.lastPlayEpoch = now() -- reset baseline so we don’t double-advance
  end
  drawUI(state)
end

local function handleMonitorTouch(x, y)
  if ui.playRect and rectContains(ui.playRect, x, y) then
    if state.playing then
      -- Pause: compute current offset precisely, pause speakers, update state
      state.offsetBytes = currentOffsetBytes()
      state.playing = false
      state.lastPlayEpoch = nil
      commandPause()
    else
      -- First play or resume
      ensureAllCached()
      local startAt = now() + 50 -- 1 tick ~ 50 ms
      local offset = clampOffset(state.offsetBytes)
      scheduleStart(startAt, offset)
      -- set state to playing from offset
      state.playing = true
      state.lastPlayEpoch = now()
    end
    updateUI()
  elseif ui.restartRect and rectContains(ui.restartRect, x, y) then
    -- Restart from beginning
    state.offsetBytes = 0
    local startAt = now() + 50
    commandRestart(startAt)
    state.playing = true
    state.lastPlayEpoch = now()
    updateUI()
  end
end

-- Initial discover + cache (non-blocking-ish; we’ll also cache lazily on first play)
discoverSpeakers()

-- UI draw once
updateUI()

-- Event loop
while true do
  local e = { os.pullEvent() }
  if e[1] == "monitor_touch" then
    local _, side, x, y = table.unpack(e)
    handleMonitorTouch(x, y)
  elseif e[1] == "timer" then
    -- noop
  elseif e[1] == "rednet_message" then
    -- track speaker acks/hello to keep 'cached' up to date
    local id, msg, proto = e[2], e[3], e[4]
    if proto == PROTOCOL and type(msg) == "table" then
      if msg.type == "speaker_here" then
        speakers[id] = true
      elseif msg.type == "cache_ok" then
        cached[id] = true
      end
    end
  end

  -- refresh progress bar ~10x/sec without spamming
  updateUI()
  os.sleep(0.1)
end
