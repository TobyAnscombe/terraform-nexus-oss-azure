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
| curl + jq | `brew install jq` |

`curl` and `jq` must be present on the machine running `terraform apply`
(the bootstrap script uses them to configure Nexus over HTTP).

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

Both scripts create the storage account, blob container, and write `backend.hcl` in the repo root.

`backend.hcl` is git-ignored — it contains deployment-specific values and is regenerated locally by each team member. See [backend.hcl.example](backend.hcl.example) for the format.

---

## Deploy

### Option A — Public (internet-accessible, default)

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set admin_password; leave vnet_integrated = false

terraform init -backend-config=backend.hcl
terraform apply
```

### Option B — Managed private VNet

```bash
cp terraform.tfvars.example terraform.tfvars
# set admin_password, vnet_integrated = true, nsg_inbound_source = "<your-cidr>"
# run terraform apply from a machine on the VPN / ExpressRoute

terraform init -backend-config=backend.hcl
terraform apply
```

### Option C — Existing subnet

```bash
cp terraform.tfvars.example terraform.tfvars
# set admin_password
# set existing_subnet_id = "/subscriptions/.../subnets/<name>"
# (vnet_integrated and nsg_inbound_source are ignored)
# run terraform apply from a machine that can reach the subnet's private IP

terraform init -backend-config=backend.hcl
terraform apply
```

**Total time: ~6–8 minutes** (Nexus initialises its database on first boot).

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

2. **NSG rule** — inbound TCP 8081 from the sources that need to reach Nexus (pip clients, CI runners, etc.). This module does **not** create or modify NSGs on existing subnets.

3. **Reachability** — `terraform apply` must run from a machine that can reach the private IP, so the bootstrap script can configure Nexus over HTTP.

---

## Live deployment details

| Resource | Value |
|----------|-------|
| Web UI | http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081 |
| pip index URL | http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/ |
| pip upload URL | http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-hosted/ |
| R repo URL | http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/r-group/ |
| IP address | 4.250.120.71 |
| Resource group | rg-nexus-oss |
| Storage account | stnexusprod3g1xti |
| Azure region | UK South |

---

## Configuring pip

### Option 1 — Global (all projects on this machine)

```bash
mkdir -p ~/.pip && cat > ~/.pip/pip.conf << 'EOF'
[global]
index-url  = http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/
trusted-host = nexus-oss-3g1xti.uksouth.azurecontainer.io
EOF
```

### Option 2 — Per virtualenv

```bash
cat > .venv/pip.conf << 'EOF'
[global]
index-url  = http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/
trusted-host = nexus-oss-3g1xti.uksouth.azurecontainer.io
EOF
```

> **Why `trusted-host`?** The repo runs on plain HTTP. pip refuses unencrypted connections by default — `trusted-host` marks this host as safe. Remove it if you add TLS later.

---

## Configuring R

### Option 1 — Persistent (all sessions for this user)

Add to `~/.Rprofile` (or `Rprofile.site` for system-wide):

```r
options(repos = c(
  NEXUS = "http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/r-group/",
  CRAN  = "@CRAN@"
))
```

The `CRAN = "@CRAN@"` fallback is kept so RStudio's mirror selector still works for any package not yet in the allowlist.

### Option 2 — Per session

```r
options(repos = c(NEXUS = "http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/r-group/"))
install.packages("dplyr")
```

### Option 3 — renv projects

In `.Rprofile` at the project root (renv will pick this up):

```r
options(repos = c(NEXUS = "http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/r-group/"))
```

> **RStudio note:** Once `options(repos)` points at Nexus, RStudio's *Packages → Install* panel uses Nexus automatically — no further IDE configuration is needed.

---

## Testing the deployment

### Python — install and cache-hit test

```bash
# First install — Nexus fetches from PyPI and caches
python -m venv .venv && .venv/bin/pip install pandas \
  --index-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/ \
  --trusted-host nexus-oss-3g1xti.uksouth.azurecontainer.io

