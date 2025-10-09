-- jukebox_monitor.lua  (DEBUG build; logs to terminal + /controller.log)
local PROTOCOL        = "ccaudio_sync_v1"
local DEFAULT_DELAYMS = 50
local CHUNK_BYTES     = 64
local CHUNKS_PER_PUMP = 128
local TRACK_PATH      = "/disk/music/track.dfpwm"
local VOLUME          = 1.0
local DEBUG           = true
local LOG_PATH        = "/controller.log"

-- ===== Utils =====
local function now_ms() return os.epoch("utc") end
local function t() return ("%d"):format(now_ms() % 1000000) end
local native = term.native()
local function log_write(s)
  -- mirror to native terminal
  local old = term.current()
  term.redirect(native); print(s); term.redirect(old)
  -- append to file
  local fh = fs.open(LOG_PATH, "a"); if fh then fh.writeLine(s); fh.close() end
end
local function log(...) if DEBUG then log_write(("[%s][CTRL ] "):format(t()) .. table.concat({...}," ")) end end
local function broadcast(msg) rednet.broadcast(msg, PROTOCOL) end

local function openAnyModem()
  for _, s in ipairs(peripheral.getNames()) do
    if peripheral.getType(s) == "modem" and not rednet.isOpen(s) then rednet.open(s) end
  end
end
local function findMonitor() local m=peripheral.find("monitor"); assert(m,"No monitor"); assert(m.isColor and m.isColor(),"Need advanced monitor"); m.setTextScale(0.5); return m end
local function findDrive() local d=peripheral.find("drive"); assert(d,"No disk drive"); return d end
local function fmt_time(s) s=math.max(0,math.floor(s+0.5)); return ("%d:%02d"):format(math.floor(s/60), s%60) end
local function basename(p) p=tostring(p):gsub("[/\\]+$",""); return p:match("([^/\\]+)$") or p end

