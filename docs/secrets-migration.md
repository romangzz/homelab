# Secrets migration: Sealed Secrets → SOPS + External Secrets

Moves the repo from `SealedSecret` (write-only, sealed by hand against a
fetched cert) to:

| Kind of secret | Tool | Human step |
|---|---|---|
| **Internal random values** (DB passwords, signing keys) for new apps | **External Secrets Operator** `Password` generator: created in-cluster, never in git | None |
| **External values** (tokens, API keys, VPN keys) and **existing values that must not change** | **SOPS + age**, applied as `SopsSecret` by **sops-secrets-operator** | `sops <file>` → edit → save → commit |

**Why sops-secrets-operator and not KSOPS:** KSOPS decrypts inside ArgoCD's
repo-server, which would mean adopting the ArgoCD install into this repo
first (it isn't managed here today). sops-secrets-operator keeps the same
shape as Sealed Secrets (an encrypted CRD in git, an in-cluster controller
decrypts it), so ArgoCD itself is untouched.

## Progress

- [x] **Phase 1**: tooling (laptop + repo). Done 2026-11-08: age key in 1Password
  (vault *Homelab*, item `homelab-sops-age-key`), public key in `.sops.yaml`,
  plaintext guard in CI + pre-commit
- [x] **Phase 2**: sops-secrets-operator. Done 2026-11-08: chart 0.29.1 running,
  age key bootstrapped, smoke-test SopsSecret decrypted and was owned/GC'd
  correctly
- [x] **Phase 3**: External Secrets Operator. Done 2026-11-08: chart 2.14.0 Healthy;
  smoke test confirmed Password generator, templating and `CreatedOnce`
- [x] **Phase 4**: Plane on generated secrets. Done 2026-11-08: `plane-secrets`
  generated (immutable), SealedSecrets pruned, PVCs wiped, Plane Healthy.
  Blocked for a while by a node AppArmor bug unrelated to secrets (see
  "Phase 4 incident" below)
- [x] **Phase 5**: migrate existing SealedSecrets to SOPS. Done 2026-11-08: all 9
  Secrets taken over in place (same objects, same data digests), no unplanned
  restarts
  - [x] Batch 1 (2026-11-08): `open-webui-secret`, `unpackerr-secret`,
    `recyclarr-config`. Taken over in place (same objects, same data
    digests), SealedSecrets pruned, apps Healthy throughout
  - [x] Batch 2 (2026-11-08): `vpn-secret`, `tailscale-auth`,
    `cloudflare-tunnel-token`. Taken over in place; VPN, Tailscale and the
    Cloudflare tunnel never restarted
  - [x] Batch 3 (2026-11-08): `cloudflare-api-token`. Taken over in place;
    staging DNS-01 test issued in ~100s before, after step A and after step B
  - [x] Batch 4 (2026-11-08): `authelia-secrets`, `authelia-users`. Taken over
    in place; one deliberate restart started cleanly (storage key validated)
- [x] **Phase 6**: decommission Sealed Secrets. Done 2026-11-08: controller and CRD
  removed via ArgoCD (cascade finalizer); all 3 sealing keys backed up in
  1Password (vault *Homelab*, `homelab-sealed-secrets-master-keys`) for old
  git history

## Phase 1: Tooling (no cluster changes)

1. Install `sops`, `age` (pacman) and the 1Password CLI `op` (AUR
   `1password-cli`). Enable *Settings → Developer → Integrate with
   1Password CLI* in the desktop app.
2. Generate the age key at sops' default path,
   `~/.config/sops/age/keys.txt`.
3. **Back up the private key in 1Password** (document item
   `homelab-sops-age-key`) and offline. It is the one secret that can never
   live in git, the role the Sealed Secrets master key plays today.
4. `.sops.yaml` at the repo root: files named `*.sops.yaml` under `apps/`
   are encrypted to the age public key, and only `data`/`stringData` values
   are encrypted, so resource names and keys stay readable in diffs.
5. ~~gitleaks allowlist for SOPS ciphertext~~ **Not needed** (verified with
   gitleaks 8.30.1, default rules only): `ENC[AES256_GCM,data:...,iv:...,tag:...]`
   values don't match any rule, while a planted plaintext GitHub token in the
   same tree was still caught.
6. Guard against plaintext: `.github/scripts/check-sops-encrypted.sh` runs
   in CI and as a pre-commit hook (`.githooks/pre-commit`, enabled with
   `git config core.hooksPath .githooks`). It fails if any `*.sops.yaml` is
   missing SOPS metadata or has a non-`ENC[...]` value under
   `data`/`stringData`, or if any plain `kind: Secret` with data is
   committed outside a `*.sops.yaml`.

## Phase 2: sops-secrets-operator

1. ArgoCD Application for the operator's Helm chart.
2. **One manual bootstrap step**: the age private key goes into the cluster
   once as Secret `sops-age-key` (key `keys.txt`) in namespace
   `sops-secrets-operator`, streamed from 1Password over SSH so it never
   touches disk (exact command in the README prerequisites). The operator
   mounts it at `/etc/sops-age` and reads it via `SOPS_AGE_KEY_FILE`.
3. Smoke test: a dummy `SopsSecret` → Secret appears → delete it.

## Phase 3: External Secrets Operator

1. ArgoCD Application for the ESO Helm chart 2.14.0 (with CRDs). Used only
   for its in-cluster generators; no external SecretStore backend.
   - `ServerSideApply=true`: the SecretStore CRDs are ~720KB, over
     client-side apply's 256KB annotation limit.
   - `ignoreDifferences` for what the cert-controller writes at runtime (the
     webhook Secret's `data` and the webhook configs' `caBundle`).
   - Its chart is served from GitHub release assets, so a GitHub outage at
     sync time shows up as a `ComparisonError` (as happened with Plane);
     a hard refresh once GitHub recovers fixes it.
2. `SkipDryRunOnMissingResource=true` on apps that use ESO resources, so the
   first sync doesn't fail before the CRDs exist.

## Phase 4: Plane on generated secrets

Only possible because Plane holds no data yet. **Don't start the Plane
first-time setup before this phase is done.**

1. Replace the 6 SealedSecrets with **one** `ExternalSecret`
   (`apps/plane/generated-secrets.yaml`): a single `Password` generator fills
   five keys via `secretKeys`, and the template builds `DATABASE_URL` /
   `AMQP_URL` from them. All six chart `external_secrets.*` names point at
   that one Secret, `plane-secrets`, so the passwords can't drift apart.
2. Three settings together keep ESO from **ever** regenerating a password
   that Postgres/RabbitMQ/MinIO already use (each tested on the cluster):
   - `refreshPolicy: CreatedOnce`: normal and forced syncs don't regenerate.
   - `creationPolicy: Orphan`: deleting the ExternalSecret keeps the Secret.
   - `immutable: true`: needed because a **re-created** ExternalSecret with
     only the two settings above *does* regenerate and overwrite the
     orphaned Secret (observed in testing). With `immutable`, the API server
     refuses the overwrite and the original passwords survive.
   Use the same three settings for any future generated credential that a
   datastore persists.
3. Wipe Plane's 4 PVCs once (Postgres keeps whatever password it started
   with), then resync.
