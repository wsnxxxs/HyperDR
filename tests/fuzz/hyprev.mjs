// HYPREV is consumed only by the legacy web panel, not by native C++/Swift.
// Exercise the real consumer in Node rather than invent a second native parser.
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';
const source=fs.readFileSync(new URL('../../apps/panel/web/js/preview/packet.js',import.meta.url),'utf8')
 .replace('import { t } from "../i18n/index.js";', 'const t = value => value;');
const {decodePreview}=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const seeds=fs.readdirSync(new URL('./seeds/hyprev/',import.meta.url)).map(n=>new Uint8Array(fs.readFileSync(new URL('./seeds/hyprev/'+n,import.meta.url))));
const seconds=Number(process.argv[2]||600),start=performance.now();let count=0,state=0x43ab18d;
function random(){state^=state<<13;state^=state>>>17;state^=state<<5;return state>>>0;}
while(performance.now()-start<seconds*1000){
 const seed=seeds[random()%seeds.length];let bytes=seed.slice();
 if(random()%4===0)bytes=bytes.slice(0,random()%(bytes.length+1));
 else for(let i=0,n=1+random()%8;i<n;i++)if(bytes.length)bytes[random()%bytes.length]^=1<<(random()%8);
 try{decodePreview(bytes.buffer);}catch{}
 count++;
}
console.log(JSON.stringify({target:'hyprev',seconds:(performance.now()-start)/1000,executions:count}));
