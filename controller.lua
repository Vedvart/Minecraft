-- controller.lua (full, with fixes applied)

local PROTOCOL = "ccsync_audio_v1"
local SONG_TITLE = "title"
local DISK_PATH  = "disk/music/track.dfpwm"
local SAMPLE_RATE = 48000
local BYTES_PER_SEC = math.floor(SAMPLE_RATE / 8 + 0.5)

local mon = peripheral.find("monitor")
if not mon then error("No monitor attached.") end
mon.setTextScale(0.5)
mon.setBackgroundColor(colors.black)
mon.clear()
mon.setCursorPos(1,1)

local modem = peripheral.find("modem")
if not modem then error("No modem attached.") end
local modemName = peripheral.getName(modem)
if not rednet.isOpen(modemName) then rednet.open(modemName) end

local sizeBytes = fs.getSize(DISK_PATH)
local totalSamples = sizeBytes * 8
local totalSeconds = totalSamples / SAMPLE_RATE

local function center(txt, w) txt = tostring(txt); if #txt >= w then return txt end local pad = math.floor((w - #txt)/2) return string.rep(" ", pad)..txt end
local function blitBox(x, y, w, h, bg) mon.setBackgroundColor(bg) for i = 0, h-1 do mon.setCursorPos(x, y+i) mon.write(string.rep(" ", w)) end end
local function drawText(x, y, txt, fg, bg) mon.setTextColor(fg or colors.white) if bg then mon.setBackgroundColor(bg) end mon.setCursorPos(x, y) mon.write(txt) end

local w,h = mon.getSize()
local ui = { headerY=1, buttonsY=4, progressY=8, btnW=12, btnH=3, gap=2, playRect=nil, restartRect=nil }
local function rectContains(r, x, y) return x>=r.x and x<=r.x+r.w-1 and y>=r.y and y<=r.y+r.h-1 end

