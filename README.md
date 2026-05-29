# Nexus OSS — Azure Container Instance (Terraform)

A hosted Python package repository in Azure UK South with three tiers:

| Who | Can do |
|-----|--------|
| **Anonymous** (no credentials) | Browse and install allowlisted packages (proxied from PyPI) and anything an admin has uploaded |
| **Authenticated** (with credentials) | Everything above + upload new packages to the hosted repo |
| **Admin** | Full Nexus UI access, manage users, roles, and the package allowlist |

One URL for everything: `http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/`

---

## Architecture

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
                              │
                    ┌─────────▼─────────┐
                    │  PyPI / PyPI CDN  │
                    └───────────────────┘
                              │ cached in
                    ┌─────────▼─────────┐
                    │  Azure Files      │
                    │  nexus-data share │
                    └───────────────────┘
```

**Why this layout?**

- `pypi-hosted` is checked first, so internal packages shadow any same-named PyPI package (prevents dependency-confusion attacks).
- The routing rule on `pypi-pypi.org` enforces the package allowlist — only pre-approved packages are ever fetched from the internet.
- Cached packages remain available even if PyPI is down.

---

## Prerequisites

| Tool | Notes |
|------|-------|
| Terraform ≥ 1.5 | `brew install terraform` |
| Azure CLI | `brew install azure-cli` |
| curl + jq | `brew install jq` |

`curl` and `jq` must be present on the machine running `terraform apply`
(the bootstrap script uses them to configure Nexus over HTTP).
The bootstrap runs under `/bin/bash` (the system shell); no third-party bash is required.

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

3. **Reachability** — `terraform apply` must run from a machine that can reach the private IP (on the VPN or in the VNet), so the bootstrap script can configure Nexus over HTTP.

---

## Live deployment details

| Resource | Value |
|----------|-------|
| Web UI | http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081 |
| pip index URL | http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/ |
| Upload URL | http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-hosted/ |
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

Verify:

```bash
pip config list
# global.index-url='http://nexus-oss-3g1xti...'
# global.trusted-host='nexus-oss-3g1xti...'
```

### Option 2 — Per virtualenv

```bash
cat > .venv/pip.conf << 'EOF'
[global]
index-url  = http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/
trusted-host = nexus-oss-3g1xti.uksouth.azurecontainer.io
EOF
```

> **Why `trusted-host`?** The repo runs on plain HTTP. pip refuses unencrypted connections by default — `trusted-host` marks this specific host as safe. Remove this line if you add TLS later.

---

## Testing the deployment

### 1. Create a virtualenv and install pandas

```bash
python -m venv .venv && \
  .venv/bin/pip install pandas \
    --index-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/ \
    --trusted-host nexus-oss-3g1xti.uksouth.azurecontainer.io
```

Expected output — Nexus fetches pandas and its dependencies from PyPI on first install, then caches them:

```
Collecting pandas
  Downloading http://nexus-oss-3g1xti.../pandas-2.x.x-...whl
Collecting numpy...
...
Successfully installed pandas-2.x.x numpy-... python-dateutil-... pytz-... six-...
```

### 2. Confirm the cache — install again (should be instant)

```bash
.venv/bin/pip install pandas \
  --index-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/ \
  --trusted-host nexus-oss-3g1xti.uksouth.azurecontainer.io
```

Second install hits the Nexus cache — no outbound PyPI traffic, noticeably faster.

### 3. Verify the allowlist is blocking unlisted packages

```bash
.venv/bin/pip install flask \
  --index-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-group/simple/ \
  --trusted-host nexus-oss-3g1xti.uksouth.azurecontainer.io
