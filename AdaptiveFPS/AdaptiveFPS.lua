-- Adaptive FPS for Wrath 3.3.5a: when the frame rate stays below a target, step shadows and then distant detail down
-- (view distance, ground clutter, environment detail), and step them back up when it recovers. Every change is
-- reversible: your own settings are restored on /afps off, on logout and when Video Options opens.
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
    for _,key in ipairs(keys) do
        say(string.format("%s: %s (normal %s)",key,tostring(read(key)),tostring(db.baseline[key] or "pending")))
    end
end
local function command(input)
    if not db then return end
    local cmd,arg=string.match(string.lower(input or ""),"^%s*(%S*)%s*(.-)%s*$")
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
    elseif cmd=="profile" then
        if profile then say("CPU capture is already running."); return end
        if profileNeedsReload then say("Run /reload to finish the previous profiling session first."); return end
        db.profileRequested=true;SetCVar("scriptProfile","1")
        say("Profiling prepared. Run /reload, wait 40 seconds here, then /reload again. /afps report retains the result.")
    elseif cmd=="report" then profileReport()
    elseif cmd=="" or cmd=="status" then status()
    else say("/afps status | on | off | target 45 | combat 15 | scope busy/all | baseline | profile | report") end
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
        inWorld=false; restore()
        if profile then db.cpuReport={error="world/loading transition interrupted capture"};profileCleanup() end
    elseif event=="ZONE_CHANGED_NEW_AREA" then
        warmUntil=math.max(warmUntil,GetTime()+8); clearSamples()
    elseif event=="PLAYER_REGEN_DISABLED" then
        fighting=true; clearSamples()
    elseif event=="PLAYER_REGEN_ENABLED" then
        fighting=false; clearSamples()
    elseif event=="PLAYER_LOGOUT" then
        restore()
        if profile then db.cpuReport={error="reload/logout interrupted capture"};profileCleanup() end
    end
end)
frame:SetScript("OnUpdate",function(self,elapsed)
    if not ready or not inWorld then return end
    if profile then profileTick(GetTime()); return end
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
