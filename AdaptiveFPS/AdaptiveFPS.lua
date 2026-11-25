-- Adaptive FPS for Wrath 3.3.5a: when the frame rate stays below a target, step shadows and then distant detail down
-- (view distance, ground clutter, environment detail), and step them back up when it recovers. Every change is
-- reversible: your own settings are restored on /afps off, on logout and when Video Options opens.
-- /afps bench measures what each shadow level costs where you stand, and puts your shadows back afterwards.
-- No graphics restart, DLL calls, character-detail or combat-effect changes.
-- The guard keeps a second copy (Carbonite Runes once embedded this) from starting a second controller.
if not ChromieAdaptiveFPSLoaded then
local frame = CreateFrame("Frame")
local keys = {"farclip", "groundEffectDist", "environmentDetail", "extShadowQuality"}
local profiles = {
    -- Live comparison: shadows cost more here than the scenery reductions.
    -- Keep scenery intact for the first three steps and keep shadows at >=3
    -- unless the user's own normal setting is already lower.
    {1, 140, 1.5}, {1, 140, 1.5, 4}, {1, 140, 1.5, 3},
    -- Step 3 holds building shadows for another interval before reducing scenery.
    {1, 140, 1.5, 3}, {.85, 140, 1.5, 3}, {.70, 130, 1.5, 3}, {.55, 120, 1.25, 3},
}
local cities = {
    ["Dalaran"]=true, ["Shattrath City"]=true, ["Shattrath"]=true,
    ["Stormwind City"]=true, ["Stormwind"]=true, ["Ironforge"]=true,
    ["Darnassus"]=true, ["The Exodar"]=true, ["Orgrimmar"]=true,
    ["Undercity"]=true, ["Thunder Bluff"]=true, ["Silvermoon City"]=true,
}
local db, inWorld, ready = nil, false, false
local fighting = false -- PLAYER_REGEN_DISABLED .. PLAYER_REGEN_ENABLED
local level, low, high, stable, smooth = 0, 0, 0, 0, nil
local warmUntil, lastChange, restoreAfter, elapsedTotal = 0, -100, 0, 0
local rejected, reason = {}, "starting"
-- WoW in the background runs at its background frame cap (maxfpsbk, 30 by default): a frame rate held still at a cap
-- is the limiter, not scene load, so a backgrounded client must not lower anything. Lua can't see the window's
-- focus, but it can see the frame rate
-- sit at a cap: 2 below to 1 above it, varying by less than 0.8 FPS over 5 seconds. A loaded scene wobbles more.
local capWindow, capSpread, recent, atCap = 5, .8, {}, false
local profile, profileNeedsReload
local profilingAtLoad = GetCVar("scriptProfile")=="1"
-- /afps bench (further down) measures what each shadow level costs where you stand. While it runs it owns the shadow
-- setting and the controller is paused. benchSettle: seconds before the first level; benchWarm: seconds thrown away
-- after each change, while the client rebuilds its shadow maps; benchKeep: saved runs kept.
local bench, stopBench
local benchSettle, benchWarm, benchKeep = 5, 3, 8
local function say(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff69adffAdaptive FPS:|r "..text)
end
local function equal(a,b)
    return a and b and math.abs(a-b)<.01
end
local function read(key)
    local ok, value=pcall(GetCVar,key)
    value=ok and tonumber(value)
    if value and value==value and value>=0 and value<100000 then return value end
end
local function heldAtCap(fps)
    table.insert(recent,fps); if #recent>capWindow then table.remove(recent,1) end
    if #recent<capWindow then return end
    local lo,hi=math.huge,-math.huge
    for _,v in ipairs(recent) do lo=math.min(lo,v); hi=math.max(hi,v) end
    if hi-lo>capSpread then return end
    for _,key in ipairs({"maxfpsbk","maxfps"}) do
        local cap=read(key)
        if not cap and key=="maxfpsbk" then cap=30 end
        if cap and cap>0 and cap<db.target+2 and lo>=cap-2 and hi<=cap+1 then return cap end
    end
end
local function clearSamples()
    low, high, stable, smooth = 0, 0, 0, nil
end
local function write(key,value)
    local current=read(key)
    if equal(current,value) then return current end
    local ok=pcall(SetCVar,key,tostring(value))
    local actual=read(key)
    if not ok or not equal(actual,value) then
        if not rejected[key] then say("Client could not apply "..key.."; automatic changes to it are paused.") end
        rejected[key]=true
    end
    return actual
end
-- Only restore values we still own. A manual edit or another addon's edit wins.
local function restore()
    if not db then return end
    for _,key in ipairs(keys) do
        local current, applied=read(key),tonumber(db.applied[key])
        local original=tonumber(db.baseline[key])
        if current and applied then
            if equal(current,applied) and original then
                local actual=write(key,original)
                if equal(actual,original) then db.applied[key]=nil end
            else
                db.baseline[key]=current; db.applied[key]=nil
            end
        end
    end
    level=0; db.level=0; clearSamples()
    return next(db.applied)==nil
end
local function captureMissing()
    for _,key in ipairs(keys) do
        if not tonumber(db.baseline[key]) then db.baseline[key]=read(key) end
    end
end
local function syncManualChanges(now)
    local changed=false
    for _,key in ipairs(keys) do
        local current=read(key)
        local expected=tonumber(db.applied[key]) or tonumber(db.baseline[key])
        if current and expected and not equal(current,expected) then
            db.baseline[key]=current; db.applied[key]=nil; changed=true
        end
    end
    if changed then clearSamples(); warmUntil=math.max(warmUntil,now+15) end
end
local function desired(key, index)
    local base=tonumber(db.baseline[key])
    if not base then return nil end
    if index==0 then return base end
    local p=profiles[index+1]
    if key=="farclip" then return math.min(base,math.max(500,math.floor(base*p[1]+.5))) end
    if key=="groundEffectDist" then return math.min(base,p[2]) end
    if key=="extShadowQuality" then return math.min(base,p[4]) end
    return math.min(base,p[3])
end
local function apply(index, now)
    local previous=level
    for _,key in ipairs(keys) do
        local value=desired(key,index)
        if value and not rejected[key] then
            local actual=write(key,value)
            if actual then
                if equal(actual,db.baseline[key]) then db.applied[key]=nil
                else db.applied[key]=actual end
            end
        end
    end
    level=index; db.level=index; lastChange=now; clearSamples()
    if index>previous then restoreAfter=now+60 end
    if previous==0 and index>0 then
        say("Sustained low FPS: adjusting shadows first toward "..db.target.." FPS. /afps shows status.")
    elseif previous>0 and index==0 then say("Normal visual settings restored.") end
end
local function busyArea()
    local inside, kind=IsInInstance()
    if inside and (kind=="raid" or kind=="party" or kind=="pvp" or kind=="arena") then return true end
    return cities[GetRealZoneText() or ""] or GetZonePVPInfo()=="sanctuary"
end
local function shown(name)
    local object=_G[name]
    return object and object.IsShown and object:IsShown()
end
-- Video Options writes snapshots back even if only VSync was changed. Restore
-- normal CVars before editing, and refresh only the affected controls.
local function optionsOpened()
    if not db then return end
    if bench then stopBench("Video Options opened") end
    captureMissing(); syncManualChanges(GetTime()); restore()
    local controlled={farclip=true,groundEffectDist=true,environmentDetail=true,extShadowQuality=true}
    for _,control in pairs(VideoOptionsEffectsPanel and VideoOptionsEffectsPanel.controls or {}) do
        if controlled[control.cvar] then
            local value=read(control.cvar)
            if value then
                if control.SetDisplayValue then control:SetDisplayValue(value) end
                control.value=value
                -- A slider can round/clamp the display of a Max Zoom value.
                -- This is not a user edit and must not be saved by Apply.
                control.newValue=nil
            end
        end
    end
    reason="paused in video options; normal visuals restored"
end
if VideoOptionsFrame and VideoOptionsFrame.HookScript then
    VideoOptionsFrame:HookScript("OnShow",optionsOpened)
    VideoOptionsFrame:HookScript("OnHide",function()
        if db then syncManualChanges(GetTime()); clearSamples(); warmUntil=GetTime()+20 end
    end)
end
local function cpuSnapshot()
    UpdateAddOnCPUUsage()
    local values={}
    for i=1,GetNumAddOns() do
        if IsAddOnLoaded(i) then
            local name=GetAddOnInfo(i)
            local value=GetAddOnCPUUsage(i)
            if name and type(value)=="number" then values[name]=value end
        end
    end
    return values
end
local function profileReport()
    local result=db.cpuReport
    if not result then say("No CPU capture yet. /afps profile prepares one."); return end
    if result.error then say("CPU capture incomplete: "..result.error); return end
    say(string.format("Addon CPU over %.1f seconds (%d frames), highest first:",result.seconds,result.frames))
    for i=1,math.min(8,#result.rows) do
        local row=result.rows[i]
        say(string.format("%s: %.2f ms/frame, %.1f ms/second",row.name,row.ms/result.frames,row.ms/result.seconds))
    end
    say("Profiling adds overhead; these rank Lua work, not total rendering cost. /reload removes profiling overhead.")
end
local function profileCleanup()
    profile=nil; ChromieAdaptiveFPSProfiling=nil
    -- Native profiling needs a reload to switch off. Set the next session off
    -- immediately so an exit, interrupted capture or error cannot leave it on.
    pcall(SetCVar,"scriptProfile","0")
    profileNeedsReload=true;clearSamples()
end
local function startProfile()
    if type(UpdateAddOnCPUUsage)~="function" or type(GetAddOnCPUUsage)~="function" then
        say("This client does not expose addon CPU counters.");profileCleanup();return
    end
    profile={startAfter=GetTime()+10}
    ChromieAdaptiveFPSProfiling=true
    say("CPU capture starts in 10 seconds and records for 30. Keep WoW focused here; then /reload to switch profiling off.")
end
local function profileTick(now)
    if not profile or now<profile.startAfter then return end
    local ok,err=pcall(function()
        if not profile.started then
            profile.before=cpuSnapshot();profile.started=now;profile.frames=0
            say("Recording addon CPU for 30 seconds...")
        end
        profile.frames=profile.frames+1
        if now-profile.started<30 then return end
        local after=cpuSnapshot()
        local result={seconds=now-profile.started,frames=profile.frames,rows={},zone=GetRealZoneText()}
        for name,initial in pairs(profile.before) do
            local final=after[name]
            if final then
                if final<initial then error("another addon reset CPU counters during capture") end
                result.rows[#result.rows+1]={name=name,ms=final-initial}
            end
        end
        table.sort(result.rows,function(a,b) return a.ms>b.ms end)
        db.cpuReport=result;profileCleanup();profileReport()
    end)
    if not ok then
        db.cpuReport={error=tostring(err)};profileCleanup();profileReport()
        say("Run /reload to switch profiling off.")
    end
end
-- Shadow bench. GetFramerate() is smoothed, so this counts the frames themselves. Each level the graphics setup
-- supports is held for the same time, up the levels and back down, so slow drift (a crowd arriving) lands on both
-- sides of every level; the lowest level is therefore measured first and last, and the gap between those two passes
-- says how much of any difference is noise.
local function benchReport(run)
    if not run then say("No bench saved yet. /afps bench measures the shadow levels where you stand."); return end
    say(string.format("Shadow bench, %s%s, %d seconds a level, up and back%s:",tostring(run.zone or "unknown place"),
        run.label and run.label~="" and " ("..run.label..")" or "",run.seconds,run.when and ", "..run.when or ""))
    local base=run.levels[1]
    local capped={}
    for _,row in ipairs(run.levels) do
        local text=string.format("level %d: %.1f FPS (%.1f ms), worst second %.1f",row.level,row.fps,row.ms,row.worst or row.fps)
        if row.second then text=text..string.format("; the two passes %.1f and %.1f",row.first,row.second) end
        if row~=base then text=text..string.format("; %+.1f ms against level %d",row.ms-base.ms,base.level) end
        if row.level==run.normal then text=text.." (your normal)" end
        if row.cap then capped[#capped+1]=row.level end
        say(text)
    end
    if base and base.second then
        say(string.format("Level %d was measured first and last: %.1f and %.1f FPS. Differences smaller than that gap are noise.",
            base.level,base.first,base.second))
    end
    if #capped>0 then
        say("Held at a frame cap, so possibly faster than shown: level "..table.concat(capped,", ")
            ..". Try a busier place, and keep WoW in front.")
    end
    if run.refused and #run.refused>0 then
        say("Not available with this graphics setup: level "..table.concat(run.refused,", ")..".")
    end
end
-- The level is owned like any step's value (db.applied), so a crash or reload in the middle puts the normal one back.
local function benchSet(value)
    local actual=read("extShadowQuality")
    if not equal(actual,value) then
        local ok=pcall(SetCVar,"extShadowQuality",tostring(value))
        actual=read("extShadowQuality")
        if not ok or not equal(actual,value) then return false end
    end
    if equal(actual,db.baseline.extShadowQuality) then db.applied.extShadowQuality=nil
    else db.applied.extShadowQuality=actual end
    return true
end
local function benchBegin(now)
    local b=bench
    b.warmUntil=now+benchWarm
    b.frames,b.time,b.secFrames,b.secTime,b.worst=0,0,0,0,nil
end
local function benchFinish(now)
    local b=bench
    bench=nil
    restore()
    clearSamples(); warmUntil=math.max(warmUntil,now+20); reason="settling after the shadow bench"
    local run={when=type(date)=="function" and date("%Y-%m-%d %H:%M") or nil,zone=GetRealZoneText(),
        subzone=type(GetSubZoneText)=="function" and GetSubZoneText() or nil,label=b.label,seconds=b.seconds,
        normal=b.normal,farclip=read("farclip"),levels={},refused={}}
    local caps={}
    for _,key in ipairs({"maxfps","maxfpsbk"}) do
        local cap=read(key)
        if not cap and key=="maxfpsbk" then cap=30 end
        if cap and cap>0 then caps[#caps+1]=cap end
    end
    for value=0,b.top do
        local passes=b.passes[value]
        if passes then
            local frames,time,worst=0,0,nil
            for _,pass in ipairs(passes) do
                frames=frames+pass.frames; time=time+pass.time
                if pass.worst and (not worst or pass.worst<worst) then worst=pass.worst end
            end
            local row={level=value,fps=frames/time,ms=1000*time/frames,worst=worst,
                first=passes[1].frames/passes[1].time,second=passes[2] and passes[2].frames/passes[2].time}
            -- At a cap the rate is also steady: a scene that merely averages 30 has seconds well below it.
            for _,cap in ipairs(caps) do
                if row.fps>=cap-1.5 and row.fps<=cap+1 and (worst or row.fps)>=cap-1.5 then row.cap=cap end
            end
            run.levels[#run.levels+1]=row
        elseif b.refused[value] then run.refused[#run.refused+1]=value end
    end
    if #run.levels==0 then say("Bench: the client accepted none of the shadow levels; nothing was measured."); return end
    db.bench=type(db.bench)=="table" and db.bench or {}
    table.insert(db.bench,run)
    while #db.bench>benchKeep do table.remove(db.bench,1) end
    benchReport(run)
    say("Saved; your normal shadows are back. /reload or logging out writes it to disk; /afps bench report shows it again.")
end
local function benchNext(now)
    local b=bench
    while true do
        b.index=b.index+1
        local value=b.order[b.index]
        if not value then benchFinish(now); return end
        if benchSet(value) then b.phase="level"; benchBegin(now); return end
        b.refused[value]=true
    end
end
local function benchFrame(elapsed,now)
    local b=bench
    if b.phase=="settle" then
        if now>=b.settleUntil then benchNext(now) end
        return
    end
    -- A long frame (a loading hitch, alt-tab) spoils the pass: take it again, and give up if it keeps happening.
    if elapsed>.5 then
        b.stalls=b.stalls+1
        if b.stalls>3 then stopBench("too many long stalls; was WoW in front the whole time?") else benchBegin(now) end
        return
    end
    if now<b.warmUntil then return end
    b.frames=b.frames+1; b.time=b.time+elapsed
    b.secFrames=b.secFrames+1; b.secTime=b.secTime+elapsed
    if b.secTime>=1 then
        local rate=b.secFrames/b.secTime
        if not b.worst or rate<b.worst then b.worst=rate end
        b.secFrames,b.secTime=0,0
        if fighting or UnitAffectingCombat("player") then stopBench("combat started"); return end
        if shown("CinematicFrame") or shown("MovieFrame") then stopBench("a cinematic started"); return end
    end
    if b.time>=b.seconds then
        local value=b.order[b.index]
        b.passes[value]=b.passes[value] or {}
        table.insert(b.passes[value],{frames=b.frames,time=b.time,worst=b.worst})
        benchNext(now)
    end
end
stopBench=function(why)
    if not bench then return end
    bench=nil
    local restored=restore()
    clearSamples(); warmUntil=math.max(warmUntil,GetTime()+10); reason="settling after the shadow bench"
    say("Bench stopped: "..why..(restored and "; your normal shadows are back." or "; the client rejected a restoration, /afps shows current values.")
        .." Nothing was saved.")
end
local function startBench(arg,now)
    if bench then
        say(string.format("Bench is running: pass %d of %d. /afps bench stop cancels it.",math.max(bench.index,1),#bench.order))
        return
    end
    if profile or profileNeedsReload then say("Finish the CPU capture first (/reload)."); return end
    if not ready or not inWorld then return end
    if fighting or UnitAffectingCombat("player") then say("Not in combat: the bench changes shadows every few seconds."); return end
    if shown("VideoOptionsFrame") then say("Close Video Options first."); return end
    local seconds,label=string.match(arg,"^(%d+)%s*(.-)$")
    seconds=tonumber(seconds)
    if not seconds then seconds,label=20,arg end
    if seconds<5 or seconds>120 then say("Use /afps bench 5-120: seconds a level, 20 if left out. A word after it labels the run."); return end
    local steppedDown=level>0
    captureMissing(); syncManualChanges(now); restore()
    local normal=read("extShadowQuality")
    if not normal then say("This client has no extShadowQuality setting to measure."); return end
    local top=5
    if type(GetCVarMax)=="function" then
        local ok,value=pcall(GetCVarMax,"extShadowQuality")
        value=ok and tonumber(value)
        if value and value>=0 and value<5 then top=math.floor(value) end
    end
    local order={}
    for value=0,top do order[#order+1]=value end
    for value=top,0,-1 do order[#order+1]=value end
    -- Restoring a stepped-down view distance can bring a short loading screen: wait longer before the first level.
    local settle=steppedDown and 15 or benchSettle
    bench={seconds=seconds,label=label or "",order=order,index=0,top=top,normal=normal,passes={},refused={},stalls=0,
        phase="settle",settleUntil=now+settle}
    reason="paused for the shadow bench"
    say(string.format("Bench: shadow levels 0-%d, %d seconds each, up and back: about %.0f minutes. Stand still, or keep walking"
        .." the same loop, with WoW in front. /afps bench stop cancels it.",top,seconds,(#order*(seconds+benchWarm)+settle)/60))
end
local function tick(now)
    if not db or not ready or not inWorld then return end
    if profile or profileNeedsReload then reason="paused for CPU measurement; /reload when finished"; return end
    if shown("VideoOptionsFrame") then reason="paused in video options"; return end
    captureMissing(); syncManualChanges(now)
    if not db.enabled then reason="off"; return end
    if now<warmUntil then reason="settling after loading/settings change"; return end
    if UnitIsAFK("player") or shown("CinematicFrame") or shown("MovieFrame") or shown("VideoOptionsFrame") then
        clearSamples(); reason="paused while AFK or in video options/cinematic"; return
    end
    -- In combat a reload (view distance and environment detail changes can bring a short loading screen) hurts more
    -- than a low frame rate: nothing is restored until combat ends, and it steps down only below db.combatTarget.
    local inCombat=fighting or UnitAffectingCombat("player")
    if db.scope=="busy" and not busyArea() then
        reason=inCombat and "outside cities/instances; holding in combat" or "outside cities/instances"
        if level>0 and not inCombat and now-lastChange>=5 then apply(level-1,now) end
        return
    end
    local fps=GetFramerate()
    if not fps or fps<5 or fps>1000 then clearSamples(); reason="ignoring a stall"; return end
    local cap=heldAtCap(fps)
    if cap then
        if not atCap then clearSamples() end
        atCap=true; db.lastFPS=math.floor(fps+.5); reason="frame rate held at the "..math.floor(cap+.5).." FPS cap (WoW in the background?): paused"
        return
    elseif atCap then
        atCap=false; clearSamples(); warmUntil=math.max(warmUntil,now+3); reason="settling after the frame cap"
        return
    end
    smooth=smooth and smooth*.7+fps*.3 or fps
    db.lastFPS=math.floor(smooth+.5)
    reason=level==0 and "normal visuals" or (level<=3 and "adapting shadows; scenery unchanged" or "adapting shadows and distant detail")
    if inCombat then reason=reason.."; in combat: steps down only below "..db.combatTarget.." FPS" end
    if smooth<(inCombat and db.combatTarget or db.target)-2 then low=low+1 else low=0 end
    if smooth>=db.target+7 then high=high+1 else high=0 end
    if smooth>=db.target+2 then stable=stable+1 else stable=0 end
    if low>=10 and now-lastChange>=15 and level<#profiles-1 then
        apply(level+1,now)
    elseif level>0 and not inCombat and now>=restoreAfter and now-lastChange>=25 and (high>=25 or stable>=90) then
        apply(level-1,now)
    elseif level==#profiles-1 and low>=10 then reason="detail floor reached; FPS target may not be achievable" end
end
local function status()
    say(string.format("%s; target %d FPS (%d in combat); detail step %d/%d; FPS %s; %s.",
        db.enabled and "On" or "Off",db.target,db.combatTarget,level,#profiles-1,tostring(db.lastFPS or "pending"),reason))
    if bench then say(string.format("Shadow bench running: pass %d of %d.",math.max(bench.index,1),#bench.order)) end
    for _,key in ipairs(keys) do
        say(string.format("%s: %s (normal %s)",key,tostring(read(key)),tostring(db.baseline[key] or "pending")))
    end
end
local function command(input)
    if not db then return end
    local cmd,arg=string.match(string.lower(input or ""),"^%s*(%S*)%s*(.-)%s*$")
    -- These put the normal settings back or redefine them, which a running bench cannot survive.
    if bench and (cmd=="off" or cmd=="restore" or cmd=="baseline") then stopBench("/afps "..cmd) end
    if cmd=="off" or cmd=="restore" then
        syncManualChanges(GetTime()); local restored=restore(); db.enabled=false; reason="off"
        say(restored and "Off; normal settings restored." or "Off; the client rejected a restoration. /afps shows current values.")
    elseif cmd=="on" then
        db.enabled=true; clearSamples(); warmUntil=GetTime()+10; say("On; target "..db.target.." FPS.")
    elseif cmd=="target" then
        local n=tonumber(arg)
        if not n or n<20 or n>120 then say("Use /afps target 20-120"); return end
        db.target=math.floor(n); clearSamples(); say("Target set to "..db.target.." FPS.")
    elseif cmd=="combat" then
        local n=tonumber(arg)
        if not n or n<5 or n>60 then say("Use /afps combat 5-60: in combat it steps down only below that FPS."); return end
        db.combatTarget=math.floor(n); clearSamples()
        say("In combat: steps down only below "..db.combatTarget.." FPS, and restores nothing until combat ends.")
    elseif cmd=="scope" and (arg=="busy" or arg=="all") then
        db.scope=arg; clearSamples(); say(arg=="busy" and "Enabled in cities and group instances." or "Enabled in all locations.")
    elseif cmd=="baseline" then
        -- Explicitly accept the current live profile; never do this on reload.
        db.baseline={}; db.applied={}; level=0; db.level=0; captureMissing(); clearSamples()
        warmUntil=GetTime()+15; say("Current visuals saved as the normal profile.")
    elseif cmd=="bench" then
        if arg=="stop" then
            if bench then stopBench("stopped by you") else say("No bench is running.") end
        elseif arg=="report" then benchReport(type(db.bench)=="table" and db.bench[#db.bench] or nil)
        else startBench(arg,GetTime()) end
    elseif cmd=="profile" then
        if bench then say("Stop the bench first: /afps bench stop."); return end
        if profile then say("CPU capture is already running."); return end
        if profileNeedsReload then say("Run /reload to finish the previous profiling session first."); return end
        db.profileRequested=true;SetCVar("scriptProfile","1")
        say("Profiling prepared. Run /reload, wait 40 seconds here, then /reload again. /afps report retains the result.")
    elseif cmd=="report" then profileReport()
    elseif cmd=="" or cmd=="status" then status()
    else say("/afps status | on | off | target 45 | combat 15 | scope busy/all | baseline | bench | bench report | profile | report") end
end
SLASH_CHROMIEADAPTIVEFPS1="/afps"
SlashCmdList.CHROMIEADAPTIVEFPS=command
frame:SetScript("OnEvent",function(self,event)
    if event=="PLAYER_LOGIN" then
        -- Settings live in ChromieAdaptiveFPSDB. An earlier copy, embedded in Carbonite Runes, kept them in
        -- CarboniteRunesDB.adaptiveFPS: those are taken over once.
        if type(ChromieAdaptiveFPSDB)~="table" then
            local old=type(CarboniteRunesDB)=="table" and CarboniteRunesDB.adaptiveFPS
            ChromieAdaptiveFPSDB=type(old)=="table" and old or {}
        end
        db=ChromieAdaptiveFPSDB
        db.baseline=type(db.baseline)=="table" and db.baseline or {}
        db.applied=type(db.applied)=="table" and db.applied or {}
        db.target=math.max(20,math.min(120,tonumber(db.target) or 45))
        db.combatTarget=math.max(5,math.min(60,tonumber(db.combatTarget) or 15))
        if db.enabled==nil then db.enabled=true end
        if db.scope~="all" then db.scope="busy" end
        restore(); ready=true; inWorld=true; warmUntil=GetTime()+20
        say("Ready: "..db.target.." FPS target in "..(db.scope=="busy" and "cities/instances" or "all locations")..". /afps for status; /afps off restores normal visuals.")
        -- Also supports first installation via /console scriptProfile 1 + /reload.
        if profilingAtLoad and (db.profileRequested or not db.cpuReport) then
            db.profileRequested=nil;startProfile()
        elseif db.profileRequested then
            db.profileRequested=nil;say("CPU profiling did not activate; /afps profile can retry.")
        end
    elseif event=="PLAYER_ENTERING_WORLD" then
        inWorld=true; warmUntil=GetTime()+20; clearSamples()
    elseif event=="PLAYER_LEAVING_WORLD" then
        if bench then stopBench("a loading screen") end
        inWorld=false; restore()
        if profile then db.cpuReport={error="world/loading transition interrupted capture"};profileCleanup() end
    elseif event=="ZONE_CHANGED_NEW_AREA" then
        if bench then stopBench("you left the zone") end
        warmUntil=math.max(warmUntil,GetTime()+8); clearSamples()
    elseif event=="PLAYER_REGEN_DISABLED" then
        fighting=true; clearSamples()
        if bench then stopBench("combat started") end
    elseif event=="PLAYER_REGEN_ENABLED" then
        fighting=false; clearSamples()
    elseif event=="PLAYER_LOGOUT" then
        bench=nil
        restore()
        if profile then db.cpuReport={error="reload/logout interrupted capture"};profileCleanup() end
    end
end)
frame:SetScript("OnUpdate",function(self,elapsed)
    if not ready or not inWorld then return end
    if profile then profileTick(GetTime()); return end
    if bench then benchFrame(elapsed,GetTime()); return end
    -- A long frame or alt-tab stall is not evidence of sustained scene load.
    if elapsed>.5 then clearSamples(); elapsedTotal=0; warmUntil=math.max(warmUntil,GetTime()+5); return end
    elapsedTotal=elapsedTotal+elapsed
    if elapsedTotal<1 then return end
    elapsedTotal=elapsedTotal-1
    tick(GetTime())
end)
for _,event in ipairs({"PLAYER_LOGIN","PLAYER_ENTERING_WORLD","PLAYER_LEAVING_WORLD","ZONE_CHANGED_NEW_AREA","PLAYER_LOGOUT",
        "PLAYER_REGEN_DISABLED","PLAYER_REGEN_ENABLED"}) do frame:RegisterEvent(event) end
ChromieAdaptiveFPSLoaded=true
end