# Second install — hits the Nexus cache, noticeably faster
.venv/bin/pip install pandas \
  --index-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/ \
  --trusted-host nexus-oss-3g1xti.uksouth.azurecontainer.io
```

### Python — verify the allowlist blocks unlisted packages

```bash
.venv/bin/pip install flask \
  --index-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/ \
  --trusted-host nexus-oss-3g1xti.uksouth.azurecontainer.io
# Expected: ERROR: Could not find a version that satisfies the requirement flask
```

### R — install and cache-hit test

```r
options(repos = c(NEXUS = "http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/r-group/"))

# First install — Nexus fetches from CRAN and caches
install.packages("dplyr")

# Second install — hits the Nexus cache
install.packages("dplyr")
```

### R — verify the allowlist blocks unlisted packages

```r
install.packages("shiny")
# Expected: Warning: unable to access index for repository ...
#           package 'shiny' is not available
```

### Browse via the web UI

1. Go to http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081
2. Click **Browse** in the left sidebar.
3. Open **pypi-group** or **r-group** to see available packages.
4. Open the proxy repo (`pypi-pypi.org` or `r-cran.r-project.org`) to see what has been fetched and cached so far.

---

## Package allowlist

Routing rules (`pypi-allowlist`, `r-cran-allowlist`) control which packages each proxy will fetch.
Packages uploaded to the hosted repos (`pypi-hosted`, `r-hosted`) are always available regardless of the allowlist.

### Python allowlist (`bootstrap.tf` → `pypi-allowlist`)

| Category | Packages |
|----------|---------|
| **Toolchain** | pip, setuptools, wheel, twine, build, poetry, pytest |
| **Core data** | numpy, pandas, scipy, polars, pyarrow |
| **Distributed** | dask, pyspark |
| **Visualisation** | matplotlib, seaborn, plotly, bokeh, altair, kaleido, missingno |
| **ML / Stats** | scikit-learn, xgboost, lightgbm, statsmodels, lifelines, pingouin |
| **MLOps** | mlflow |
| **Explainability** | shap, lime, eli5 |
| **Data quality** | pandera, great-expectations |
| **I/O & storage** | openpyxl, xlrd, xlsxwriter, fastparquet, sqlalchemy, psycopg2-binary, pymysql, pyodbc |
| **Jupyter** | jupyter, jupyterlab, ipython, ipykernel, notebook, nbformat, nbconvert, ipywidgets, widgetsnbextension |
| **Runtime utilities** | joblib, numba, tqdm, requests, httpx, aiohttp, python-dateutil, pytz, tzdata, six, certifi, charset-normalizer, idna, urllib3, packaging, click, pydantic, pydantic-core, typing-extensions, attrs, annotated-types |

### R allowlist (`bootstrap.tf` → `r-cran-allowlist`)

| Category | Packages |
|----------|---------|
| **Toolchain** | rlang, vctrs, lifecycle, cli, glue, magrittr, generics, R6, Rcpp, withr, pkgconfig, ellipsis |
| **Tidyverse plumbing** | tibble, purrr, readr, forcats, hms, vroom, tidyselect, pillar, fansi, utf8, crayon, bit64, bit |
| **Data wrangling** | tidyverse, dplyr, tidyr, stringr, stringi, data.table, lubridate, broom, modelr |
| **I/O & formats** | haven, readxl, openxlsx, rio, foreign, cellranger, zip, jsonlite, curl, httr |
| **Visualisation** | ggplot2, scales, gtable, isoband, farver, labeling, munsell, RColorBrewer, viridisLite, colorspace, MASS |
| **String matching** | fuzzyjoin, stringdist |

> **Tidyverse note:** `tidyverse` is a meta-package that installs ~30 sub-packages. The tidyverse plumbing row covers the transitive dependencies most likely to be pulled. If an install fails with a 404 on an unlisted dependency, add it and re-apply (see below).

### Adding a new Python package

1. Open `bootstrap.tf`, find the `nexus_upsert_routing_rule "pypi-allowlist"` call.
2. Add two matchers for the new package:

   ```
   "^/simple/your-package(/.*)?$",  "^/packages/your-package(/.*)?$",
   ```

3. Bump `allowlist_version` in the `triggers` block (e.g. `"6"` → `"7"`).
4. Run `terraform apply` — the routing rule updates in-place, no infrastructure changes.

> **Name normalisation:** PyPI normalises names to lowercase with hyphens. Use `scikit-learn` not `scikit_learn`.

### Adding a new R package

1. Open `bootstrap.tf`, find the `nexus_upsert_routing_rule "r-cran-allowlist"` call.
2. Add three matchers for the new package (source tarball + Windows binary + macOS binary):

   ```
   "^/src/contrib/your-package_",
   "^/bin/windows/contrib/[^/]+/your-package_",
   "^/bin/macosx/[^/]+/contrib/[^/]+/your-package_"
   ```

   If the package name contains a `.` (e.g. `data.table`), escape it as `data\.table` in the regex.

3. Bump `allowlist_version` in the `triggers` block and run `terraform apply`.

---

## Uploading packages to the hosted repos

### Python — push to pypi-hosted

```bash
# Download from PyPI
pip download requests --no-deps -d /tmp/nx-upload/

