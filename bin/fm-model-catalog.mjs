#!/usr/bin/env node
// Score live harness model listings into quality/economy weights and roles.
//
// Artificial Analysis supplies quality and USD per million token pricing:
// https://artificialanalysis.ai/ . Vendor listings determine availability.
// score/write accept artificialAnalysis: {data: [...]} beside those listings.
// refresh-aa <cache> enriches stdin with a 24h cached, paginated free API result;
// only the daily rebuild calls it. No credentials enter the payload/cache.
// pick <harness> <role> reads a scored catalog on stdin, without network I/O.
// bin/fm-model-catalog.sh owns collection, daily refresh, and dispatch expansion.

import { readFileSync, writeFileSync, renameSync, unlinkSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import path from "node:path";

const ROLE_CHEAP = "cheap";
const ROLE_CURRENT = "current";
const ROLE_FLAGSHIP = "flagship";
const ROLE_EFFORT = {
  [ROLE_CHEAP]: "low",
  [ROLE_CURRENT]: "medium",
  [ROLE_FLAGSHIP]: "high",
};
const EXCLUDED_ROLE_EFFORT = new Set(["xhigh", "max", "ultra", "none"]);

export function generationOf(id) {
  const s = String(id || "").toLowerCase();
  let m = s.match(/(\d+)\.(\d+)/);
  if (m) return Number(m[1]) + Number(m[2]) / 10;
  m = s.match(/(?:opus|sonnet|haiku|fable)-(\d+)-(\d+)/);
  if (m) return Number(m[1]) + Number(m[2]) / 10;
  m = s.match(/(?:opus|sonnet|haiku|fable)-(\d+)(?:-|$)/);
  if (m) return Number(m[1]);
  m = s.match(/gpt-(\d+)(?:-|$)/);
  if (m) return Number(m[1]);
  m = s.match(/grok-(\d+)/);
  if (m) return Number(m[1]);
  m = s.match(/composer-(\d+)/);
  if (m) return Number(m[1]);
  m = s.match(/claude-(\d+)(?:-|$)/);
  if (m) return Number(m[1]);
  return 0;
}

export function claudeSpawnId(cursorId) {
  let id = String(cursorId || "");
  const strip = [
    "-fast",
    "-thinking",
    "-extra-high",
    "-xhigh",
    "-none",
    "-low",
    "-medium",
    "-high",
    "-max",
  ];
  let changed = true;
  while (changed) {
    changed = false;
    for (const suffix of strip) {
      if (id.toLowerCase().endsWith(suffix)) {
        id = id.slice(0, -suffix.length);
        changed = true;
      }
    }
  }
  return id;
}

function clamp(n) {
  return Math.max(0, Math.min(100, Math.round(n)));
}

export function isFastId(id, label = "") {
  const s = String(id || "").toLowerCase();
  if (s.endsWith("-fast") || s.includes("build-fast")) return true;
  return /\bfast\b/i.test(label) && /fast/i.test(s);
}

export function effortOf(id) {
  const s = String(id || "").toLowerCase().replace(/-fast$/, "");
  if (/-ultra$/.test(s)) return "ultra";
  if (/-max$/.test(s)) return "max";
  if (/-xhigh$/.test(s) || /-extra-high$/.test(s)) return "xhigh";
  if (/-high$/.test(s)) return "high";
  if (/-medium$/.test(s)) return "medium";
  if (/-low$/.test(s)) return "low";
  if (/-none$/.test(s)) return "none";
  return null;
}

function scoreRow({ id, label = "", extra = {} }, aa = null) {
  const text = `${id} ${label} ${extra.description || ""}`.toLowerCase();
  const generation = generationOf(id);
  const fast = isFastId(id, label);
  const effort = effortOf(id);
  let quality = generation * 12;
  let economy = 100 - generation * 8;
  if (!aa && /\b(current|flagship|frontier)\b/.test(text)) quality += 18;
  if (/\b(older|legacy|previous generation)\b/.test(text)) {
    quality -= 28;
    economy += 8;
  }
  if (!aa && id.toLowerCase().includes("composer")) {
    economy += 22;
    quality += 8;
  }
  if (id.toLowerCase().includes("haiku") || id.toLowerCase().includes("luna") || id.toLowerCase().includes("reserve")) {
    economy += 18;
    quality -= 4;
  }
  if (id.toLowerCase().includes("sonnet")) economy += 12;
  if (/opus|fable/i.test(id)) economy -= 8;
  if (fast) {
    // Fast SKUs cost about 2x the standard model; never treat them as economical.
    economy -= 30;
    quality -= 4;
  }
  if (effort === "xhigh" || effort === "max" || effort === "ultra") quality += 4;
  if (effort === "high") quality += 3;
  if (effort === "low") {
    quality -= 4;
    economy += 6;
  }
  if (extra.default) quality += 6;
  if (typeof extra.priority === "number") quality += Math.max(0, 16 - extra.priority);
  quality = clamp(quality);
  economy = clamp(economy);
  const weight = clamp(quality * 0.65 + economy * 0.35);
  const row = { id, label, generation, quality, economy, weight, fast, effort, ...extra };
  if (!aa) return row;
  // Exact effort-specific measurements take precedence; never borrow a sibling
  // effort's score. A base measurement may cover a listing with an effort suffix.
  const slug = id.toLowerCase().replaceAll(".", "-");
  const measured = aa.get(slug) || aa.get(claudeSpawnId(slug));
  const evaluations = measured?.evaluations;
  const index = evaluations?.artificial_analysis_intelligence_index;
  const usable = (value) => typeof value === "number" && Number.isFinite(value) && value > 0;
  if (!usable(index)) return { ...row, source: "generation" };
  const pricing = measured.pricing || {};
  let price = pricing.price_1m_blended_3_to_1;
  if (!usable(price)) {
    const input = pricing.price_1m_input_tokens;
    const output = pricing.price_1m_output_tokens;
    price = typeof input === "number" && input >= 0 && typeof output === "number" && output >= 0
      ? input + output : null;
  }
  price = usable(price) ? price : null;
  return {
    ...row, source: "Artificial Analysis", aaSlug: measured.slug,
    quality: index, economy: price == null ? null : 1 / price,
    qualityPerDollar: price == null ? null : index / price,
    price, weight: index,
  };
}

export function parseCursorList(text) {
  const models = [];
  for (const raw of String(text || "").split(/\r?\n/)) {
    const line = raw.replace(/\s+$/, "");
    const sep = line.indexOf(" - ");
    if (sep <= 0) continue;
    const id = line.slice(0, sep).trim();
    const label = line.slice(sep + 3).trim();
    if (!id || id.toLowerCase() === "auto" || id.includes(" ")) continue;
    models.push(scoreRow({ id, label }));
  }
  return models;
}

export function parseGrokList(text) {
  const models = [];
  for (const raw of String(text || "").split(/\r?\n/)) {
    const m = raw.match(/^\s*([*-])\s+(\S+)/);
    if (!m) continue;
    const id = m[2];
    if (id.toLowerCase() === "available") continue;
    models.push(scoreRow({
      id,
      label: raw.includes("default") ? "default" : "",
      extra: { default: m[1] === "*" || /default/i.test(raw) },
    }));
  }
  return models;
}

export function parseCodexCache(cache) {
  const list = Array.isArray(cache?.models) ? cache.models : [];
  const models = [];
  for (const row of list) {
    if (!row?.slug) continue;
    if (row.visibility && row.visibility !== "list") continue;
    models.push(scoreRow({
      id: row.slug,
      label: `${row.display_name || ""} ${row.description || ""}`,
      extra: {
        description: row.description || "",
        priority: row.priority,
        displayName: row.display_name,
      },
    }));
  }
  return models;
}

function matchesRoleEffort(row, role) {
  const effort = row.effort;
  if (EXCLUDED_ROLE_EFFORT.has(effort)) return false;
  if (role === ROLE_FLAGSHIP) return effort === "high" || effort == null;
  if (role === ROLE_CURRENT) return effort === "medium" || effort == null;
  if (role === ROLE_CHEAP) return effort === "low" || effort === "medium" || effort == null;
  return true;
}

function pickForRole(standard, role, aaAvailable = false) {
  if (aaAvailable) {
    const eligible = standard.filter((m) => matchesRoleEffort(m, role));
    const effortRank = (m) => (m.effort === "low" ? 0 : m.effort === "medium" ? 1 : 2);
    const measured = eligible.filter((m) => m.source === "Artificial Analysis"
      && (role === ROLE_FLAGSHIP || m.price != null));
    const metric = role === ROLE_FLAGSHIP ? "quality" : role === ROLE_CURRENT ? "qualityPerDollar" : "economy";
    if (measured.length) return [...measured].sort((a, b) =>
      b[metric] - a[metric] || b.quality - a.quality
      || (role === ROLE_CHEAP ? effortRank(a) - effortRank(b) : 0)
      || a.id.localeCompare(b.id))[0];
    // Preserve availability for an entirely unmeasured harness, but never mix
    // heuristic weights with measured indices or assign an incompatible effort.
    const unmatched = eligible.filter((m) => m.source !== "Artificial Analysis");
    return [...unmatched].sort((a, b) => b.generation - a.generation
      || b.quality - a.quality || a.id.localeCompare(b.id))[0] || null;
  }
  const exact = standard.filter((m) => matchesRoleEffort(m, role));
  const pool = exact.length ? exact : standard.filter((m) => !EXCLUDED_ROLE_EFFORT.has(m.effort));
  const use = pool.length ? pool : standard;
  if (!use.length) return null;
  if (role === ROLE_CHEAP) {
    const labeled = use.find((m) => /\bcurrent\b/i.test(m.label || ""));
    if (labeled) return labeled;
    return [...use].sort(
      (a, b) => (b.economy + b.generation * 15) - (a.economy + a.generation * 15) || b.weight - a.weight,
    )[0];
  }
  if (role === ROLE_CURRENT) {
    const labeled = use.find((m) => /\bcurrent\b/i.test(m.label || ""));
    if (labeled) return labeled;
  }
  return [...use].sort(
    (a, b) => b.generation - a.generation || b.quality - a.quality || b.weight - a.weight,
  )[0];
}

function pickRoles(models, harness, aaAvailable = false) {
  const standard = models.filter((m) => !m.fast);
  if (!standard.length) return {};
  const toRole = (row, role) => {
    if (!row) return null;
    const effort = harness === "cursor" ? row.effort : row.effort || ROLE_EFFORT[role];
    return {
      role,
      model: row.id,
      effort,
      fast: false,
      quality: row.quality,
      economy: row.economy,
      weight: row.weight,
      generation: row.generation,
      source: row.source || "heuristic",
      aaSlug: row.aaSlug,
      price: row.price,
      qualityPerDollar: row.qualityPerDollar,
      why: row.label || row.description || "",
    };
  };
  const roles = {};
  const flagship = toRole(pickForRole(standard, ROLE_FLAGSHIP, aaAvailable), ROLE_FLAGSHIP);
  const current = toRole(pickForRole(standard, ROLE_CURRENT, aaAvailable), ROLE_CURRENT);
  const cheap = toRole(pickForRole(standard, ROLE_CHEAP, aaAvailable), ROLE_CHEAP);
  if (flagship) roles[ROLE_FLAGSHIP] = flagship;
  if (current) roles[ROLE_CURRENT] = current;
  if (cheap) roles[ROLE_CHEAP] = cheap;
  return roles;
}

function isClaudeCodeId(id) {
  return /^claude-(haiku|sonnet|opus|fable)-/i.test(id);
}

function claudeFromCursor(cursorModels) {
  const mapped = [];
  const seen = new Set();
  for (const row of cursorModels) {
    if (!/^claude-/i.test(row.id)) continue;
    const id = claudeSpawnId(row.id);
    if (!id || !isClaudeCodeId(id) || seen.has(id)) continue;
    seen.add(id);
    mapped.push(scoreRow({ id, label: row.label }));
  }
  return mapped;
}

export function buildCatalog(input) {
  const aa = input.artificialAnalysis == null ? null : new Map(
    validateAA(input.artificialAnalysis).map((row) => [row.slug, row]),
  );
  const cursor = parseCursorList(input.cursorText || "");
  const grok = parseGrokList(input.grokText || "");
  const codex = parseCodexCache(input.codexCache || {});
  const claudeListed = parseCursorList(input.claudeText || "");
  const claude = claudeListed.length ? claudeListed : claudeFromCursor(cursor);
  const harnesses = {};
  const assign = (name, models) => {
    if (!models.length) return;
    if (aa) models = models.map(({ id, label, ...extra }) => {
      const { quality, economy, weight, generation, fast, effort, ...metadata } = extra;
      return scoreRow({ id, label, extra: metadata }, aa);
    });
    models = models.filter((m) => m.generation > 0 || m.source === "Artificial Analysis");
    if (!models.length) return;
    harnesses[name] = { roles: pickRoles(models, name, aa != null), models };
  };
  assign("cursor", cursor);
  assign("grok", grok);
  assign("codex", codex);
  assign("claude", claude);
  return {
    schema: "fm-model-catalog.v1",
    generatedAt: input.generatedAt || new Date().toISOString(),
    source: aa ? "Artificial Analysis" : "live-harness-listings",
    attribution: aa ? "Artificial Analysis (https://artificialanalysis.ai/)" : undefined,
    harnesses,
  };
}

export function expandDispatchRoles(dispatch, catalog) {
  const roleOf = (harness, token) => catalog?.harnesses?.[harness]?.roles?.[token];
  const expandProfile = (p) => {
    if (!p || typeof p !== "object") return p;
    const model = p.model;
    if (typeof model !== "string" || !model.startsWith("@")) return p;
    const role = roleOf(p.harness, model.slice(1));
    if (!role?.model) throw new Error(`catalog role unavailable: ${p.harness}/${model}`);
    const out = { ...p, model: role.model, catalogRole: model.slice(1) };
    // Cursor encodes effort in the model id and rejects a separate effort flag.
    if (p.harness !== "cursor" && role.effort) out.effort = role.effort;
    else if (p.harness === "cursor") delete out.effort;
    return out;
  };
  const expandUse = (use) => {
    if (Array.isArray(use)) return use.map(expandProfile);
    return expandProfile(use);
  };
  const out = { ...dispatch };
  if (Array.isArray(dispatch.rules)) {
    out.rules = dispatch.rules.map((rule) => ({ ...rule, use: expandUse(rule.use) }));
  }
  if (dispatch.default) out.default = expandUse(dispatch.default);
  return out;
}

function readStdin() {
  return readFileSync(0, "utf8");
}

function validateAA(payload) {
  if (!Array.isArray(payload?.data) || !payload.data.length
    || payload.data.some((row) => typeof row?.slug !== "string" || !row.slug)) {
    throw new Error("Artificial Analysis returned an invalid or empty model list");
  }
  return payload.data;
}

function atomicJson(file, value) {
  const temporary = `${file}.${process.pid}.tmp`;
  try {
    writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporary, file);
  } finally {
    if (existsSync(temporary)) unlinkSync(temporary);
  }
}

