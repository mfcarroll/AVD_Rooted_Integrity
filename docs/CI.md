# CI — kernel builds

`.github/workflows/kernel.yml` builds the custom GKI kernel and publishes the
images.

| | |
|---|---|
| Trigger | `workflow_dispatch` (pick `both` / `arm64` / `x86_64`), or a push touching `kernel-build/**` |
| Matrix | chosen per push by `.github/scripts/select-arches.sh` — see below |
| Runner | `ubuntu-latest`, one job per selected arch, `fail-fast: false` |
| Build | the same `kernel-build/Dockerfile` and `./scripts/build-all.sh --arch <a>` used locally |
| Output | `Image.gz` (arm64), `bzImage` (x86_64) |
| Always | uploaded as a run artifact (`kernel-<arch>`) |
| Conditionally | pushed to `$GCS_BUCKET/payloads/kernel/` |

Both builds are cross-compiles, so one `ubuntu-latest` runner and one container
image cover both — no self-hosted arm64 runner is needed.

## Which arches a push builds

A push used to build both every time, which is 25–75 runner-minutes. A `select`
job now diffs `github.event.before..github.sha` and narrows the matrix.

**Narrowing requires positive evidence, and the only evidence accepted is an arch
name in the path** — `patches/<arch>/`, `configs/<arch>-*.config`,
`scripts/*-<arch>.sh`. Everything else that is a build input builds both: a
shared script, the `Dockerfile`, the workflow itself, and any range that cannot
be diffed (a new branch, or history rewritten out from under the run). Markdown
is dropped by the path filter before the workflow starts and ignored again here,
so a doc in a mixed commit never widens the matrix.

It errs that way on purpose. A wrong "both" costs minutes; a wrong "one arch"
publishes a kernel nobody compiled, and that hides until a device fails to boot.

The classifier reads paths, so renaming or moving a file under `kernel-build/`
can silently reclassify it. There is a test for exactly that:

```bash
./.github/scripts/select-arches.test.sh
```

In practice most commits still build both, because nearly everything routes
through `scripts/build.sh`. The saving is on config- and patch-only work.

Two things the runner needs that a local build does not:

- **Disk.** The source clone is ~3 GB and the build tree ~10 GB more, which does
  not fit on a stock runner. The workflow deletes the preinstalled .NET, Android
  SDK, GHC and CodeQL trees first.
- **ccache.** Restored from `actions/cache` keyed on arch, otherwise every run is
  a cold build. Measured cold on `ubuntu-latest`: arm64 33 min, x86_64 26 min.

## Enabling the GCS publish

**This is Terraform, not a manual setup.** It lives in the sibling repo:

```bash
cd avd-cloud-portable/infra
GITHUB_TOKEN=$(gh auth token) terraform apply
```

That creates the Workload Identity pool and GitHub OIDC provider, the
`kernel-ci` service account with `objectAdmin` on the payload bucket only, the
Secret Manager secret for the keybox, and it sets the three repo variables on
this repository directly:

| Variable | Set by Terraform to |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<num>/locations/global/workloadIdentityPools/github/providers/github` |
| `GCP_SERVICE_ACCOUNT` | `kernel-ci@<project>.iam.gserviceaccount.com` |
| `GCS_BUCKET` | the bucket name, **no `gs://` prefix** |

Pass `-var manage_github_variables=false` to set them by hand instead; the root
outputs the same three values.

Authentication is **Workload Identity Federation** — GitHub's OIDC token is
exchanged for short-lived Google credentials. There is no service-account JSON
key in the repository or in secrets, so there is no long-lived credential to
leak or rotate.

The provider's attribute condition is scoped to this repository:

    assertion.repository == "mfcarroll/AVD_Rooted_Integrity"

That is load-bearing, not decoration. Without it the provider trusts the whole
`github.com` issuer and any repository on GitHub can mint tokens for the
service account. This repository is public.

> **Variables are snapshotted when a run is created.** Setting them does not
> affect a run already in flight — its publish steps still skip. Re-run the
> workflow afterwards.

## The keybox is not built into anything

The keybox holds private keys. It is never committed, never baked into a
published image and never uploaded to the bucket:

- `payloads/keybox/` is deliberately **excluded** from `BLOB_DIRS` in
  `avd-cloud-portable/scripts/payloads.sh`, so `payloads.sh push` cannot sync it.
- In CI it belongs in **Secret Manager**, read through the same Workload
  Identity Federation binding, and injected at deploy or first boot by
  `avd-cloud-portable/scripts/install-keybox.sh` — which is a standalone flow for
  exactly this reason, and validates the keybox against Google's live CRL.
- Terraform creates the secret **container** only, never a
  `google_secret_manager_secret_version`. Terraform state holds every attribute
  in plaintext, so a version resource would write the private key into
  `terraform.tfstate` and every backup and plan file. Load the value out of band:

      gcloud secrets versions add avd-keybox --data-file=payloads/keybox/keybox.xml

Published images stay keybox-free. Rotation is then a secret update, not a
rebuild — which matters, because a keybox that gets distributed widely is one
Google revokes.
