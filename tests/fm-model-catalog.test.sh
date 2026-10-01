#!/usr/bin/env bash
# Behavior tests for the live model catalog scorer (bin/fm-model-catalog.mjs).
#
# Drives score and expand through the public node CLI. Fixtures are vendor
# listing shapes, not implementation source. GPT-6 must outrank GPT-5.3.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

SCORER="$ROOT/bin/fm-model-catalog.mjs"
[ -f "$SCORER" ] || fail "missing bin/fm-model-catalog.mjs"

score_json=$(node "$SCORER" score <<'JSON'
{
  "generatedAt": "2026-09-23T00:00:00Z",
  "cursorText": "auto - Auto (default)\ngpt-5.3-codex-high - Codex 5.3 High\ngpt-5.6-sol-xhigh - GPT-5.6 Sol Extra High\ngpt-5.6-sol-high - GPT-5.6 Sol High\ngpt-5.6-sol-high-fast - GPT-5.6 Sol High Fast\ncomposer-2.5 - Composer 2.5 (current)\ncomposer-2.5-fast - Composer 2.5 Fast\ngrok-4.7-high - Grok 4.7 High\ngrok-4.7-high-fast - Grok 4.7 High Fast\nclaude-opus-5-5-high - Claude Opus 5.5 1M High\n",
  "grokText": "Available models:\n  - grok-4.7\n  - grok-4.7-build-fast\n  * grok-4.6 (default)\n  - grok-4.5\n",
  "codexCache": {
    "models": [
      {"slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "description": "Frontier intelligence for the most demanding work.", "visibility": "list", "priority": 1},
      {"slug": "gpt-5.6-sol", "display_name": "GPT-5.6-Sol", "description": "Older coding model for complex work.", "visibility": "list", "priority": 4},
      {"slug": "gpt-5.5", "display_name": "GPT-5.5", "description": "Legacy coding model.", "visibility": "list", "priority": 12},
      {"slug": "gpt-reserve", "display_name": "GPT-Reserve", "description": "Fast and affordable", "visibility": "hide", "priority": 3}
    ]
  }
}
JSON
) || fail "scorer exited non-zero"

codex_flag=$(printf '%s' "$score_json" | jq -r '.harnesses.codex.roles.flagship.model')
[ "$codex_flag" = "gpt-6-astra" ] || fail "codex flagship was '$codex_flag', expected gpt-6-astra"
pass "codex flagship is GPT-6 Astra, not a 5.x id"

printf '%s' "$score_json" | jq -e '.harnesses.codex.models | map(.id) | index("gpt-reserve") == null' >/dev/null \
  || fail "hidden Codex models leaked into the catalog"
pass "hidden Codex models are omitted"

cursor_cheap=$(printf '%s' "$score_json" | jq -r '.harnesses.cursor.roles.cheap.model')
[ "$cursor_cheap" = "composer-2.5" ] || fail "cursor cheap was '$cursor_cheap', expected composer-2.5"
pass "cursor cheap role is Composer 2.5"

cursor_flag=$(printf '%s' "$score_json" | jq -r '.harnesses.cursor.roles.flagship.model')
[ "$cursor_flag" = "gpt-5.6-sol-high" ] || fail "cursor flagship was '$cursor_flag', expected standard high not xhigh/fast"
pass "cursor flagship is standard high, not xhigh or fast"

printf '%s' "$score_json" | jq -e '[.harnesses.cursor.roles[].model] | all(test("-fast$")|not)' >/dev/null \
  || fail "a cursor role picked a -fast SKU"
pass "cursor roles never pick 2x-cost fast SKUs"

grok_cheap=$(printf '%s' "$score_json" | jq -r '.harnesses.grok.roles.cheap.model')
[ "$grok_cheap" = "grok-4.7" ] || fail "grok cheap was '$grok_cheap', expected grok-4.7 not build-fast"
pass "grok cheap is standard grok-4.7, not build-fast"

grok_cheap_effort=$(printf '%s' "$score_json" | jq -r '.harnesses.grok.roles.cheap.effort')
[ "$grok_cheap_effort" = "low" ] || fail "grok cheap effort was '$grok_cheap_effort'"
pass "grok cheap role carries effort low"

codex_flag_effort=$(printf '%s' "$score_json" | jq -r '.harnesses.codex.roles.flagship.effort')
[ "$codex_flag_effort" = "high" ] || fail "codex flagship effort was '$codex_flag_effort'"
pass "codex flagship role carries effort high"

grok_flag=$(printf '%s' "$score_json" | jq -r '.harnesses.grok.roles.flagship.model')
[ "$grok_flag" = "grok-4.7" ] || fail "grok flagship was '$grok_flag', expected grok-4.7"
pass "grok flagship prefers 4.7 over the still-default 4.6"

claude_flag=$(printf '%s' "$score_json" | jq -r '.harnesses.claude.roles.flagship.model')
[ "$claude_flag" = "claude-opus-5-5" ] || fail "claude flagship was '$claude_flag', expected claude-opus-5-5"
pass "claude flagship strips Cursor effort suffixes to claude-opus-5-5"

astra_q=$(printf '%s' "$score_json" | jq -r '.harnesses.codex.models[] | select(.id=="gpt-6-astra") | .quality')
legacy_q=$(printf '%s' "$score_json" | jq -r '.harnesses.codex.models[] | select(.id=="gpt-5.5") | .quality')
python - "$astra_q" "$legacy_q" <<'PY' || fail "GPT-6 quality did not beat GPT-5.5"
import sys
a=float(sys.argv[1]); b=float(sys.argv[2])
raise SystemExit(0 if a > b else 1)
PY
pass "GPT-6 quality weight beats GPT-5.5"

expanded=$(node "$SCORER" expand <<EOF
{"catalog": $score_json, "dispatch": {"rules":[{"when":"big","use":{"harness":"codex","model":"@flagship","effort":"high"}}],"default":[{"harness":"cursor","model":"@cheap"}]}}
EOF
) || fail "expand exited non-zero"
got=$(printf '%s' "$expanded" | jq -r '.rules[0].use.model')
[ "$got" = "gpt-6-astra" ] || fail "expand left model as '$got'"
got=$(printf '%s' "$expanded" | jq -r '.default[0].model')
[ "$got" = "composer-2.5" ] || fail "expand default cheap was '$got'"
got=$(printf '%s' "$expanded" | jq -r '.rules[0].use.effort')
[ "$got" = "high" ] || fail "expand did not apply catalog effort high, got '$got'"
pass "dispatch @flagship/@cheap expand to live catalog ids and role effort"

# Public score/pick/refresh commands with synthetic AA responses; no live network
# or host vault lookup is permitted, including on Windows developer machines.
node --input-type=module - "$SCORER" <<'JS' || fail "Artificial Analysis catalog behavior"
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const scorer = process.argv[2];
const temp = mkdtempSync(path.join(tmpdir(), 'fm-aa-test-'));
try {
  const model = (slug, intelligence, coding, input, output, blended) => ({
    slug, evaluations: { artificial_analysis_intelligence_index: intelligence, artificial_analysis_coding_index: coding },
    pricing: { price_1m_input_tokens: input, price_1m_output_tokens: output, price_1m_blended_3_to_1: blended },
  });
  const aa = { data: [
    model('grok-4-7', 46.4, null, 2, 6),
    model('gpt-5-6-sol-high', 42.3, 77.2, 4, 20),
    model('gpt-5-6-sol-medium', 42.3, 60, 4, 20),
    model('gpt-6-astra', 52.7, null, 10, 50),
    model('gpt-4-mini', 20, null, 1, 1),
    model('gpt-7-high-fast', 100, 100, 0.01, 0.01),
    model('gpt-8-high', null, null, 0.01, 0.01),
  ] };
  function run(command, payload, args = [], env = {}, imports = []) {
    return spawnSync(process.execPath, [...imports, scorer, command, ...args], {
      encoding: 'utf8', input: JSON.stringify(payload), env: { ...process.env, ...env },
    });
  }
  function json(command, payload, args = []) {
    const result = run(command, payload, args);
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  }
  const input = {
    artificialAnalysis: aa,
    cursorText: [
      'composer-2.5 - Composer (current)', 'grok-4.7-medium - Grok medium',
      'grok-4.7-high - Grok high', 'gpt-5.6-sol-medium - Sol medium',
      'gpt-5.6-sol-high - Sol high', 'gpt-6-astra - Astra',
      'gpt-4-mini - Mini', 'gpt-7-high-fast - Fast', 'gpt-8-high - Missing index',
    ].join('\n'),
    grokText: '- grok-4.7\n- grok-4.7-build-fast',
    codexCache: { models: [{ slug: 'gpt-6-astra' }, { slug: 'gpt-4-mini' }] },
    claudeText: 'claude-opus-5-5 - Opus\nclaude-sonnet-4-5 - Sonnet (current)',
  };
  const catalog = json('score', input);
  const pick = (role) => json('pick', catalog, ['cursor', role]);
  assert.equal(pick('flagship').model, 'gpt-5.6-sol-high');
  assert.equal(pick('flagship').quality, 77.2);
  assert.equal(pick('current').model, 'gpt-4-mini');
  assert.equal(pick('cheap').model, 'gpt-4-mini');
  assert.match(catalog.attribution, /Artificial Analysis/);
  const grok = catalog.harnesses.cursor.models.find(m => m.id === 'grok-4.7-medium');
  assert.equal(grok.aaSlug, 'grok-4-7');
  assert.equal(grok.quality, 46.4);
  assert.equal(grok.economy, 1 / 8);
  assert.equal(catalog.harnesses.claude.roles.current.model, 'claude-opus-5-5');
  const plainComposer = json('score', { ...input, cursorText: 'composer-2.5 - Composer' });
  assert.equal(catalog.harnesses.cursor.models[0].quality, plainComposer.harnesses.cursor.models[0].quality);
  const priced = structuredClone(input);
  priced.artificialAnalysis.data[4].pricing.price_1m_blended_3_to_1 = 10;
  const changed = json('score', priced);
  assert.equal(json('pick', changed, ['cursor', 'current']).model, 'grok-4.7-medium');
  assert.equal(json('pick', changed, ['cursor', 'cheap']).model, 'grok-4.7-medium');
  const missingPrice = structuredClone(input);
  missingPrice.artificialAnalysis.data[4].pricing = {};
  assert.equal(json('score', missingPrice).harnesses.cursor.roles.cheap.model, 'grok-4.7-medium');
  const onlyHigh = json('score', { ...input, cursorText: 'gpt-5.6-sol-high - High' });
  assert.equal(run('pick', onlyHigh, ['cursor', 'current']).status, 1);
  assert.equal(run('score', { ...input, artificialAnalysis: { data: [] } }).status, 1);
  assert.equal(run('expand', { catalog, dispatch: { default: { harness: 'unknown', model: '@cheap' } } }).status, 1);
  const noGeneration = json('score', { cursorText: 'o3 - Coding model', artificialAnalysis: { data: [model('o3', 30, null, 1, 2)] } });
  assert.equal(noGeneration.harnesses.cursor.roles.current.model, 'o3');
  console.log('ok - AA roles honor quality, price, effort, missing measurements, slug mapping and fast exclusions');

  const fixture = path.join(temp, 'aa.json');
  const calls = path.join(temp, 'calls.jsonl');
  const loader = path.join(temp, 'fetch.mjs');
  const cache = path.join(temp, 'artificial-analysis.json');
  writeFileSync(fixture, JSON.stringify(aa));
  writeFileSync(loader, `
    import { readFileSync, appendFileSync } from 'node:fs';
    Object.defineProperty(process, 'platform', { value: 'linux' });
    globalThis.fetch = async (url, options) => {
      if (options.headers['x-api-key'] !== 'fixture-secret') throw Error('wrong test key');
      appendFileSync(process.env.AA_CALLS, JSON.stringify({url})+'\\n');
      if (process.env.AA_ERROR) return {ok:false,status:403};
      const rows = JSON.parse(readFileSync(process.env.AA_FIXTURE)).data;
      const page = Number(new URL(url).searchParams.get('page'));
      return {ok:true,json:async()=>({data:page===1?rows.slice(0,2):rows.slice(2),pagination:{total_pages:2}})};
    };
  `);
  const env = { ARTIFICIAL_ANALYSIS_API_KEY: 'fixture-secret', AA_CALLS: calls, AA_FIXTURE: fixture };
  const imports = ['--import', pathToFileURL(loader).href];
  const refresh = (overrides = {}) => run('refresh-aa', {}, [cache], { ...env, ...overrides }, imports);
  assert.equal(refresh().status, 0);
  assert.equal(readFileSync(calls, 'utf8').trim().split('\n').length, 2);
  assert.equal(JSON.parse(readFileSync(cache)).data.length, aa.data.length);
  assert.ok(!readFileSync(cache, 'utf8').includes('fixture-secret'));
  assert.equal(refresh({ AA_ERROR: 'yes' }).status, 0);
  assert.equal(readFileSync(calls, 'utf8').trim().split('\n').length, 2);
  const stale = { ...JSON.parse(readFileSync(cache)), fetchedAt: '2000-01-01T00:00:00Z' };
  writeFileSync(cache, JSON.stringify(stale));
  const before = readFileSync(cache, 'utf8');
  const failed = refresh({ AA_ERROR: 'yes' });
  assert.equal(failed.status, 1);
  assert.ok(!failed.stderr.includes('fixture-secret'));
  assert.equal(readFileSync(cache, 'utf8'), before);
  assert.equal(JSON.parse(refresh({ ARTIFICIAL_ANALYSIS_API_KEY: '' }).stdout).artificialAnalysis, null);
  assert.ok(!existsSync(cache + '.' + process.pid + '.tmp'));
  console.log('ok - daily AA collection paginates once, reuses its 24h cache, preserves it on failure and never stores the key');
} finally {
  rmSync(temp, { recursive: true, force: true });
}
JS
pass "Artificial Analysis score/pick and cached refresh behavior"

catalog_tmp=$(mktemp -d) || fail "mktemp"
printf '%s' "$score_json" > "$catalog_tmp/model-catalog.json"
touch -t 200001010000 "$catalog_tmp/model-catalog.json"
printf '%s\n' '{"default":{"harness":"codex","model":"@flagship"}}' > "$catalog_tmp/dispatch.json"
FM_CONFIG_OVERRIDE="$catalog_tmp" bash "$ROOT/bin/fm-model-catalog.sh" --ensure || fail "stale catalog ensure should read without refresh"
FM_CONFIG_OVERRIDE="$catalog_tmp" bash "$ROOT/bin/fm-model-catalog.sh" --expand "$catalog_tmp/dispatch.json" > "$catalog_tmp/expanded.json" || fail "stale catalog expansion"
[ "$(jq -r '.default.model' "$catalog_tmp/expanded.json" | tr -d '\r')" = gpt-6-astra ] || fail "cached dispatch role"
[ ! -e "$catalog_tmp/artificial-analysis.json" ] || fail "read path created AA cache"
rm -f "$catalog_tmp/model-catalog.json"
if FM_CONFIG_OVERRIDE="$catalog_tmp" bash "$ROOT/bin/fm-model-catalog.sh" --ensure >/dev/null 2>&1; then fail "missing catalog ensure succeeded"; fi
rm -r "$catalog_tmp"
pass "stale and missing catalog reads never rebuild or fetch"