function apiKey() {
  if (process.env.ARTIFICIAL_ANALYSIS_API_KEY?.trim()) return process.env.ARTIFICIAL_ANALYSIS_API_KEY.trim();
  if (process.platform !== "win32") return null;
  const modulePath = path.join(homedir(), ".agents", "skills", "secret-vault", "scripts", "CredentialVault.psm1");
  if (!existsSync(modulePath)) return null;
  // The command contains only the module path; the secret stays in a captured
  // pipe, never argv, logs, a temporary file, or a child process's environment.
  try {
    return execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command",
      `$ErrorActionPreference='Stop'; Import-Module '${modulePath.replaceAll("'", "''")}' -DisableNameChecking -WarningAction SilentlyContinue; $key=Get-VaultSecret -TargetName artificial-analysis-api-key -WarningAction SilentlyContinue; if ($key) { [Console]::Out.Write($key) }`],
    { encoding: "utf8", timeout: 15000, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] }).trim() || null;
  } catch {
    throw new Error("Artificial Analysis credential lookup failed");
  }
}

async function refreshAA(cacheFile) {
  let cached;
  try {
    cached = JSON.parse(readFileSync(cacheFile, "utf8"));
    validateAA(cached);
    const age = Date.now() - Date.parse(cached.fetchedAt);
    if (age >= 0 && age < 24 * 60 * 60 * 1000) return cached;
  } catch { /* Missing or invalid cache requires the daily refresh. */ }
  const key = apiKey();
  if (!key) return null;
  const data = [];
  const seen = new Set();
  // One paginated collection per rebuild, shared by every harness. Never follow
  // server-supplied URLs with a credential; only numeric pages on this origin.
  for (let page = 1; page <= 100; page++) {
    let response;
    try {
      response = await fetch(`https://artificialanalysis.ai/api/v2/language/models/free?page=${page}`, {
        headers: { "x-api-key": key }, redirect: "error", signal: AbortSignal.timeout(30000),
      });
    } catch { throw new Error("Artificial Analysis request failed; catalog preserved"); }
    if (!response.ok) throw new Error(`Artificial Analysis HTTP ${response.status}; catalog preserved`);
    let payload;
    try { payload = await response.json(); } catch { throw new Error("Artificial Analysis returned invalid JSON"); }
    if (!Array.isArray(payload?.data)) throw new Error("Artificial Analysis returned an invalid page");
    if (!payload.data.length) break;
    for (const row of validateAA(payload)) {
      if (seen.has(row.slug)) throw new Error("Artificial Analysis repeated a model across pages");
      seen.add(row.slug);
      data.push(row);
    }
    const pagination = payload.pagination || payload.meta || {};
    const pages = pagination.total_pages ?? pagination.last_page;
    if ((Number.isInteger(pages) && page >= pages)
      || pagination.has_more === false || pagination.has_next_page === false
      || pagination.next_page === null) break;
    if (page === 100) throw new Error("Artificial Analysis pagination exceeded limit");
  }
  const result = { fetchedAt: new Date().toISOString(), attribution: "Artificial Analysis (https://artificialanalysis.ai/)", data };
  validateAA(result);
  atomicJson(cacheFile, result);
  return result;
}

