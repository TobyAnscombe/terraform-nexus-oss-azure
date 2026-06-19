# Nexus OSS — Azure Container Instance (Terraform)

A hosted Python and R package repository in Azure UK South with three tiers:

| Who | Can do |
|-----|--------|
| **Anonymous** (no credentials) | Browse and install allowlisted packages (proxied from PyPI / CRAN) and anything an admin has uploaded |
| **Authenticated** (with credentials) | Everything above + upload new packages to the hosted repos |
| **Admin** | Full Nexus UI access, manage users, roles, and the package allowlists |

---

## Architecture

### Python (PyPI proxy)

```
pip install pandas
      │
      ▼
 pypi-group  (group repo — single pip URL for all clients)
      │
      ├── pypi-hosted   (checked first — admin-uploaded / internal packages)
      │
      └── pypi-pypi.org (proxy → https://pypi.org)
                │
                └── pypi-allowlist (routing rule, ALLOW mode)
                        only approved package names pass through
                        everything else → 404
```

### R (CRAN proxy)

```
install.packages("dplyr")
      │
      ▼
 r-group  (group repo — single URL for all R clients)
      │
      ├── r-hosted      (checked first — admin-uploaded / internal packages)
      │
      └── r-cran.r-project.org (proxy → https://cran.r-project.org)
                │
                └── r-cran-allowlist (routing rule, ALLOW mode)
                        only approved package names pass through
                        everything else → 404
```

Both stacks share the same Azure Files share and Nexus instance. Cached packages remain
available even if PyPI or CRAN is unreachable.

**Why this layout?**

- Hosted repos are checked first, so internal packages shadow same-named public packages (prevents dependency-confusion attacks).
- Routing rules enforce the allowlist — only pre-approved packages are ever fetched from the internet.

### Container architecture

The ACI container group runs two containers that share `localhost`:

```
Internet (HTTPS)
        │
        ▼
  Cloudflare edge  ←  cloudflare/cloudflared  (outbound tunnel, no open ports)
                               │  proxy localhost:8081
                               ▼
                     sonatype/nexus3           ← internal only (port 8081)
                               │
                               └── /nexus-data (Azure Files share — persists across restarts)
```

No ports are exposed on Azure. cloudflared connects **outbound** to Cloudflare's network using the tunnel token; Cloudflare routes HTTPS traffic through the tunnel to Nexus. TLS termination happens at Cloudflare's edge — no certificate management required.

---

## Prerequisites