# Push to Nexus
twine upload \
  --repository-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-hosted/ \
  -u admin -p 'YOUR_PASSWORD' \
  /tmp/nx-upload/*
rm -rf /tmp/nx-upload
```

Or build and publish your own package:

```bash
python -m build
twine upload \
  --repository-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-hosted/ \
  -u YOUR_USER -p YOUR_PASSWORD \
  dist/*
```

### R — push to r-hosted

Use the **web UI**: log in → **Browse → r-hosted → Upload component**, then select the `.tar.gz` source package or binary.

Or use the Nexus REST API:

```bash
curl -u admin:YOUR_PASSWORD \
  -F "r.asset=@/path/to/package_1.0.0.tar.gz;type=application/octet-stream" \
  http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/service/rest/v1/components?repository=r-hosted
```

---

## Creating user accounts

1. Log in to http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081 as `admin`.
2. **Administration → Security → Users → Create local user**.
3. Assign roles as appropriate:

   | Role | Access |
   |------|--------|
   | `pypi-anonymous-reader` | Browse + install Python packages from pypi-group |
   | `pypi-authenticated-deployer` | Above + upload to pypi-hosted |
   | `r-anonymous-reader` | Browse + install R packages from r-group |
   | `r-authenticated-deployer` | Above + upload to r-hosted |

---

## Supply-chain risk mitigations

| Risk | Mitigation in place |
|------|-------------------|
| Typosquatting | Allowlist — only approved package names served by the proxies |
| Dependency confusion | Hosted repos checked before proxies; internal packages win on name conflict |
| Compromised package version | Pin exact versions; use `pip-compile --generate-hashes` for Python |
| Known CVEs | Run `pip-audit -r requirements.txt` in CI (not enforced by Nexus OSS) |
| PyPI / CRAN outage | Nexus caches every download — previously-fetched packages remain available |

### Scanning Python dependencies for CVEs

```bash
pip install pip-audit
pip-audit -r requirements.txt
```

### Hash-pinning Python requirements (strongest protection)

```bash
pip install pip-tools
pip-compile --generate-hashes requirements.in   # produces requirements.txt with SHA-256 hashes
pip install --require-hashes -r requirements.txt  # fails if any file is tampered with
```

---

## Troubleshooting

### pip / install.packages returns 404 for a package

The package is not on the allowlist. Either:
- Add it to the allowlist in `bootstrap.tf` and `terraform apply`, **or**
- Upload it directly to the hosted repo via the web UI or API.

### Python package on the allowlist still returns 404

The routing rule requires two matchers per package (`/simple/` and `/packages/`). Check that both are present in `bootstrap.tf`.

### R package on the allowlist still fails to install

The routing rule requires three matchers per package (source + Windows binary + macOS binary paths). Check all three are present. Also verify that dot characters in the package name are escaped as `\.` in the regex.

### Container logs

```bash
az container logs \
  --resource-group rg-nexus-oss \
  --name aci-prod-nexus-oss \
  --container-name nexus
```

### Bootstrap can't authenticate

Because `NEXUS_SECURITY_RANDOMPASSWORD=false` is set, Nexus starts with the fixed default password `admin123`. The bootstrap immediately replaces that with `var.admin_password`.

If the bootstrap can't authenticate, the most likely cause is a partial previous run where the password was already changed to something other than `var.admin_password`. Fix:

1. Confirm the password in `terraform.tfvars` is correct and run `terraform apply` again — the bootstrap is idempotent.
2. If the state is unknown, exec into the container:

```bash
az container exec \
  --resource-group rg-nexus-oss \
  --name aci-prod-nexus-oss \
  --container-name nexus \
  --exec-command "ls /nexus-data/admin.password 2>/dev/null && cat /nexus-data/admin.password || echo 'no password file — default admin123 is active'"
```

   - File absent → Nexus is using `admin123`. Set `admin_password = "admin123"` in tfvars, apply to let bootstrap set your real password, then restore and apply again.
   - File present → use the file contents as `admin_password` and apply.

### Re-run bootstrap without replacing infrastructure

Bump `allowlist_version` in the `bootstrap.tf` triggers block and run `terraform apply`.
The bootstrap script is fully idempotent — safe to re-run at any time.

---

## Upgrading Nexus

1. Check the [Nexus 3 release notes](https://help.sonatype.com/en/sonatype-nexus-repository-release-notes.html) for breaking changes.
2. In [container.tf](container.tf), update the image tag:
   ```hcl
   image = "sonatype/nexus3:3.X.Y"
   ```
3. Run `terraform apply` — ACI replaces the container, Nexus runs any DB migrations on first boot.
4. The bootstrap only re-runs if `admin_password_sha256` or `allowlist_version` changed, so existing repos and roles are untouched.

> The Azure Files share holds all persistent data and survives container replacement.

---

## Teardown

```bash
# Optional: snapshot the file share first (preserves all cached packages)
az storage share snapshot \
  --account-name <storage-account-name> \
  --name nexus-data

# Destroy all resources
terraform destroy
```

> ⚠️ `terraform destroy` deletes the resource group and **all** contents, including the Azure Files share and every cached package. Take a snapshot (above) if you may need to recover.

The remote state backend (`rg-nexus-tf-state`) is managed separately and is **not** destroyed by `terraform destroy`. Delete it manually if no longer needed:

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
├── providers.tf               azurerm / null / random / time
├── variables.tf               All inputs (including existing_subnet_id)
├── locals.tf                  URLs, JVM sizing, use_vnet flag
├── main.tf                    Resource Group + random suffix
├── storage.tf                 Storage Account + nexus-data File Share
├── network.tf                 VNet + ACI subnet + NSG (conditional on existing_subnet_id)
├── container.tf               ACI Container Group (single Nexus container)
├── bootstrap.tf               Waits for startup, configures Nexus via REST API
│                                Python stack:
│                                  pypi-allowlist routing rule
│                                  pypi-hosted / pypi-pypi.org proxy / pypi-group
│                                  pypi-proxy-cleanup policy (90-day)
│                                  pypi-anonymous-reader / pypi-authenticated-deployer roles
│                                R stack:
│                                  r-cran-allowlist routing rule
│                                  r-hosted / r-cran.r-project.org proxy / r-group
│                                  r-proxy-cleanup policy (90-day)
│                                  r-anonymous-reader / r-authenticated-deployer roles
│                                  anonymous user locked to both reader roles
├── outputs.tf                 pip URLs, twine command, pip.conf snippets, NSG rule output
├── terraform.tfvars.example
├── backend.hcl.example        Template for backend.hcl (git-ignored)
├── scripts/
│   ├── create-backend.sh      Bash: provision remote state storage + write backend.hcl
│   └── create-backend.ps1     PowerShell: same as above for Windows
└── .github/
    └── workflows/
        └── ci.yml             CI: calls reusable terraform-ci.yml from TobyAnscombe/github-actions
                                   (terraform fmt/validate, TFLint, Trivy security scan)
```
