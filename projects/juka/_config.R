# =============================================================================
# JuKa Project Configuration Loader
# =============================================================================
# This script reads settings from .env and sets up all global variables
# used by the three main processing scripts.
#
# Usage: source("_config.R")
# =============================================================================

# Check if .env exists; if not, offer helpful error message
if (!file.exists(".env")) {
  stop(
    "Configuration file '.env' not found.\n",
    "Please copy '.env.example' to '.env' and edit the paths:\n",
    "  cp .env.example .env\n",
    "Then update DATA_DIR and other settings for your system."
  )
}

# Read .env file: simple key=value parser
.env_data <- readLines(".env")
.env_data <- .env_data[!grepl("^\\s*#", .env_data)]  # skip comments
.env_data <- .env_data[.env_data != ""]              # skip empty lines

for (line in .env_data) {
  parts <- strsplit(line, "=", fixed = TRUE)[[1]]
  if (length(parts) == 2) {
    key <- trimws(parts[1])
    val <- trimws(parts[2])
    # Convert "TRUE"/"FALSE" strings to logical
    if (val == "TRUE") {
      val <- TRUE
    } else if (val == "FALSE") {
      val <- FALSE
    } else if (grepl("^[0-9]+\\.?[0-9]*$", val)) {
      # Convert numeric strings to numbers
      val <- as.numeric(val)
    }
    # Assign to global environment
    assign(key, val, envir = .GlobalEnv)
  }
}

# Clean up temporary variable
rm(.env_data, envir = .GlobalEnv)

# Set up derived paths (relative to DATA_DIR)
PLOTS_DIR  <- file.path(DATA_DIR, "plots")
PRC_DIR    <- file.path(DATA_DIR, "PRC")
SLICE_DIR  <- file.path(DATA_DIR, "plots", "slices")
RASTER_DIR <- file.path(DATA_DIR, "plots", "rasters")

# Assign to global so scripts can use them
assign("PLOTS_DIR",  PLOTS_DIR,  envir = .GlobalEnv)
assign("PRC_DIR",    PRC_DIR,    envir = .GlobalEnv)
assign("SLICE_DIR",  SLICE_DIR,  envir = .GlobalEnv)
assign("RASTER_DIR", RASTER_DIR, envir = .GlobalEnv)

# Print summary so the user can verify
cat("=== JuKa Configuration Loaded ===\n")
cat("DATA_DIR    :", DATA_DIR, "\n")
cat("PLOTS_DIR   :", PLOTS_DIR, "\n")
cat("PRC_DIR     :", PRC_DIR, "\n")
cat("V_RADAR     :", V_RADAR, "m/ns\n")
cat("CRS_SURVEY  :", CRS_SURVEY, "\n")
cat("================================\n\n")
