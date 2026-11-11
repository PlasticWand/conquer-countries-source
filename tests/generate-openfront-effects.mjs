// Run originals copied to Temp; never execute in the authoritative checkout.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
const ref = process.argv[2] ?? '../reference/openfront-v0.35.2';
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'conquest-effects-'));
const hashes = {};
function read(rel) {
  const s = fs.readFileSync(path.join(ref, rel), 'utf8');
  hashes[rel] = crypto.createHash('sha256').update(s).digest('hex');
  return s;
}
function body(s, marker) {
  const start = s.indexOf(marker); if (start < 0) throw Error(marker);
  const brace = s.indexOf('{', start); let end = brace+1, depth = 1;
  while(depth && end<s.length) { if(s[end]==='{')depth++; if(s[end]==='}')depth--; end++; }
  return s.slice(start,end);
}
const trailSrc = read('src/client/render/frame/TrailManager.ts');
fs.writeFileSync(path.join(temp,'Trail.ts'), trailSrc
 .replace(/import type[^;]+;\s*/g,'')
 .replace(/import \{ SMOOTHED_NUKE_TYPES \}[^;]+;/,'const SMOOTHED_NUKE_TYPES = new Set(["Atom Bomb","Hydrogen Bomb","MIRV","MIRV Warhead"]);'));
const {TrailManager} = await import('file:///'+path.join(temp,'Trail.ts').replaceAll('\\','/'));
const trails = new TrailManager(24,16);
const units = new Map(); const trailCases=[];
for(let tick=0;tick<45;tick++) {
  if(tick<24) {
    for(const id of [1,2,3,4]) {
      const pos = (id===1 ? 3*24+Math.min(tick,20) : id===2 ? Math.min(tick,14)*24+10 : id===3 ? (14-Math.min(tick,14))*24+10 : 0);
      const previous=units.get(id)?.pos ?? pos;
      units.set(id,{unitType:id===3?'Atom Bomb':'Transport',ownerID:id,pos,lastPos:previous});
    }
  }
  if(tick===14) units.delete(2);
  if(tick===24) units.delete(3);
  if(tick===30) units.delete(1);
  if(tick===40) units.clear();
  trails.update(units,[...units.keys()]);
  trailCases.push({units:[...units].map(([id,u])=>({id,...u})),values:[...trails.getTrailState()]});
}
const src = read('src/client/render/gl/passes/fx-pass/FxSpritePass.ts');
const settings = JSON.parse(read('src/client/render/gl/render-settings.json'));
const methods=['spawnFxForUnit(','private spawnNukeSprites(','pushFx(','private pushDebris(','applyConquestEvents(','tick(','private rebuildInstances(']
 .map(m=>body(src,'\n  '+m).trim().replace(/^private /,''));
const constants=src.slice(src.indexOf('export const FX_NUKE'),src.indexOf('// Active FX state'))+
 [...src.matchAll(/const SPRITE_(?:FLOATS|BYTES) = [^;]+;/g)].map(m=>m[0]).join('\n');
const prelude = `const UT_WARSHIP='Warship',UT_SHELL='Shell',UT_TRAIN='Train';
 const STRUCTURE_TYPES=new Set(['City','Port','Factory','Defense Post','SAM Launcher','Missile Silo']);
 const nukeExplosionRadius=(fx,t)=>({'Atom Bomb':fx.nukeRadiusAtom,'Hydrogen Bomb':fx.nukeRadiusHydro,'MIRV Warhead':fx.nukeRadiusMirv})[t];`;
fs.writeFileSync(path.join(temp,'Fx.ts'),prelude+constants+`\nexport {FX_CONFIG,seededRandom};\nexport class OriginalFx {mapW=24; settings=${JSON.stringify(settings)};activeFx=[]; clock=1000;timeFn=()=>this.clock;config={msPerTick:()=>100};raw=new ArrayBuffer(65536);instanceBuf={ensureCapacity:()=>{},float32:new Float32Array(this.raw),uint8:new Uint8Array(this.raw)};${methods.join('\n')}}`);
const {OriginalFx,FX_CONFIG,seededRandom}=await import('file:///'+path.join(temp,'Fx.ts').replaceAll('\\','/'));
const cases=[];
for(const kind of ['Atom Bomb','Hydrogen Bomb','MIRV Warhead','MIRV','SAMMissile','Warship','Shell','Train','City','Port','Factory','Defense Post','SAM Launcher','Missile Silo']) {
 for(const reachedTarget of [false,true]) {
  const f=new OriginalFx(); const u={unitType:kind,pos:123,reachedTarget};
  f.spawnFxForUnit(u,1000); cases.push({kind,reachedTarget,sprites:f.activeFx});
 }
}
const textSrc=read('src/client/render/gl/passes/WorldTextPass.ts');
fs.writeFileSync(path.join(temp,'Gold.ts'),'export '+body(textSrc,'function formatGold('));
const {formatGold}=await import('file:///'+path.join(temp,'Gold.ts').replaceAll('\\','/'));
const textConstants=[...textSrc.matchAll(/const CONQUEST_\w+ = [^;]+;/g)].map(m=>m[0]).join('\n');
fs.writeFileSync(path.join(temp,'ConquestText.ts'),textConstants+'\n'+body(textSrc,'function formatGold(')+
 '\nexport class OriginalText {active=[];now=()=>1000;config={msPerTick:()=>100};'+body(textSrc,'applyConquestEvents(')+'}');
const {OriginalText}=await import('file:///'+path.join(temp,'ConquestText.ts').replaceAll('\\','/'));
const conquestCases=[];
for(const tickAge of [0,1,24,25,26]) {
 const event={x:12,y:20,gold:125000,tickAge};
 const f=new OriginalFx(),text=new OriginalText();
 f.applyConquestEvents([event]);text.applyConquestEvents([event]);
 const samples=[];
 for(const age of [0,125,250,899,900,1500,2000,2499,2500]) {
  f.clock=1000+age;f.tick();
  samples.push({now:f.clock,count:f.activeFx.length,frame:f.instanceBuf.uint8[12],alpha:f.instanceBuf.uint8[13]});
 }
 const original=new OriginalFx();original.applyConquestEvents([event]);
 conquestCases.push({event,sprites:original.activeFx,popups:text.active,samples});
}
const goldValues=[1,999,1000,1001,1050,1150,1250,2250,10050,22500,999999,1000000,1050000,1150000,1250000,2250000,999999999];
const out={reference:'OpenFrontIO v0.35.2',hashes,trailCases,fxCases:cases,fxConfig:FX_CONFIG,conquestCases,
 gold:goldValues.map(value=>({value,text:formatGold(value)})),
 seeds:[0,1,123,123456789,4294967295,7978376863].map(value=>({value,result:seededRandom(value)}))};
fs.writeFileSync('tests/fixtures/OpenFrontEffects.json',JSON.stringify(out)+'\n');
console.log(`Original TS: ${trailCases.length} trail states, ${cases.length} death cases, ${conquestCases.length} conquest timelines; ${temp}`);
