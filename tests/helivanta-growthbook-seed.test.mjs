import { test } from "node:test";
import assert from "node:assert/strict";
import { seedHelivanta, persistReader } from "../charts/thirdparty/growthbook/files/helivanta-release.mjs";

function provider() {
  const state = { projects: [{id:"other",name:"Other product",publicId:"other"}], envs: [{id:"production"}], features: [], connections: [{name:"Shared legacy",projects:[],key:"sdk-unrelated"}], writes: [] };
  const request = async (method,path,body) => {
    if(method==="POST") state.writes.push({path,body});
    if(path==="/organization/definitions") return {projects:state.projects};
    if(path==="/organization") return {organization:{settings:{environments:state.envs}}};
    if(path==="/projects") {const project={id:"helivanta-project",...body};state.projects.push(project);return {project};}
    if(path==="/environment") {state.envs.push(body.environment);return {};}
    if(path.startsWith("/feature?")) return {features:state.features};
    if(path==="/feature") {state.features.push(body);return {};}
    if(path==="/sdk-connections" && method==="GET") return {connections:state.connections};
    if(path==="/sdk-connections") {const connection={...body,key:"sdk-helivanta"};state.connections.push(connection);return {connection};}
    throw new Error("Unexpected provider operation");
  };
  return {state,request};
}
const config={flags:{"helivanta.release.team_accounts":true,"helivanta.release.pharmacy_counter":false}};

test("creates an isolated project/environment/reader and retries without changing shared data",async()=>{
 const {state,request}=provider(); const result=await seedHelivanta(request,config);
 assert.equal(result.key,"sdk-helivanta");assert.equal(result.flags,2);
 assert.deepEqual(state.projects[0],{id:"other",name:"Other product",publicId:"other"});
 assert.deepEqual(state.envs[0],{id:"production"});
 assert.deepEqual(state.connections[0],{name:"Shared legacy",projects:[],key:"sdk-unrelated"});
 assert.equal(state.features[0].defaultValue,"false");
 assert.deepEqual(state.features[0].environmentSettings,{"helivanta-production":{enabled:true}});
 assert.equal(state.features[0].rules[0].type,"force");assert.equal(state.features[0].rules[0].value,"true");assert.deepEqual(state.features[0].rules[0].environments,["helivanta-production"]);
 assert.deepEqual(state.features[1].rules,[]);
 const count=state.writes.length;await seedHelivanta(request,config);assert.equal(state.writes.length,count);
});
test("refuses an existing globally scoped Helivanta reader",async()=>{
 const {state,request}=provider();state.connections.push({name:"Helivanta production release reader",key:"sdk-wrong",environment:"helivanta-production",projects:[]});
 await assert.rejects(seedHelivanta(request,config),/reader scope mismatch/);
});
test("does not overwrite a human-changed flag",async()=>{
 const {state,request}=provider();await seedHelivanta(request,config);state.features[0].rules=[];
 const count=state.writes.length;await assert.rejects(seedHelivanta(request,config),/reviewed configuration/);assert.equal(state.writes.length,count);
});
test("stores a new reader with CAS and never rotates a different existing credential",async()=>{
 const writes=[];await persistReader(async(method,path,body)=>{if(method==="GET")return null;writes.push({path,body});},"sdk-synthetic");
 assert.deepEqual(writes,[{path:"/v1/kv/data/helivanta/prod/app/helivanta-growthbook-sdk-key",body:{options:{cas:0},data:{value:"sdk-synthetic"}}}]);
 await assert.rejects(persistReader(async()=>({data:{data:{value:"sdk-other"}}}),"sdk-synthetic"),/rotation requires review/);
});
