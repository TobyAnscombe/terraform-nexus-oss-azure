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

---

## Prerequisites

| Tool | Notes |
|------|-------|
| Terraform ≥ 1.5 | `brew install terraform` |
| Azure CLI | `brew install azure-cli` |

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

```bash
sed 's/nexus-oss.terraform.tfstate/infra.tfstate/' backend.hcl > infra/backend.hcl
sed 's/nexus-oss.terraform.tfstate/nexus.tfstate/'  backend.hcl > nexus/backend.hcl
```

`backend.hcl` is git-ignored. See [infra/backend.hcl.example](infra/backend.hcl.example) and [nexus/backend.hcl.example](nexus/backend.hcl.example) for the format.

---

## Deploy

### Phase 1 — Infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars as needed

terraform init --backend-config=backend.hcl
terraform apply
```

**Total time: ~5–7 minutes** (includes a 2-minute startup wait for Nexus).

### Phase 2 — Nexus configuration

```bash
cd nexus
cp terraform.tfvars.example terraform.tfvars
# set admin_password and state_storage_account

terraform init --backend-config=backend.hcl
```

Nexus ships with a built-in `anonymous` user that must be imported into state before the first apply, otherwise Terraform will try to create it and fail with a duplicate-user error:

```bash
terraform import nexus_security_user.anonymous anonymous
terraform apply
```

Phase 2 reads the Nexus URL from Phase 1's remote state and changes the admin password from the Nexus default (`admin123`) to the value set in `admin_password`. Run Phase 1 fully before Phase 2.

### Option B — Managed private VNet

```bash
# In infra/terraform.tfvars:
# set vnet_integrated = true, nsg_inbound_source = "<your-cidr>"
# run terraform apply from a machine on the VPN / ExpressRoute

cd infra && terraform apply
# Phase 2 must also run from a machine that can reach the private IP:
cd nexus && terraform apply
```

### Option C — Existing subnet

```bash
# In infra/terraform.tfvars:
# set existing_subnet_id = "/subscriptions/.../subnets/<name>"

cd infra && terraform apply
cd nexus && terraform apply
```

---

## Networking modes

| Mode | `existing_subnet_id` | `vnet_integrated` | ACI access | Managed VNet |
|------|----------------------|-------------------|------------|--------------|
| Public | `null` | `false` | Public IP + DNS label | Created (unused) |
| Managed private | `null` | `true` | Private IP in snet-aci | Created and used |
| Existing subnet | `<resource-id>` | ignored | Private IP in your subnet | **Not created** |

### Existing subnet prerequisites

Before setting `existing_subnet_id`, ensure the target subnet has:

1. **Delegation** — `Microsoft.ContainerInstance/containerGroups`

   ```bash
   az network vnet subnet update \
     --resource-group <rg> --vnet-name <vnet> --name <subnet> \
     --delegations Microsoft.ContainerInstance/containerGroups
   ```

2. **NSG rule** — inbound TCP 80 from the sources that need to reach Nexus (pip clients, CI runners, etc.). This module does **not** create or modify NSGs on existing subnets.

3. **Reachability** — `terraform apply` (Phase 2) must run from a machine that can reach the private IP.

---

## Live deployment details

| Resource | Value |
|----------|-------|
| Web UI | http://nexus-oss-3g1xti.uksouth.azurecontainer.io |
| pip index URL | http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/pypi-group/simple/ |
| pip upload URL | http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/pypi-hosted/ |
| R repo URL | http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/r-group/ |
| IP address | 4.250.120.71 |
| Resource group | rg-nexus-oss |
| Storage account | stnexusprod3g1xti |
| Azure region | UK South |

---

## Configuring pip

### Option 1 — Global (all projects on this machine)

```ini
# ~/.pip/pip.conf  (macOS/Linux)
# %APPDATA%\pip\pip.ini  (Windows)
[global]
index-url  = http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/pypi-group/simple/
trusted-host = nexus-oss-3g1xti.uksouth.azurecontainer.io
```

### Option 2 — Per virtualenv

```ini
# .venv/pip.conf
[global]
index-url  = http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/pypi-group/simple/
trusted-host = nexus-oss-3g1xti.uksouth.azurecontainer.io
```

> **Why `trusted-host`?** The repo runs on plain HTTP. pip refuses unencrypted connections by default — `trusted-host` marks this host as safe. Remove it if you add TLS later.

---

## Configuring R

### Option 1 — Persistent (all sessions for this user)

Add to `~/.Rprofile` (or `Rprofile.site` for system-wide):

```r
options(repos = c(
  NEXUS = "http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/r-group/",
  CRAN  = "@CRAN@"
))
```

The `CRAN = "@CRAN@"` fallback is kept so RStudio's mirror selector still works for any package not yet in the allowlist.

### Option 2 — Per session

```r
options(repos = c(NEXUS = "http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/r-group/"))
install.packages("dplyr")
```

### Option 3 — renv projects

In `.Rprofile` at the project root (renv will pick this up):

```r
options(repos = c(NEXUS = "http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/r-group/"))
```

> **RStudio note:** Once `options(repos)` points at Nexus, RStudio's *Packages → Install* panel uses Nexus automatically — no further IDE configuration is needed.

---

## Testing the deployment

### Python — install and cache-hit test

```bash
# First install — Nexus fetches from PyPI and caches
pip install pandas \
  --index-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/pypi-group/simple/ \
  --trusted-host nexus-oss-3g1xti.uksouth.azurecontainer.io