-- ===== UI helper =====
local UI = {}
function UI.new(mon)
  local o={mon=mon,w=0,h=0,buttons={}}
  function o:resize() self.w,self.h=self.mon.getSize() end
  function o:clear() self.mon.setBackgroundColor(colors.black); self.mon.clear() end
  function o:btn(id,label,x,y,w,h,active)
    self.buttons[id]={x=x,y=y,w=w,h=h}
    self.mon.setBackgroundColor(active and colors.lime or colors.gray)
    self.mon.setTextColor(colors.black)
    for yy=y,y+h-1 do self.mon.setCursorPos(x,yy); self.mon.write((" "):rep(w)) end
    self.mon.setCursorPos(x+math.floor((w-#label)/2), y+math.floor(h/2)); self.mon.write(label)
    self.mon.setBackgroundColor(colors.black); self.mon.setTextColor(colors.white)
  end
  function o:bar(x,y,w,value)
    value=math.max(0,math.min(1,value or 0))
    local fill=math.floor(w*value+0.5)
    self.mon.setCursorPos(x,y); self.mon.setBackgroundColor(colors.gray); self.mon.write((" "):rep(w))
    self.mon.setCursorPos(x,y); self.mon.setBackgroundColor(colors.lightBlue); if fill>0 then self.mon.write((" "):rep(fill)) end
    self.mon.setBackgroundColor(colors.black)
  end
  function o:text(x,y,msg,fg,bg)
    if bg then self.mon.setBackgroundColor(bg) end; if fg then self.mon.setTextColor(fg) end
    self.mon.setCursorPos(x,y); self.mon.write(msg)
    self.mon.setTextColor(colors.white); self.mon.setBackgroundColor(colors.black)
  end
  function o:hit(x,y)
    for id,b in pairs(self.buttons) do if x>=b.x and y>=b.y and x<b.x+b.w and y<b.y+b.h then return id end end
  end
  o:resize(); return o
end

-- ===== State =====
local mon = findMonitor()
local drive = findDrive()
openAnyModem(); assert(rednet.isOpen(), "No modem open")
local ui = UI.new(mon)

local chunks, fileBytes, durationSec, title = {}, 0, 0, "Unknown"
local playing, paused = false, false
local sid, start_ms = nil, 0
local pause_accum, pause_started = 0, 0
local streamer = nil
local last_chunk_sent, sent_started_ms = 0, 0

-- ===== Load / Title =====
local function loadTrack()
  assert(fs.exists(TRACK_PATH), "Track not found: "..TRACK_PATH)
  chunks = {}; fileBytes = fs.getSize(TRACK_PATH); durationSec = (fileBytes * 8) / 48000
  local fh = fs.open(TRACK_PATH, "rb")
  while true do local d = fh.read(CHUNK_BYTES); if not d then break end; chunks[#chunks+1] = d end
  fh.close()
  log("track loaded bytes=", tostring(fileBytes), " chunks=", tostring(#chunks))
end
local function readTitle()
  local label = drive.getDiskLabel and drive.getDiskLabel() or nil
  title = (label and #label>0) and label or basename(TRACK_PATH)
  log("title=", title)
end

-- ===== Playhead/UI =====
local function playhead_sec()
  if not playing then return 0 end
  local base = paused and (pause_started - start_ms - pause_accum) or (now_ms() - start_ms - pause_accum)
  return math.max(0, base/1000)
end
local function redraw()
  ui:resize(); ui:clear()
  local w,h=ui.w,ui.h
  ui:text(2,2,"Now Playing:",colors.yellow); ui:text(2,3,title,colors.white)
  local playLabel = paused and "Resume" or (playing and "Pause" or "Play")
  ui:btn("playpause", playLabel, 2,5,10,3, playing and not paused)
  ui:btn("restart",  "Restart", 14,5,10,3, false)
  local elapsed=math.min(playhead_sec(), durationSec)
  local pct=durationSec>0 and (elapsed/durationSec) or 0
  ui:text(2,9,("[%s / %s]"):format(fmt_time(elapsed), fmt_time(durationSec)), colors.white)
  ui:bar(2,10,w-3,pct)
end

local function new_sid() return tostring(now_ms()).."-"..tostring(math.random(1000,9999)) end

-- ===== Streamer =====
local function start_streamer(current_sid, current_start_ms)
  last_chunk_sent = 0; sent_started_ms = now_ms()
  streamer = coroutine.create(function()
    log("stream begin sid=", current_sid, " start_ms=", tostring(current_start_ms))
    local i=1
    while i <= #chunks do
      for _=1, CHUNKS_PER_PUMP do
        if i > #chunks then break end
        broadcast({ cmd="CHUNK", sid=current_sid, seq=i, data=chunks[i] })
        i = i + 1
      end
      last_chunk_sent = i-1
      if last_chunk_sent % 1000 == 0 or last_chunk_sent < 50 then
        local elapsed = (now_ms() - sent_started_ms)/1000
        log("sent seq=", tostring(last_chunk_sent), "/", tostring(#chunks), " in ", string.format("%.3fs", elapsed))
      end
      coroutine.yield()
    end
    broadcast({ cmd="END", sid=current_sid, total=#chunks, start_epoch_ms=current_start_ms })
    local elapsed = (now_ms() - sent_started_ms)/1000
    log("END sent total=", tostring(#chunks), " stream_time=", string.format("%.3fs", elapsed))
  end)
end

local function pump_streamer()
  if streamer and coroutine.status(streamer) == "suspended" then
    for _=1, 200 do
      if coroutine.status(streamer) ~= "suspended" then break end
      local ok, err = coroutine.resume(streamer)
      if not ok then log("streamer error: ", tostring(err)); streamer=nil; break end
    end
  end
end

-- ===== Controls =====
local function do_start()
  loadTrack(); readTitle()
  paused, pause_accum, pause_started = false, 0, 0
  sid = new_sid()
  start_ms = now_ms() + DEFAULT_DELAYMS
  playing = true
  log("PLAY -> PREP sid=", sid, " start_in_ms=", tostring(start_ms - now_ms()), " chunks=", tostring(#chunks))
  broadcast({ cmd="PREP", sid=sid, start_epoch_ms=start_ms, volume=VOLUME, name=title })
  start_streamer(sid, start_ms)
end
local function do_toggle_pause()
  if not playing then do_start(); redraw(); return end
  if not paused then
    paused, pause_started = true, now_ms()
    log("PAUSE")
    broadcast({ cmd="PAUSE", sid=sid })
  else
    pause_accum = pause_accum + (now_ms() - pause_started)
    paused = false
    log("RESUME")
    broadcast({ cmd="RESUME", sid=sid })
  end
end
local function do_restart()
  log("RESTART")
  broadcast({ cmd="STOP" })
  playing, paused, sid, streamer = false, false, nil, nil
  do_start()
end

-- ===== Main =====
local function main()
  print("Controller UI (DEBUG) starting… (logs mirrored to /controller.log)")
  term.redirect(mon); term.setCursorBlink(false)
  loadTrack(); readTitle(); redraw()

  local refresh = os.startTimer(0)
  while true do
    pump_streamer()
    local ev = { os.pullEvent() }

    if ev[1]=="timer" and ev[2]==refresh then
      redraw(); refresh = os.startTimer(0.05)

    elseif ev[1]=="monitor_touch" then
      local _,_,x,y = table.unpack(ev)
      local id = UI.hit and UI.hit(ui,x,y) or (ui.hit and ui:hit(x,y))
      if id=="playpause" then do_toggle_pause(); redraw()
      elseif id=="restart"  then do_restart();      redraw()
      end

    elseif ev[1]=="disk" or ev[1]=="disk_eject" then
      if TRACK_PATH:match("^/disk/") and fs.exists(TRACK_PATH) then loadTrack(); readTitle(); redraw() end

    elseif ev[1]=="rednet_message" and ev[4]==PROTOCOL then
      local sender, msg = ev[2], ev[3]
      if type(msg)=="table" then
        if msg.cmd=="NACK" and msg.sid==sid then
          local seq = tonumber(msg.seq or -1)
          if seq and chunks[seq] then
            rednet.send(sender, { cmd="CHUNK", sid=sid, seq=seq, data=chunks[seq] }, PROTOCOL)
            if seq % 500 == 0 or seq < 10 then log("resend seq=", tostring(seq), " to #", tostring(sender)) end
          end
        elseif msg.cmd=="READY"   then log("READY  from #", tostring(sender), " sid=", tostring(msg.sid))
        elseif msg.cmd=="PAUSED"  then log("PAUSED ack from #", tostring(sender), " seq=", tostring(msg.seq))
        elseif msg.cmd=="RESUMED" then log("RESUMED ack from #", tostring(sender), " seq=", tostring(msg.seq))
        elseif msg.cmd=="RESULT"  then log("RESULT from #", tostring(sender), " ok=", tostring(msg.ok), " info=", tostring(msg.info))
        elseif msg.cmd=="PONG"    then log("PONG from #", tostring(sender))
        end
      end
    end
  end
end

main()
