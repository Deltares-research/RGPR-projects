# Setup script for RGPR project packages
# Run this once: source("setup_packages.R")

# Create personal library if needed
lib_path <- "C:/Users/nieboer/R_packages"
dir.create(lib_path, showWarnings = FALSE, recursive = TRUE)

# Add to library path
.libPaths(c(lib_path, .libPaths()))

# Remove stale lock directories left by interrupted installs
lock_dirs <- Sys.glob(file.path(lib_path, "00LOCK*"))
if (length(lock_dirs) > 0) {
  unlink(lock_dirs, recursive = TRUE, force = TRUE)
}

# Install required dependencies only if missing in the target library
cran_required <- c("remotes", "jsonlite", "rlang", "languageserver")
installed_in_lib <- rownames(installed.packages(lib.loc = lib_path))
cran_missing <- setdiff(cran_required, installed_in_lib)

if (length(cran_missing) > 0) {
  install.packages(
    cran_missing,
    lib = lib_path,
    repos = "https://cloud.r-project.org"
  )
} else {
  cat("All CRAN dependencies already present in", lib_path, "\n")
}

# Load remotes
library(remotes, lib.loc = lib_path)

# Install RGPR from GitHub
remotes::install_github(
  "emanuelhuber/RGPR",
  lib = lib_path,
  dependencies = TRUE,
  upgrade = "never"
)

# Verify installation
if (require(jsonlite, lib.loc = lib_path) && 
    require(rlang, lib.loc = lib_path) && 
    require(languageserver, lib.loc = lib_path) && 
    require(RGPR, lib.loc = lib_path)) {
  cat("\n✓ SUCCESS: All packages installed and loaded!\n")
  cat("Packages location:", lib_path, "\n")
} else {
  cat("\n✗ ERROR: Some packages failed to load\n")
}
