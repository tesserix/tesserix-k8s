import { describe, it, expect } from "vitest";
import { escapeHTML, render } from "../src/interpolate";

describe("escapeHTML", () => {
  it("escapes the five HTML-sensitive characters", () => {
    expect(escapeHTML(`<script>alert("x&y'z")</script>`)).toBe(
      "&lt;script&gt;alert(&quot;x&amp;y&#39;z&quot;)&lt;/script&gt;",
    );
  });

  it("leaves safe text untouched", () => {
    expect(escapeHTML("Acme Roasters · Specialty coffee")).toBe(
      "Acme Roasters · Specialty coffee",
    );
  });

  it("handles empty string", () => {
    expect(escapeHTML("")).toBe("");
  });
});

describe("render", () => {
  const template = `<h1>{{STORE_NAME}}</h1><a href="mailto:{{SUPPORT_EMAIL}}">Contact</a>`;

  it("interpolates escaped fields", () => {
    const out = render(template, {
      STORE_NAME: `<b>Acme</b>`,
      SUPPORT_EMAIL: `x"@y.com`,
    });
    expect(out).toContain("&lt;b&gt;Acme&lt;/b&gt;");
    expect(out).toContain(`mailto:x&quot;@y.com`);
  });

  it("replaces missing fields with empty string", () => {
    const out = render(template, {});
    expect(out).toContain("<h1></h1>");
    expect(out).toContain(`mailto:`);
  });

  it("ignores unknown placeholders (leaves them literal)", () => {
    const out = render(`{{UNKNOWN}} {{STORE_NAME}}`, { STORE_NAME: "X" });
    expect(out).toBe("{{UNKNOWN}} X");
  });

  it("handles XSS-style injection in store name without breaking layout", () => {
    const out = render(`<title>{{STORE_NAME}}</title>`, {
      STORE_NAME: `</title><script>alert(1)</script><title>x`,
    });
    expect(out).not.toContain("</title><script>");
    expect(out).toContain("&lt;/title&gt;&lt;script&gt;");
  });
});
