import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {reconcileCatalogue} from '../../charts/thirdparty/growthbook/files/helivanta-catalogue.mjs';
const origin='http://127.0.0.1:3100';
const schema=JSON.parse(await readFile(new URL('../../charts/apps/onboarding-service/files/helivanta-catalogue.schema.json',import.meta.url)));
const catalogue={version:1,policy_version:'hosted-contract',capabilities:[{key:'team_accounts',owner:'platform',eligible:true,dependencies:[]}]};
let headers={};let stage='provider startup';let status;
const delay=milliseconds=>new Promise(resolve=>setTimeout(resolve,milliseconds));
async function request(method,path,body){
 stage=path.startsWith('/api/features/')?'SDK read':method+' '+path;
 const response=await fetch(origin+path,{method,headers:{...headers,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(10000),redirect:'error'});
 status=response.status;
 if(!response.ok)throw new Error('Provider operation refused');
 return response.json();
}
try{
 let ready=false;
 for(let attempt=0;attempt<90;attempt++){
  try{const response=await fetch(origin+'/healthcheck',{signal:AbortSignal.timeout(1000)});if(response.ok){ready=true;break;}}catch{}
  await delay(1000);
 }
 assert.ok(ready);
 const {token}=await request('POST','/auth/firsttime',{email:'catalogue@example.invalid',password:randomBytes(32).toString('hex'),name:'Catalogue contract',companyname:'Helivanta'});
 assert.equal(typeof token,'string');headers={Authorization:'Bearer '+token};
 let {organizations}=await request('GET','/user');
 if(!organizations.length){await request('POST','/organization',{company:'Helivanta'});({organizations}=await request('GET','/user'));}
 assert.equal(organizations.length,1);headers['x-organization']=organizations[0].id;
 const {projects}=await request('GET','/organization/definitions');
 assert.equal(projects.length,1);const project=projects[0].id;
 await request('PUT','/projects/'+encodeURIComponent(project),{name:'Helivanta',publicId:'helivanta',description:'Hosted catalogue contract'});
 const first=await reconcileCatalogue(request,catalogue,catalogue,schema,project);
 assert.deepEqual(first,{created:1,preserved:0,policyVersion:'hosted-contract'});
 const {connection}=await request('POST','/sdk-connections',{name:'Catalogue SDK',environment:'production',projects:[project],languages:['go'],encryptPayload:false});
 assert.equal(typeof connection.key,'string');
 async function expectSDK(enabled){
  stage='SDK convergence';
  for(let attempt=0;attempt<30;attempt++){
   const payload=await request('GET','/api/features/'+encodeURIComponent(connection.key));
   const feature=payload.features?.['helivanta.release.team_accounts'];
   if(feature){let value=feature.defaultValue;for(const rule of feature.rules??[])if(typeof rule.force==='boolean')value=rule.force;if(value===enabled)return;}
   await delay(250);
  }
  throw new Error('SDK did not converge');
 }
 await expectSDK(false);
 const {key}=await request('POST','/keys',{description:'Hosted console-style manager',type:'admin'});
 assert.equal(typeof key.key,'string');const userHeaders=headers;
 headers={Authorization:'Bearer '+key.key};
 await request('POST','/api/v2/features/helivanta.release.team_accounts',{rules:[{id:'console-style-production',type:'force',value:'true',allEnvironments:false,environments:['production'],enabled:true}],environments:{production:{enabled:true}},comment:'Hosted operator preservation contract'});
 headers=userHeaders;
 const replay=await reconcileCatalogue(request,catalogue,catalogue,schema,project);
 assert.equal(replay.created,0);assert.equal(replay.preserved,1);
 await expectSDK(true);
 const features=await request('GET','/feature?project='+encodeURIComponent(project));
 assert.equal(features.features.length,1);
 console.log(JSON.stringify({contract:'helivanta-catalogue',createdDisabled:true,consoleValuePreserved:true,replayCreates:0,sdkVerified:true}));
}catch{
 console.error(JSON.stringify({contract:'helivanta-catalogue',stage,status:status??null,failed:true}));process.exitCode=1;
}
