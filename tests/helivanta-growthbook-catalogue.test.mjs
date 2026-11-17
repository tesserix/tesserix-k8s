import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { validateCatalogue, reconcileCatalogue } from '../charts/thirdparty/growthbook/files/helivanta-catalogue.mjs';
const schema = JSON.parse(await readFile(new URL('../charts/apps/onboarding-service/values.schema.json',import.meta.url))).properties.helivantaFeatureCatalogue.properties.catalogue;
const catalogue = {version:1,policy_version:'r1',capabilities:[{key:'team_accounts',owner:'platform',eligible:true,dependencies:[]}]};
test('rejects malformed and unreviewed catalogues before provider calls',async()=>{
 for(const bad of [ {...catalogue,constructor:{}}, {...catalogue,toString:"unexpected"}, {...catalogue,unknown:true}, {...catalogue,capabilities:[{...catalogue.capabilities[0],key:'bad-key'}]}, {...catalogue,capabilities:[...catalogue.capabilities,...catalogue.capabilities]}, {...catalogue,capabilities:[{...catalogue.capabilities[0],dependencies:['missing']}]}, {...catalogue,capabilities:[{...catalogue.capabilities[0],dependencies:['team_accounts']}]} ]) {
  assert.throws(()=>validateCatalogue(bad,schema));
 }
 let calls=0;
 await assert.rejects(reconcileCatalogue(async()=>{calls++;},catalogue,{...catalogue,policy_version:'different'},schema,'prj-helivanta'));
 assert.equal(calls,0);
});
test('creates default-off flags once and preserves existing console values',async()=>{
 const features=[];const writes=[];
 const request=async(method,path,body)=>{
  if(method==='GET')return {features,hasMore:false};
  writes.push(body);features.push({...body,dateUpdated:'2026-11-17T00:00:00Z'});return {feature:features.at(-1)};
 };
 const result=await reconcileCatalogue(request,catalogue,catalogue,schema,'prj-helivanta');
 assert.equal(result.created,1);assert.equal(writes[0].defaultValue,'false');assert.deepEqual(writes[0].rules,[]);
 features[0].rules=[{type:'force',value:'true',allEnvironments:false,environments:['production'],enabled:true}];
 await reconcileCatalogue(request,catalogue,catalogue,schema,'prj-helivanta');
 assert.equal(writes.length,1);
 assert.equal(features[0].rules[0].value,'true');
});
test('preflights all existing definitions before any create',async()=>{
 const config={...catalogue,capabilities:[...catalogue.capabilities,{key:'staff_core',owner:'workforce',eligible:true,dependencies:['team_accounts']}]};
 let writes=0;
 await assert.rejects(reconcileCatalogue(async(method)=>{if(method!=='GET')writes++;return {hasMore:false,features:[{id:'helivanta.release.staff_core',project:'foreign'}]};},config,config,schema,'prj-helivanta'));
 assert.equal(writes,0);
});
test('recovers partial progress after a lost create response without resetting values',async()=>{
 const config={...catalogue,capabilities:[...catalogue.capabilities,{key:'staff_core',owner:'workforce',eligible:true,dependencies:['team_accounts']}]};
 const features=[];let attempted=0;let lose=true;
 const request=async(method,path,body)=>{
  if(method==='GET')return {features,hasMore:false};
  attempted++;features.push(body);
  if(lose){lose=false;throw new Error('lost response');}
  return {feature:body};
 };
 await assert.rejects(reconcileCatalogue(request,config,config,schema,'prj-helivanta'),/lost response/);
 const result=await reconcileCatalogue(request,config,config,schema,'prj-helivanta');
 assert.equal(attempted,2);assert.equal(result.created,1);assert.equal(result.preserved,1);
});
