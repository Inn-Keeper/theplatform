# theplatform — A Beginner's Guide

This repo deploys **Lambari** (a Go API + a web dashboard) to **Microsoft Azure** using **Terraform**, **Docker**, and **GitHub Actions** — the same building blocks real platform teams use, kept inside Azure's free tiers.

If you've never used any of these tools, start at the top. Each section builds on the previous one.

---

## 1. The big picture

```
 Developer pushes code
          │
          ▼
 ┌──────────────────┐   builds    ┌──────────────────┐
 │  Lambari repo    │ ──────────▶ │  Docker image    │  stored in GHCR
 │  (app code)      │             │  (the packaged   │  (GitHub's image registry)
 └──────────────────┘             │   API)           │
          │                       └──────────────────┘
          │ "new version ready"            │
          ▼                                │ pulled by Azure
 ┌──────────────────┐   Terraform  ┌───────▼──────────┐
 │  theplatform     │ ───────────▶ │  Azure           │
 │  (this repo:     │   via GitHub │  dev  →  prd     │
 │   infrastructure)│   Actions    │                  │
 └──────────────────┘              └──────────────────┘
```

Two repos, two jobs:

| Repo | Owns | Answers the question |
|---|---|---|
| **lambari** | Application code | *What* does the app do? |
| **theplatform** | Infrastructure code | *Where* and *how* does it run? |

Keeping them separate is common in real companies: app teams ship features, the platform team owns the cloud setup.

---

## 2. Core concepts

### 2.1 Docker — packaging the app

**Problem:** "It works on my machine." The app needs a specific Go version, OS libraries, and config.

**Solution:** Docker bundles the app *and everything it needs* into an **image** — a read-only snapshot. Running an image produces a **container**.

| Term | Analogy |
|---|---|
| **Dockerfile** | A recipe |
| **Image** | The baked cake (frozen, reusable) |
| **Container** | A slice being eaten (a running copy) |
| **Registry** | The bakery shelf where cakes are stored (GHCR, Docker Hub) |

Lambari's `backend/Dockerfile` (in the Lambari repo) uses a **multi-stage build**:
1. Stage 1 uses a full Go image to compile the code.
2. Stage 2 copies *only the compiled binary* into a tiny "distroless" image with no shell and runs it as a non-root user.

Result: a small, secure image. Azure doesn't care that it's Go — it just runs the container.

**GHCR** (GitHub Container Registry, `ghcr.io`) is where our images live. Free for public images.

### 2.2 Terraform — infrastructure as code

**Problem:** Clicking around the Azure portal is slow, undocumented, and impossible to review or repeat.

**Solution:** Terraform lets you *describe* infrastructure in text files (`.tf`). You write *what you want*; Terraform figures out *how* to get there.

```hcl
resource "azurerm_resource_group" "env" {
  name     = "rg-lambari-dev"
  location = "eastus"
}
```

Key ideas:

