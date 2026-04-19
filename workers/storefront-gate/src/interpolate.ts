// Allowlist-based HTML escape. Safe for both element content and quoted
// attributes. We never interpolate into <script>, <style>, or unquoted
// attrs, so these five replacements are sufficient. Unknown placeholders
// stay literal so a typo fails loudly in code review rather than rendering
// blank.
const ESCAPE_MAP: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

export function escapeHTML(input: string): string {
  return input.replace(/[&<>"']/g, (ch) => ESCAPE_MAP[ch] ?? ch);
}

const ALLOWED_KEYS = new Set([
  "STORE_NAME",
  "LOGO_URL",
  "SUPPORT_EMAIL",
  "RETURN_URL",
]);

// render replaces every {{KEY}} with the HTML-escaped value of fields[KEY].
// Missing keys render as empty strings; placeholders not in ALLOWED_KEYS
// are left untouched so typos surface in the rendered output during review.
export function render(template: string, fields: Record<string, string>): string {
  return template.replace(/\{\{([A-Z_]+)\}\}/g, (match, key: string) => {
    if (!ALLOWED_KEYS.has(key)) return match;
    return escapeHTML(fields[key] ?? "");
  });
}
