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
                                              "repo:Inn-Keeper/theplatform:environment:prd"?
                                  ◀─────── 3. Yes → here's a 1-hour Azure access token
 4. Runs terraform with it
```

- **No stored cloud secret** — nothing to leak or rotate.
- A fork, another repo, or another branch/environment **can't** get in — the subject won't match.
- The values stored in GitHub (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) are **identifiers, not passwords**. Knowing them alone grants nothing.

Plus **least privilege**: the dev identity can only touch `rg-lambari-dev`; the prd identity only `rg-lambari-prd`. A bug in dev can't break prd.

The only real secret is `TF_API_TOKEN` (access to HCP state), stored encrypted in GitHub Secrets.

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
│   ├── bootstrap/        # one-time setup, run by hand (✅ done)
│   ├── modules/app/      # reusable Lambari module (step 2)
│   └── envs/
│       ├── dev/          # dev: calls the module (step 2)
│       └── prd/          # prd: calls the module (step 2)
├── .github/workflows/    # CI/CD pipelines (steps 3–5)
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

### Step 2 — The app module (next)

[infra/modules/app/](../infra/modules/app/) will define Lambari's runtime:

- **Container Apps Environment** — the shared "cluster" apps run in.
- **Container App** — runs the API image on port 8080, public HTTPS, health-checked on `/api/health`, 0.25 vCPU / 0.5 GiB, scales 0→1.
- **Static Web App** — hosts the frontend.
- **CORS wiring** — the API's `LAMBARI_ALLOWED_ORIGINS` is set to the frontend's URL automatically, so they can talk to each other.

`envs/dev` and `envs/prd` each call this module with their own image tag. Until Lambari's image exists in GHCR (step 4), a Microsoft hello-world image stands in.

### Step 3 — Plan on pull request

A workflow that runs on every PR:

```
fmt check → validate → tflint (linting) → checkov (security scan) → terraform plan
                                                                    → posted as a PR comment
```

Reviewers see *exactly* what will change in Azure before approving. Nothing is applied.

### Step 4 — Apply on merge + connect Lambari

```
merge to main ─▶ apply dev (automatic) ─▶ apply prd (waits for your approval)
```

In the Lambari repo, a workflow builds the Docker image, pushes it to GHCR tagged with the commit SHA (e.g. `sha-abc123`), deploys the frontend, then notifies this repo (`repository_dispatch`) to roll out the new tag.

Tagging by commit SHA (never `latest`) means every deploy is traceable and **rollback = redeploy the previous tag** (or revert the commit).

### Step 5 — Hardening

- **Drift detection:** a nightly `terraform plan`. If someone changed Azure by hand, the plan won't be empty → the workflow opens a GitHub issue.
- **Runbook** in the README: how to roll back, recover state, check costs.

---

## 7. How a change flows, end to end (after step 4)

1. You change Lambari's Go code and push.
2. Lambari's workflow builds image `ghcr.io/inn-keeper/lambari-api:sha-abc123`.
3. It pings theplatform: "deploy `sha-abc123`".
4. theplatform's workflow logs into Azure via OIDC as the **dev** identity, runs `terraform apply` → dev now runs the new image.
5. The **prd** job pauses. You get a GitHub notification, review, click **Approve**.
6. It logs in as the **prd** identity and applies → production updated.

No passwords stored, no portal clicks, every change reviewed and recorded in git.

---

## 8. Glossary

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
