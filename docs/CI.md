# CI — kernel builds

`.github/workflows/kernel.yml` builds the custom GKI kernel for both target
arches and publishes the images.

| | |
|---|---|
| Trigger | `workflow_dispatch` (pick `both` / `arm64` / `x86_64`), or a push touching `kernel-build/**` |
| Runner | `ubuntu-latest`, one job per arch, `fail-fast: false` |
| Build | the same `kernel-build/Dockerfile` and `./scripts/build-all.sh --arch <a>` used locally |
| Output | `Image.gz` (arm64), `bzImage` (x86_64) |
| Always | uploaded as a run artifact (`kernel-<arch>`) |
| Conditionally | pushed to `$GCS_BUCKET/payloads/kernel/` |

Both builds are cross-compiles, so one `ubuntu-latest` runner and one container
image cover both — no self-hosted arm64 runner is needed.

Two things the runner needs that a local build does not:

- **Disk.** The source clone is ~3 GB and the build tree ~10 GB more, which does
  not fit on a stock runner. The workflow deletes the preinstalled .NET, Android
  SDK, GHC and CodeQL trees first.
- **ccache.** Restored from `actions/cache` keyed on arch, otherwise every run is
  a cold ~30–60 min build.

## Enabling the GCS publish

The publish steps are skipped unless the repository variable
`GCP_WORKLOAD_IDENTITY_PROVIDER` is set, so the workflow is useful (as an
artifact build) before any cloud setup exists. To turn publishing on, set three
**repository variables** — not secrets; none of these are sensitive:

| Variable | Example |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/123456789/locations/global/workloadIdentityPools/github/providers/github` |
| `GCP_SERVICE_ACCOUNT` | `kernel-ci@<project>.iam.gserviceaccount.com` |
| `GCS_BUCKET` | `avd-cloud-vms` |

Authentication is **Workload Identity Federation** — GitHub's OIDC token is
exchanged for short-lived Google credentials. There is no service-account JSON
key in the repository or in secrets, so there is no long-lived credential to
leak or rotate.

Scope the pool's attribute condition to this repository. A provider that trusts
the whole `github.com` issuer lets *any* repository on GitHub mint tokens for
your service account:

    attribute.repository == "mfcarroll/AVD_Rooted_Integrity"

Grant the service account `roles/storage.objectAdmin` on the bucket only, not at
project level.

## The keybox is not built into anything

The keybox holds private keys. It is never committed, never baked into a
published image and never uploaded to the bucket:

- `payloads/keybox/` is deliberately **excluded** from `BLOB_DIRS` in
  `avd-cloud-portable/scripts/payloads.sh`, so `payloads.sh push` cannot sync it.
- In CI it belongs in **Secret Manager**, read through the same Workload
  Identity Federation binding, and injected at deploy or first boot by
  `avd-cloud-portable/scripts/install-keybox.sh` — which is a standalone flow for
  exactly this reason, and validates the keybox against Google's live CRL.

Published images stay keybox-free. Rotation is then a secret update, not a
rebuild — which matters, because a keybox that gets distributed widely is one
Google revokes.
