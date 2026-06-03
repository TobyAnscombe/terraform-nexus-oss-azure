###############################################################################
# Nexus OSS configuration — Phase 2
#
# All resources are idempotent: re-running terraform apply is safe at any time.
# No bash, no null_resource, no local-exec.
#
# Note: The datadrivers/nexus provider (v2.x) does not expose a
# nexus_cleanup_policy resource.  Cleanup policies (90-day last-downloaded
# for the two proxy repos) must be created once via the Nexus admin UI:
#   Administration → Cleanup Policies → Create Cleanup Policy
###############################################################################

locals {
  # Flatten all PyPI packages into a single list for the routing rule.
  all_pypi_packages = flatten(values(var.pypi_allowlist))

  # Flatten all R packages; dots are escaped for regex matching.
  all_r_packages = flatten(values(var.r_allowlist))
}

###############################################################################
# Anonymous access
###############################################################################

resource "nexus_security_anonymous" "main" {
  enabled    = true
  user_id    = "anonymous"
  realm_name = "NexusAuthorizingRealm"
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
      "^/packages/${pkg}(/.*)?$",
    ]
  ]))
}

resource "nexus_repository_pypi_hosted" "main" {
  name   = "pypi-hosted"
  online = true

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
    write_policy                   = "ALLOW"
  }
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
      "^/src/contrib/PACKAGES",
      "^/src/contrib/Meta/",
      "^/bin/windows/contrib/[^/]+/PACKAGES",
      "^/bin/macosx/[^/]+/contrib/[^/]+/PACKAGES",
    ],
    flatten([
      for pkg in local.all_r_packages : [
        "^/src/contrib/${replace(pkg, ".", "\\.")}_",
        "^/bin/windows/contrib/[^/]+/${replace(pkg, ".", "\\.")}_",
        "^/bin/macosx/[^/]+/contrib/[^/]+/${replace(pkg, ".", "\\.")}_",
      ]
    ])
  ))
}

resource "nexus_repository_r_hosted" "main" {
  name   = "r-hosted"
  online = true

  storage {
    blob_store_name                = "default"
    strict_content_type_validation = true
    write_policy                   = "ALLOW"
  }
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
