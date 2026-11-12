import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { reconcile } from "../charts/thirdparty/rocketchat/files/ensure-membership.mjs";

const member = {
  _id: "mahesh-id",
  active: true,
  type: "user",
  roles: ["user", "admin"],
};

function workspace({
  users = [member],
  fail = "",
  rooms = [
    { _id: "public", t: "c" },
    { _id: "private", t: "p" },
  ],
} = {}) {
  const joined = new Set();
  const invites = [];
  const fetch = async (url, options) => {
    const endpoint = url.pathname.split("/").at(-1);
    if (endpoint === fail)
      return new Response(JSON.stringify({ success: false }), { status: 403 });
    let data;
    if (endpoint === "users.list") {
      const offset = Number(url.searchParams.get("offset"));
      data = { users: users.slice(offset, offset + 1), total: users.length };
    } else if (endpoint.endsWith(".list") || endpoint === "groups.listAll") {
      const key = endpoint.startsWith("channels") ? "channels" : "groups";
      const type = key === "channels" ? "c" : "p";
      const all = rooms.filter((room) => room.t === type);
      const offset = Number(url.searchParams.get("offset"));
      data = { [key]: all.slice(offset, offset + 1), total: all.length };
    } else if (endpoint.endsWith(".invite")) {
      const body = JSON.parse(options.body);
      const key = `${body.roomId}:${body.userId}`;
      if (!joined.has(key)) invites.push([endpoint, body.roomId, body.userId]);
      joined.add(key);
      data = {};
    } else throw new Error("Unexpected API call");
    return new Response(JSON.stringify({ success: true, ...data }));
  };
  return { fetch, invites, joined };
}

const options = {
  baseURL: "https://rocketchat.tesserix.app",
  authUserId: "operator",
  authToken: "test-only",
};

test("executes the CLI through a ConfigMap-style symlink", () => {
  const directory = mkdtempSync(join(tmpdir(), "rocketchat-cli-"));
  try {
    const mounted = join(directory, "mounted.mjs");
    const preload = join(directory, "fetch.mjs");
    symlinkSync(
      fileURLToPath(
        new URL(
          "../charts/thirdparty/rocketchat/files/ensure-membership.mjs",
          import.meta.url,
        ),
      ),
      mounted,
    );
    writeFileSync(
      preload,
      "globalThis.fetch = async () => new Response('{}', {status: 403});",
    );
    const result = spawnSync(process.execPath, ["--import", preload, mounted], {
      encoding: "utf8",
      timeout: 5000,
      env: {
        ROCKETCHAT_URL: "https://rocketchat.example.invalid",
        ROCKETCHAT_AUTH_USER_ID: "test-user",
        ROCKETCHAT_AUTH_TOKEN: "test-only",
      },
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Rocket.Chat users.list HTTP 403/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("joins existing public and private channels once and picks up a new channel", async () => {
  const rooms = [
    { _id: "public", t: "c" },
    { _id: "private", t: "p" },
  ];
  const api = workspace({ rooms });
  await reconcile({ ...options, fetch: api.fetch });
  assert.deepEqual(api.invites, [
    ["channels.invite", "public", "mahesh-id"],
    ["groups.invite", "private", "mahesh-id"],
  ]);
  await reconcile({ ...options, fetch: api.fetch });
  assert.equal(api.invites.length, 2);
  rooms.push({ _id: "new-channel", t: "c" });
  await reconcile({ ...options, fetch: api.fetch });
  assert.deepEqual(api.invites.at(-1), [
    "channels.invite",
    "new-channel",
    "mahesh-id",
  ]);
});

test("paginates rooms rather than stopping at the first page", async () => {
  const api = workspace({
    rooms: [
      { _id: "first", t: "c" },
      { _id: "second", t: "c" },
    ],
  });
  await reconcile({ ...options, fetch: api.fetch });
  assert.deepEqual([...api.joined], ["first:mahesh-id", "second:mahesh-id"]);
});

test("joins new active humans while excluding deactivated users and service identities", async () => {
  const users = [
    member,
    { ...member, _id: "disabled", active: false },
    { ...member, _id: "bot", roles: ["user", "bot"] },
    { ...member, _id: "app", type: "app" },
    { ...member, _id: "automation", roles: ["admin"] },
  ];
  const api = workspace({ users });
  await reconcile({ ...options, fetch: api.fetch });
  assert.equal(api.invites.length, 2);
  users.push({ ...member, _id: "new-human", roles: ["user"] });
  await reconcile({ ...options, fetch: api.fetch });
  assert.deepEqual(api.invites.slice(2), [
    ["channels.invite", "public", "new-human"],
    ["groups.invite", "private", "new-human"],
  ]);
});

test("does not turn authorization failures into missing rooms or success", async () => {
  const api = workspace({ fail: "groups.listAll" });
  await assert.rejects(reconcile({ ...options, fetch: api.fetch }), /403/);
  assert.equal(api.invites.length, 0);
});

test("fails if invitation is refused and never logs a token in its error", async () => {
  const api = workspace({ fail: "channels.invite" });
  await assert.rejects(
    reconcile({ ...options, fetch: api.fetch }),
    (error) =>
      error.message.includes("403") &&
      !error.message.includes(options.authToken),
  );
});
