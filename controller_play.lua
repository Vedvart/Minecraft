-- jukebox_monitor.lua
-- Touch UI on an ADVANCED MONITOR to control streaming, pause/resume, restart,
-- and show a live progress bar based on DFPWM length estimate.

-- ========= Config =========
local PROTOCOL = "ccaudio_sync_v1"
local DEFAULT_DELAY = 2500           -- ms before (re)starts
local CHUNK_BYTES = 8192             -- keep under rednet payload limits
local TRACK_PATH = "/disk/music/track.dfpwm"  -- change if needed
-- ==========================

-- --- Helpers ---
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
  mon.setTextScale(0.5) -- more room
  return mon
end

local function findDrive()
  local drv = peripheral.find("drive")
  assert(drv, "No disk drive attached.")
  return drv
end

local function fmt_time(s)
  s = math.max(0, math.floor(s + 0.5))
  local m = math.floor(s / 60)
  local ss = s % 60
  return ("%d:%02d"):format(m, ss)
end

local function basename(p)
  p = tostring(p):gsub("[/\\]+$", "")
  return p:match("([^/\\]+)$") or p
end

-- UI drawing (simple immediate mode)
local UI = {}
function UI.new(mon)
  local o = { mon = mon, w=0, h=0, buttons = {} }
  function o:resize()
    self.w, self.h = self.mon.getSize()
  end
  function o:clear()
    self.mon.setBackgroundColor(colors.black)
    self.mon.clear()
  end
  function o:btn(id, label, x, y, w, h, active)
    self.buttons[id] = {x=x,y=y,w=w,h=h}
    self.mon.setBackgroundColor(active and colors.lime or colors.gray)
    self.mon.setTextColor(colors.black)
    for yy=y, y+h-1 do
      self.mon.setCursorPos(x, yy)
      self.mon.write((" "):rep(w))
    end
    local cx = x + math.floor((w - #label)/2)
    local cy = y + math.floor(h/2)
    self.mon.setCursorPos(cx, cy)
    self.mon.write(label)
    self.mon.setBackgroundColor(colors.black)
  end
  function o:bar(x, y, w, value) -- 0..1
    value = math.max(0, math.min(1, value or 0))
    local fill = math.floor(w * value + 0.5)
    self.mon.setCursorPos(x, y)
    self.mon.setBackgroundColor(colors.gray)
    self.mon.write((" "):rep(w))
    self.mon.setCursorPos(x, y)
    self.mon.setBackgroundColor(colors.lightBlue)
    if fill > 0 then self.mon.write((" "):rep(fill)) end
    self.mon.setBackgroundColor(colors.black)
  end
  function o:text(x, y, msg, fg, bg)
    if bg then self.mon.setBackgroundColor(bg) end
    if fg then self.mon.setTextColor(fg) end
    self.mon.setCursorPos(x, y)
    self.mon.write(msg)
    self.mon.setTextColor(colors.white)
    self.mon.setBackgroundColor(colors.black)
  end
  function o:hit(x, y)
    for id,b in pairs(self.buttons) do
      if x>=b.x and y>=b.y and x<b.x+b.w and y<b.y+b.h then return id end
    end
  end
  o:resize()
  return o
end

-- Networking
local function count(tbl) local c=0 for _ in pairs(tbl) do c=c+1 end return c end
local function broadcast(msg) rednet.broadcast(msg, PROTOCOL) end
local function send(to, msg) rednet.send(to, msg, PROTOCOL) end

-- --- State ---
local mon = findMonitor()
local drive = findDrive()
openAnyModem()
assert(rednet.isOpen(), "No modem opened.")

local chunks = {}
local fileBytes = 0
local durationSec = 0
local title = "Unknown"

local playing = false
local paused = false
local sid = nil
local start_ms = 0
local pause_accum = 0      -- total ms we’ve been paused
local pause_started = 0    -- ms when last paused began

-- Load DFPWM from floppy path on the controller
local function loadTrack()
  assert(fs.exists(TRACK_PATH), "Track not found: " .. TRACK_PATH)
  chunks = {}
  fileBytes = fs.getSize(TRACK_PATH)
  durationSec = (fileBytes * 8) / 48000
  local fh = fs.open(TRACK_PATH, "rb")
  while true do
    local data = fh.read(CHUNK_BYTES)
    if not data then break end
    chunks[#chunks+1] = data
  end
  fh.close()
end

-- Determine title from floppy disk (label preferred)
local function readTitle()
  local label = drive.getDiskLabel and drive.getDiskLabel() or nil
  if label and #label > 0 then
    title = label
  else
    title = basename(TRACK_PATH)
  end
end

-- Compute playhead seconds based on timing (controller-side estimate)
local function now_ms() return os.epoch("utc") end
local function playhead_sec()
  if not playing then return paused and (pause_started - start_ms - pause_accum)/1000 or 0 end
  local base = now_ms() - start_ms - pause_accum
  if paused then base = (pause_started - start_ms - pause_accum) end
  return math.max(0, base / 1000)
end

-- Draw UI
local ui = UI.new(mon)
local function redraw()
  ui:resize(); ui:clear()
  local w,h = ui.w, ui.h

  -- Title
  ui:text(2, 2, "Now Playing:", colors.yellow)
  ui:text(2, 3, title, colors.white)

  -- Buttons
  local playLabel = paused and "Resume" or (playing and "Pause" or "Play")
  ui:btn("playpause", playLabel, 2, 5, 10, 3, playing and not paused)
  ui:btn("restart", "Restart", 14, 5, 10, 3, false)

  -- Progress
  local elapsed = math.min(playhead_sec(), durationSec)
  local pct = durationSec > 0 and (elapsed / durationSec) or 0
  ui:text(2, 9, ("[%s / %s]"):format(fmt_time(elapsed), fmt_time(durationSec)), colors.white)
  ui:bar(2, 10, w-3, pct)
end

-- Ping clients (optional)
local function pingClients(short_window)
  broadcast({ cmd = "PING" })
  local clients = {}
  local t = os.startTimer(short_window and 0.5 or 1.0)
  while true do
    local e,a,b,c = os.pullEvent()
    if e=="timer" and a==t then break end
    if e=="rednet_message" and c==PROTOCOL then
      local sender, msg = a,b
      if type(msg)=="table" and msg.cmd=="PONG" then clients[sender]=true end
    end
  end
  return count(clients)
end

-- Stream the current chunks to all clients for session sid
local function stream_all(current_sid)
  for i=1,#chunks do
    broadcast({ cmd="CHUNK", sid=current_sid, seq=i, data=chunks[i] })
    os.queueEvent("yield"); os.pullEvent()
  end
  broadcast({ cmd="END", sid=current_sid, total=#chunks, start_epoch_ms=start_ms })
end

-- Start (or restart) playback from the beginning
local function do_start()
  loadTrack(); readTitle()
  paused = false; pause_accum = 0; pause_started = 0
  sid = tostring(now_ms()) .. "-" .. tostring(math.random(1000,9999))
  start_ms = now_ms() + DEFAULT_DELAY
  playing = true

  -- Let clients prep with the agreed start time & volume (1.0; tweak if needed)
  broadcast({ cmd="PREP", sid=sid, start_epoch_ms=start_ms, volume=1.0, name=title })

  -- Small window for READY (not strictly required)
  local t = os.startTimer(0.6)
  while true do
    local e = { os.pullEvent() }
    if e[1]=="timer" and e[2]==t then break end
  end

  -- Stream chunks and END
  stream_all(sid)
end

-- Toggle pause/resume
local function do_toggle_pause()
  if not playing then
    -- start fresh if not already playing
    do_start()
    return
  end
  if not paused then
    paused = true
    pause_started = now_ms()
    broadcast({ cmd="PAUSE", sid=sid })
  else
    -- Resume: schedule resume a smidge in the future for sync
    pause_accum = pause_accum + (now_ms() - pause_started)
    paused = false
    local resume_at = now_ms() + 500
    broadcast({ cmd="RESUME", sid=sid, start_epoch_ms = resume_at })
  end
end

-- Restart from beginning
local function do_restart()
  -- Tell clients to STOP existing session (optional cleanup), then start fresh
  broadcast({ cmd="STOP" })
  playing = false; paused = false; sid = nil
  do_start()
end

-- Main: initial load + UI loop
local function main()
  term.redirect(mon)
  term.setCursorBlink(false)

  -- Initial content & UI
  loadTrack(); readTitle()
  redraw()

  -- Optional: ping to show clients up
  pingClients(true)
  redraw()

  -- Background timer to refresh progress bar
  local refresh = os.startTimer(0.2)

  while true do
    local e = { os.pullEvent() }
    if e[1] == "monitor_touch" then
      local _, _, x, y = table.unpack(e)
      local id = ui:hit(x, y)
      if id == "playpause" then
        do_toggle_pause()
        redraw()
      elseif id == "restart" then
        do_restart()
        redraw()
      end

    elseif e[1] == "disk" or e[1] == "disk_eject" then
      -- Floppy changed; reload if our TRACK_PATH is on /disk
      if TRACK_PATH:match("^/disk/") and fs.exists(TRACK_PATH) then
        loadTrack(); readTitle()
        redraw()
      end

    elseif e[1] == "timer" and e[2] == refresh then
      redraw()
      refresh = os.startTimer(0.2)

    elseif e[1] == "rednet_message" then
      -- Optionally handle RESULT/PAUSED/RESUMED logs; not required for UI
      -- local sender, msg, proto = e[2], e[3], e[4]
      -- (left silent to keep UI snappy)
    end
  end
end

-- Ensure modem is open and monitor is ready, then go.
print("Controller UI ready on monitor. Touch Play/Pause or Restart.")
main()
