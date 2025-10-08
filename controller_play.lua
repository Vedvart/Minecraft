-- jukebox_monitor.lua (fixed)
-- Advanced monitor UI + non-blocking streamer + pause/resume/restart + live progress.

-- ========= Config =========
local PROTOCOL      = "ccaudio_sync_v1"
local DEFAULT_DELAY = 4000            -- time for clients to prebuffer
local CHUNK_BYTES   = 8192
local TRACK_PATH    = "/disk/music/track.dfpwm"
local VOLUME        = 1.0
-- ==========================

-- Utils
local function openAnyModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then rednet.open(side) end
    end
  end
end

local function findMonitor()
  local mon = peripheral.find("monitor")
  assert(mon, "No monitor attached.")
  assert(mon.isColor and mon.isColor(), "Need an ADVANCED monitor.")
  mon.setTextScale(0.5)
  return mon
end

local function findDrive()
  local drv = peripheral.find("drive")
  assert(drv, "No disk drive attached.")
  return drv
end

local function fmt_time(s) s=math.max(0,math.floor(s+0.5)); return ("%d:%02d"):format(math.floor(s/60), s%60) end
local function basename(p) p=tostring(p):gsub("[/\\]+$",""); return p:match("([^/\\]+)$") or p end
local function now_ms() return os.epoch("utc") end