local function drawUI(state)
  mon.setBackgroundColor(colors.black); mon.clear()
  drawText(1, ui.headerY, center(SONG_TITLE, w), colors.white, colors.black)
  local totalBtnW = ui.btnW*2 + ui.gap
  local startX = math.floor((w - totalBtnW)/2)+1
  local btnY = ui.buttonsY

  blitBox(startX, btnY, ui.btnW, ui.btnH, colors.gray)
  drawText(startX + math.floor((ui.btnW- (#(state.playing and "Pause" or "Play")))/2),
           btnY + 1, state.playing and "Pause" or "Play", colors.black, colors.gray)
  ui.playRect = {x=startX, y=btnY, w=ui.btnW, h=ui.btnH}

  local rx = startX + ui.btnW + ui.gap
  blitBox(rx, btnY, ui.btnW, ui.btnH, colors.gray)
  drawText(rx + math.floor((ui.btnW- #("Restart"))/2), btnY + 1, "Restart", colors.black, colors.gray)
  ui.restartRect = {x=rx, y=btnY, w=ui.btnW, h=ui.btnH}

  drawText(2, ui.progressY-1, ("0:00 / %d:%02d"):format(math.floor(totalSeconds/60), math.floor(totalSeconds%60)), colors.lightGray, colors.black)
  blitBox(2, ui.progressY, w-2, 1, colors.lightGray)
  local frac = (state.offsetBytes or 0) / sizeBytes
  frac = math.max(0, math.min(1, frac))
  local filled = math.max(0, math.min(w-2, math.floor((w-2) * frac)))
  if filled > 0 then blitBox(2, ui.progressY, filled, 1, colors.lime) end
  local curSec = math.floor(((state.offsetBytes or 0) * 8) / SAMPLE_RATE + 0.5)
  drawText(w-10, ui.progressY-1, ("%d:%02d"):format(math.floor(curSec/60), curSec%60), colors.white, colors.black)
end

local speakers, cached = {}, {}
local function discoverSpeakers()
  speakers, cached = {}, {}
  rednet.broadcast({type="hello"}, PROTOCOL)
  local t = os.startTimer(0.5)
  while true do
    local ev = { os.pullEvent() }
    if ev[1]=="rednet_message" then
      local id,msg,proto = ev[2],ev[3],ev[4]
      if proto==PROTOCOL and type(msg)=="table" and msg.type=="speaker_here" then speakers[id]=true end
    elseif ev[1]=="timer" and ev[2]==t then break end
  end
end

local function sendFileTo(id)
  local fh = fs.open(DISK_PATH, "rb")
  if not fh then return false end
  rednet.send(id, {type="cache_begin", name="track.dfpwm", size=sizeBytes}, PROTOCOL)
  local chunkSize = 16*1024
  while true do
    local chunk = fh.read(chunkSize)
    if not chunk then break end
    rednet.send(id, {type="cache_chunk", data=chunk}, PROTOCOL)
    os.sleep(0)
  end
  fh.close()
  rednet.send(id, {type="cache_end"}, PROTOCOL)
  local ok=false; local t=os.startTimer(5)
  while true do
    local e={os.pullEvent()}
    if e[1]=="rednet_message" then
      local from,msg,proto=e[2],e[3],e[4]
      if from==id and proto==PROTOCOL and type(msg)=="table" and msg.type=="cache_ok" then ok=true; break end
    elseif e[1]=="timer" and e[2]==t then break end
  end
  return ok
end

local function ensureAllCached() for id in pairs(speakers) do if not cached[id] then cached[id]=sendFileTo(id) or nil end end end
local state = { playing=false, offsetBytes=0, lastPlayEpoch=nil }
local function now() return os.epoch("utc") end
local function clampOffset(b) return math.max(0, math.min(b, sizeBytes)) end
local function currentOffsetBytes()
  if not state.playing or not state.lastPlayEpoch then return clampOffset(state.offsetBytes) end
  local adv = math.floor(((now()-state.lastPlayEpoch)/1000) * BYTES_PER_SEC + 0.5)
  return clampOffset(state.offsetBytes + adv)
end
local function broadcast(msg) for id in pairs(speakers) do rednet.send(id, msg, PROTOCOL) end end
local function scheduleStart(atMs, off) broadcast({type="play", start_at=atMs, offset=off}) end
local function commandPause() broadcast({type="pause"}) end
local function commandRestart(atMs) broadcast({type="restart", start_at=atMs}) end

local function updateUI()
  if state.playing then
    state.offsetBytes = currentOffsetBytes()
    state.lastPlayEpoch = now()
  end
  drawUI(state)
end

local function handleMonitorTouch(x,y)
  if ui.playRect and x>=ui.playRect.x and x<=ui.playRect.x+ui.playRect.w-1 and y>=ui.playRect.y and y<=ui.playRect.y+ui.playRect.h-1 then
    if state.playing then
      state.offsetBytes = currentOffsetBytes()
      state.playing=false; state.lastPlayEpoch=nil
      commandPause()
    else
      ensureAllCached()
      local startAt = now() + 50
      local offset = clampOffset(state.offsetBytes)
      scheduleStart(startAt, offset)
      state.playing=true; state.lastPlayEpoch=now()
    end
    updateUI()
  elseif ui.restartRect and x>=ui.restartRect.x and x<=ui.restartRect.x+ui.restartRect.w-1 and y>=ui.restartRect.y and y<=ui.restartRect.y+ui.restartRect.h-1 then
    state.offsetBytes=0
    local startAt=now()+50
    commandRestart(startAt)
    state.playing=true; state.lastPlayEpoch=now()
    updateUI()
  end
end

discoverSpeakers()
updateUI()
while true do
  local e={os.pullEvent()}
  if e[1]=="monitor_touch" then local _,side,x,y=table.unpack(e) handleMonitorTouch(x,y)
  elseif e[1]=="rednet_message" then
    local id,msg,proto=e[2],e[3],e[4]
    if proto==PROTOCOL and type(msg)=="table" then
      if msg.type=="speaker_here" then speakers[id]=true
      elseif msg.type=="cache_ok" then cached[id]=true end
    end
  end
  updateUI(); os.sleep(0.1)
end
