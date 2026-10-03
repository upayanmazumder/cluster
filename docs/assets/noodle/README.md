# Noodle — ArgoCD's reconciliation buddy

The git write-back identity for this cluster is `noodle <noodle@upayan.dev>`
(renamed 2026-10-03 from `argocd-image-updater <image-updater@upayan.dev>`;
see `k8s/platform/argocd-image-updater/values.yaml`). `argocd-image-updater`
authors the `build: automatic update of <app>` commits — the intended
write-back, not something to revert — and GitHub renders that author's avatar
from a Gravatar lookup on `noodle@upayan.dev`.

Noodle has a face per cluster mood. Use the version that matches what the
cluster is actually doing rather than a single static image, so a glance at a
commit, a doc, or a runbook says the state without reading it.

## Assets

| File | Mood | Use it for |
|---|---|---|
| `sleepy.png` | sleepy | Idle — nothing queued, no drift pending. |
| `happy.png` | happy | Ordinary healthy progress; a routine successful operation. |
| `confused.png` | confused | `Unknown`/indeterminate — status not yet reported, or a state the tooling can't classify. |
| `grumpy.png` | grumpy | `Degraded` — a workload is unhealthy and needs a human. |
| `excited.png` | excited | `Synced` right after a change landed. |
| `checking.png` | checking… | Reconciling / diffing (`Progressing` during comparison). |
| `syncing.png` | syncing… | Sync in flight — applying resources. |
| `all-good.png` | all good! | `Synced` **and** `Healthy` — the steady state. |
| `something-wrong.png` | something's wrong… | Drift detected or a sync failed — `OutOfSync`, error, or incident. |
| `back-to-sleep.png` | back to sleep | Idle again after work finished; a settled post-incident state. |

`noodle-sheet.png` is the original full reference sheet (all moods, states,
and the caption set) — kept for re-cropping, not for use as an icon.

## Using them

- **Commit avatar / GitHub bot icon.** Set `gitCommitUser`/`gitCommitMail` to
  the `noodle` identity (already done) and register the image you want as the
  Gravatar for `noodle@upayan.dev`. GitHub resolves it from the email; no API
  can set it for an arbitrary address, so the upload is a manual step.
  `happy.png` is the neutral default for that, and `noodle-pfp.png` (470x470 —
  the sheet's own portrait at full resolution, where the mood crops are only
  220x220) is the same face sized for that upload.
- **Docs and runbooks.** Reference the specific variant that matches the state
  being described, e.g. `![grumpy](assets/noodle/grumpy.png)` in a degraded-path
  runbook, rather than one generic mascot everywhere.
- **Alerts and incident notes.** Pick the file by the same table above — a
  drift alert is `something-wrong.png`, an all-clear is `all-good.png`.

Assets are tight square crops on the sheet's own background, so they sit on
dark surfaces without a halo. Re-crop from `noodle-sheet.png` if a size or an
uncropped variant is ever needed (the sheet's grid: 5 columns; row 1 moods,
row 2 states).