| Tool | macOS / Linux | Windows |
|------|--------------|---------|
| Terraform ≥ 1.5 | `brew install terraform` | [terraform.io/downloads](https://developer.hashicorp.com/terraform/install) |
| Azure CLI | `brew install azure-cli` | `winget install Microsoft.AzureCLI` |
| PowerShell | built-in | built-in (Windows 11) |

---

## Two-phase layout

The repository uses a two-phase Terraform structure:

| Phase | Directory | Manages |
|-------|-----------|---------|
| **1 — infra** | `infra/` | Azure Container Instance, Storage Account, VNet / NSG, Resource Group |
| **2 — nexus** | `nexus/` | Nexus repositories, routing rules, roles, anonymous access |

Phase 2 reads the Nexus URL from Phase 1's remote state. A `time_sleep` resource in Phase 1
ensures the `nexus_base_url` output is only written after a 2-minute startup wait, so Phase 2
cannot initialise the nexus provider before Nexus is ready.

---

## Remote state setup (one-time)

Terraform state is stored in Azure Blob Storage so the state file is shared and locked across team members. Run this once before the first deploy:

**macOS / Linux**
```bash
az login
az account set --subscription "<subscription-id>"
./scripts/create-backend.sh
```

**Windows (PowerShell)**
```powershell
az login
az account set --subscription "<subscription-id>"
.\scripts\create-backend.ps1
```

Both scripts create the storage account, blob container, and write `backend.hcl` in the repo root. Copy and adjust the key for each phase:

**macOS / Linux**
```bash
sed 's/nexus-oss.terraform.tfstate/infra.tfstate/' backend.hcl > infra/backend.hcl
sed 's/nexus-oss.terraform.tfstate/nexus.tfstate/'  backend.hcl > nexus/backend.hcl
```

**Windows (PowerShell)**
```powershell
(Get-Content backend.hcl) -replace 'nexus-oss.terraform.tfstate','infra.tfstate' | Set-Content infra\backend.hcl
(Get-Content backend.hcl) -replace 'nexus-oss.terraform.tfstate','nexus.tfstate'  | Set-Content nexus\backend.hcl
```

`backend.hcl` is git-ignored. See [infra/backend.hcl.example](infra/backend.hcl.example) and [nexus/backend.hcl.example](nexus/backend.hcl.example) for the format.

---

## Deploy

### Phase 1 — Infrastructure

Before deploying, create the Cloudflare Tunnel:

1. In [Zero Trust dashboard](https://one.dash.cloudflare.com) → **Networks → Tunnels → Create a tunnel** (Cloudflared type)
2. Under **Public Hostnames**, add: `<your-hostname>` → `http://localhost:8081`
3. Copy the tunnel token into `infra/terraform.tfvars` as `cloudflare_tunnel_token`

Then deploy:

**macOS / Linux**
```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# fill in cloudflare_tunnel_token and cloudflare_tunnel_hostname

terraform init --backend-config=backend.hcl
terraform apply
```

**Windows (PowerShell)**
```powershell
cd infra
Copy-Item terraform.tfvars.example terraform.tfvars
# fill in cloudflare_tunnel_token and cloudflare_tunnel_hostname

terraform init -backend-config=backend.hcl
terraform apply
```

**Total time: ~5–7 minutes** (includes a 2-minute startup wait for Nexus).

### Bot Fight Mode note

Cloudflare's **Bot Fight Mode** blocks programmatic HTTP clients from corporate networks (SSL-inspecting proxies alter the TLS fingerprint, causing Cloudflare to flag the request as a bot). The `datadrivers/nexus` provider connects to Nexus through the Cloudflare Tunnel — but the password **bootstrap** scripts (`set-nexus-password.sh/ps1`) now bypass this entirely by uploading a temp script to Azure Files and running it inside the container via `az container exec`, which goes through Azure ARM APIs rather than Cloudflare.

**No action needed** — `terraform apply nexus/` handles this automatically via the `null_resource.set_admin_password` resource.

### Phase 2 — Nexus configuration

**macOS / Linux**
```bash
cd nexus
cp terraform.tfvars.example terraform.tfvars
# set admin_password and state_storage_account

terraform init --backend-config=backend.hcl
```

**Windows (PowerShell)**
```powershell
cd nexus
Copy-Item terraform.tfvars.example terraform.tfvars
# set admin_password and state_storage_account

terraform init -backend-config=backend.hcl
```

Nexus ships with a built-in `anonymous` user that must be imported into state before the first apply, otherwise Terraform will try to create it and fail with a duplicate-user error:

```
terraform import nexus_security_user.anonymous anonymous
terraform apply
```

Phase 2 reads the Nexus URL from Phase 1's remote state and changes the admin password from the Nexus default (`admin123`) to the value set in `admin_password`. Run Phase 1 fully before Phase 2.

### Password bootstrap script

`scripts/set-nexus-password.sh` (and `.ps1` for Windows) is called automatically by `terraform apply nexus/` via the `null_resource.set_admin_password` resource. You can also run it manually — for example to reset the password after a container restart.

The script uploads a temporary bash script to the Nexus Azure Files share and executes it inside the container via `az container exec`, running `curl` against `localhost:8081`. This bypasses Cloudflare entirely — no tunnel involved. The temp file is deleted immediately after the bootstrap completes.

The bootstrap is idempotent: it tries `admin123` first (fresh instance), then falls back to `NEW_PASSWORD` (already bootstrapped). It also accepts the Nexus CE EULA as its first step, which is required before any repository content is accessible.

**Requires**: Azure CLI (`az login`) with at least Contributor access to the resource group.

**macOS / Linux**
```bash
NEW_PASSWORD=<your-admin-password> \
RESOURCE_GROUP=rg-nexus-oss \
CONTAINER_GROUP=aci-prod-nexus-oss \
STORAGE_ACCOUNT=<storage-account-name> \
bash scripts/set-nexus-password.sh
```

**Windows (PowerShell)**
```powershell
$env:NEW_PASSWORD    = "<your-admin-password>"
$env:RESOURCE_GROUP  = "rg-nexus-oss"
$env:CONTAINER_GROUP = "aci-prod-nexus-oss"
$env:STORAGE_ACCOUNT = "<storage-account-name>"
.\scripts\set-nexus-password.ps1
```

Or using named parameters:
```powershell
.\scripts\set-nexus-password.ps1 `
  -NewPassword    "<your-admin-password>" `
  -ResourceGroup  "rg-nexus-oss" `
  -ContainerGroup "aci-prod-nexus-oss" `
  -StorageAccount "<storage-account-name>"
```

---

## Networking

ACI is always deployed with a **private IP** in a managed VNet — no public IP, no exposed Azure ports. Configure the address space in `infra/terraform.tfvars`:

```hcl
vnet_address_space = "10.100.0.0/16"
aci_subnet_prefix  = "10.100.1.0/24"
```

Public access is via **Cloudflare Tunnel** only — the cloudflared sidecar connects outbound to Cloudflare, so no inbound NSG rules or TLS certificates are needed.

---

## Live deployment details

Run `terraform output` from `infra/` after deploying to get your URLs. Example:

| Resource | Value |
|----------|-------|
| Web UI | https://nexus.example.com |
| pip index URL | https://nexus.example.com/repository/pypi-group/simple/ |
| pip upload URL | https://nexus.example.com/repository/pypi-hosted/ |
| R repo URL | https://nexus.example.com/repository/r-group/ |
| ACI private IP | (from `container_group_ip` output — VNet-internal only) |
| Resource group | rg-nexus-oss |
| Storage account | (from `storage_account_name` output) |
| Azure region | UK South |

---

## Configuring pip

Replace `nexus.example.com` with your `cloudflare_tunnel_hostname`. No `trusted-host` needed — traffic is HTTPS via Cloudflare.

### Option 1 — Global (all projects on this machine)

```ini
# ~/.pip/pip.conf  (macOS/Linux)
# %APPDATA%\pip\pip.ini  (Windows)
[global]
index-url = https://nexus.example.com/repository/pypi-group/simple/
```

### Option 2 — Per virtualenv

```ini
# .venv/pip.conf
[global]
index-url = https://nexus.example.com/repository/pypi-group/simple/
```

---

## Configuring R

Replace `nexus.example.com` with your `cloudflare_tunnel_hostname`.

### Option 1 — Persistent (all sessions for this user)

Add to `~/.Rprofile` (or `Rprofile.site` for system-wide):

```r
options(repos = c(
  NEXUS = "https://nexus.example.com/repository/r-group/",
  CRAN  = "@CRAN@"
))
```

The `CRAN = "@CRAN@"` fallback is kept so RStudio's mirror selector still works for any package not yet in the allowlist.

### Option 2 — Per session

```r
options(repos = c(NEXUS = "https://nexus.example.com/repository/r-group/"))
install.packages("dplyr")
```

### Option 3 — renv projects

In `.Rprofile` at the project root (renv will pick this up):

```r
options(repos = c(NEXUS = "https://nexus.example.com/repository/r-group/"))
```

> **RStudio note:** Once `options(repos)` points at Nexus, RStudio's *Packages → Install* panel uses Nexus automatically — no further IDE configuration is needed.

---

## Testing the deployment

### Python — install and cache-hit test

```bash
# First install — Nexus fetches from PyPI and caches
pip install pandas \
  --index-url https://nexus.example.com/repository/pypi-group/simple/
```

### Python — verify the allowlist blocks unlisted packages

```bash
pip install flask \
  --index-url https://nexus.example.com/repository/pypi-group/simple/
# Expected: ERROR: Could not find a version that satisfies the requirement flask
```

### R — install and cache-hit test

```r
options(repos = c(NEXUS = "https://nexus.example.com/repository/r-group/"))
install.packages("dplyr")
```

### R — verify the allowlist blocks unlisted packages

```r
install.packages("shiny")
# Expected: Warning: unable to access index for repository ...
#           package 'shiny' is not available
```

### Browse via the web UI

1. Go to `https://nexus.example.com`
2. Click **Browse** in the left sidebar.
3. Open **pypi-group** or **r-group** to see available packages.

---

## Package allowlist

Routing rules (`pypi-allowlist`, `r-cran-allowlist`) control which packages each proxy will fetch.
Packages uploaded to the hosted repos (`pypi-hosted`, `r-hosted`) are always available regardless of the allowlist.

### Python allowlist (`nexus/variables.tf` → `pypi_allowlist`)

| Category | Packages |
|----------|---------|
| **build_tools** | pip, setuptools, wheel, twine, build, poetry, pytest |
| **core** | numpy, pandas, scipy, polars, pyarrow, dask, pyspark |
| **visualisation** | matplotlib, seaborn, plotly, bokeh, altair, kaleido, missingno |
| **ml** | scikit-learn, xgboost, lightgbm, statsmodels, lifelines, pingouin, mlflow, shap, lime, eli5, pandera, great-expectations |
| **data_io** | openpyxl, xlrd, xlsxwriter, fastparquet, sqlalchemy, psycopg2-binary, pymysql, pyodbc |
| **jupyter** | jupyter, jupyterlab, ipython, ipykernel, notebook, nbformat, nbconvert, ipywidgets, widgetsnbextension |
| **utilities** | joblib, numba, tqdm, requests, httpx, aiohttp, python-dateutil, pytz, tzdata, six, certifi, charset-normalizer, idna, urllib3, packaging, click, pydantic, pydantic-core, typing-extensions, attrs, annotated-types |

### R allowlist (`nexus/variables.tf` → `r_allowlist`)

| Category | Packages |
|----------|---------|
| **tidyverse_plumbing** | rlang, vctrs, lifecycle, cli, glue, magrittr, generics, R6, Rcpp, withr, pkgconfig, ellipsis, tibble, purrr, readr, forcats, hms, vroom, tidyselect, pillar, fansi, utf8, crayon, bit64, bit |
| **data_wrangling** | tidyverse, dplyr, tidyr, stringr, stringi, data.table, lubridate, broom, modelr |
| **io_formats** | haven, readxl, openxlsx, rio, foreign, cellranger, zip, jsonlite, curl, httr |
| **visualisation** | ggplot2, scales, gtable, isoband, farver, labeling, munsell, RColorBrewer, viridisLite, colorspace, MASS |
| **string_matching** | fuzzyjoin, stringdist |

> **Tidyverse note:** `tidyverse` is a meta-package that installs ~30 sub-packages. The tidyverse_plumbing row covers the transitive dependencies most likely to be pulled. If an install fails with a 404 on an unlisted dependency, add it and re-apply (see below).

### Adding a new Python package

1. Open `nexus/variables.tf`, find `var.pypi_allowlist`, add the package to the appropriate category list.
2. Run `terraform apply` from `nexus/` — the routing rule updates in-place, no infrastructure changes.

> **Name normalisation:** PyPI normalises names to lowercase with hyphens. Use `scikit-learn` not `scikit_learn`.

### Adding a new R package

1. Open `nexus/variables.tf`, find `var.r_allowlist`, add the package to the appropriate category list.
2. Run `terraform apply` from `nexus/` — the routing rule updates in-place.

   If the package name contains a `.` (e.g. `data.table`), add it as-is — dot escaping is handled automatically by the Terraform code.

---

## Uploading packages to the hosted repos

### Python — push to pypi-hosted

```bash
# Download from PyPI
pip download requests --no-deps -d /tmp/nx-upload/

# Push to Nexus
twine upload \
  --repository-url https://nexus.example.com/repository/pypi-hosted/ \
  -u admin -p 'YOUR_PASSWORD' \
  /tmp/nx-upload/*
rm -rf /tmp/nx-upload
```

Or build and publish your own package:

```bash
python -m build
twine upload \
  --repository-url https://nexus.example.com/repository/pypi-hosted/ \
  -u YOUR_USER -p YOUR_PASSWORD \
  dist/*
```

### R — push to r-hosted

Use the **web UI**: log in → **Browse → r-hosted → Upload component**, then select the `.tar.gz` source package or binary.

---

## Creating user accounts

1. Log in to https://nexus.example.com as `admin`.
2. **Administration → Security → Users → Create local user**.
3. Assign roles as appropriate:

   | Role | Access |
   |------|--------|
   | `pypi-anonymous-reader` | Browse + install Python packages from pypi-group |
   | `pypi-authenticated-deployer` | Above + upload to pypi-hosted |
   | `r-anonymous-reader` | Browse + install R packages from r-group |
   | `r-authenticated-deployer` | Above + upload to r-hosted |

---

## Cleanup policies

The `datadrivers/nexus` Terraform provider (v2.x) does not expose a `nexus_cleanup_policy` resource. Cleanup policies must be created once via the Nexus admin UI:

1. **Administration → Cleanup Policies → Create Cleanup Policy**
2. Create `pypi-proxy-cleanup`: format `PyPI`, last downloaded `> 90 days`
3. Create `r-proxy-cleanup`: format `R`, last downloaded `> 90 days`
4. Associate each policy with its proxy repo via **Browse → \<repo\> → Edit → Cleanup**.

Without cleanup, the Azure Files share will grow as packages are proxied.

---

## Supply-chain risk mitigations

| Risk | Mitigation in place |
|------|-------------------|
| Typosquatting | Allowlist — only approved package names served by the proxies |
| Dependency confusion | Hosted repos checked before proxies; internal packages win on name conflict |
| Compromised package version | Pin exact versions; use `pip-compile --generate-hashes` for Python |
| Known CVEs | Run `pip-audit -r requirements.txt` in CI (not enforced by Nexus OSS) |
| PyPI / CRAN outage | Nexus caches every download — previously-fetched packages remain available |

---

## Troubleshooting

### pip / install.packages returns 404 for a package

The package is not on the allowlist. Either:
- Add it to the relevant category in `nexus/variables.tf` and `terraform apply` from `nexus/`, **or**
- Upload it directly to the hosted repo via the web UI or API.

### Python package on the allowlist still returns 404

The routing rule requires two matchers per package (`/simple/` and `/packages/`). These are generated automatically from `var.pypi_allowlist` — verify the package name spelling (lowercase, hyphens).

### R package on the allowlist still fails to install

Three matchers per package (source + Windows binary + macOS binary) are generated automatically. Verify the package name in `var.r_allowlist`. Dot escaping (e.g. `data.table`) is handled automatically.

### CRAN metadata fetch returns 404 or 403

Nexus does not support the bare `PACKAGES` endpoint for the R format — it returns 404 with "This metadata type is not supported for now". R clients request `PACKAGES.gz`, `PACKAGES.rds`, or `PACKAGES.bz2` instead, which Nexus does proxy correctly.

If `PACKAGES.gz` returns 403 the routing rule is blocking it. This happens when the regex uses `($|\\.)` which only matches a bare trailing dot, not extensions like `.gz`. The correct pattern is `(\\.[^/]*)?$`. Run `terraform apply` from `nexus/` to push the updated matchers.

### Container logs

```bash
az container logs \
  --resource-group rg-nexus-oss \
  --name aci-prod-nexus-oss \
  --container-name nexus
```

### Nexus admin password

Because `NEXUS_SECURITY_RANDOMPASSWORD=false` is set, Nexus starts with the fixed default password `admin123`. Phase 2 (`nexus/`) sets the real password via the `admin_password` variable, using `scripts/set-nexus-password.sh` (or `.ps1`).

To reset or re-set the password manually (e.g. after a container restart resets to `admin123`):

**macOS / Linux**
```bash
NEW_PASSWORD=<your-admin-password> \
RESOURCE_GROUP=rg-nexus-oss \
CONTAINER_GROUP=aci-prod-nexus-oss \
STORAGE_ACCOUNT=<storage-account-name> \
bash scripts/set-nexus-password.sh
```

**Windows (PowerShell)**
```powershell
.\scripts\set-nexus-password.ps1 `
  -NewPassword    "<your-admin-password>" `
  -ResourceGroup  "rg-nexus-oss" `
  -ContainerGroup "aci-prod-nexus-oss" `
  -StorageAccount "<storage-account-name>"
```

If Phase 2 fails to authenticate, confirm `admin_password` in `nexus/terraform.tfvars` and re-run. If the state is unknown, exec into the container:

```bash
az container exec \
  --resource-group rg-nexus-oss \
  --name aci-prod-nexus-oss \
  --container-name nexus \
  --exec-command "ls /nexus-data/admin.password 2>/dev/null && cat /nexus-data/admin.password || echo 'no password file — default admin123 is active'"
```

---

## Upgrading Nexus

### Why upgrade

Sonatype publishes new Nexus 3 releases roughly monthly. Reasons to upgrade:
- **Security patches** — CVEs in Nexus itself or its bundled Java/JVM components
- **Bug fixes** — routing rule edge cases, provider API changes that affect the `datadrivers/nexus` Terraform provider
- **New features** — new repo formats, improved REST API coverage

Always check the [Nexus 3 release notes](https://help.sonatype.com/en/sonatype-nexus-repository-release-notes.html) before upgrading — major version jumps (e.g. 3.x → 3.y where y is a new LTS line) sometimes rename REST endpoints.

### Impact

| What changes | Impact |
|---|---|
| ACI container replaced | **~3–5 minutes downtime** — pip installs fail during this window |
| DB migration (automatic on first boot) | Additional **1–10 minutes** for large version jumps; Nexus logs show progress |
| Azure Files share | **Not touched** — all cached packages, blobs, and OrientDB/H2 data survive |
| Nexus configuration | **Not touched** — repos, routing rules, roles, and users are stored in the data volume |

Schedule upgrades during a maintenance window. pip clients will get connection errors until Nexus restarts and the liveness probe passes.

### Steps

1. **Check release notes** for breaking changes or required configuration updates.

2. **Update the image tag** in `infra/variables.tf`:
   ```hcl
   nexus_image = "sonatype/nexus3:3.X.Y"
   ```

3. **Apply the infra change** — ACI tears down and recreates the container:

   **macOS / Linux**
   ```bash
   cd infra && terraform apply
   ```
   **Windows (PowerShell)**
   ```powershell
   cd infra; terraform apply
   ```

   Terraform will show the container group as `forces replacement`. The Azure Files share is not in this plan and is not affected.

4. **Wait for Nexus to start** — the `time_sleep.nexus_ready` resource waits 2 minutes. Nexus DB migrations run during this time. For major version bumps, check the container logs until you see `Started Sonatype Nexus`:
   ```bash
   az container logs --resource-group rg-nexus-oss --name aci-prod-nexus-oss --container-name nexus --follow
   ```

5. **Verify with the smoke test**:
   ```powershell
   .\scripts\smoke-test.ps1
   ```

6. **Re-apply nexus/ if needed** — usually not required, but run it if Phase 2 configuration drifted or if the release notes mention REST API changes:
   ```powershell
   cd nexus; terraform apply
   ```

### Staying notified of new versions

Both container images are hosted on GitHub. The simplest way to receive release notifications is to watch the GitHub repositories:

1. Go to each repository and click **Watch → Custom → Releases** (untick everything else to avoid noise):
   - Nexus OSS: [github.com/sonatype/nexus-public](https://github.com/sonatype/nexus-public)
   - cloudflared: [github.com/cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)

   GitHub will send an email for each new release. Nexus publishes roughly monthly; cloudflared publishes roughly weekly.

2. **RSS / Atom feeds** — if you prefer a feed reader instead of email:

   | Image | Feed URL |
   |-------|----------|
   | sonatype/nexus3 | `https://github.com/sonatype/nexus-public/releases.atom` |
   | cloudflare/cloudflared | `https://github.com/cloudflare/cloudflared/releases.atom` |

3. **Renovate** (automated PRs) — [Renovate Bot](https://github.com/renovatebot/renovate) can detect Docker image versions inside Terraform variable defaults and open a PR automatically when a new tag is published. Install it from the GitHub Marketplace and add a `renovate.json` at the repo root:

   ```json
   {
     "extends": ["config:recommended"],
     "terraform": { "enabled": true }
   }
   ```

   Renovate will find `nexus_image` and `cloudflared_image` in `infra/variables.tf` and raise a PR for each new release, including a changelog link. This is the lowest-overhead option for keeping versions current.

### Rollback

If the new version has a startup failure, revert the tag in `infra/variables.tf` to the previous version and re-apply. The data volume is compatible — Nexus does not write a migration flag that prevents downgrading within a minor version series.

> **Downgrading across a major version boundary** (e.g. 3.y → 3.x where the DB schema changed) is not supported by Sonatype and may corrupt the data volume. Always snapshot the Azure Files share before a major upgrade:
> ```bash
> az storage share snapshot --account-name <storage-account-name> --name nexus-data
> ```

---

## Teardown

```bash
# Optional: snapshot the file share first (preserves all cached packages)
az storage share snapshot \
  --account-name <storage-account-name> \
  --name nexus-data

# Remove the anonymous user from state before destroying — Nexus hard-blocks
# deletion of this built-in account and terraform destroy will fail without this.
cd nexus && terraform state rm nexus_security_user.anonymous

# Destroy Phase 2 (removes Nexus config from state)
terraform destroy

# Then destroy Phase 1 (removes Azure infrastructure)
cd ../infra && terraform destroy
```

> ⚠️ `terraform destroy` in `infra/` deletes the resource group and **all** contents, including the Azure Files share and every cached package.

The remote state backend (`rg-nexus-tf-state`) is managed separately and is **not** destroyed. Delete it manually if no longer needed:

```bash
az group delete --name rg-nexus-tf-state
```

---

## Cost estimate (uksouth, 2025)

| Resource | SKU | Est. monthly |
|----------|-----|--------------|
| ACI — 2 vCPU / 4 GB | Standard | ~£55 |
| Storage — 100 GB LRS | Standard | ~£2 |
| **Total** | | **~£57/mo** |

---

## File layout

```
.
├── infra/                         Phase 1 — Azure infrastructure
│   ├── providers.tf               azurerm / null / random / time / http
│   ├── variables.tf               All inputs (location, sizing, container images, networking, Cloudflare tunnel, etc.)
│   ├── locals.tf                  URLs, JVM sizing
│   ├── main.tf                    Resource Group + random suffix
│   ├── storage.tf                 Storage Account + nexus-data File Share
│   ├── network.tf                 VNet + ACI subnet + NSG
│   ├── container.tf               ACI Container Group + time_sleep.nexus_ready (2 min)
│   ├── outputs.tf                 nexus_base_url, nexus_private_url, pip URLs, snippets
│   ├── terraform.tfvars.example
│   ├── backend.hcl.example        key = infra.tfstate
│   └── .terraform.lock.hcl
│
├── nexus/                         Phase 2 — Nexus configuration (datadrivers/nexus provider)
│   ├── providers.tf               datadrivers/nexus >= 2.0.0; URL from infra remote state
│   ├── variables.tf               admin_password, state_storage_account,
│   │                                pypi_allowlist (7 categories), r_allowlist (5 categories)
│   ├── main.tf                    null_resource: password bootstrap via set-nexus-password script
│   │                                nexus_security_anonymous
│   │                                pypi-allowlist routing rule (loop-generated matchers)
│   │                                pypi-hosted / pypi-pypi.org proxy / pypi-group
│   │                                r-cran-allowlist routing rule (loop-generated matchers)
│   │                                r-hosted / r-cran.r-project.org proxy / r-group
│   │                                4 roles + anonymous user locked to reader roles
│   ├── terraform.tfvars.example
│   ├── backend.hcl.example        key = nexus.tfstate
│   └── .terraform.lock.hcl
│
├── scripts/
│   ├── create-backend.sh          Bash: provision remote state storage + write backend.hcl
│   ├── create-backend.ps1         PowerShell: same as above for Windows
│   ├── set-nexus-password.sh      Bash: accept EULA + change admin password via az container exec
│   ├── set-nexus-password.ps1     PowerShell: same as above for Windows
│   ├── smoke-test.sh              Bash: Phase 1+2 smoke test (PyPI, CRAN)
│   ├── smoke-test.ps1             PowerShell: same as above for Windows
│   ├── smoke-test-phase2.sh       Bash: comprehensive Phase 2 validation (auth, repos, routing rules, pip client)
│   └── smoke-test-phase2.ps1      PowerShell: same as above for Windows
└── .github/
    └── workflows/
        └── ci.yml                 fmt / validate / TFLint / Trivy for infra/ and nexus/
                                     (apply is manual only)
```
