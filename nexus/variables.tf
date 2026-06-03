variable "admin_password" {
  description = "Nexus admin password. Must match the password set when the container started (default 'admin123' on first boot)."
  type        = string
  sensitive   = true
}

variable "state_storage_account" {
  description = "Name of the Azure Storage Account that holds the Terraform remote state (the same account used by infra/)."
  type        = string
}

variable "pypi_allowlist" {
  description = "PyPI packages allowed through the proxy, grouped by category. Each package generates two routing-rule matchers: /simple/<pkg> and /packages/<pkg>."
  type = object({
    build_tools   = list(string)
    core          = list(string)
    visualisation = list(string)
    ml            = list(string)
    data_io       = list(string)
    jupyter       = list(string)
    utilities     = list(string)
  })
  default = {
    build_tools = [
      "pip", "setuptools", "wheel", "twine", "build", "poetry", "pytest",
    ]
    core = [
      "numpy", "pandas", "scipy", "polars", "pyarrow",
      "dask", "pyspark",
    ]
    visualisation = [
      "matplotlib", "seaborn", "plotly", "bokeh", "altair", "kaleido", "missingno",
    ]
    ml = [
      "scikit-learn", "xgboost", "lightgbm", "statsmodels", "lifelines", "pingouin",
      "mlflow",
      "shap", "lime", "eli5",
      "pandera", "great-expectations",
    ]
    data_io = [
      "openpyxl", "xlrd", "xlsxwriter", "fastparquet",
      "sqlalchemy", "psycopg2-binary", "pymysql", "pyodbc",
    ]
    jupyter = [
      "jupyter", "jupyterlab", "ipython", "ipykernel", "notebook",
      "nbformat", "nbconvert", "ipywidgets", "widgetsnbextension",
    ]
    utilities = [
      "joblib", "numba", "tqdm",
      "requests", "httpx", "aiohttp",
      "python-dateutil", "pytz", "tzdata", "six",
      "certifi", "charset-normalizer", "idna", "urllib3",
      "packaging", "click",
      "pydantic", "pydantic-core", "typing-extensions", "attrs", "annotated-types",
    ]
  }
}

variable "r_allowlist" {
  description = "R packages allowed through the CRAN proxy, grouped by category. Each package generates three routing-rule matchers: source tarball, Windows binary, macOS binary."
  type = object({
    tidyverse_plumbing = list(string)
    data_wrangling     = list(string)
    io_formats         = list(string)
    visualisation      = list(string)
    string_matching    = list(string)
  })
  default = {
    tidyverse_plumbing = [
      "rlang", "vctrs", "lifecycle", "cli", "glue", "magrittr", "generics",
      "R6", "Rcpp", "withr", "pkgconfig", "ellipsis",
      "tibble", "purrr", "readr", "forcats", "hms", "vroom",
      "tidyselect", "pillar", "fansi", "utf8", "crayon", "bit64", "bit",
    ]
    data_wrangling = [
      "tidyverse", "dplyr", "tidyr", "stringr", "stringi",
      "data.table", "lubridate", "broom", "modelr",
    ]
    io_formats = [
      "haven", "readxl", "openxlsx", "rio", "foreign",
      "cellranger", "zip", "jsonlite", "curl", "httr",
    ]
    visualisation = [
      "ggplot2", "scales", "gtable", "isoband", "farver", "labeling",
      "munsell", "RColorBrewer", "viridisLite", "colorspace", "MASS",
    ]
    string_matching = [
      "fuzzyjoin", "stringdist",
    ]
  }
}
