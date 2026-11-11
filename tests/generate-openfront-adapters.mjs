// Execute only copies of original v0.35.2 pure functions in Temp.
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import crypto from 'node:crypto';
const ref=process.argv[2]??'../reference/openfront-v0.35.2';
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'conquest-adapters-')); const hashes={};
function read(p){const s=fs.readFileSync(path.join(ref,p),'utf8');hashes[p]=crypto.createHash('sha256').update(s).digest('hex');return s;}
function body(s,marker){const i=s.indexOf(marker);if(i<0)throw Error(marker);const brace=s.indexOf('{',i);let end=brace+1,depth=1;while(depth){if(s[end]==='{')depth++;if(s[end]==='}')depth--;end++;}return s.slice(i,end);}
async function original(name,src){const p=path.join(temp,name+'.ts');fs.writeFileSync(p,src);return import('file:///'+p.replaceAll('\\','/'));}
const relation=await original('Relations',read('src/client/render/frame/derive/RelationMatrix.ts').replace(/import type[^;]+;\s*/g,''));
const cluster=await original('Clusters',read('src/client/render/frame/derive/AllianceClusters.ts').replace(/import type[^;]+;\s*/g,''));
const rosters=[
 [{smallID:1,team:null,allies:[2],embargoes:[]},{smallID:2,team:null,allies:[],embargoes:[1]},{smallID:3,team:null,allies:[],embargoes:[]}],
 [{smallID:2,team:'Blue',allies:[1],embargoes:[]},{smallID:1,team:'Blue',allies:[3],embargoes:[]},{smallID:3,team:'Red',allies:[],embargoes:[2]}],
 [{smallID:0,team:'A',allies:[1],embargoes:[]},{smallID:1,team:'A',allies:[1023,1024,4095],embargoes:[]},{smallID:1023,team:null,allies:[],embargoes:[1]},{smallID:1024,team:'A',allies:[4095],embargoes:[]},{smallID:4095,team:'A',allies:[],embargoes:[]}],
 [{smallID:1,team:null,allies:[],embargoes:[3]},{smallID:2,team:null,allies:[],embargoes:[]},{smallID:3,team:null,allies:[1],embargoes:[]}]
];
const relations=rosters.map(players=>{const map=new Map(players.map(p=>[p.smallID,p]));const {matrix,size}=relation.buildRelationMatrix(map,relation.buildTeamMap(players));const entries=[];for(let i=0;i<matrix.length;i++)if(matrix[i])entries.push([i,matrix[i]]);return {players,size,entries,clusters:[...cluster.computeAllianceClusters(map)]};});
const samSource=read('src/client/render/gl/passes/SamRadiusPass.ts');
const traj=read('src/client/render/gl/utils/NukeTrajectory.ts');
const geometry=samSource.slice(samSource.indexOf('function compareIntervalStart'),samSource.indexOf('// ---------------------------------------------------------------------------\n// Pass'));
const methods=['getSAMBaseGroup(','getSAMColor(','collectSAMCircles(','pushSAMCircles('].map(m=>body(samSource,'\n  private '+m).trim().replace(/^private /,''));
const rangeConstants=['MAX_SAM_RANGE','SAM_RANGE_DIVISOR','SAM_RANGE_OFFSET'].map(name=>traj.match(new RegExp(`(?:export )?const ${name}[^;]+;`))[0]).join('\n');
const sam=await original('SAM',`const TWO_PI=Math.PI*2,EPS=1e-9;const UT_SAM_LAUNCHER='SAM Launcher';const COLOR_SELF=[0,1,0],COLOR_ALLY=[1,1,0],COLOR_ENEMY=[1,0,0];\n${rangeConstants}\n${body(traj,'export function samRange(')}\n${geometry}\nexport {computeUncoveredArcs}; export class OriginalSAM {mapW=64;localPlayerID=1;allies=new Set([2]);allianceClusters=new Map([[1,1],[2,1],[3,3]]);colorMode='perspective';paletteData=null;colorScratch=[0,0,0];dirtyGroups=new Set();hasUpgradingSAM=false;${methods.join('\n')}}`);
const samCases=[];
const layouts=[[[10,10,10],[20,10,10]],[[10,10,10],[11,10,20]],[[10,10,10],[30,10,10]],[[10,10,10],[10,10,20]],[[0,0,10],[8,-1,8],[8,5,7]],[[0,0,10],[100,0,10]]];
for(const layout of layouts){const circles=layout.map(([x,y,radius])=>({x,y,radius,r:1,g:1,b:0,alpha:1,group:0,spin:1}));samCases.push({circles,arcs:circles.map(c=>sam.computeUncoveredArcs(c,circles))});}
const collect=[];
for(const tick of [0,12.5,22.5,45,100])for(const ownerMode of [false,true]){
 const units=[{id:1,unitType:'SAM Launcher',ownerID:1,pos:650,level:1,isActive:true,samUpgradeStartTick:0,samUpgradeDuration:45,samUpgradeStartRange:70,samUpgradeTargetLevel:2},
 {id:2,unitType:'SAM Launcher',ownerID:2,pos:680,level:2,isActive:true,samUpgradeStartTick:null},
 {id:3,unitType:'SAM Launcher',ownerID:3,pos:690,level:3,isActive:true,samUpgradeStartTick:null}];
 const pass=new sam.OriginalSAM(); pass.colorMode=ownerMode?'owner':'perspective';const circles=pass.collectSAMCircles(new Map(units.map(u=>[u.id,u])),tick);
 collect.push({tick,ownerMode,units,circles});
}
const bar=read('src/client/render/gl/passes/BarPass.ts');
const bm=['computeStructureProgress(','missileReadiness('].map(m=>body(bar,'\n  private '+m).trim().replace(/^private /,''));
const {OriginalBar}=await original('Bar',`const UT_MISSILE_SILO='Missile Silo',UT_SAM_LAUNCHER='SAM Launcher';export class OriginalBar{config:any;${bm.join('\n')}}`);
const bars=[];
for(const type of ['City','SAM Launcher','Missile Silo'])for(const tick of [0,1,10,20,50,100,400])for(const mode of ['build','reload','delete','idle']){
 const unit={unitType:type,markedForDeletion:mode==='delete'?300:false,underConstruction:mode==='build',constructionStartTick:mode==='build'?0:null,level:2,missileTimerQueue:mode==='reload'?[0]:[]};
 const pass=new OriginalBar();pass.config={deletionMarkDuration:()=>300,unitInfo:()=>({constructionDuration:type==='City'?20:type==='SAM Launcher'?300:100}),SAMCooldown:()=>90,SiloCooldown:()=>90};
 bars.push({type,tick,mode,value:pass.computeStructureProgress(unit,tick)});
}
fs.writeFileSync('tests/fixtures/OpenFrontAdapters.json',JSON.stringify({reference:'OpenFrontIO v0.35.2',hashes,relations,samCases,collect,bars})+'\n');
console.log(`Original TS: ${relations.length} relation graphs, ${samCases.length} union layouts, ${collect.length} upgrade states, ${bars.length} bar states; ${temp}`);