```

Expected: `ERROR: Could not find a version that satisfies the requirement flask` — flask is not on the allowlist so Nexus returns 404.

### 4. Browse via the web UI

1. Go to http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081
2. Click **Browse** in the left sidebar.
3. Open **pypi-group** — you will see packages from both `pypi-hosted` and `pypi-pypi.org`.
4. Open **pypi-pypi.org** — shows packages Nexus has fetched and cached from PyPI so far.

---

## Package allowlist

The routing rule `pypi-allowlist` controls which packages the proxy will fetch from PyPI.
Packages already uploaded to `pypi-hosted` are always available regardless of the allowlist.

### Allowlisted packages (managed in `bootstrap.tf`)

| Category | Packages |
|----------|---------|
| **Build tools** | pip, setuptools, wheel, twine, build |
| **Core** | numpy, pandas, scipy, polars |
| **Visualisation** | matplotlib, seaborn, plotly, bokeh, altair, kaleido |
| **ML / Stats** | scikit-learn, statsmodels, xgboost, lightgbm |
| **Data I/O** | openpyxl, xlrd, xlsxwriter, pyarrow, fastparquet, sqlalchemy, psycopg2-binary, pymysql, pyodbc |
| **Utilities** | tqdm, joblib, numba, dask, requests, httpx, aiohttp, python-dateutil, pytz, tzdata, six, certifi, charset-normalizer, idna, urllib3, packaging, click, pydantic, pydantic-core, typing-extensions, attrs, annotated-types |
| **Jupyter** | jupyter, jupyterlab, ipython, ipykernel, notebook, nbformat, nbconvert, ipywidgets, widgetsnbextension |
| **Data quality** | pandera |

### Adding a new package to the allowlist

1. Open `bootstrap.tf`.
2. In the `nexus_upsert_routing_rule` call, add two lines for the new package (one for the index, one for the file download):

```
"^/simple/your-package-name(/.*)?$",  "^/packages/your-package-name(/.*)?$",
```

3. Bump `allowlist_version` in the `triggers` block (e.g. `"3"` → `"4"`).
4. Run `terraform apply` — the routing rule updates in-place, no infrastructure changes.

> **Package name normalisation:** PyPI normalises names to lowercase with hyphens. Use `scikit-learn` not `scikit_learn`, `psycopg2-binary` not `psycopg2_binary`.

---

## Uploading packages to the hosted repo

Any user with the `pypi-authenticated-deployer` role (or admin) can publish packages.
Once uploaded, the package is immediately available to all users including anonymous.

### Option 1 — Grab from PyPI and push to Nexus (most common)

```bash
# Download from PyPI
pip download requests --no-deps -d /tmp/nx-upload/

