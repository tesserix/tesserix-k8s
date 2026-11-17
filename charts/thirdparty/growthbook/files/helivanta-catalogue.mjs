import { readFile } from 'node:fs/promises';

const origin = 'http://helivanta-growthbook.helivanta-growthbook.svc.cluster.local:3100';
const contractURL = 'https://raw.githubusercontent.com/tesserix/helivanta/release/prod/contracts/release-capabilities.json';
const prefix = 'helivanta.release.';

function validate(value, schema) {
  if ('const' in schema && value !== schema.const) throw new Error('Catalogue constant mismatch');
  if (schema.enum && !schema.enum.includes(value)) throw new Error('Catalogue enumeration mismatch');
  if (schema.type === 'object') {
    if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error('Catalogue object required');
    for (const name of schema.required ?? []) if (!(name in value)) throw new Error('Catalogue field missing');
    for (const [name, child] of Object.entries(value)) {
      if (!schema.properties?.[name]) { if (schema.additionalProperties === false) throw new Error('Unknown catalogue field'); }
      else validate(child, schema.properties[name]);
    }
  } else if (schema.type === 'array') {
    if (!Array.isArray(value) || value.length < (schema.minItems ?? 0) || value.length > (schema.maxItems ?? Infinity)) throw new Error('Invalid catalogue array');
    if (schema.uniqueItems && new Set(value.map(row => JSON.stringify(row))).size !== value.length) throw new Error('Repeated catalogue entry');
    for (const child of value) validate(child, schema.items);
  } else if (schema.type === 'string') {
    if (typeof value !== 'string' || value.length < (schema.minLength ?? 0) || value.length > (schema.maxLength ?? Infinity) || (schema.pattern && !new RegExp(schema.pattern).test(value))) throw new Error('Invalid catalogue string');
  } else if (schema.type === 'boolean' && typeof value !== 'boolean') throw new Error('Catalogue boolean required');
}

export function validateCatalogue(catalogue, schema) {
  validate(catalogue, schema);
  const definitions = new Map(catalogue.capabilities.map(row => [row.key,row]));
  if (definitions.size !== catalogue.capabilities.length) throw new Error('Duplicate catalogue key');
  const visited = new Set(); const active = new Set();
  function visit(key) {
    if (active.has(key)) throw new Error('Cyclic catalogue dependency');
    if (visited.has(key)) return;
    const definition = definitions.get(key);
    if (!definition) throw new Error('Unknown catalogue dependency');
    active.add(key);
    for (const dependency of definition.dependencies) visit(dependency);
    active.delete(key); visited.add(key);
  }
  for (const key of definitions.keys()) visit(key);
}