```

### Python — verify the allowlist blocks unlisted packages

```bash
pip install flask \
  --index-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/pypi-group/simple/ \
  --trusted-host nexus-oss-3g1xti.uksouth.azurecontainer.io
# Expected: ERROR: Could not find a version that satisfies the requirement flask
```

### R — install and cache-hit test

```r
options(repos = c(NEXUS = "http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/r-group/"))
install.packages("dplyr")
```

### R — verify the allowlist blocks unlisted packages

```r
install.packages("shiny")
# Expected: Warning: unable to access index for repository ...
#           package 'shiny' is not available
```

### Browse via the web UI

1. Go to http://nexus-oss-3g1xti.uksouth.azurecontainer.io
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
  --repository-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/pypi-hosted/ \
  -u admin -p 'YOUR_PASSWORD' \
  /tmp/nx-upload/*
rm -rf /tmp/nx-upload
```

Or build and publish your own package:

```bash
python -m build
twine upload \
  --repository-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io/repository/pypi-hosted/ \
  -u YOUR_USER -p YOUR_PASSWORD \
  dist/*
```

### R — push to r-hosted

Use the **web UI**: log in → **Browse → r-hosted → Upload component**, then select the `.tar.gz` source package or binary.

---

## Creating user accounts

1. Log in to http://nexus-oss-3g1xti.uksouth.azurecontainer.io as `admin`.
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

### Container logs

```bash
az container logs \
  --resource-group rg-nexus-oss \
  --name aci-prod-nexus-oss \
  --container-name nexus
```

### Nexus admin password

Because `NEXUS_SECURITY_RANDOMPASSWORD=false` is set, Nexus starts with the fixed default password `admin123`. Phase 2 (`nexus/`) sets the real password via the `admin_password` variable.

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

1. Check the [Nexus 3 release notes](https://help.sonatype.com/en/sonatype-nexus-repository-release-notes.html) for breaking changes.
2. In [infra/container.tf](infra/container.tf), update the image tag:
   ```hcl
   image = "sonatype/nexus3:3.X.Y"
   ```
3. Run `terraform apply` from `infra/` — ACI replaces the container; Nexus runs DB migrations on first boot.
4. Re-run `terraform apply` from `nexus/` if any provider-managed configuration needs to be reconfirmed.

> The Azure Files share holds all persistent data and survives container replacement.

---

## Teardown

```bash
# Optional: snapshot the file share first (preserves all cached packages)
az storage share snapshot \
  --account-name <storage-account-name> \
  --name nexus-data

# Destroy Phase 2 first (removes Nexus config from state)
cd nexus && terraform destroy

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
│   ├── providers.tf               azurerm / null / random / time
│   ├── variables.tf               All inputs (location, sizing, networking, etc.)
│   ├── locals.tf                  URLs, JVM sizing, use_vnet flag
│   ├── main.tf                    Resource Group + random suffix
│   ├── storage.tf                 Storage Account + nexus-data File Share
│   ├── network.tf                 VNet + ACI subnet + NSG (conditional)
│   ├── container.tf               ACI Container Group + time_sleep.nexus_ready (2 min)
│   ├── outputs.tf                 nexus_base_url (gated on time_sleep), pip URLs, snippets
│   ├── terraform.tfvars.example
│   ├── backend.hcl.example        key = infra.tfstate
│   └── .terraform.lock.hcl
│
├── nexus/                         Phase 2 — Nexus configuration (datadrivers/nexus provider)
│   ├── providers.tf               datadrivers/nexus >= 2.0.0; URL from infra remote state
│   ├── variables.tf               admin_password, state_storage_account,
│   │                                pypi_allowlist (7 categories), r_allowlist (5 categories)
│   ├── main.tf                    nexus_security_anonymous
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
│   └── create-backend.ps1         PowerShell: same as above for Windows
└── .github/
    └── workflows/
        └── ci.yml                 infra (CI) → infra-apply → nexus-config (CI) → nexus-config-apply
                                     (apply jobs run on main branch pushes only)
```