# Push to Nexus
twine upload \
  --repository-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-hosted/ \
  -u admin -p 'YOUR_PASSWORD' \
  /tmp/nx-upload/*

# Clean up
rm -rf /tmp/nx-upload
```

### Option 2 — Web UI upload

1. Log in to http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081 as `admin`.
2. Click **Upload** in the left sidebar (or **Browse → pypi-hosted → Upload component**).
3. Select the `.whl` or `.tar.gz` and click **Upload**.

### Option 3 — Publish a package you built yourself

```bash
# Build
python -m build

# Publish
twine upload \
  --repository-url http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081/repository/pypi-hosted/ \
  -u YOUR_USER -p YOUR_PASSWORD \
  dist/*
```

---

## Creating user accounts

1. Log in to http://nexus-oss-3g1xti.uksouth.azurecontainer.io:8081 as `admin`.
2. **Administration → Security → Users → Create local user**.
3. Assign the `pypi-authenticated-deployer` role for read + upload access.
4. Leave without a role for anonymous (read-only) access.

---

## Supply-chain risk mitigations

| Risk | Mitigation in place |
|------|-------------------|
| Typosquatting | Allowlist — only approved package names served by the proxy |
| Dependency confusion | `pypi-hosted` is checked before the proxy; internal packages win on name conflict |
| Compromised package version | Pin exact versions in `requirements.txt`; use `pip-compile --generate-hashes` |
| Known CVEs | Run `pip-audit -r requirements.txt` in CI (not enforced by Nexus OSS) |
| PyPI outage | Nexus caches every download — previously-fetched packages remain available |

### Scanning for vulnerabilities with pip-audit

```bash
pip install pip-audit
pip-audit -r requirements.txt
```

Run this in your CI pipeline on every pull request and as a nightly scheduled job.

### Hash-pinning requirements (strongest protection)

```bash
pip install pip-tools
pip-compile --generate-hashes requirements.in   # produces requirements.txt with SHA-256 hashes
pip install --require-hashes -r requirements.txt  # fails if any file is tampered with
```

---

## Troubleshooting

### pip returns 404 for a package

The package is not on the allowlist. Either:
- Add it to the allowlist in `bootstrap.tf` and `terraform apply`, **or**
- Upload it directly to `pypi-hosted` via twine or the web UI.

### pip returns 404 for a package that IS on the allowlist

The routing rule requires two matchers per package (`/simple/` and `/packages/`). Check that both are present in `bootstrap.tf`.

### Container logs

```bash
az container logs \
  --resource-group rg-nexus-oss \
  --name aci-prod-nexus-oss \
  --container-name nexus
```

### Bootstrap can't authenticate

Because `NEXUS_SECURITY_RANDOMPASSWORD=false` is set, Nexus does **not** write a random
`/nexus-data/admin.password` file on first boot — it starts with the fixed default password
`admin123`. The bootstrap immediately replaces that with `var.admin_password`.

If the bootstrap can't authenticate, the most likely cause is a partial previous run where
the password was already changed to something different from `var.admin_password`. Fix:

1. Confirm the password currently set in `terraform.tfvars` is correct and run `terraform apply`
   again — the bootstrap is idempotent and will detect the right credentials.
2. If the container was manually reset or the state is unknown, exec into the container to
   check whether the password file exists:

```bash
az container exec \
  --resource-group rg-nexus-oss \
  --name aci-prod-nexus-oss \
  --container-name nexus \
  --exec-command "ls /nexus-data/admin.password 2>/dev/null && cat /nexus-data/admin.password || echo 'no password file — default admin123 is active'"
```

   - If the file is absent: Nexus is using `admin123`. Update `admin_password = "admin123"` in
     `terraform.tfvars`, run `terraform apply` to let bootstrap set your real password, then
     restore `admin_password` to your desired value and apply once more.
   - If the file is present: use the file's contents as `admin_password` and apply.

### Re-run bootstrap without replacing infrastructure

Bump `allowlist_version` in `bootstrap.tf` triggers block and run `terraform apply`.
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
# Optional: snapshot the file share first (preserves cached packages)
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
├── variables.tf               All inputs
├── locals.tf                  URLs, JVM sizing
├── main.tf                    Resource Group + random suffix
├── storage.tf                 Storage Account + nexus-data File Share
├── network.tf                 VNet + ACI subnet + NSG (always created; ACI joins when vnet_integrated = true)
├── container.tf               ACI Container Group (single Nexus container)
├── bootstrap.tf               Waits for startup, configures Nexus via REST API
│                                - routing rule (pypi-allowlist)
│                                - pypi-hosted  (local / admin-uploaded packages)
│                                - pypi-pypi.org (proxy to PyPI, allowlist applied)
│                                - pypi-group   (group: hosted + proxy, single URL)
│                                - roles + anonymous user assignment
├── outputs.tf                 pip URLs, twine command, pip.conf snippets
├── terraform.tfvars.example
├── backend.hcl.example        Template for backend.hcl (git-ignored, generated by create-backend)
├── scripts/
│   ├── create-backend.sh      Bash: provision remote state storage + write backend.hcl
│   └── create-backend.ps1     PowerShell: same as above for Windows
└── .github/
    └── workflows/
        └── ci.yml             CI: terraform fmt/validate, TFLint, Trivy security scan
```
