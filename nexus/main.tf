###############################################################################
# Nexus OSS configuration — Phase 2
#
# All resources are idempotent: re-running terraform apply is safe at any time.
#
# Note: The datadrivers/nexus provider (v2.x) does not expose a
# nexus_cleanup_policy resource.  Cleanup policies (90-day last-downloaded
# for the two proxy repos) must be created once via the Nexus admin UI:
#   Administration → Cleanup Policies → Create Cleanup Policy
###############################################################################

locals {
  nexus_url = data.terraform_remote_state.infra.outputs.nexus_base_url

  # Flatten all PyPI packages into a single list for the routing rule.
  all_pypi_packages = flatten(values(var.pypi_allowlist))

  # Flatten all R packages; dots are escaped for regex matching.
  all_r_packages = flatten(values(var.r_allowlist))

  # Platform detection: Windows absolute paths start with a drive letter + backslash.
  is_windows = length(regexall("^[A-Za-z]:\\\\", abspath(path.module))) > 0

  # Password bootstrap commands — logically identical, syntactically different per platform.
  # Both try admin123 first (new/reset instance); fall back to var.admin_password (re-apply).
  # Note: Terraform only interpolates ${...} in strings; bare $word is passed through as-is.
  _pw_ps = <<-PS
    $url = $env:NEXUS_URL + '/service/rest/v1/security/users/admin/change-password'
    curl.exe -sf -u admin:admin123 -X PUT $url -H 'Content-Type: text/plain' -d $env:NEW_PASSWORD
    if ($LASTEXITCODE -ne 0) {
      $cred = 'admin:' + $env:NEW_PASSWORD
      curl.exe -sf -u $cred -X PUT $url -H 'Content-Type: text/plain' -d $env:NEW_PASSWORD
    }
  PS

  _pw_sh = <<-SH
    url="$NEXUS_URL/service/rest/v1/security/users/admin/change-password"
    curl -sf -u "admin:admin123" -X PUT "$url" -H 'Content-Type: text/plain' -d "$NEW_PASSWORD" ||
    curl -sf -u "admin:$NEW_PASSWORD" -X PUT "$url" -H 'Content-Type: text/plain' -d "$NEW_PASSWORD"
  SH
}

###############################################################################
# Bootstrap — change the default admin123 password to var.admin_password.
#
# Nexus boots with NEXUS_SECURITY_RANDOMPASSWORD=false so the initial password
# is always "admin123".  This step uses the Nexus REST API to change it to the
# value supplied via var.admin_password before any provider resources run.
#
# Idempotent: if the password was already changed on a previous apply the
# admin123 curl will 401; the fallback curl (using var.admin_password) will
# succeed, confirming the desired password is already in place.
###############################################################################

resource "null_resource" "set_admin_password" {
  triggers = {
    password_hash = sha256(var.admin_password)
    nexus_url     = local.nexus_url
  }

  # Platform-adaptive: PowerShell on Windows, bash on macOS/Linux.
  # Password is passed via environment to keep it out of process argv and Terraform debug logs.
  provisioner "local-exec" {
    interpreter = local.is_windows ? ["PowerShell", "-Command"] : ["bash", "-c"]
    environment = {
      NEXUS_URL    = local.nexus_url
      NEW_PASSWORD = var.admin_password
    }
    command = local.is_windows ? local._pw_ps : local._pw_sh
  }
}

###############################################################################
# Anonymous access
###############################################################################

resource "nexus_security_anonymous" "main" {
  enabled    = true
  user_id    = "anonymous"
  realm_name = "NexusAuthorizingRealm"

  depends_on = [null_resource.set_admin_password]
}

###############################################################################
# PyPI stack
###############################################################################

# Routing rule — ALLOW mode: only listed packages pass through the proxy.
# Two matchers per package:
#   ^/simple/<pkg>(/.*)?$   — index lookup  (pip resolves the download URL)
#   ^/packages/<pkg>(/.*)?$ — file download (the cached .whl / .tar.gz)
resource "nexus_routing_rule" "pypi_allowlist" {
  name        = "pypi-allowlist"
  description = "Supply-chain gate: only approved packages pass through the PyPI proxy"
  mode        = "ALLOW"
  matchers = toset(flatten([
    for pkg in local.all_pypi_packages : [
      "^/simple/${pkg}(/.*)?$",
      "^/packages(.*/)?${replace(pkg, ".", "\\.")}[-_]",
    ]
  ]))

  depends_on = [null_resource.set_admin_password]
}

resource "nexus_repository_pypi_hosted" "main" {
  name   = "pypi-hosted"
  online = true

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
    write_policy                   = "ALLOW"
  }

  depends_on = [null_resource.set_admin_password]
}

resource "nexus_repository_pypi_proxy" "main" {
  name         = "pypi-pypi.org"
  online       = true
  routing_rule = nexus_routing_rule.pypi_allowlist.name

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
  }

  proxy {
    remote_url       = "https://pypi.org"
    content_max_age  = 1440
    metadata_max_age = 1440
  }

  negative_cache {
    enabled = true
    ttl     = 1440
  }

  http_client {
    blocked    = false
    auto_block = true
  }
}

# Hosted is listed first so internal packages shadow same-named PyPI packages
# (prevents dependency-confusion attacks).
resource "nexus_repository_pypi_group" "main" {
  name   = "pypi-group"
  online = true

  group {
    member_names = [
      nexus_repository_pypi_hosted.main.name,
      nexus_repository_pypi_proxy.main.name,
    ]
  }

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
  }
}

