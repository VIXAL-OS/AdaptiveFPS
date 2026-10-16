"""Runs AdaptiveFPS.lua under Lua 5.1 (lupa) with a mocked client: CVars, frame rate, zones, combat, Video Options and
the CPU counters. Usage: python tests/test_adaptive_fps.py [folder holding lupa, if it is not installed]"""
from pathlib import Path
import json, sys
if len(sys.argv) > 1:
    sys.path.insert(0, sys.argv[1])
from lupa.lua51 import LuaRuntime
addon=Path(__file__).resolve().parents[1]/'AdaptiveFPS'
source=(addon/'AdaptiveFPS.lua').read_text(encoding='utf-8')
LuaRuntime().eval('function(s) assert(loadstring(s)) end')(source)
toc=(addon/'AdaptiveFPS.toc').read_text()
assert '## SavedVariables: ChromieAdaptiveFPSDB' in toc
assert [s for s in toc.splitlines() if s and not s.startswith('#')]==['AdaptiveFPS.lua']

def host(prelude=''):
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
now=0; fps=60; zone='Dalaran'; pvp='sanctuary'; afk=false; inside=false; kind='none'
cvars={farclip=2000,groundEffectDist=140,environmentDetail=1.5,extShadowQuality=5,projectedTextures=1,groundEffectDensity=64}
writes={}; messages={}; SlashCmdList={}
function GetTime() return now end
function GetCVar(k) return cvars[k] and tostring(cvars[k]) end
function SetCVar(k,v)
 if reject==k then error('mock rejected CVar') end
 cvars[k]=tonumber(v); writes[#writes+1]={key=k,value=tonumber(v),time=now}
end
function GetFramerate() return fps end
function GetRealZoneText() return zone end
function GetZonePVPInfo() return pvp end
function IsInInstance() return inside,kind end
function UnitIsAFK() return afk end
function UnitAffectingCombat() return incombat end
DEFAULT_CHAT_FRAME={AddMessage=function(self,s) messages[#messages+1]=s end}
VideoOptionsFrame={IsShown=function() return videoOptions end}
videoHooks={}
function VideoOptionsFrame:HookScript(k,v) videoHooks[k]=v end
VideoOptionsEffectsPanel={controls={}}
for _,k in ipairs({'farclip','groundEffectDist','environmentDetail','extShadowQuality'}) do
 local control={cvar=k}
 function control:SetDisplayValue(value)
  self.display=value;self.newValue=self.cvar=='farclip' and math.min(1277,value) or value
 end
 VideoOptionsEffectsPanel.controls[#VideoOptionsEffectsPanel.controls+1]=control
end
function openVideo()
 videoOptions=true
 for _,c in ipairs(VideoOptionsEffectsPanel.controls) do c.value=cvars[c.cvar];c.newValue=c.value end
 videoHooks.OnShow()
end
function applyVideo()
 for _,c in ipairs(VideoOptionsEffectsPanel.controls) do
  SetCVar(c.cvar,c.newValue or c.value);c.value=c.newValue or c.value;c.newValue=nil
 end
end
function closeVideo() videoOptions=false;videoHooks.OnHide() end
cpuRates={Heavy=60,Light=5,CarboniteRunes=1}
cpuNames={'Heavy','Light','CarboniteRunes'};cpuUpdates=0
function GetNumAddOns() return #cpuNames end
function IsAddOnLoaded(i) return true end
function GetAddOnInfo(i) return cpuNames[i] end
function UpdateAddOnCPUUsage() cpuUpdates=cpuUpdates+1;if cpuError then error('counter failure') end end
function GetAddOnCPUUsage(i)
 if resetCounters and now>25 then return 0 end
 return now*cpuRates[cpuNames[i]]
end
function CreateFrame()
 controller={scripts={},events={}}
 function controller:SetScript(k,v) self.scripts[k]=v end
 function controller:RegisterEvent(e) self.events[e]=true end
 return controller
end
function event(e) controller.scripts.OnEvent(controller,e) end
function step(seconds,newFPS)
 fps=newFPS or fps
 for i=1,math.floor(seconds*10) do now=now+.1;controller.scripts.OnUpdate(controller,.1) end
end
function cmd(s) SlashCmdList.CHROMIEADAPTIVEFPS(s) end
""")
    lua.execute(prelude)
    lua.execute(source)
    lua.execute("event('PLAYER_LOGIN')")
    return lua

checks=['Compiles in Lua 5.1; the TOC loads AdaptiveFPS.lua and saves ChromieAdaptiveFPSDB']
def case(name,body,prelude=''):
    lua=host(prelude)
    lua.execute(body)
    checks.append(name)

case('City entry alone keeps normal graphics',"""
step(120,60); assert(ChromieAdaptiveFPSDB.target==45)
assert(ChromieAdaptiveFPSDB.level==0 and #writes==0)
""")
case('Command registration; settings saved in ChromieAdaptiveFPSDB',"""
assert(SLASH_CHROMIEADAPTIVEFPS1=='/afps')
cmd('status');assert(string.find(messages[#messages-4],'target 45 FPS',1,true))
cmd('target 50');assert(ChromieAdaptiveFPSDB.target==50)
""")
case("Settings kept by Carbonite Runes' copy are taken over","""
assert(ChromieAdaptiveFPSDB.target==48 and ChromieAdaptiveFPSDB.enabled==false)
assert(CarboniteRunesDB.speed==1.5)
""","CarboniteRunesDB={speed=1.5,adaptiveFPS={target=48,enabled=false}}")
case('Its own saved settings take precedence over the old copy',"""
assert(ChromieAdaptiveFPSDB.target==55 and ChromieAdaptiveFPSDB.enabled==false)
""","CarboniteRunesDB={adaptiveFPS={target=48}};ChromieAdaptiveFPSDB={target=55,enabled=false}")
duplicate=host()
duplicate.execute('originalController=controller;originalCommand=SlashCmdList.CHROMIEADAPTIVEFPS')
duplicate.execute(source)
duplicate.execute('assert(controller==originalController and SlashCmdList.CHROMIEADAPTIVEFPS==originalCommand)')
checks.append('A second copy (Carbonite Runes once embedded this) cannot create a second controller')
case('Warmup and sustained low FPS; first three steps only reduce shadows',"""
step(28,20);assert(ChromieAdaptiveFPSDB.level==0)
step(6,20);assert(ChromieAdaptiveFPSDB.level==1)
assert(cvars.farclip==2000 and cvars.extShadowQuality==4 and cvars.groundEffectDist==140 and cvars.environmentDetail==1.5)
step(15,20);assert(ChromieAdaptiveFPSDB.level==2 and cvars.farclip==2000 and cvars.extShadowQuality==3)
step(15,20);assert(ChromieAdaptiveFPSDB.level==3 and cvars.farclip==2000 and cvars.extShadowQuality==3)
for _,w in ipairs(writes) do assert(w.key=='extShadowQuality') end
""")
case('Brief dips do not lower graphics',"""
step(30,60);step(5,15);step(25,60);assert(ChromieAdaptiveFPSDB.level==0)
""")
case('Bounded reductions and gradual restoration',"""
step(145,20);assert(ChromieAdaptiveFPSDB.level==6)
assert(cvars.farclip==1100 and cvars.groundEffectDist==120 and cvars.environmentDetail==1.25 and cvars.extShadowQuality==3)
step(30,60);assert(ChromieAdaptiveFPSDB.level>0 and ChromieAdaptiveFPSDB.level<6)
step(200,60);assert(ChromieAdaptiveFPSDB.level==0)
assert(cvars.farclip==2000 and cvars.groundEffectDist==140 and cvars.environmentDetail==1.5 and cvars.extShadowQuality==5)
for _,w in ipairs(writes) do assert(w.key=='farclip' or w.key=='groundEffectDist' or w.key=='environmentDetail' or w.key=='extShadowQuality') end
assert(cvars.projectedTextures==1 and cvars.groundEffectDensity==64)
""")
case('Leaving busy content restores even when outdoor FPS is low',"""
step(95,20);assert(ChromieAdaptiveFPSDB.level>0)
zone='Elwynn Forest';pvp='friendly';event('ZONE_CHANGED_NEW_AREA');step(50,20)
assert(ChromieAdaptiveFPSDB.level==0 and cvars.farclip==2000 and cvars.extShadowQuality==5)
""")
case('Outdoor low FPS ignored by default; all-location option works',"""
zone='Elwynn Forest';pvp='friendly';step(120,20);assert(#writes==0)
cmd('scope all');step(35,20);assert(ChromieAdaptiveFPSDB.level>0)
""")
case('Raid context enables adaptation outside city names',"""
zone='Icecrown Citadel';pvp='contested';inside=true;kind='raid';step(40,20)
assert(ChromieAdaptiveFPSDB.level==1)
""")
case('Manual changes win and off restores only owned settings',"""
step(80,20);cvars.farclip=1234;step(2,20)
assert(ChromieAdaptiveFPSDB.baseline.farclip==1234)
cmd('off');assert(cvars.farclip==1234 and cvars.groundEffectDist==140 and cvars.environmentDetail==1.5)
local count=#writes;step(60,20);assert(#writes==count)
""")
case('Reload/crash recovery does not adopt reduced values as baseline',"""
step(145,20);assert(cvars.farclip==1100)
event('PLAYER_LOGIN')
assert(cvars.farclip==2000 and ChromieAdaptiveFPSDB.baseline.farclip==2000 and cvars.extShadowQuality==5)
assert(ChromieAdaptiveFPSDB.level==0 and next(ChromieAdaptiveFPSDB.applied)==nil)
""")
case('Logout restores baseline',"""
step(100,20);event('PLAYER_LOGOUT')
assert(cvars.farclip==2000 and cvars.groundEffectDist==140 and cvars.environmentDetail==1.5 and cvars.extShadowQuality==5)
""")
case('World transitions and Max Zoom reassertion settle before adapting',"""
step(80,20);event('PLAYER_LEAVING_WORLD');step(30,20)
assert(cvars.farclip==2000 and ChromieAdaptiveFPSDB.level==0)
event('PLAYER_ENTERING_WORLD');cvars.farclip=2200;step(25,20)
assert(ChromieAdaptiveFPSDB.level==0 and ChromieAdaptiveFPSDB.baseline.farclip==2200)
step(10,20);assert(cvars.farclip==2200 and cvars.extShadowQuality==4)
""")
case('AFK, video options and long stalls are excluded',"""
afk=true;step(90,20);assert(#writes==0)
afk=false;videoOptions=true;step(90,20);assert(#writes==0)
videoOptions=false;now=now+3;controller.scripts.OnUpdate(controller,3)
step(5,20);assert(#writes==0);step(30,60);assert(#writes==0)
""")
case('Never raise a user setting already below the adaptive floor',"""
step(150,20);assert(cvars.farclip==400 and cvars.groundEffectDist==50 and cvars.environmentDetail==.3 and cvars.extShadowQuality==0)
""","cvars.farclip=400;cvars.groundEffectDist=50;cvars.environmentDetail=.3;cvars.extShadowQuality=0")
case('Missing or rejected CVar leaves other controls functional',"""
step(100,20);assert(cvars.farclip==2000 and cvars.environmentDetail==nil)
assert(cvars.groundEffectDist<140)
cmd('off');assert(cvars.groundEffectDist==140)
""","cvars.environmentDetail=nil;reject='farclip'")
case('Target validation, status and explicit baseline capture',"""
cmd('target 55');assert(ChromieAdaptiveFPSDB.target==55)
cmd('target 0');assert(ChromieAdaptiveFPSDB.target==55)
cmd('target garbage');assert(ChromieAdaptiveFPSDB.target==55)
step(80,20);local value=cvars.farclip;cmd('baseline')
assert(ChromieAdaptiveFPSDB.baseline.farclip==value and ChromieAdaptiveFPSDB.level==0)
cmd('status');cmd('off');assert(cvars.farclip==value)
""")
case('Opening Video Options restores normal values, ignoring clamped display values',"""
step(145,20);assert(cvars.farclip==1100)
openVideo();assert(cvars.farclip==2000 and cvars.groundEffectDist==140 and cvars.extShadowQuality==5)
local far=VideoOptionsEffectsPanel.controls[1]
assert(far.value==2000 and far.newValue==nil)
applyVideo();closeVideo();assert(cvars.farclip==2000 and ChromieAdaptiveFPSDB.baseline.farclip==2000)
step(15,20);assert(cvars.farclip==2000)
openVideo();far.newValue=1234;applyVideo();closeVideo()
assert(cvars.farclip==1234 and ChromieAdaptiveFPSDB.baseline.farclip==1234)
""")
case('In combat: steps down only below the combat target, restores nothing until combat ends',"""
event('PLAYER_REGEN_DISABLED');step(60,20);assert(ChromieAdaptiveFPSDB.level==0)
step(30,10);local inFight=ChromieAdaptiveFPSDB.level;assert(inFight>=1)
step(200,60);assert(ChromieAdaptiveFPSDB.level==inFight)
event('PLAYER_REGEN_ENABLED');step(300,60);assert(ChromieAdaptiveFPSDB.level==0)
assert(cvars.farclip==2000 and cvars.extShadowQuality==5)
""")
case('A frame rate held at the background cap (WoW unfocused) changes nothing',"""
cvars.maxfpsbk=30;step(120,30);assert(ChromieAdaptiveFPSDB.level==0 and #writes==0)
""")
case('Timed CPU capture uses deltas, ranks addons, freezes adaptation and turns profiling off',"""
assert(ChromieAdaptiveFPSProfiling)
step(9,20);assert(cpuUpdates==0)
step(32,20);local r=ChromieAdaptiveFPSDB.cpuReport
assert(r and not r.error and #r.rows==3 and r.rows[1].name=='Heavy')
assert(math.abs(r.rows[1].ms/r.seconds-60)<.001 and r.frames>0)
assert(cpuUpdates==2 and cvars.scriptProfile==0 and not ChromieAdaptiveFPSProfiling)
assert(cvars.farclip==2000 and cvars.groundEffectDist==140)
step(100,20);assert(cvars.farclip==2000 and cpuUpdates==2)
cmd('report');assert(ChromieAdaptiveFPSDB.cpuReport==r)
""","cvars.scriptProfile=1")
case('CPU API failure clears ownership and turns the next session off',"""
step(41,20);assert(ChromieAdaptiveFPSDB.cpuReport.error)
assert(cvars.scriptProfile==0 and not ChromieAdaptiveFPSProfiling)
""","cvars.scriptProfile=1;cpuError=true")
case('CPU counter reset aborts instead of producing misleading rankings',"""
step(41,20);assert(ChromieAdaptiveFPSDB.cpuReport.error)
assert(cvars.scriptProfile==0 and not ChromieAdaptiveFPSProfiling)
""","cvars.scriptProfile=1;resetCounters=true")
case('Interrupted capture cleans up on loading or logout',"""
step(15,20);event('PLAYER_LEAVING_WORLD')
assert(ChromieAdaptiveFPSDB.cpuReport.error and cvars.scriptProfile==0)
assert(not ChromieAdaptiveFPSProfiling)
""","cvars.scriptProfile=1")
case('Profiler is opt-in and preparing one never reloads or starts it prematurely',"""
step(30,60);assert(cpuUpdates==0 and not ChromieAdaptiveFPSProfiling)
cmd('profile');assert(ChromieAdaptiveFPSDB.profileRequested and cvars.scriptProfile==1)
step(30,60);assert(cpuUpdates==0)
""")
case('Saved report remains available without reactivating profiling',"""
cmd('report');step(30,60);assert(cpuUpdates==0 and not ChromieAdaptiveFPSProfiling)
""","cvars.scriptProfile=0;CarboniteRunesDB={adaptiveFPS={cpuReport={seconds=30,frames=900,rows={{name='Heavy',ms=1800}}}}}")
case('Shadow adjustment improves FPS before scenery is reduced; off restores full shadows',"""
step(34,20);assert(cvars.extShadowQuality==4)
step(40,45);assert(ChromieAdaptiveFPSDB.level==1 and cvars.farclip==2000)
cmd('off');assert(cvars.extShadowQuality==5 and cvars.farclip==2000)
""")
case('Manual shadow edits are respected',"""
step(70,20);assert(cvars.extShadowQuality==3)
cvars.extShadowQuality=1;step(2,20);cmd('off')
assert(cvars.extShadowQuality==1 and ChromieAdaptiveFPSDB.baseline.extShadowQuality==1)
""")
case('Missing or rejected shadow CVar leaves distant-detail fallback available',"""
step(150,20);assert(cvars.extShadowQuality==5 and cvars.farclip==1100)
cmd('off');assert(cvars.extShadowQuality==5 and cvars.farclip==2000)
""","reject='extShadowQuality'")
case('Reload recovery restores a shadow value applied before a crash',"""
assert(cvars.extShadowQuality==5 and ChromieAdaptiveFPSDB.baseline.extShadowQuality==5)
""","cvars.extShadowQuality=2;CarboniteRunesDB={adaptiveFPS={baseline={extShadowQuality=5},applied={extShadowQuality=2}}}")
for name in checks:
    print('ok   ', name)
print('PASSED (%d checks)' % len(checks))
