// Execute the pinned BuildPreviewController only after copying it to Temp.
// Engine queries, UI settings and renderer services are explicit read fixtures.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';
const ref = process.argv[2] ?? '../reference/openfront-v0.35.2';
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'conquest-preview-'));
const hashes = {};
function read(file) {
  const source = fs.readFileSync(path.join(ref, file), 'utf8');
  hashes[file] = createHash('sha256').update(source).digest('hex');
  return source;
}
function body(source, marker) {
  const start = source.indexOf(marker);
  if (start < 0) throw Error(marker);
  let end = source.indexOf('{', start) + 1, depth = 1;
  for (; depth; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  return source.slice(start, end);
}
const names = {City:'City', Factory:'Factory', Port:'Port', DefensePost:'Defense Post', MissileSilo:'Missile Silo',
  SAMLauncher:'SAM Launcher', Warship:'Warship', AtomBomb:'Atom Bomb', HydrogenBomb:'Hydrogen Bomb', MIRV:'MIRV'};
const structures = Object.values(names).slice(0, 6);
const prelude = `const UnitType=${JSON.stringify(names)}; const Structures=new Set(${JSON.stringify(structures)});\n`;
const bulk = body(read('packages/engine-api/src/game/GameTypes.ts'), 'export function bulkCost(');
const source = read('src/client/controllers/BuildPreviewController.ts').replace(/^import[\s\S]*?;\s*/gm, '');
const output = path.join(scratch, 'BuildPreviewController.mjs');
fs.writeFileSync(output, stripTypeScriptTypes(prelude + bulk + '\n' + source, {mode:'transform'}));
const {BuildPreviewController} = await import(pathToFileURL(output).href);
const cases = [];
const configurations = Object.values(names).map(type => ({name:type, type})).concat([
  {name:'upgrade SAM',type:'SAM Launcher',upgrade:true},
  {name:'upgrade City',type:'City',upgrade:true},
  {name:'missing upgrade unit',type:'SAM Launcher',upgrade:true,missing:true},
  {name:'snapped placement',type:'City',snap:true},
  {name:'snapped same tile',type:'City',snap:true,sameTile:true},
  {name:'invalid placement',type:'Factory',invalid:true},
  {name:'unaffordable',type:'Port',gold:10},
  {name:'no ready tubes',type:'Atom Bomb',ready:0},
  {name:'warning and cost hidden',type:'Hydrogen Bomb',warning:true,showCost:false},
]);
for (const c of configurations) {
  const tile = 130;
  const bu = {type:c.type,canBuild:c.invalid ? false : c.sameTile ? tile : 200,
    canUpgrade:c.upgrade ? 9 : false,cost:125000n,ghostRailPaths:[[0,1,65]],overlappingRailroads:[0,1]};
  if (c.upgrade) bu.upgradeCosts = [125000n,375000n];
  const config = {samRange:level=>150-480/(level+5),nukeMagnitudes:type=>({outer:type==='Atom Bomb'?30:100}),
    trainStationMaxRange:()=>110,defensePostRange:()=>30};
  const game = {myPlayer:()=>({gold:()=>BigInt(c.gold??2000000),smallID:()=>1,readyMissileCount:()=>c.ready??1}),
    x:t=>t%64,y:t=>Math.floor(t/64),unit:()=>c.missing?undefined:{tile:()=>0,level:()=>2},config:()=>config};
  const controller = new BuildPreviewController(game,{}, {upgradeMultiplier:1}, {}, {},
    {snapBuildPreview:()=>c.snap??false,cursorCostLabel:()=>c.showCost??true});
  controller.ghostUnit = {buildableUnit:bu};
  const expected = controller.buildGhostPreviewData(tile,c.warning??false);
  cases.push({...c,tile,gold:c.gold??2000000,ready:c.ready??1,
    buildable:JSON.parse(JSON.stringify(bu,(_,v)=>typeof v==='bigint'?Number(v):v)),expected});
}
fs.writeFileSync('tests/fixtures/OpenFrontPreview.json',JSON.stringify({reference:'OpenFrontIO v0.35.2',hashes,cases})+'\n');
console.log(`Original TS: ${cases.length} build ghost cases; ${scratch}`);