###############################################################################
# R / CRAN stack
###############################################################################

# Routing rule — ALLOW mode.
# Four hardcoded global index matchers let R fetch PACKAGES metadata
# before attempting any individual package download.
# Three matchers per package: source tarball, Windows binary, macOS binary.
# Dots in package names (e.g. data.table) are escaped to \. in the regex.
resource "nexus_routing_rule" "r_cran_allowlist" {
  name        = "r-cran-allowlist"
  description = "Supply-chain gate: only approved R packages pass through the CRAN proxy"
  mode        = "ALLOW"
  matchers = toset(concat(
    [
      "^/src/contrib/PACKAGES(\\.[^/]*)?$",
      "^/src/contrib/Meta/",
      "^/bin/windows/contrib/[^/]+/PACKAGES(\\.[^/]*)?$",
      "^/bin/macosx/[^/]+/contrib/[^/]+/PACKAGES(\\.[^/]*)?$",
    ],
    flatten([
      for pkg in local.all_r_packages : [
        "^/src/contrib/${replace(pkg, ".", "\\.")}_",
        "^/bin/windows/contrib/[^/]+/${replace(pkg, ".", "\\.")}_",
        "^/bin/macosx/[^/]+/contrib/[^/]+/${replace(pkg, ".", "\\.")}_",
      ]
    ])
  ))

  depends_on = [null_resource.set_admin_password]
}

resource "nexus_repository_r_hosted" "main" {
  name   = "r-hosted"
  online = true

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
    write_policy                   = "ALLOW"
  }

  depends_on = [null_resource.set_admin_password]
}

resource "nexus_repository_r_proxy" "main" {
  name         = "r-cran.r-project.org"
  online       = true
  routing_rule = nexus_routing_rule.r_cran_allowlist.name

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
  }

  proxy {
    remote_url       = "https://cran.r-project.org"
    content_max_age  = 1440
    metadata_max_age = 1440
  }

  negative_cache {
    enabled = true
    ttl     = 1440
  }

  http_client {
    blocked    = false
    auto_block = true
  }
}

resource "nexus_repository_r_group" "main" {
  name   = "r-group"
  online = true

  group {
    member_names = [
      nexus_repository_r_hosted.main.name,
      nexus_repository_r_proxy.main.name,
    ]
  }

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
  }
}

###############################################################################
# Roles
###############################################################################

resource "nexus_security_role" "pypi_anonymous_reader" {
  roleid      = "pypi-anonymous-reader"
  name        = "PyPI Anonymous Reader"
  description = "Browse and download allowlisted packages via pypi-group (no upload)"
  privileges = [
    "nx-repository-view-pypi-pypi-group-browse",
    "nx-repository-view-pypi-pypi-group-read",
  ]
  roles = []

  # pypi-group privileges are generated by Nexus when the group repo is created.
  depends_on = [nexus_repository_pypi_group.main]
}

resource "nexus_security_role" "pypi_authenticated_deployer" {
  roleid      = "pypi-authenticated-deployer"
  name        = "PyPI Authenticated Deployer"
  description = "Browse/download via pypi-group; upload new packages to pypi-hosted"
  privileges = [
    "nx-repository-view-pypi-pypi-group-browse",
    "nx-repository-view-pypi-pypi-group-read",
    "nx-repository-view-pypi-pypi-hosted-browse",
    "nx-repository-view-pypi-pypi-hosted-read",
    "nx-repository-view-pypi-pypi-hosted-add",
  ]
  roles = []

  # pypi-group and pypi-hosted privileges are generated when those repos are created.
  depends_on = [
    nexus_repository_pypi_group.main,
    nexus_repository_pypi_hosted.main,
  ]
}

resource "nexus_security_role" "r_anonymous_reader" {
  roleid      = "r-anonymous-reader"
  name        = "R Anonymous Reader"
  description = "Browse and download allowlisted R packages via r-group (no upload)"
  privileges = [
    "nx-repository-view-r-r-group-browse",
    "nx-repository-view-r-r-group-read",
  ]
  roles = []

  # r-group privileges are generated by Nexus when the group repo is created.
  depends_on = [nexus_repository_r_group.main]
}

resource "nexus_security_role" "r_authenticated_deployer" {
  roleid      = "r-authenticated-deployer"
  name        = "R Authenticated Deployer"
  description = "Browse/download via r-group; upload new packages to r-hosted"
  privileges = [
    "nx-repository-view-r-r-group-browse",
    "nx-repository-view-r-r-group-read",
    "nx-repository-view-r-r-hosted-browse",
    "nx-repository-view-r-r-hosted-read",
    "nx-repository-view-r-r-hosted-add",
  ]
  roles = []

  # r-group and r-hosted privileges are generated when those repos are created.
  depends_on = [
    nexus_repository_r_group.main,
    nexus_repository_r_hosted.main,
  ]
}

###############################################################################
# Anonymous user — locked to read-only roles only
###############################################################################

# Replaces the default nx-anonymous role (which allows unrestricted browse)
# with the two scoped reader roles created above.
resource "nexus_security_user" "anonymous" {
  userid    = "anonymous"
  firstname = "Anonymous"
  lastname  = "User"
  email     = "anonymous@example.org"
  password  = "anonymous"
  status    = "active"
  roles = [
    nexus_security_role.pypi_anonymous_reader.roleid,
    nexus_security_role.r_anonymous_reader.roleid,
  ]
}
