import { randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
export async function ensureRuntime(request) {
 const path='/v1/kv/data/helivanta/prod/app/helivanta-growthbook-runtime';
 const existing=await request('GET',path,undefined,true);
 if(existing) {
  for(const key of ['jwt-secret','encryption-key','mongodb-root-password','password']) {
   if(!/^[a-f0-9]{64}$/.test(existing.data?.data?.[key]??'')) throw new Error('Invalid existing runtime credential');
  }
  return;
 }
 await request('POST',path,{options:{cas:0},data:Object.fromEntries(['jwt-secret','encryption-key','mongodb-root-password','password'].map(key=>[key,randomBytes(32).toString('hex')]))});
}
async function run() {
 let token;
 const request=async(method,path,body,missing=false)=>{
  const response=await fetch('http://openbao.openbao.svc:8200'+path,{method,headers:{'Content-Type':'application/json',...(token?{'X-Vault-Token':token}:{})},body:body===undefined?undefined:JSON.stringify(body),redirect:'error',signal:AbortSignal.timeout(15000)});
  if(missing&&response.status===404)return null;
  if(!response.ok)throw new Error('OpenBao operation refused ('+response.status+')');
  return response.status===204?{}:await response.json();
 };
 const jwt=(await readFile('/var/run/bao/token','utf8')).trim();
 const login=await request('POST','/v1/auth/kubernetes/login',{role:'helivanta-growthbook-writer',jwt});
 token=login.auth.client_token;
 try {await ensureRuntime(request);} finally {await request('POST','/v1/auth/token/revoke-self',{});}
 console.log('Helivanta provider runtime credentials ready');
}
if(process.argv.includes('--run'))run().catch(()=>{console.error('Helivanta runtime bootstrap failed');process.exitCode=1;});
