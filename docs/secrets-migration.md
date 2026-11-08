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
- [ ] **Phase 2**: sops-secrets-operator
- [ ] **Phase 3**: External Secrets Operator
- [ ] **Phase 4**: Plane on generated secrets
- [ ] **Phase 5**: migrate existing SealedSecrets to SOPS
- [ ] **Phase 6**: decommission Sealed Secrets

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
2. **One manual bootstrap step**: put the age private key into the cluster
   once (`kubectl create secret generic ... --from-file=keys.txt` in the
   operator's namespace). Documented in the README prerequisites alongside
   the Sealed Secrets key.
3. Smoke test: a dummy `SopsSecret` → Secret appears → delete it.

## Phase 3: External Secrets Operator

1. ArgoCD Application for the ESO Helm chart (with CRDs).
2. `SkipDryRunOnMissingResource=true` on apps that use ESO resources, so the
   first sync doesn't fail before the CRDs exist.

## Phase 4: Plane on generated secrets

Only possible because Plane holds no data yet. **Don't start the Plane
first-time setup before this phase is done.**

1. Replace the 6 SealedSecrets with **one** `ExternalSecret` that uses
   `Password` generators and templates `DATABASE_URL` / `AMQP_URL` from the
   generated values. All six chart `external_secrets.*` names point at that
   single Secret, so the passwords can't drift apart.
2. `refreshPolicy: CreatedOnce`, so ESO **never** regenerates a password
   Postgres is already using.
3. Wipe Plane's 4 PVCs once (Postgres keeps whatever password it started
   with), then resync.
4. Delete `apps/plane/sealed-secrets.yaml`.

## Phase 5: Migrate existing secrets to SOPS (same values)

A script reads each live Secret from the cluster over SSH and pipes it
straight into `sops -e`. Plaintext never touches disk, and the values stay
identical, so no app notices the change. One secret per commit, lowest risk
first:

| Order | Secret(s) | Risk if it breaks |
|---|---|---|
| 1 | `open-webui-secret` (ai), `unpackerr-secret`, `recyclarr-config` (media) | Low |
| 2 | `vpn-secret` (media), `tailscale-auth` (tailscale), `cloudflare-tunnel-token` (n8n) | Medium: networking/VPN |
| 3 | `cloudflare-api-token` (cert-manager) | High: TLS renewals |
| 4 | `authelia-secrets`, `authelia-users` (auth) | High: login for protected apps. `STORAGE_ENCRYPTION_KEY` **must** stay identical or Authelia won't start |

**Cutover per secret**: in one commit, the SealedSecret goes out and the
SopsSecret comes in. The SealedSecret controller garbage-collects its Secret
and sops-secrets-operator recreates it from SOPS. Running pods are
unaffected; a pod that restarts during those seconds waits briefly in
`CreateContainerConfigError`. After each commit, verify the Secret's owner
and the app's health before the next one.

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