4. Delete `apps/plane/sealed-secrets.yaml`.

### Phase 4 incident: AppArmor blocked signals inside containers

Plane's Postgres showed `Running` but never started. The cause was on the node:
containers carry stacked AppArmor labels (`cri-containerd.apparmor.d//&unconfined`,
`chromium//&cri-containerd.apparmor.d`) that containerd's profile peer rules
don't match, so **signals and ptrace reads between processes of the same
container were denied**: `gosu` spun forever, `pg_ctl` got `Permission denied`,
and Go lost SIGURG preemption. It wasn't a kernel-version bug (booting -42
didn't help). Fixed with a local profile override,
[`docs/host/cri-containerd.apparmor.d`](host/cri-containerd.apparmor.d)
(see the README prerequisites). Lessons for later phases:

- Scaling Plane's chart StatefulSets to 0 sticks: the chart omits `replicas`,
  so ArgoCD doesn't restore it. Scale back by hand.
- ArgoCD can keep serving a cached Helm render after a values change in
  `apps/argocd-apps/plane.yaml`; a hard refresh applies it.

## Phase 5: Migrate existing secrets to SOPS (same values)

A script reads each live Secret from the cluster over SSH and pipes it
straight into `sops -e`. Plaintext never touches disk, and the values stay
identical, so no app notices the change. One secret per commit, lowest risk
first:

| Order | Secret(s) | Risk if it breaks |
|---|---|---|
| 1 | `open-webui-secret` (ai), `unpackerr-secret`, `recyclarr-config` (media) | Low |
| 2 | `vpn-secret` (media), `tailscale-auth` (tailscale), `cloudflare-tunnel-token` (n8n) | Medium: networking/VPN |
| 3 | `cloudflare-api-token` (cert-manager) | High: TLS renewals. Verify with a throwaway Let's Encrypt **staging** issuer + Certificate using the same DNS-01 solver, before and after (renewal itself is weeks away) |
| 4 | `authelia-secrets`, `authelia-users` (auth) | High: login for protected apps. `STORAGE_ENCRYPTION_KEY` **must** stay identical or Authelia won't start |

**Cutover per secret (no gap)**: the SopsSecret is added with
`spec.enforceOwnership: true`, so sops-secrets-operator rewrites the existing
Secret's owner reference to itself instead of refusing a Secret it didn't
create. The Sealed Secrets controller then sees a Secret it no longer owns and
leaves it alone, so the old SealedSecret can be removed without Kubernetes
garbage-collecting the Secret. The Secret never disappears, so even pods that
restart mid-cutover are unaffected. Two commits per secret:

1. Add the `*.sops.yaml` (same name/namespace, `enforceOwnership: true`),
   generated straight from the live Secret: `kubectl get secret -o json`
   over SSH → a converter that keeps the exact base64 `data`, type, labels
   and annotations → `sops -e --filename-override <path> /dev/stdin`.
   Plaintext never touches disk; check the decrypted file's data digest
   against the live Secret before committing.
   Verify: the Secret's `ownerReferences` points at the SopsSecret, values
   unchanged.
2. Remove the SealedSecret. Verify: the Secret still exists, app healthy.

## Phase 6: Decommission

1. Remove the sealed-secrets Application. **Keep its master key backup**:
   old git history can only be decrypted with it.
2. Update `README.md`, `AGENTS.md` and the gitleaks config (drop the
   SealedSecret allowlist regex).
3. The agent-worker's GitHub/Plane tokens are created directly as
   SopsSecrets.

## Known trade-offs

- **Generated passwords exist only in the cluster.** A backup of Plane's
  Postgres PVC is useless without the generated Secret, so cluster backups
  must include Secrets.
- **The age key decrypts everything in git.** Same care as the Sealed
  Secrets master key: 1Password + offline copy, never in the repo.