-- UI helper
local UI = {}
function UI.new(mon)
  local o = { mon=mon, w=0, h=0, buttons={} }
  function o:resize() self.w,self.h = self.mon.getSize() end
  function o:clear() self.mon.setBackgroundColor(colors.black); self.mon.clear() end
  function o:btn(id,label,x,y,w,h,active)
    self.buttons[id]={x=x,y=y,w=w,h=h}
    self.mon.setBackgroundColor(active and colors.lime or colors.gray)
    self.mon.setTextColor(colors.black)
    for yy=y,y+h-1 do self.mon.setCursorPos(x,yy); self.mon.write((" "):rep(w)) end
    self.mon.setCursorPos(x+math.floor((w-#label)/2), y+math.floor(h/2))
    self.mon.write(label)
    self.mon.setBackgroundColor(colors.black); self.mon.setTextColor(colors.white)
  end
  function o:bar(x,y,w,value)
    value=math.max(0,math.min(1,value or 0))
    local fill = math.floor(w*value+0.5)
    self.mon.setCursorPos(x,y); self.mon.setBackgroundColor(colors.gray); self.mon.write((" "):rep(w))
    self.mon.setCursorPos(x,y); self.mon.setBackgroundColor(colors.lightBlue); if fill>0 then self.mon.write((" "):rep(fill)) end
    self.mon.setBackgroundColor(colors.black)
  end
  function o:text(x,y,msg,fg,bg)
    if bg then self.mon.setBackgroundColor(bg) end
    if fg then self.mon.setTextColor(fg) end
    self.mon.setCursorPos(x,y); self.mon.write(msg)
    self.mon.setTextColor(colors.white); self.mon.setBackgroundColor(colors.black)
  end
  function o:hit(x,y)
    for id,b in pairs(self.buttons) do
      if x>=b.x and y>=b.y and x<b.x+b.w and y<b.y+b.h then return id end
    end
  end
  o:resize(); return o
end

-- Networking
local function broadcast(msg) rednet.broadcast(msg, PROTOCOL) end

-- State
local mon     = findMonitor()
local drive   = findDrive()
openAnyModem(); assert(rednet.isOpen(), "No modem opened.")

local ui      = UI.new(mon)
local chunks  = {}
local fileLen = 0
local durationSec = 0
local title   = "Unknown"

local playing = false
local paused  = false
local sid     = nil
local start_ms = 0
local pause_accum = 0
local pause_started = 0

-- streamer thread handle
local streamer_thread = nil

-- Load/Title
local function loadTrack()
  assert(fs.exists(TRACK_PATH), "Track not found: "..TRACK_PATH)
  chunks = {}
  fileLen = fs.getSize(TRACK_PATH)
  durationSec = (fileLen * 8) / 48000
  local fh = fs.open(TRACK_PATH, "rb")
  while true do
    local data = fh.read(CHUNK_BYTES)
    if not data then break end
    chunks[#chunks+1] = data
  end
  fh.close()
end

local function readTitle()
  local label = drive.getDiskLabel and drive.getDiskLabel() or nil
  title = (label and #label>0) and label or basename(TRACK_PATH)
end

-- Playhead (controller-side estimate)
local function playhead_sec()
  if not playing then return 0 end
  local base
  if paused then base = (pause_started - start_ms - pause_accum)
  else base = (now_ms() - start_ms - pause_accum) end
  return math.max(0, base/1000)
end

-- UI drawing
local function redraw()
  ui:resize(); ui:clear()
  local w,h=ui.w,ui.h
  ui:text(2,2,"Now Playing:",colors.yellow)
  ui:text(2,3,title,colors.white)
  local playLabel = paused and "Resume" or (playing and "Pause" or "Play")
  ui:btn("playpause", playLabel, 2,5,10,3, playing and not paused)
  ui:btn("restart", "Restart", 14,5,10,3, false)
  local elapsed = math.min(playhead_sec(), durationSec)
  local pct = durationSec>0 and (elapsed/durationSec) or 0
  ui:text(2,9,("[%s / %s]"):format(fmt_time(elapsed), fmt_time(durationSec)), colors.white)
  ui:bar(2,10,w-3,pct)
end

local function new_sid() return tostring(now_ms()).."-"..tostring(math.random(1000,9999)) end

-- Streamer: ONLY sends CHUNKs/END and yields with sleep(0). No event pulling here.
local function start_streamer(current_sid, current_start_ms)
  streamer_thread = coroutine.create(function()
    -- Push chunks
    for i=1,#chunks do
      broadcast({ cmd="CHUNK", sid=current_sid, seq=i, data=chunks[i] })
      sleep(0) -- yield but don't eat events
    end
    -- Tell clients total & the agreed start time
    broadcast({ cmd="END", sid=current_sid, total=#chunks, start_epoch_ms=current_start_ms })
    -- Done; thread exits.
  end)
  coroutine.resume(streamer_thread)
end

-- Control ops
local function do_start()
  loadTrack(); readTitle()
  paused=false; pause_accum=0; pause_started=0
  sid = new_sid()
  start_ms = now_ms() + DEFAULT_DELAY
  playing=true

  -- Tell clients to prep
  broadcast({ cmd="PREP", sid=sid, start_epoch_ms=start_ms, volume=VOLUME, name=title })

  -- Kick off the streamer (independent coroutine)
  start_streamer(sid, start_ms)
end

local function do_toggle_pause()
  if not playing then do_start(); redraw(); return end
  if not paused then
    paused=true; pause_started = now_ms()
    broadcast({ cmd="PAUSE", sid=sid })
  else
    pause_accum = pause_accum + (now_ms() - pause_started)
    paused=false
    local resume_at = now_ms() + 1200
    broadcast({ cmd="RESUME", sid=sid, start_epoch_ms=resume_at })
  end
end

local function do_restart()
  broadcast({ cmd="STOP" }) -- clear any current playback
  playing=false; paused=false; sid=nil
  do_start()
end

-- Main
local function main()
  term.redirect(mon); term.setCursorBlink(false)
  loadTrack(); readTitle(); redraw()

  local refresh = os.startTimer(0.1)

  while true do
    -- If streamer is alive, keep it running
    if streamer_thread and coroutine.status(streamer_thread) == "suspended" then
      coroutine.resume(streamer_thread)
    end

    local e = { os.pullEvent() }

    if e[1]=="monitor_touch" then
      local _,_,x,y = table.unpack(e)
      local id = ui:hit(x,y)
      if id=="playpause" then do_toggle_pause(); redraw()
      elseif id=="restart" then do_restart(); redraw()
      end

    elseif e[1]=="disk" or e[1]=="disk_eject" then
      if TRACK_PATH:match("^/disk/") and fs.exists(TRACK_PATH) then
        loadTrack(); readTitle(); redraw()
      end

    elseif e[1]=="timer" and e[2]==refresh then
      redraw()
      refresh = os.startTimer( playing and 0.1 or 0.25 )

    elseif e[1]=="rednet_message" and e[4]==PROTOCOL then
      -- Handle NACKs here so the streamer never pulls events
      local sender,msg = e[2],e[3]
      if type(msg)=="table" and msg.cmd=="NACK" and msg.sid==sid then
        local seq = tonumber(msg.seq or -1)
        if seq and chunks[seq] then rednet.send(sender, { cmd="CHUNK", sid=sid, seq=seq, data=chunks[seq] }, PROTOCOL) end
      end
    end
  end
end

print("Controller UI ready. Touch Play/Pause or Restart.")
main()
