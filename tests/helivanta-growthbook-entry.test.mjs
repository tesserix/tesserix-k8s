import {test} from "node:test";
import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";

test("the production entry point persists both credentials before reporting success",()=>{
 const moduleURL=new URL("../charts/thirdparty/growthbook/files/helivanta-release.mjs",import.meta.url).href;
 const program=`
 import assert from 'node:assert/strict';
 import fs from 'node:fs/promises';
 import {syncBuiltinESMExports} from 'node:module';
 const config={dedicated:true,consoleManaged:true,adminEmail:'fixture@example.invalid',flags:{'helivanta.release.team_accounts':false}};
 fs.readFile=async(path)=>{
  if(path==='/config/helivanta-release.json')return JSON.stringify(config);
  if(path==='/var/run/growthbook-admin/password')return 'synthetic-password';
  if(path==='/var/run/bao/token')return 'synthetic-kubernetes-token';
  throw new Error('unexpected file read');
 };
 syncBuiltinESMExports();
 const writes=[];
 const project={id:'prj-helivanta',name:'Helivanta',publicId:'helivanta'};
 globalThis.fetch=async(address,options)=>{
  const url=new URL(address);const path=url.pathname;const method=options.method;
  const body=options.body?JSON.parse(options.body):undefined;
  let result={};let status=200;
  if(url.hostname==='openbao.openbao.svc'){
   if(path==='/v1/auth/kubernetes/login')result={auth:{client_token:'synthetic-bao-token'}};
   else if(path.startsWith('/v1/kv/data/')&&method==='GET')status=404;
   else if(path.startsWith('/v1/kv/data/')&&method==='POST')writes.push({path,body});
   else assert.equal(path,'/v1/auth/token/revoke-self');
  }else{
   assert.equal(url.hostname,'helivanta-growthbook.helivanta-growthbook.svc.cluster.local');
   if(path==='/auth/login')result={token:'synthetic-provider-token'};
   else if(path==='/user')result={organizations:[{id:'org-helivanta',name:'Helivanta'}]};
   else if(path==='/organization/definitions')result={projects:[project]};
   else if(path==='/organization')result={organization:{settings:{environments:[{id:'production'}]}}};
   else if(path==='/feature'&&method==='GET')result={features:[]};
   else if(path==='/feature'&&method==='POST')result={};
   else if(path==='/sdk-connections'&&method==='GET')result={connections:[]};
   else if(path==='/sdk-connections'&&method==='POST')result={connection:{...body,key:'sdk-synthetic'}};
   else if(path==='/keys'&&method==='GET')result={keys:[]};
   else if(path==='/keys'&&method==='POST')result={key:{id:'key-synthetic',key:'synthetic-provider-management-key-only',role:body.type,secret:true}};
   else throw new Error('unexpected provider operation');
  }
  return new Response(JSON.stringify(result),{status,headers:{'Content-Type':'application/json'}});
 };
 let complete;const finished=new Promise(resolve=>complete=resolve);
 console.log=(message)=>complete(JSON.parse(message));
 const deadline=setTimeout(()=>{process.stderr.write('entry point did not complete');process.exit(1);},3000);
 process.argv.push('--run');await import(${JSON.stringify(moduleURL)});
 const result=await finished;clearTimeout(deadline);
 assert.equal(result.managementStored,true);
 assert.equal(writes.length,2);
 assert.deepEqual(writes.map(row=>row.path),['/v1/kv/data/helivanta/prod/app/helivanta-growthbook-sdk-key','/v1/kv/data/helivanta/prod/app/helivanta-growthbook-management']);
 assert.equal(writes[1].body.options.cas,0);
 assert.equal(writes[1].body.data.project,project.id);
 `;
 const result=spawnSync(process.execPath,['--input-type=module','-e',program],{encoding:'utf8',timeout:10000});
 assert.equal(result.status,0,result.stderr);
});
