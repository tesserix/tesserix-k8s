import { readFile } from "node:fs/promises";

export async function seedHelivanta(request, config) {
  const definitions = await request("GET", "/organization/definitions");
  const matches = definitions.projects.filter((p) => p.publicId === "helivanta" || p.name === "Helivanta");
  if (matches.length > 1) throw new Error("Ambiguous Helivanta project");
  const project = matches[0] ?? (await request("POST", "/projects", { name: "Helivanta", publicId: "helivanta", description: "Helivanta release availability; independent of IAM authority" })).project;
  if (project.name !== "Helivanta" || project.publicId !== "helivanta") throw new Error("Helivanta project ownership mismatch");
  const env = "helivanta-production";
  const organization = (await request("GET", "/organization")).organization;
  const existing = organization.settings?.environments?.find((row) => row.id === env);
  if (!existing) await request("POST", "/environment", { environment: { id: env, description: "Helivanta production release controls", projects: [project.id], toggleOnList: true, defaultState: false } });
  else if (existing.projects?.length !== 1 || existing.projects[0] !== project.id) throw new Error("Helivanta environment ownership mismatch");
  const features = (await request("GET", "/feature?project=" + encodeURIComponent(project.id))).features;
  for (const [key, enabled] of Object.entries(config.flags)) {
    if (!/^helivanta\.release\.[a-z_]+$/.test(key) || typeof enabled !== "boolean") throw new Error("Invalid Helivanta release configuration");
    const current = features.find((row) => row.id === key);
    const desired = { enabled: true };
    const rules = enabled ? [{ id: "", type: "force", value: "true", description: "Helivanta foundation release", allEnvironments: false, environments: [env], enabled: true }] : [];
    if (current) {
      const settings = current.environmentSettings?.[env];
      if (current.project !== project.id || current.valueType !== "boolean" || current.defaultValue !== "false" || !settings?.enabled ||
          (enabled ? current.rules?.length !== 1 || current.rules[0].type !== "force" || current.rules[0].value !== "true" || current.rules[0].allEnvironments !== false || current.rules[0].environments?.length !== 1 || current.rules[0].environments[0] !== env || current.rules[0].enabled === false : !!current.rules?.length)) {
        throw new Error("Existing Helivanta feature differs; reviewed configuration change required");
      }
      continue;
    }
    await request("POST", "/feature", {
      id: key, project: project.id, valueType: "boolean", defaultValue: "false",
      description: "Release availability only; current authorization remains mandatory", tags: ["helivanta", "release"],
      environmentSettings: { [env]: desired }, rules,
    });
  }
  const connections = (await request("GET", "/sdk-connections")).connections.filter((row) => row.name === "Helivanta production release reader");
  if (connections.length > 1) throw new Error("Ambiguous Helivanta reader");
  const connection = connections[0] ?? (await request("POST", "/sdk-connections", {
    name: "Helivanta production release reader", environment: env, projects: [project.id], languages: ["go"],
    encryptPayload: false, includeRuleIds: false, includeVisualExperiments: false, includeDraftExperiments: false,
    includeProjectIdInMetadata: false, includeTagsInMetadata: false,
  })).connection;
  if (connection.environment !== env || connection.projects?.length !== 1 || connection.projects[0] !== project.id || connection.encryptPayload || !/^sdk-[a-zA-Z0-9_-]+$/.test(connection.key)) throw new Error("Helivanta reader scope mismatch");
  return { key: connection.key, project: project.id, environment: env, flags: Object.keys(config.flags).length };
}

export async function persistReader(request, key) {
  const path = "/v1/kv/data/helivanta/prod/app/helivanta-growthbook-sdk-key";
  const existing = await request("GET", path, undefined, true);
  if (existing) {
    if (existing.data?.data?.value !== key) throw new Error("Existing reader differs; credential rotation requires review");
    return;
  }
  await request("POST", path, { options: { cas: 0 }, data: { value: key } });
}

async function run() {
  const config = JSON.parse(await readFile("/config/helivanta-release.json", "utf8"));
  const password = (await readFile("/var/run/growthbook-admin/password", "utf8")).trim();
  const base = "http://growthbook.growthbook.svc.cluster.local:3100";
  const json = async (origin, headers, method, path, body, missing = false) => {
    let response;
    try { response = await fetch(origin + path, { method, headers: { ...headers, "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000), redirect: "error" }); }
    catch { throw new Error("Provider operation unavailable"); }
    if (missing && response.status === 404) return null;
    if (!response.ok) throw new Error("Provider operation refused (" + response.status + ")");
    const raw = await response.text();
    if (raw.length > 2_000_000) throw new Error("Provider response exceeds bound");
    try { return raw ? JSON.parse(raw) : {}; } catch { throw new Error("Invalid provider response"); }
  };
  const auth = await json(base, {}, "POST", "/auth/login", { email: config.adminEmail, password });
  if (!auth.token) throw new Error("Provider authentication refused");
  const headers = { Authorization: "Bearer " + auth.token };
  const user = await json(base, headers, "GET", "/user");
  const organizations = user.organizations.filter((row) => row.name === "Tesserix");
  if (organizations.length !== 1) throw new Error("Provider organization is ambiguous");
  headers["x-organization"] = organizations[0].id;
  const result = await seedHelivanta((...args) => json(base, headers, ...args), config);
  const bao = "http://openbao.openbao.svc:8200";
  const jwt = (await readFile("/var/run/bao/token", "utf8")).trim();
  const login = await json(bao, {}, "POST", "/v1/auth/kubernetes/login", { role: "helivanta-growthbook-writer", jwt });
  const baoHeaders = { "X-Vault-Token": login.auth.client_token };
  try { await persistReader((...args) => json(bao, baoHeaders, ...args), result.key); }
  finally { await json(bao, baoHeaders, "POST", "/v1/auth/token/revoke-self", {}); }
  console.log(JSON.stringify({ project: result.project, environment: result.environment, flagCount: result.flags, readerStored: true }));
}
if (process.argv.includes("--run")) run().catch((error) => { console.error("Helivanta release provisioning failed: " + (error instanceof Error ? error.message : "unknown error")); process.exitCode = 1; });
