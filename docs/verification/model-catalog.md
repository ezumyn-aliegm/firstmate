# Model catalog scoring verification

Audience: maintainer verification.

This record supports the Artificial Analysis role scoring in `bin/fm-model-catalog.sh` and `bin/fm-model-catalog.mjs`, whose contract is owned by the header of `bin/fm-model-catalog.sh`.
It records only the live end-to-end result that must be re-established when the Artificial Analysis API or the scoring rules change.
The deterministic fixture coverage lives in `tests/fm-model-catalog.test.sh` and `tests/fm-dispatch-resolve.test.sh`.

## Live scoring against the real endpoint

Verified 2026-10-01 on Windows 11 against the Artificial Analysis free API, with the credential read from the Windows Credential Manager target `artificial-analysis-api-key` through the secret-vault module.
The key was never printed or written; the cache file `artificial-analysis.json` holds only API data.
Command, with a scratch config directory so no real catalog was touched:

```
FM_CONFIG_OVERRIDE=<scratch dir> bash bin/fm-model-catalog.sh --print
```

The run exited 0 and scored the local harness listings (cursor 245 models, grok 4, codex 8, claude 8) with `source` `Artificial Analysis` and generation timestamp 2026-10-01T22:40:51Z.
The roles it resolved, with the Artificial Analysis index and the blended price in USD per million tokens, were:

| Harness | Role | Model | Effort | Index | Index value | USD per 1M tokens | AA model |
| --- | --- | --- | --- | --- | --- | --- | --- |
| cursor | flagship | claude-fable-5-1-thinking-high | high | coding | 81.6 | 60 | claude-fable-5-1 |
| cursor | current | gpt-5.6-luna-medium | medium | coding | 50.7 | 1.4 | gpt-5-6-luna-medium |
| cursor | cheap | gpt-5.6-luna-medium | medium | coding | 50.7 | 1.4 | gpt-5-6-luna-medium |
| grok | flagship | grok-4.6 | high | coding | 76.8 | 8 | grok-4-6 |
| grok | current | grok-4.6 | medium | coding | 76.8 | 8 | grok-4-6 |
| grok | cheap | grok-4.6 | low | coding | 76.8 | 8 | grok-4-6 |
| codex | flagship | gpt-5.6-sol | high | coding | 77.4 | 24 | gpt-5-6-sol |
| codex | current | gpt-6-luna | medium | intelligence | 38.1 | 0.6 | gpt-6-luna |
| codex | cheap | gpt-6-luna | low | intelligence | 38.1 | 0.6 | gpt-6-luna |
| claude | flagship | claude-fable-5-1 | high | coding | 81.6 | 60 | claude-fable-5-1 |
| claude | current | claude-sonnet-5 | medium | coding | 71.5 | 12 | claude-sonnet-5 |
| claude | cheap | claude-sonnet-5 | low | coding | 71.5 | 12 | claude-sonnet-5 |

Every resolved role came from Artificial Analysis data rather than the generation heuristic, no fast SKU received a role, and the cheap and current roles landed at medium or lower effort.
