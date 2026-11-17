import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
const schema = JSON.parse(await readFile(new URL('../charts/apps/onboarding-service/files/helivanta-catalogue.schema.json',import.meta.url)));
const moduleURL=new URL('../charts/thirdparty/growthbook/files/helivanta-catalogue.mjs',import.meta.url).href;
test('actual reconciler entry consumes mounted catalogue and creates only disabled features',()=>{
 const program=`
 import assert from 'node:assert/strict';
 import fs from 'node:fs/promises';
 import {syncBuiltinESMExports} from 'node:module';
 const catalogue={version:1,policy_version:'r1',capabilities:[{key:'team_accounts',owner:'platform',eligible:true,dependencies:[]}]};
 const config={dedicated:true,consoleManaged:true,adminEmail:'synthetic@example.invalid'};
 fs.readFile=async(path)=>{
  if(path==='/catalogue/catalogue.json')return JSON.stringify(catalogue);
  if(path==='/catalogue/schema.json')return ${JSON.stringify(JSON.stringify(schema))};
  if(path==='/config/helivanta-release.json')return JSON.stringify(config);
  if(path==='/var/run/growthbook-admin/password')return 'synthetic-password';
  throw new Error('unexpected file read');
 };
 syncBuiltinESMExports();
 let writes=0;
 globalThis.fetch=async(address,options)=>{
  const url=new URL(address);const path=url.pathname;
  let result={};
  if(url.hostname==='raw.githubusercontent.com'){
   assert.equal(options.headers,undefined);result=catalogue;
  }else{
   assert.equal(url.hostname,'helivanta-growthbook.helivanta-growthbook.svc.cluster.local');
   if(path==='/auth/login')result={token:'synthetic-token'};
   else {
    assert.equal(options.headers.Authorization,'Bearer synthetic-token');
    if(path==='/user')result={organizations:[{id:'org-one',name:'Helivanta'}]};
    else if(path==='/organization/definitions')result={projects:[{id:'prj-one',name:'Helivanta',publicId:'helivanta'}]};
    else if(path==='/feature'&&options.method==='GET')result={features:[]};
    else if(path==='/feature'&&options.method==='POST'){
     writes++;const body=JSON.parse(options.body);
     assert.equal(body.id,'helivanta.release.team_accounts');assert.equal(body.defaultValue,'false');assert.deepEqual(body.rules,[]);
    }else throw new Error('unexpected provider operation');
   }
  }
  return new Response(JSON.stringify(result),{status:200});
 };
 const complete=new Promise(resolve=>console.log=message=>resolve(JSON.parse(message)));
 const deadline=setTimeout(()=>process.exit(1),3000);
 process.argv.push('--run');await import(${JSON.stringify(moduleURL)});
 const result=await complete;clearTimeout(deadline);
 assert.equal(result.actor,'helivanta-feature-catalogue');assert.equal(result.created,1);assert.equal(writes,1);
 `;
 const result=spawnSync(process.execPath,['--input-type=module','-e',program],{encoding:'utf8',timeout:10000});
 assert.equal(result.status,0,result.stderr);
 assert.equal(result.stdout,'');
});