try {
  const cmd = process.argv[2];
  if (cmd === "refresh-aa") {
    const input = JSON.parse(readStdin());
    const artificialAnalysis = await refreshAA(process.argv[3]);
    process.stdout.write(`${JSON.stringify({ ...input, artificialAnalysis })}\n`);
  } else if (cmd === "pick") {
    const catalog = JSON.parse(readStdin());
    const role = catalog?.harnesses?.[process.argv[3]]?.roles?.[process.argv[4]];
    if (!role) throw new Error("catalog role unavailable");
    process.stdout.write(`${JSON.stringify(role)}\n`);
  } else if (cmd === "score") {
    const input = JSON.parse(readStdin());
    process.stdout.write(`${JSON.stringify(buildCatalog(input), null, 2)}\n`);
  } else if (cmd === "expand") {
    const input = JSON.parse(readStdin());
    process.stdout.write(`${JSON.stringify(expandDispatchRoles(input.dispatch, input.catalog), null, 2)}\n`);
  } else if (cmd === "write") {
    const outPath = process.argv[3];
    const input = JSON.parse(readStdin());
    const catalog = buildCatalog(input);
    atomicJson(outPath, catalog);
    process.stdout.write(`${outPath}\n`);
  }
} catch (error) {
  process.stderr.write(`model-catalog: ${error.message}\n`);
  process.exitCode = 1;
}
