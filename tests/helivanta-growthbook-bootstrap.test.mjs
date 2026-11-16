import {test} from 'node:test';
import assert from 'node:assert/strict';
import {ensureRuntime} from '../charts/thirdparty/growthbook/files/helivanta-bootstrap.mjs';
test('runtime secrets are independent and create-only',async()=>{
 let created;
 await ensureRuntime(async(method,path,body)=>{if(method==='GET')return null;created=body;});
 assert.equal(created.options.cas,0);
 const values=Object.values(created.data);
 assert.equal(new Set(values).size,4);
 assert.ok(values.every(value=>/^[a-f0-9]{64}$/.test(value)));
 await ensureRuntime(async(method)=>{assert.equal(method,'GET');return {data:{data:created.data}};});
});
test('malformed existing credentials fail without overwriting',async()=>{
 await assert.rejects(ensureRuntime(async(method)=>{assert.equal(method,'GET');return {data:{data:{}}};}),/Invalid existing/);
});
