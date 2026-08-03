# Localabs evals

Clinical faithfulness eval for the on-device pipeline: **does the report
MedGemma 4B wrote actually match the lab report it was shown?**

LLM-as-a-judge (G-Eval / DeepEval-style), ported from Civassist's
`eligibility/eval_faithfulness.py` and retargeted at Localabs' output.

## Choosing a judge

| Provider | Default model | Independence |
|---|---|---|
| `anthropic` | `claude-opus-5` | **Strong** — different model family from MedGemma |
| `gemini` | `gemini-3.5-flash` | **Weaker** — MedGemma is a Gemma derivative, so judge and subject share lineage |

Never judge with the model under test; a model grading its own output inherits
its own blind spots. Gemini isn't that — it's a vastly different model at a
vastly different scale — but it's kin, and shared lineage can mean shared blind
spots. A medical convention both models learned the same wrong way is exactly
what neither would flag.

So: Gemini is fine for iterating cheaply, and the canaries still prove the
judge can catch planted errors. Re-grade anything surprising — and any result
you plan to cite — on Anthropic.

## Setup

```bash
cd evals
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

Put the key in `evals/.env` (gitignored, loaded automatically) so it stays out
of your shell history:

```bash
echo 'GEMINI_API_KEY=...' > .env       # or ANTHROPIC_API_KEY=...
```

An `export` in the shell also works and takes precedence over the file.

## Run

```bash
.venv/bin/python eval_faithfulness.py --only-canary          # self-test the judge, no fixtures needed
.venv/bin/python eval_faithfulness.py --canary               # real fixtures + self-test
.venv/bin/python eval_faithfulness.py --canary --provider gemini
.venv/bin/python eval_faithfulness.py --canary --workers 4 --json-out results.json
```

The provider is auto-detected from whichever key is present (Claude wins if
both are). Exit code 0 = every real report faithful and every canary behaved;
1 = problems. That makes it CI-droppable as-is.

Env overrides: `JUDGE_PROVIDER`, `JUDGE_MODEL`, `JUDGE_EFFORT` (default `high`;
mapped to Gemini's coarser `thinking_level` on that backend). `results.json`
records which judge produced the verdicts — a verdict is only interpretable
against the model that produced it.

### Gemini free-tier quota

`gemini-3.5-flash` allows **20 requests/day** on the free tier, and one full
`--canary` run costs 5. You will hit the wall faster than you expect while
iterating.

The quota is **per model** (`GenerateRequestsPerDayPerProjectPerModel`), so the
cheap escape hatch is another model rather than another day:

```bash
.venv/bin/python eval_faithfulness.py --only-canary --model gemini-3.5-flash-lite
```

`flash-lite` passes the canary self-test too — it catches all three corruptions
and clears the clean control. The judging task is easier than the summarizing
task, so the cheap tier is genuinely fine for iteration; save the strong model
for runs whose verdicts you intend to act on.

## Getting real cases

`cases/example-lipid-cbc.json` is a hand-written template. Real cases come off
the device:

1. Run a DEBUG build on the phone and scan a report as usual.
2. **History → long-press the report → Export Eval Fixture (Dev)**.
3. Save to Files / AirDrop to the dev Mac.
4. Drop the `.json` into `cases/` — it needs no editing.

The fixture pairs `source.ocr_text` (what VisionOCRService gave the model —
the only thing it was allowed to see) with the five sections it produced.

> **Privacy.** A fixture holds the report's real OCR text, and the eval sends
> it to a cloud judge. That is the one place Localabs data deliberately leaves
> the device. Use reports you own or have redacted. `cases/` is committed, so
> treat anything you put there as public to everyone with repo access.

## The canaries

`--canary` appends four synthetic cases that test the *harness*, not the app:

| Canary | Must be |
|---|---|
| `canary/fabricated-value` | FLAGGED — labs that were never measured |
| `canary/dangerous-advice` | FLAGGED — tells the patient to change a dose |
| `canary/missed-critical` | FLAGGED — buries a panic-range value |
| `canary/clean-control` | **FAITHFUL** — the control |

The clean control is the important half. A judge that flags everything
"catches" all three corruptions while being useless, and only the control
exposes it. If any canary misbehaves, the run's verdicts on real reports mean
nothing — fix the judge before reading them.
