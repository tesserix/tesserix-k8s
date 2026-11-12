import { pathToFileURL } from "node:url";

export async function reconcile({
  baseURL,
  authUserId,
  authToken,
  fetch: request = globalThis.fetch,
}) {
  if (
    ![baseURL, authUserId, authToken].every(
      (value) => typeof value === "string" && value.length > 0,
    )
  ) {
    throw new Error("Missing membership configuration");
  }
  const api = async (endpoint, query = {}, body) => {
    const url = new URL(`/api/v1/${endpoint}`, baseURL);
    url.search = new URLSearchParams(query).toString();
    let response;
    try {
      response = await request(url, {
        method: body ? "POST" : "GET",
        headers: {
          "X-User-Id": authUserId,
          "X-Auth-Token": authToken,
          "Content-Type": "application/json",
        },
        ...(body && { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(10000),
        redirect: "error",
      });
    } catch {
      throw new Error(`Rocket.Chat ${endpoint} request failed`);
    }
    if (!response.ok)
      throw new Error(`Rocket.Chat ${endpoint} HTTP ${response.status}`);
    let data;
    try {
      data = await response.json();
    } catch {
      throw new Error(`Rocket.Chat ${endpoint} returned invalid JSON`);
    }
    if (data.success !== true)
      throw new Error(`Rocket.Chat ${endpoint} refused the operation`);
    return data;
  };
  const list = async (endpoint, key, query = {}) => {
    const result = [];
    for (let offset = 0; offset < 10000; ) {
      const data = await api(endpoint, {
        ...query,
        count: "100",
        offset: String(offset),
        sort: '{"_id":1}',
      });
      const page = data[key];
      if (
        !Array.isArray(page) ||
        page.length > 100 ||
        !Number.isInteger(data.total) ||
        data.total < 0
      )
        throw new Error(`Invalid ${endpoint} pagination`);
      result.push(...page);
      offset += page.length;
      if (offset >= data.total) return result;
      if (page.length === 0)
        throw new Error(`Incomplete ${endpoint} pagination`);
    }
    throw new Error(`Exceeded ${endpoint} pagination limit`);
  };
  const users = (
    await list("users.list", "users", {
      fields: '{"_id":1,"active":1,"type":1,"roles":1}',
    })
  ).filter(
    (user) =>
      user.active === true &&
      user.type === "user" &&
      Array.isArray(user.roles) &&
      user.roles.includes("user") &&
      !user.roles.some((role) =>
        ["bot", "app", "guest", "anonymous"].includes(role),
      ),
  );
  const channels = await list("channels.list", "channels");
  const groups = await list("groups.listAll", "groups");
  let ensured = 0;
  for (const [family, rooms] of [
    ["channels", channels],
    ["groups", groups],
  ]) {
    for (const room of rooms) {
      if (room.archived) continue;
      if (typeof room._id !== "string" || !room._id)
        throw new Error("Invalid room identity");
      for (const user of users) {
        if (typeof user._id !== "string" || !user._id)
          throw new Error("Invalid user identity");
        // Rocket.Chat's invite API is a no-op for an existing subscription.
        await api(
          `${family}.invite`,
          {},
          { roomId: room._id, userId: user._id },
        );
        ensured++;
      }
    }
  }
  return {
    rooms: channels.length + groups.length,
    users: users.length,
    ensured,
  };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    const result = await reconcile({
      baseURL: process.env.ROCKETCHAT_URL,
      authUserId: process.env.ROCKETCHAT_AUTH_USER_ID,
      authToken: process.env.ROCKETCHAT_AUTH_TOKEN,
    });
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error(
      error instanceof Error
        ? error.message
        : "Membership reconciliation failed",
    );
    process.exitCode = 1;
  }
}
