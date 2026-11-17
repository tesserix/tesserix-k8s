import {test} from "node:test";
import assert from "node:assert/strict";
import {ensureManagement} from "../charts/thirdparty/growthbook/files/helivanta-management.mjs";

const project = "prj-helivanta";
const key = {id:"key-test",key:"synthetic-secret-for-provider-tests-only",secret:true,role:"admin",projectRoles:[]};
test("creates dedicated provider management credential with CAS0",async()=>{
 const writes=[];
 await ensureManagement(async(method,path,body)=>{if(method==="GET")return {keys:[]};writes.push({path,body});return {key};},async(method,path,body)=>{if(method==="GET")return null;writes.push({path,body});},project);
 assert.equal(writes[0].path,"/keys");assert.equal(writes[0].body.type,"admin");assert.equal(writes[0].body.projectRoles,undefined);
 assert.equal(writes[1].body.options.cas,0);assert.equal(writes[1].body.data.id,key.id);assert.equal(writes[1].body.data.project,project);
});
test("preserves existing secret and refuses unexpected or foreign management scope",async()=>{
 const stored={data:{data:{value:key.key,project,id:key.id}}};
 let writes=0;
 const bao=async(method)=>{if(method==="GET")return stored;writes++;};
 await ensureManagement(async()=>({keys:[{...key,description:"Tesserix console Helivanta release manager"}]}),bao,project);
 assert.equal(writes,0);
 for(const bad of [{...key,role:"user"},{...key,projectRoles:[{project:"foreign",role:"admin"}]},{...key,userId:"user-other"},{...key,limitAccessByEnvironment:true}]){
  await assert.rejects(ensureManagement(async()=>({keys:[{...bad,description:"Tesserix console Helivanta release manager"}]}),bao,project),/scope mismatch/);
 }
 assert.equal(writes,0);
});
test("never rotates or duplicates a credential after partial persistence failure",async()=>{
 const provider=async()=>({keys:[{...key,description:"Tesserix console Helivanta release manager"}]});
 await assert.rejects(ensureManagement(provider,async()=>null,project),/recovery requires review/);
 await assert.rejects(ensureManagement(provider,async()=>({data:{data:{value:key.key,project:"foreign",id:key.id}}}),project),/recovery requires review/);
});
