// Execute copies of the pinned source in Temp, never in the read-only checkout.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import crypto from 'node:crypto';
const ref='../reference/openfront-v0.35.2';
const rel='src/client/render/frame/derive/PlayerStatus.ts';
const source=fs.readFileSync(path.join(ref,rel),'utf8');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'conquest-status-'));
const copy=source.replace(/import type[\s\S]*?;\s*/g,'')
 .replace(/import \{ NUKE_TYPES, UT_MIRV_WARHEAD \} from "..\/..\/types";/,
 'const NUKE_TYPES=["Atom Bomb","Hydrogen Bomb","MIRV"],UT_MIRV_WARHEAD="MIRV Warhead";');
const original=path.join(temp,'PlayerStatus.ts'); fs.writeFileSync(original,copy);
const {computePlayerStatus}=await import(pathToFileURL(original));
const ps=(id,extra={})=>({smallID:id,isAlive:true,tilesOwned:id*10,isTraitor:false,isDisconnected:false,
 inDoomsdayClock:false,isDecaying:false,markedDoomsdayClockTick:0,traitorRemainingTicks:0,
 allies:[],embargoes:[],outgoingAllianceRequests:[],targets:[],alliances:[],...extra});
const cases=[
 {name:'leader ties keep first arrival; dead and zero tiles',players:[ps(4,{tilesOwned:30}),ps(2,{tilesOwned:30}),ps(9,{tilesOwned:99,isAlive:false}),ps(1,{tilesOwned:0})],you:1},
 {name:'no crown for unspawned zero tiles',players:[ps(1,{tilesOwned:0}),ps(2,{tilesOwned:0})],you:1},
 {name:'relative flags bilateral embargo and incoming request',players:[ps(1,{allies:[2],embargoes:[3]}),ps(2,{outgoingAllianceRequests:['p1'],alliances:[{other:'p1',expiresAt:2300}]}),ps(3,{embargoes:[1]})],you:1},
 {name:'traitor and disconnected',players:[ps(1),ps(2,{isTraitor:true,traitorRemainingTicks:100,isDisconnected:true}),ps(3,{isTraitor:true})],you:1},
 {name:'spectator has global flags only',players:[ps(1,{allies:[2],embargoes:[2]}),ps(2,{isDisconnected:true,isTraitor:true})],you:0},
 {name:'own direct allies and teammates targets; no allies of allies',players:[ps(1,{allies:[2],targets:[3]}),ps(2,{allies:[1,4],targets:[5]}),ps(3),ps(4,{targets:[6]}),ps(5),ps(6),ps(7,{targets:[4]})],you:1,teams:{1:'Blue',7:'Blue'}},
 {name:'active nukes include tile zero and exclude inactive missiles',players:[ps(1),ps(2),ps(3)],you:1,owners:[[0,1]],units:[{id:1,unitType:'Atom Bomb',ownerID:2,isActive:true,targetTile:0},{id:2,unitType:'MIRV Warhead',ownerID:3,isActive:true,targetTile:4},{id:3,unitType:'Hydrogen Bomb',ownerID:1,isActive:false,targetTile:0},{id:4,unitType:'SAMMissile',ownerID:1,isActive:true,targetTile:0}]},
 {name:'alliance drain below zero and above duration clamp',players:[ps(1,{allies:[2,3]}),ps(2,{alliances:[{other:'p1',expiresAt:400}]}),ps(3,{alliances:[{other:'p1',expiresAt:9000}]})],you:1},
];
const wanted=['crown','traitor','disconnected','alliance','allianceReq','target','embargo','nukeActive','nukeTargetsMe','traitorRemainingTicks','allianceFraction','allianceRemainingTicks'];
for(const c of cases){
 const players=new Map(c.players.map(p=>[p.smallID,p]));
 const me=players.get(c.you), tick=500, tileState=new Uint16Array(64);
 for(const [tile,owner] of c.owners??[])tileState[tile]=owner;
 const targets=new Set();
 for(const p of c.players)if(me&&(p===me||me.allies.includes(p.smallID)||(c.teams?.[c.you]!==undefined&&c.teams[c.you]===c.teams[p.smallID])))for(const id of p.targets)targets.add(id);
 const result=computePlayerStatus(players,new Map((c.units??[]).map(u=>[u.id,u])),{localPlayerSmallID:c.you,localPlayerID:`p${c.you}`,tick,allianceDuration:3000,tileState,isTransitiveTarget:id=>targets.has(id)});
 c.expected=c.players.filter(p=>p.isAlive).map(p=>({id:p.smallID,flags:Object.fromEntries(wanted.map(k=>[k,result.get(p.smallID)?.[k]??(k.endsWith('Ticks')||k==='allianceFraction'?0:false)]))}));
 c.roster=c.players.map(p=>({smallID:p.smallID,id:`p${p.smallID}`,alive:p.isAlive,tiles:p.tilesOwned,traitor:p.isTraitor,disconnected:p.isDisconnected,traitorUntil:p.traitorRemainingTicks>0?tick+p.traitorRemainingTicks:undefined,allies:p.allies,embargoes:p.embargoes,team:c.teams?.[p.smallID]}));
 c.events=c.players.flatMap(p=>p.targets.map(targetID=>({type:'TargetPlayer',playerID:p.smallID,targetID})));
 c.diplomacy={alliances:c.players.flatMap(p=>p.alliances.filter(a=>a.other===`p${c.you}`).map(a=>({other:p.smallID,expiresAt:a.expiresAt}))),incoming:c.players.filter(p=>p.outgoingAllianceRequests.includes(`p${c.you}`)).map(p=>({requestor:p.smallID})),outgoing:[]};
 c.tick=tick; delete c.players; delete c.teams;
}
const out={reference:'OpenFront v0.35.2',source:rel,sha256:crypto.createHash('sha256').update(source).digest('hex'),cases};
fs.writeFileSync('tests/fixtures/OpenFrontStatus.json',JSON.stringify(out,null,2)+'\n');
console.log(`Original computePlayerStatus: ${cases.length} cases, copied to Temp.`);
