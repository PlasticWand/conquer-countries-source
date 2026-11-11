// Executes transformed copies in Temp; the pinned checkout is read-only.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {pathToFileURL} from 'node:url';
import {stripTypeScriptTypes} from 'node:module';
import {createHash} from 'node:crypto';
const root=process.argv[2]??'../reference/openfront-v0.35.2';
const file='src/client/render/gl/utils/ColorUtils.ts';
const text=fs.readFileSync(path.join(root,file),'utf8');
const defaults=JSON.parse(fs.readFileSync(path.join(root,'src/client/render/gl/render-settings.json'),'utf8'));
const copy=path.join(fs.mkdtempSync(path.join(os.tmpdir(),'conquest-terrain-reference-')),'ColorUtils.mjs');
fs.writeFileSync(copy,stripTypeScriptTypes(`const renderDefaults=${JSON.stringify(defaults)};\n`+text.replace(/^import[^;]*;\s*/gm,''),{mode:'transform'}));
const ref=await import(pathToFileURL(copy).href);
const live=Object.fromEntries(Object.entries(defaults.terrain).map(([k,v])=>[k,ref.hexToRgb(v)]));
const cases=[null,live,{oceanColor:[0,20,255],backgroundColor:[1,2,3],highlandColor:[254,255,253]}].map(colors=>{
 const pixels=new Uint8Array(256*4);
 for(let b=0;b<256;b++)ref.encodeTerrainTile(b,pixels,b*4,colors??undefined);
 return {colors,pixels:[...pixels]};
});
fs.writeFileSync('tests/fixtures/OpenFrontTerrain.json',JSON.stringify({reference:'v0.35.2',source:file,sha256:createHash('sha256').update(text).digest('hex'),node:process.version,cases},null,2)+'\n');
console.log('Wrote 768 terrain-byte vectors from copied original TypeScript');
