// OpenFront v0.35.2 renderer vectors. Reads the pinned checkout; executes only
// transformed copies in os.tmpdir(), never code in the reference directory.
// Run: node --experimental-strip-types tests/generate-openfront-renderer.mjs
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { pathToFileURL } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';

const root = process.argv[2] ?? '../reference/openfront-v0.35.2';
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'conquest-renderer-reference-'));
const hashes = {};
const read = file => {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  hashes[file] = createHash('sha256').update(text).digest('hex');
  return text;
};
const noImports = text => text.replace(/^import[\s\S]*?;\s*/gm, '');
async function copy(name, text, prelude = '') {
  const filename = path.join(scratch, `${name}.mjs`);
  fs.writeFileSync(filename, stripTypeScriptTypes(prelude + '\n' + text, { mode: 'transform' }));
  return import(pathToFileURL(filename).href);
}
const randomSource = read('packages/engine-lib/src/PseudoRandom.ts');
const { PseudoRandom } = await copy('PseudoRandom', randomSource);
const utilSource = read('packages/engine-lib/src/Util.ts');
const hashSource = utilSource.slice(utilSource.indexOf('export function simpleHash'), utilSource.indexOf('export function calculateBoundingBox'));
const boundingSource = utilSource.slice(utilSource.indexOf('export function calculateBoundingBox'), utilSource.indexOf('\nexport ', utilSource.indexOf('export function calculateBoundingBox') + 1));
const { simpleHash } = await copy('Hash', hashSource);
const { renderNumber, renderTroops } = await copy('Format', read('packages/engine-lib/src/Format.ts'));
const cell = 'class Cell { constructor(public x: number, public y: number) {} }';
const nameBox = await copy('NameBoxCalculator', noImports(read('packages/engine/src/game/NameBoxCalculator.ts')), cell + '\n' + boundingSource);
const trajectory = await copy('NukeTrajectory', noImports(read('src/client/render/gl/utils/NukeTrajectory.ts')));
const transform = await copy('TransformHandler', noImports(read('src/client/TransformHandler.ts')),
  `${cell}\nclass ZoomEvent {} class DragEvent {} class CenterCameraEvent {} const ZOOM_DELTA_DIVISOR=600;`);

const golden = { reference: 'OpenFrontIO v0.35.2 / 08b63c054897c030e6516e0731ab7cc62b2998b7',
  node: process.version, sourceHashes: hashes, hashes: [], random: [], rectangles: [], names: [], camera: [], trajectories: [], numbers: [], firstColors: [] };
const defaultTheme=JSON.parse(read('src/client/render/gl/default-theme.json'));
const colorblindTheme=JSON.parse(read('src/client/render/gl/colorblind-theme.json'));
const allocatorSource=noImports(read('src/client/theme/ColorAllocator.ts'));
// A first allocation never invokes Colord; hex tokens suffice to execute that
// original control path without substituting a perceptual-distance function.
const allocatorPrelude=`import { PseudoRandom } from './PseudoRandom.mjs'; import { simpleHash } from './Hash.mjs';
  const extend=()=>{};const labPlugin=null;const lchPlugin=null;`;
