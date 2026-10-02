# Model catalog scoring verification

Audience: maintainer verification.

This record supports the Artificial Analysis role scoring in `bin/fm-model-catalog.sh` and `bin/fm-model-catalog.mjs`, whose contract is owned by the header of `bin/fm-model-catalog.sh`.
It records only the live end-to-end result that must be re-established when the Artificial Analysis API or the scoring rules change.
The deterministic fixture coverage lives in `tests/fm-model-catalog.test.sh` and `tests/fm-dispatch-resolve.test.sh`.

## Live scoring against the real endpoint

The previous live record scored roles with the Artificial Analysis coding index, which the scorer no longer uses; it has been removed.
The live record must be refreshed: run `FM_CONFIG_OVERRIDE=<scratch dir> bash bin/fm-model-catalog.sh --print` with the key vaulted in the Windows Credential Manager target `artificial-analysis-api-key` (never print the key), then record the resolved roles with their Intelligence Index values and blended prices.