| Term | Meaning |
|---|---|
| **Provider** | A plugin that talks to one service's API (`azurerm` for Azure, `github` for GitHub, `tfe` for HCP Terraform) |
| **Resource** | One thing to create — a resource group, an app, a GitHub environment |
| **Data source** | Something to *read* that already exists (e.g. "who am I logged in as?") |
| **Variable** | An input, so the same code works for dev and prd |
| **Output** | A value printed after apply (e.g. the app's URL) |
| **Module** | A reusable bundle of resources — like a function |
| **State** | Terraform's memory of what it created (see below) |

The workflow is always three commands:

| Command | What it does |
|---|---|
| `terraform init` | Downloads providers, connects to state storage |
| `terraform plan` | **Dry run.** Shows what *would* change. Safe — touches nothing |
| `terraform apply` | Shows the plan, asks for `yes`, then makes the changes |

#### State — the most important concept

Terraform keeps a **state file** that maps your code to real Azure resources ("`azurerm_resource_group.env["dev"]` = this specific resource ID").

- Without state, Terraform can't tell "create" from "already exists".
- If two people apply at once, state can corrupt — so it needs **locking**.
- State can contain sensitive values — **never commit it to git** (our `.gitignore` blocks it).

We store state in **HCP Terraform** (HashiCorp's free cloud service). It provides storage + locking. We use it in *local execution mode*: HCP only holds state, while the actual `plan`/`apply` runs on GitHub's machines.

### 2.3 Azure — the cloud

| Term | Meaning |
|---|---|
| **Subscription** | Your billing account. Everything lives inside one |
| **Resource Group (RG)** | A folder for related resources. Delete the RG → everything inside goes |
| **Entra ID** (formerly Azure AD) | Azure's identity system — users, apps, permissions |
| **App registration / Service principal** | An identity for a *robot* (our CI pipeline) instead of a human |
| **Role assignment** | "This identity can do *X* on *Y*" — e.g. Contributor on `rg-lambari-dev` |
| **Container Apps** | Runs Docker containers without managing servers. Scales to zero when idle |
| **Static Web Apps** | Hosts static websites (our built frontend) on a global CDN |

### 2.4 CI/CD — automation

- **CI (Continuous Integration):** every change is automatically checked — formatted, validated, security-scanned.
- **CD (Continuous Delivery/Deployment):** approved changes are automatically shipped.

We use **GitHub Actions**: YAML files in `.github/workflows/` that GitHub runs on its own machines when something happens (a push, a pull request, a schedule).

**GitHub Environments** (`dev`, `prd`) add guardrails:
- Each environment has its own variables (which Azure identity to use).
- `prd` requires **manual approval** before any job runs against it.

---

## 3. Security: how GitHub logs into Azure with no password

The naive way: create an Azure password, paste it into GitHub secrets. If it leaks, an attacker owns your cloud until someone notices.

We use **OIDC (OpenID Connect) federation** instead:

```
 GitHub Actions job                        Azure (Entra ID)
 ──────────────────                        ────────────────
 1. "I'm a job in repo Inn-Keeper/
    theplatform, environment prd"
    + a short-lived signed token  ───────▶ 2. Checks: is the signature from GitHub?
                                              Does the subject match exactly
                                              "repo:Inn-Keeper@<owner_id>/theplatform@<repo_id>:environment:prd"?
                                  ◀─────── 3. Yes → here's a 1-hour Azure access token
 4. Runs terraform with it
```

- **No stored cloud secret** — nothing to leak or rotate.
- A fork, another repo, or another branch/environment **can't** get in — the subject won't match.
- The subject pins GitHub's numeric account and repo IDs, so even renaming the repo or creating a look-alike name can't match.
- The values stored in GitHub (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) are **identifiers, not passwords**. Knowing them alone grants nothing.

Plus **least privilege**: the dev identity can only touch `rg-lambari-dev`; the prd identity only `rg-lambari-prd`. A bug in dev can't break prd.

There are three identities, one per GitHub Environment:

| Environment | Role | Used by |
|---|---|---|
| `dev` | Contributor on `rg-lambari-dev` | PR plans + applies for dev |
| `prd` | Contributor on `rg-lambari-prd` | prd applies — **requires your approval** |
| `prd-plan` | `lambari-plan-reader` (read + list secrets) on `rg-lambari-prd` | PR plans for prd, no approval needed |

Real secrets, both stored encrypted in GitHub Secrets:

- `TF_API_TOKEN` (theplatform) — access to HCP state.
- `PLATFORM_DISPATCH_TOKEN` (lambari) — fine-grained PAT that can only trigger theplatform's deploys.

### What never goes into git

| File / value | Why | Protected by |
|---|---|---|
| `*.tfstate` | Contains resource details | `.gitignore` |
| `*.tfvars` | Contains personal values (email, org) | `.gitignore` |
| `.terraform/` | Downloaded plugins, large | `.gitignore` |
| Tokens | Grant access | GitHub Secrets / your shell only |

`.terraform.lock.hcl` **is** committed — it pins exact provider versions so everyone gets the same build.

---

## 4. Cost: staying at $0

| Piece | Why it's free |
|---|---|
| Container Apps (consumption) | Monthly free grant: 180,000 vCPU-seconds, 360,000 GiB-seconds, 2M requests. With `min_replicas = 0`, idle time costs nothing |
| Static Web Apps (Free tier) | Free tier, 100 GB bandwidth/month |
| Entra ID app registrations, RGs, budgets | Always free |
| HCP Terraform | Free tier |
| GitHub Actions + Environments | Free on public repos |
| GHCR | Free for public images |

Deliberately **not** used because they cost money: Azure Container Registry, Key Vault (per-operation fees), Log Analytics (easy to overrun), Kafka/Event Hubs, managed Postgres.

**Safety net:** a **$1 monthly budget** emails an alert if actual spend passes 50¢ or forecast passes $1.

> Trade-off: scaling to zero means the first request after idle waits a few seconds (a "cold start"), and Lambari's in-memory data resets. Acceptable for a demo; same behaviour as the previous Render setup.

---

## 5. Repo layout

```
theplatform/
├── infra/
│   ├── bootstrap/        # one-time setup, run by hand
│   ├── modules/app/      # reusable Lambari module
│   ├── envs/
│   │   ├── dev/          # dev: East US
│   │   └── prd/          # prd: Container Apps in East US 2 (see §8)
│   └── lambari.version   # the Lambari image tag currently deployed
├── .github/workflows/
│   ├── terraform.yml     # PR: checks + plan comments
│   ├── apply.yml         # merge / Lambari release: dev → approval → prd
│   └── _deploy.yml       # one env: apply + frontend build/upload
└── docs/GUIDE.md         # this file
```

Why `envs/dev` and `envs/prd` as separate folders? Each has its own state, so a mistake in one can't touch the other, and each is applied by its own identity.

---

## 6. The build, step by step

### Step 1 — Bootstrap ✅ done

The chicken-and-egg step: the pipeline needs identities, permissions, and state storage *before* it can run. So these are created once, by hand, from a laptop.

[infra/bootstrap/main.tf](../infra/bootstrap/main.tf) creates, for each of `dev` and `prd`:

1. A **resource group** (`rg-lambari-dev` / `rg-lambari-prd`)
2. An **Entra ID app + service principal** (the robot identity)
3. A **federated credential** (the OIDC trust from §3)
4. A **Contributor role** on *only* its own RG
5. An **HCP Terraform workspace** (`lambari-dev` / `lambari-prd`) for state
6. A **GitHub Environment** with the three Azure IDs as variables — `prd` requires approval

Plus one **$1 budget alert** on the subscription.

Bootstrap's own state stays on the laptop (gitignored) — it can't store state in a backend it's creating.

### Step 2 — The app module ✅ done

[infra/modules/app/](../infra/modules/app/) defines Lambari's runtime:

- **Container Apps Environment** — the shared "cluster" apps run in.
- **Container App** — runs the API image on port 8080, public HTTPS, health-checked on `/api/health`, 0.25 vCPU / 0.5 GiB, scales 0→1.
- **Static Web App** — hosts the frontend.
- **CORS wiring** — the API's `LAMBARI_ALLOWED_ORIGINS` is set to the frontend's URL automatically, so they can talk to each other.

`envs/dev` and `envs/prd` each call this module. Both read the image tag from `infra/lambari.version`.

### Step 3 — Plan on pull request ✅ done

A workflow that runs on every PR:

```
fmt check → validate → tflint (linting) → checkov (security scan) → terraform plan
                                                                    → posted as a PR comment
```

Reviewers see *exactly* what will change in Azure before approving. Nothing is applied. prd is planned with the read-only `prd-plan` identity so PRs don't wait on the approval gate.

### Step 4 — Apply on merge + connect Lambari ✅ done

```
merge to main ─▶ apply dev (automatic) ─▶ apply prd (waits for your approval)
```

In the Lambari repo, the `release` job (after tests pass on `main`) builds the Docker image, pushes it to GHCR tagged with the commit SHA (e.g. `sha-<40 hex chars>`), then notifies this repo (`repository_dispatch`).

theplatform's `apply` workflow then:

1. **bump** — validates the tag format (it's input from another repo), writes it to `infra/lambari.version`, commits to `main` as `github-actions[bot]`.
2. **dev** — `terraform apply`, then builds Lambari's frontend *at that same commit* with `VITE_API_BASE` = dev's API URL, and uploads it to dev's Static Web App.
3. **prd** — waits for your approval, then the same for prd.

The frontend is built per environment because Vite bakes the API URL in at build time. The Static Web App deploy token never leaves theplatform — it's read from Terraform output and masked in logs.

Tagging by commit SHA (never `latest`) means every deploy is traceable. **Rollback = revert the `deploy: lambari sha-…` commit** on `main`; the apply workflow redeploys the previous tag.

### Step 5 — Hardening

- **Drift detection:** a nightly `terraform plan`. If someone changed Azure by hand, the plan won't be empty → the workflow opens a GitHub issue.
- **Runbook** in the README: how to roll back, recover state, check costs.

---

## 7. How a change flows, end to end

1. You change Lambari's Go code and push.
2. Lambari's workflow builds image `ghcr.io/inn-keeper/lambari-api:sha-abc123`.
3. It pings theplatform: "deploy `sha-abc123`". theplatform commits that tag to `infra/lambari.version`.
4. theplatform's workflow logs into Azure via OIDC as the **dev** identity, runs `terraform apply` → dev now runs the new image.
5. The **prd** job pauses. You get a GitHub notification, review, click **Approve**.
6. It logs in as the **prd** identity and applies → production updated.

No passwords stored, no portal clicks, every change reviewed and recorded in git.

---

## 8. Gotchas we hit (read before changing things)

Real problems found while building this, why they happen, and what the code does about them. If you're tempted to "clean up" one of these, read the reason first.

| # | Symptom | Cause | What we did |
|---|---|---|---|
| 1 | `MaxNumberOfRegionalEnvironmentsInSubExceeded` (409) when creating prd | Free/trial subscriptions allow **one Container Apps environment per region**. dev holds East US | prd's environment runs in **East US 2** (`location` in [envs/prd/main.tf](../infra/envs/prd/main.tf)). Adding a third env needs a third region |
| 2 | `AADSTS700213: No matching federated identity record` | GitHub now sends OIDC subjects with numeric IDs: `repo:Inn-Keeper@126582166/theplatform@1429722621:environment:dev` | Federated credentials use that ID-pinned format (bootstrap) |
| 3 | checkov `CKV_AZURE_249` fails on the federated credentials | The check only understands the old `repo:owner/name` subject | Inline `#checkov:skip` with the reason. Don't revert the subject to silence it |
| 4 | dev plan always shows "2 to change" on the Container Apps environment | Azure adds a default `Consumption` workload profile | Declared explicitly in the module. Same free billing |
| 5 | dev plan always shows `repository_url`/`repository_branch` → null on the Static Web App | The SWA deploy action stamps the source repo onto the site | `lifecycle.ignore_changes` on those two fields |
| 6 | prd PR plan: `403 ... listSecrets` / `listAppSettings` | Built-in Reader can't call list actions, which `plan` needs to refresh SWA / Container Apps | Custom role `lambari-plan-reader` = `*/read` + those list actions. New Azure resource types may need more actions added here |
| 7 | Provider registration errors in CI | CI identities are RG-scoped and can't register resource providers subscription-wide | `resource_provider_registrations = "none"` in envs; register once by hand: `az provider register --namespace Microsoft.App` |
| 8 | Lambari's release job: `gh: set the GH_TOKEN` | `PLATFORM_DISPATCH_TOKEN` secret missing or expired | Recreate the PAT (see renewals below) |
| 9 | tflint: `required_version attribute is required` | tflint wants it in every module, not just root | Declared in the module |

### Renewals and deadlines

| What | When | How |
|---|---|---|
| Azure Free Trial → **upgrade to Pay-As-You-Go** | Before 30 days from signup | Portal → Subscriptions → Upgrade. Without it the subscription is disabled. Free tiers stay free after upgrade |
| `PLATFORM_DISPATCH_TOKEN` (fine-grained PAT, 90 days) | ~2027-01-21 | Regenerate (only `theplatform`, Contents read/write), then `gh secret set PLATFORM_DISPATCH_TOKEN --repo Inn-Keeper/lambari` |
| `TF_API_TOKEN` (HCP team token) | Expiry you chose at creation | HCP → Settings → Teams → owners → regenerate, then `gh secret set TF_API_TOKEN` |

### Good to know

- **GHCR visibility:** the image inherited Lambari's public visibility, so Azure pulls it anonymously. If it ever becomes private, Container Apps will fail to pull.
- **Commit email:** commits use the GitHub noreply address (`126582166+Inn-Keeper@users.noreply.github.com`), set per repo. Your global git config still has your personal email — new repos will use it unless changed.
- **Error logs show the subscription ID.** It's an identifier, not a secret, but the repo is public, so Terraform errors in Actions logs reveal it. Nothing can be done with it alone.

---

## 9. Glossary

| Term | One-liner |
|---|---|
| **IaC** | Infrastructure as Code — infra defined in files, versioned in git |
| **Drift** | Real infra no longer matches the code (someone clicked in the portal) |
| **Idempotent** | Running `apply` twice gives the same result — no duplicates |
| **OIDC** | Standard for one system to vouch for an identity to another |
| **Least privilege** | Give each identity the minimum access it needs |
| **Cold start** | Delay when a scaled-to-zero app wakes up |
| **CORS** | Browser rule controlling which websites may call an API |
| **Image tag** | A label on an image version, e.g. `sha-abc123` |