const allocator=await copy('FirstColorAllocator',allocatorSource,allocatorPrelude);
for(const [palette,settings] of Object.entries({default:defaultTheme,colorblind:colorblindTheme})) {
  for(const type of ['HUMAN','NATION','BOT']) for(const id of ['Alice','Quebec','id-0001','\ud83d\ude80']) {
    const pool=type==='HUMAN'?settings.humanColors:type==='NATION'?settings.nationColors:settings.classicBotColors;
    const fallback=type==='HUMAN'?settings.fallbackColors:pool;
    golden.firstColors.push({palette,type,id,result:new allocator.ColorAllocator(pool,fallback).assignColor(id)});
  }
}
// Optional full colour oracle. Supply the directory of the exact locked npm
// colord package as argv[3]; copy it into scratch before importing any code.
const colordDir=process.argv[3] ?? path.join(path.dirname(root),'openfront-run/node_modules/colord');
golden.colord={verified:false,reason:'Exact colord 2.10.0 is not installed; first seeded allocations only. Shader equations are source-read tests, not GL execution.'};
if(fs.existsSync(path.join(colordDir,'package.json'))) {
  const manifest=JSON.parse(fs.readFileSync(path.join(colordDir,'package.json'),'utf8'));
  if(manifest.version!=='2.10.0')throw new Error('Expected locked colord 2.10.0');
  fs.cpSync(colordDir,path.join(scratch,'colord'),{recursive:true});
  const imports=`import {colord,extend} from './colord/index.mjs';import labPlugin from './colord/plugins/lab.mjs';import lchPlugin from './colord/plugins/lch.mjs';
    extend([lchPlugin,labPlugin]);import {PseudoRandom} from './PseudoRandom.mjs';import {simpleHash} from './Hash.mjs';`;
  const fullAllocator=await copy('ColorAllocator',allocatorSource,imports);
  const provider=read('src/client/theme/ThemeProvider.ts');
  const theme=await copy('SettingsTheme',noImports(provider.slice(0,provider.indexOf('class ThemeProvider'))),
    imports+`\nimport {ColorAllocator} from './ColorAllocator.mjs';const PlayerType={Human:'HUMAN',Bot:'BOT',Nation:'NATION'};const ColoredTeams={Bot:'Bot'};`);
  const resolve=await copy('PlayerColors',noImports(read('src/client/view/PlayerColors.ts')),imports);
  const lock=JSON.parse(read('package-lock.json'));
  const dependencyHashes=Object.fromEntries(['package.json','index.mjs','plugins/lab.mjs','plugins/lch.mjs'].map(file=>
    [file,createHash('sha256').update(fs.readFileSync(path.join(colordDir,file))).digest('hex')]));
  golden.colord={verified:true,version:manifest.version,integrity:lock.packages['node_modules/colord'].integrity,dependencyHashes};
  golden.colors=[];golden.teamPalettes=[];golden.conversions=[];golden.teamAssignments=[];golden.structureColors=[];
  golden.palettes={default:defaultTheme,colorblind:colorblindTheme};golden.perceptual=[];
  const {colord,extend}=await import(pathToFileURL(path.join(scratch,'colord/index.mjs')).href);
  const {default:lab}=await import(pathToFileURL(path.join(scratch,'colord/plugins/lab.mjs')).href);
  const {default:lch}=await import(pathToFileURL(path.join(scratch,'colord/plugins/lch.mjs')).href);extend([lab,lch]);
  for(const [palette,settings] of Object.entries({default:defaultTheme,colorblind:colorblindTheme})) {
    const palettes=theme.buildTeamPalettes(settings);
    for(const [team,colors] of palettes)golden.teamPalettes.push({palette,team,colors:colors.map(c=>c.toRgb())});
    const teamState=new theme.SettingsTheme(settings);
    for(const team of [...palettes.keys(),'Unlisted Team'])for(const id of ['Alice','polygenelubricants','A\ud83d\ude80e\u0301','repeat',
      ...['Alice','polygenelubricants','A\ud83d\ude80e\u0301','repeat'].map(id=>`${team}/${id}`)]) {
      // IDs are deliberately reused across teams to check source's ID-only cache.
      golden.teamAssignments.push({palette,team,id,result:teamState.teamColorForPlayer(team,id).toRgb(),base:teamState.teamColor(team).toRgb()});
    }
    const state=new theme.SettingsTheme(settings);
    for(const type of ['HUMAN','NATION','BOT']) for(let i=0;i<130;i++) {
      state.useClassicBotColors=type==='BOT' && i>=65;
      const id=`${type}-${i}`;
      const themed=state.territoryColor({id:()=>id,type:()=>type,team:()=>null});
      golden.colors.push({palette,type,id,classic:state.useClassicBotColors,territory:themed.toRgb(),border:state.borderColor(themed).toRgb()});
    }
    for(const hex of [...settings.humanColors,...settings.nationColors,...settings.classicBotColors,...settings.fallbackColors,
      '#000','#fff','#1234','#ff001880','#123456789','#12','abcd','  #1234  ']) {
      const c=colord(hex);golden.conversions.push({hex,rgb:c.toRgb(),hexResult:c.toHex(),lab:c.toLab(),lch:c.toLch(),dark:c.darken(.125).toRgb()});
    }
    for(const hex of [...settings.humanColors,...Object.values(settings.teamColors),'#000000','#ffffff']) {
      const c=colord(hex),s=state.structureColors(c),d=state.defendedBorderColors(c);
      golden.structureColors.push({palette,hex,light:s.light.toRgb(),dark:s.dark.toRgb(),defendedLight:d.light.toRgb(),defendedDark:d.dark.toRgb()});
    }
    const candidates=[...settings.humanColors,...settings.nationColors];
    for(let i=0;i<40;i++) {
      const available=Array.from({length:9},(_,j)=>candidates[(i*7+j*11)%candidates.length]);
      const assigned=Array.from({length:1+i%8},(_,j)=>candidates[(i*3+j*13)%candidates.length]);
      golden.perceptual.push({available,assigned,index:fullAllocator.selectDistinctColorIndex(available.map(colord),assigned.map(colord)),
        delta:colord(available[0]).delta(colord(assigned[0]))});
    }
    golden.perceptual.push({available:['#000000','#000000'],assigned:['#000000'],
      index:fullAllocator.selectDistinctColorIndex([colord('#000000'),colord('#000000')],[colord('#000000')]),delta:0});
    golden.resolve??=[];
    for(const team of [null,'Red'])for(const focused of [false,true])for(const cosmetics of [{},{color:{color:'#ff001880'}},{pattern:{}},{pattern:{colorPalette:{primaryColor:'#123456',secondaryColor:'#abcdef'}}},{color:{color:'#ff0018'},pattern:{}}]) {
      const c=colord('#9234ea'),r=resolve.resolvePlayerColors(state,c,cosmetics,team,focused);
      golden.resolve.push({palette,themed:'#9234ea',cosmetics,team,focused,territory:r.territory.toRgb(),border:r.border.toRgb()});
    }
  }
}
for (const value of ['', 'a', 'Alice', 'Quebec', '\u00e9', '\ud83d\ude80', 'A\ud83d\ude80e\u0301', 'polygenelubricants']) {
  golden.hashes.push({ value, hash: simpleHash(value), length: value.length });
}
for (const seed of [0, 1, -1, 2147483647, 2147483648, 4294967295, 4294967296, -2147483649, 3.7, -3.7]) {
  for (const maximum of [1, 3, 48, 63, 368]) golden.random.push({ seed, maximum, result: new PseudoRandom(seed).nextInt(0, maximum) });
}
const rng = new PseudoRandom(3512);
for (let i = 0; i < 90; i++) {
  const width = rng.nextInt(1, 16), height = rng.nextInt(1, 16);
  const grid = Array.from({ length: width }, () => Array.from({ length: height }, () => rng.nextInt(0, 3) > 0));
  golden.rectangles.push({ grid, result: nameBox.findLargestInscribedRectangle(grid) });
}
function mapFor(input) {
  const { width, height, seed } = input;
  const flag = t => ((t * 17 + seed) % 23);
  return { x: t => t % width, y: t => Math.floor(t / width), ref: (x,y) => y*width+x,
    isOnMap: ({x,y}) => x>=0 && y>=0 && x<width && y<height,
    isShore: t => flag(t) === 2, isOcean: t => flag(t) === 3 || flag(t) === 4,
    magnitude: t => flag(t) === 3 ? 9 : 10, owner: t => flag(t) < 19 ? 1 : 2,
    hasFallout: t => flag(t) === 22 };
}
for (const [width,height] of [[8,5],[24,24],[26,28],[49,51],[51,55],[101,105],[251,257],[501,512],[505,520]]) {
  for (const seed of [0,7,19]) {
    const input = { width, height, seed, name: seed===7 ? 'A\ud83d\ude80e\u0301' : 'Long Nation Name',
      bounds: { min:{x:1,y:1}, max:{x:width-2,y:height-2} }, spawn: width*2+3, fallback: seed===19 };
    const game = mapFor(input), border = [width+1, (height-2)*width+width-2];
    const player = { largestClusterBoundingBox: input.fallback ? null : input.bounds,
      borderTiles:()=>border, displayName:()=>input.name, spawnTile:()=>input.spawn };
    // Source compares owner objects by identity.
    const ownerOf = game.owner; game.owner = t => ownerOf(t)===1 ? player : null;
    golden.names.push({input, result:nameBox.placeName(game,player), spawn:nameBox.placeSpawnName(game,player)});
  }
}
let now = 0;
globalThis.window = { performance:{now:()=>now} };
for (const [width,height,vw,vh,left,top] of [[2000,1000,844,390,0,0],[2904,1672,1913,829,17,42],[20,20,1000,900,0,0]]) {
  const input={width,height,viewportWidth:vw,viewportHeight:vh,left,top,offsetX:0,offsetY:0,scale:1.8};
  const camera = new transform.TransformHandler({width:()=>width,height:()=>height}, {on(){}},
    {getBoundingClientRect:()=>({width:vw,height:vh,left,top})});
  const commands = [['centerAll',.9], ['zoom',left+200,top+125,-200], ['pan',500,-200],
    ['zoom',left+300,top+100,-599], ['zoom',left+300,top+100,1e7], ['pan',-1e6,1e6], ['centerAll',1]];
  const steps=[];
  const state=()=>({offsetX:camera.offsetX,offsetY:camera.offsetY,scale:camera.scale});
  for (const command of commands) {
    if(command[0]==='centerAll') camera.centerAll(command[1]);
    if(command[0]==='zoom') camera.onZoom({x:command[1],y:command[2],delta:command[3]});
    if(command[0]==='pan') camera.onMove({deltaX:command[1],deltaY:command[2]});
    steps.push({command,state:state(),world:camera.screenToWorldCoordinatesFloat(left+333.5,top+188.25),center:camera.screenCenter()});
  }
  for (let i=0;i<35;i++) {
    camera.target={x:width*.9,y:height*.8}; camera.targetScale=2.7;
    const dt=i===0 ? 16 : [16,33,100][i%3];
    if(i===0)camera.lastGoToCallTime=null;
    now+=dt; camera.goTo();
    steps.push({command:['goTo',width*.9,height*.8,2.7,dt],state:state(),world:camera.screenToWorldCoordinatesFloat(left+333.5,top+188.25),center:camera.screenCenter()});
  }
  golden.camera.push({input,steps});
}
for(let i=0;i<160;i++) {
  const input={srcX:rng.nextInt(0,2000),srcY:rng.nextInt(0,1000),dstX:rng.nextInt(0,2000)+.51,dstY:rng.nextInt(0,1000)+.49,
    mapH:1000,directionUp:i%2===0,sams:[]};
  if(i%3!==0) for(let j=0;j<8;j++) input.sams.push({x:rng.nextInt(0,2000),y:rng.nextInt(0,1000),r:trajectory.samRange(1+j)});
  golden.trajectories.push({input,result:trajectory.buildNukeTrajectory(input.srcX,input.srcY,input.dstX,input.dstY,input.mapH,input.directionUp,input.sams)});
}
for(const dst of [-1.5,-.5,.5,1.5,149.5,150.5,300,300.01]) {
  const input={srcX:0,srcY:0,dstX:dst,dstY:dst,mapH:50,directionUp:true,sams:[{x:0,y:0,r:70}]};
  golden.trajectories.push({input,result:trajectory.buildNukeTrajectory(input.srcX,input.srcY,input.dstX,input.dstY,input.mapH,input.directionUp,input.sams)});
}
for (const n of [-1,0,9.99,10,999,1000,1250,2675,9999,10000,99999,100000,999999,1000000,9999999,10000000,1e9,1e10]) {
  golden.numbers.push({input:n,result:renderNumber(n),troops:renderTroops(n)});
  for(const digits of [0,1,2,3])golden.numbers.push({input:n,digits,result:renderNumber(n,digits),troops:renderTroops(n)});
}
fs.mkdirSync('tests/fixtures',{recursive:true});
fs.writeFileSync('tests/fixtures/OpenFrontRenderer.json',JSON.stringify(golden,null,2)+'\n');
console.log(`Wrote original-TS vectors from copies in ${scratch}`);