function projection(catalogue) {
  return {version:catalogue.version,policy_version:catalogue.policy_version,capabilities:catalogue.capabilities.map(({key,owner,eligible,dependencies})=>({key,owner,eligible,dependencies:[...dependencies].sort()})).sort((a,b)=>a.key.localeCompare(b.key))};
}
function validFeature(feature, project) {
  const rules = feature.rules ?? [];
  return feature.project === project && !feature.archived && feature.valueType === 'boolean' && feature.defaultValue === 'false' && feature.environmentSettings?.production?.enabled === true && Array.isArray(rules) && rules.length <= 1 && rules.every(rule => rule.type === 'force' && ['true','false'].includes(rule.value) && rule.enabled !== false && rule.allEnvironments === false && rule.environments?.length === 1 && rule.environments[0] === 'production' && !rule.condition && !rule.prerequisites?.length && !rule.coverage && !rule.range && !rule.namespace);
}
export async function reconcileCatalogue(request, catalogue, released, schema, project) {
  validateCatalogue(catalogue,schema);
  const approved = projection(released);
  validateCatalogue(approved,schema);
  if (!project || JSON.stringify(projection(catalogue)) !== JSON.stringify(approved)) throw new Error('Catalogue differs from deployed release contract');
  const result = await request('GET','/feature?project='+encodeURIComponent(project));
  if (!Array.isArray(result.features) || result.features.length > 100 || result.hasMore) throw new Error('Provider catalogue exceeds bound');
  const current = new Map();
  for (const feature of result.features) {
    if (!/^helivanta\.release\.[a-z][a-z_]{0,63}$/.test(feature.id) || current.has(feature.id) || !validFeature(feature,project)) throw new Error('Existing provider definition differs; review required');
    current.set(feature.id,feature);
  }
  let created = 0;
  for (const definition of catalogue.capabilities) {
    const id = prefix+definition.key;
    if (current.has(id)) continue;
    // Provider IDs are unique: a lost response is recovered by the next read, never an overwrite.
    await request('POST','/feature',{
      id,project,valueType:'boolean',defaultValue:'false',description:'Helivanta deployment catalogue; activation managed in Tesserix console',
      tags:['helivanta','release'],environmentSettings:{production:{enabled:true}},rules:[],
    });
    created++;
  }
  return {created,preserved:catalogue.capabilities.length-created,policyVersion:catalogue.policy_version};
}
async function json(address, options = {}) {
  let response;
  try { response = await fetch(address,{...options,signal:AbortSignal.timeout(15000),redirect:'error'}); }
  catch { throw new Error('Catalogue dependency unavailable'); }
  if (!response.ok) throw new Error('Catalogue dependency refused ('+response.status+')');
  const reader = response.body.getReader(); const chunks=[]; let size=0;
  try {
    for (;;) { const {value,done}=await reader.read(); if(done)break; size+=value.length; if(size>2_000_000)throw new Error('Catalogue response exceeds bound'); chunks.push(value); }
  } finally { await reader.cancel(); }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new Error('Invalid catalogue response'); }
}
async function run() {
  const raw=await readFile('/catalogue/catalogue.json','utf8');
  if(Buffer.byteLength(raw)>262144)throw new Error('Catalogue exceeds bound');
  const catalogue=JSON.parse(raw);
  const schema=JSON.parse(await readFile('/catalogue/schema.json','utf8'));
  validateCatalogue(catalogue,schema);
  const released=await json(contractURL);
  // Validate both full catalogues before authenticating to the provider.
  validateCatalogue(projection(released),schema);
  if(JSON.stringify(projection(catalogue))!==JSON.stringify(projection(released)))throw new Error('Catalogue differs from deployed release contract');
  const config=JSON.parse(await readFile('/config/helivanta-release.json','utf8'));
  if(!config.dedicated || !config.consoleManaged)throw new Error('Dedicated console-managed provider required');
  const password=(await readFile('/var/run/growthbook-admin/password','utf8')).trim();
  const call=(method,path,body,headers={})=>json(origin+path,{method,headers:{...headers,'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});
  const auth=await call('POST','/auth/login',{email:config.adminEmail,password});
  if(!auth.token)throw new Error('Provider authentication refused');
  const headers={Authorization:'Bearer '+auth.token};
  const user=await call('GET','/user',undefined,headers);
  if(user.organizations?.length!==1 || user.organizations[0].name!=='Helivanta')throw new Error('Provider organization mismatch');
  headers['x-organization']=user.organizations[0].id;
  const definitions=await call('GET','/organization/definitions',undefined,headers);
  if(definitions.projects?.length!==1 || definitions.projects[0].publicId!=='helivanta' || definitions.projects[0].name!=='Helivanta')throw new Error('Provider project mismatch');
  const result=await reconcileCatalogue((method,path,body)=>call(method,path,body,headers),catalogue,released,schema,definitions.projects[0].id);
  console.log(JSON.stringify({actor:'helivanta-feature-catalogue',...result}));
}
if(process.argv.includes('--run'))run().catch(()=>{console.error('Helivanta catalogue reconciliation failed; configuration and existing values preserved');process.exitCode=1;});
