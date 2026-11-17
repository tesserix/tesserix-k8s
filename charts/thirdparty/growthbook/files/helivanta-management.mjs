const path = "/v1/kv/data/helivanta/prod/app/helivanta-growthbook-management";
const description = "Tesserix console Helivanta release manager";

function assertScope(key, project) {
  if (!key.id || !key.secret || key.userId || key.disabled || key.role !== "admin" ||
      key.additionalRoles?.length || key.projectRoles?.length || key.limitAccessByEnvironment ||
      key.environments?.length) throw new Error("Management key scope mismatch");
}

export async function ensureManagement(provider, bao, project) {
  const existing = await bao("GET", path, undefined, true);
  const matches = (await provider("GET", "/keys")).keys.filter((row) => row.description === description);
  if (matches.length > 1) throw new Error("Ambiguous management credential");
  if (existing) {
    const stored = existing.data?.data;
    if (matches.length !== 1 || stored?.project !== project || stored?.id !== matches[0].id ||
        typeof stored?.value !== "string" || stored.value.length < 32) throw new Error("Management credential recovery requires review");
    assertScope(matches[0], project);
    return;
  }
  if (matches.length) throw new Error("Management credential exists without durable secret; recovery requires review");
  const {key} = await provider("POST", "/keys", {
    description, type: "admin",
  });
  assertScope(key, project);
  if (typeof key.key !== "string" || key.key.length < 32) throw new Error("Management credential missing");
  await bao("POST", path, {options: {cas: 0}, data: {value: key.key, project, id: key.id}});
}
