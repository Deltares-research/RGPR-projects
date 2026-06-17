# =============================================================================
# JuKa - Script 02: Survey Assembly, Coordinates & Topographic Correction
# =============================================================================
# Loads processed GPR data from PRC/, attaches GPS coordinates from the .gp2
# files (auto-read by RGPR), sets the CRS to RD New Amersfoort (EPSG:28992),
# applies topographic correction, and saves survey plots.
#
# Prerequisites: run JuKa_01_processing.R first.
#
# What this script does:
#   1.  Reads processed DT1 files from PRC/ into a GPRsurvey object.
#   2.  Verifies that GPS coordinates were auto-loaded from the .gp2 files.
#   3.  (Optional) Re-projects coordinates if the source CRS differs from RD New.
#   4.  Sets the CRS on the survey object.
#   5.  Applies static topographic correction to each line.
#   6.  Saves topo-corrected files back to PRC/ (suffix _topoCorr).
#   7.  Produces and saves PNG plots:
#         – plan-view of all survey lines
#         – individual radargrams with topographic surface
#         – 3-D view (interactive, requires rgl; saved as screenshot if headless)
#
# Next: run JuKa_03_timeslices.R
# =============================================================================

library(RGPR)

# =============================================================================
# LOAD CONFIGURATION FROM .env
# =============================================================================

source("_config.R")  # Loads DATA_DIR, PLOTS_DIR, PRC_DIR, V_RADAR, CRS_SURVEY, etc.

# Input CRS for reprojection (set to same as OUTPUT_CRS if no reprojection needed)
INPUT_CRS  <- CRS_SURVEY    # from .env
OUTPUT_CRS <- CRS_SURVEY    # from .env

# =============================================================================
# SETUP
# =============================================================================

dir.create(PLOTS_DIR, showWarnings = FALSE, recursive = TRUE)

# Helper: save a plot to PNG
save_plot <- function(expr, fpath) {
  png(fpath, width = PNG_W, height = PNG_H, res = PNG_RES)
  tryCatch(force(expr), error = function(e) message("  Plot error: ", e$message))
  dev.off()
  invisible(NULL)
}

# =============================================================================
# 1. LOAD PROCESSED DATA INTO GPRsurvey
# =============================================================================

# Load the (migration/background-removed) files, NOT the _topoCorr ones yet.
prc_files <- sort(
  list.files(PRC_DIR,
             pattern = "^Line[0-9]+-ch2\\.DT1$",   # exclude _topoCorr files
             full.names = TRUE, ignore.case = TRUE)
)

if (length(prc_files) == 0) {
  stop("No processed DT1 files found in PRC_DIR: ", PRC_DIR,
       "\nPlease run JuKa_01_processing.R first.")
}
cat("Loading", length(prc_files), "processed line(s)...\n")

# GPRsurvey reads each DT1 file and automatically looks for a same-named .gp2
# file in the same directory. If found, trace coordinates are attached.
mySurvey <- GPRsurvey(prc_files)
print(mySurvey)

# =============================================================================
# 2. VERIFY / RECOVER COORDINATES
# =============================================================================

# Check that at least the first line has coordinates attached.
has_coords <- tryCatch({
  cc <- coords(mySurvey[[1]])
  !is.null(cc) && nrow(cc) > 0
}, error = function(e) FALSE)

if (!has_coords) {
  message(
    "Coordinates were NOT automatically loaded from .gp2 files.\n",
    "Possible reasons:\n",
    "  - .gp2 files are not in PRC_DIR (Script 01 should have copied them)\n",
    "  - .gp2 file names do not match the DT1 file names\n",
    "  - Your version of RGPR does not auto-read .gp2 files\n\n",
    "Attempting to read .gp2 files from the original data directory..."
  )

  # Fall-back: load each raw DT1 (which auto-reads the .gp2) and extract coords,
  # then assign them to the processed survey.
  raw_files <- sort(
    list.files(DATA_DIR, pattern = "^Line[0-9]+-ch2\\.DT1$",
               full.names = TRUE, ignore.case = TRUE)
  )

  coord_list <- lapply(raw_files, function(f) {
    tmp <- readGPR(dsn = f)
    tryCatch(coords(tmp), error = function(e) NULL)
  })

  valid <- !sapply(coord_list, is.null)
  if (sum(valid) == 0) {
    stop(
      "Could not load coordinates from any .gp2 file.\n",
      "Check that .gp2 files exist in: ", DATA_DIR
    )
  }

  # Assign coordinate list to survey (one data.frame per line, columns E, N, Z)
  coords(mySurvey) <- coord_list
  cat("Coordinates loaded from raw .gp2 files.\n")
} else {
  cat("GPS coordinates confirmed on", length(mySurvey), "line(s).\n")
}

# =============================================================================
# 3. (OPTIONAL) REPROJECT COORDINATES
# =============================================================================
# Uncomment and adapt if INPUT_CRS differs from OUTPUT_CRS.
# Requires the 'sf' package:  install.packages("sf")

# if (INPUT_CRS != OUTPUT_CRS) {
#   library(sf)
#   for (i in seq_along(mySurvey)) {
#     cc <- coords(mySurvey[[i]])
#     if (is.null(cc) || nrow(cc) == 0) next
#     pts <- sf::st_as_sf(as.data.frame(cc), coords = c("E", "N"), crs = INPUT_CRS)
#     pts <- sf::st_transform(pts, crs = OUTPUT_CRS)
#     xy  <- sf::st_coordinates(pts)
#     cc$E <- xy[, "X"]
#     cc$N <- xy[, "Y"]
#     coords(mySurvey[[i]]) <- cc
#   }
#   cat("Coordinates reprojected from", INPUT_CRS, "to", OUTPUT_CRS, "\n")
# }

# =============================================================================
# 4. SET COORDINATE REFERENCE SYSTEM
# =============================================================================

crs(mySurvey) <- OUTPUT_CRS
cat("CRS set to:", OUTPUT_CRS, "(RD New Amersfoort)\n")

# =============================================================================
# 5. TOPOGRAPHIC CORRECTION
# =============================================================================
# topoCorr() applies a static elevation correction by shifting each trace
# vertically according to the Z coordinate, so that the top of each profile
# reflects the true surface topography.

cat("\nApplying topographic correction to", length(mySurvey), "line(s)...\n")

for (i in seq_along(mySurvey)) {
  lname <- name(mySurvey[[i]])
  cat(sprintf("  [%d/%d] %s\n", i, length(mySurvey), lname))

  A <- mySurvey[[i]]

  A_corr <- tryCatch(
    topoCorr(A),
    error = function(e) {
      warning("topoCorr() failed for ", lname, ": ", conditionMessage(e),
              "\n  Saving uncorrected line.")
      A
    }
  )

  # Save topo-corrected DT1 to PRC with a clear suffix
  out_base <- file.path(PRC_DIR, paste0(lname, "_topoCorr"))
  writeGPR(A_corr, fPath = out_base, type = "DT1", overwrite = TRUE)

  # Copy the .gp2 file to the new name so coordinates stay attached
  gp2_src <- list.files(PRC_DIR,
                         pattern = paste0("^", lname, "\\.gp2$"),
                         full.names = TRUE, ignore.case = TRUE)
  if (length(gp2_src) > 0) {
    file.copy(gp2_src[1],
              file.path(PRC_DIR, paste0(lname, "_topoCorr.gp2")),
              overwrite = TRUE)
  }
}
cat("Topo-corrected files saved with suffix '_topoCorr' in:", PRC_DIR, "\n")

# Reload the survey from the topo-corrected files
topo_files <- sort(
  list.files(PRC_DIR, pattern = "_topoCorr\\.DT1$",
             full.names = TRUE, ignore.case = TRUE)
)
mySurvey <- GPRsurvey(topo_files)
crs(mySurvey) <- OUTPUT_CRS
cat("Reloaded", length(topo_files), "topo-corrected line(s) into GPRsurvey.\n")
print(mySurvey)

# =============================================================================
# 6. PLOTS
# =============================================================================

# ---- Plan-view map of all survey lines -------------------------------------
save_plot(
  {
    plot(mySurvey, asp = 1)
    title("JuKa GPR Survey – Plan View (RD New, EPSG:28992)")
  },
  file.path(PLOTS_DIR, "survey_planview.png")
)
cat("Saved: survey_planview.png\n")

# ---- Individual radargrams with topographic surface overlay ----------------
for (i in seq_along(mySurvey)) {
  lname <- name(mySurvey[[i]])
  save_plot(
    plot(mySurvey[[i]], addTopo = TRUE,
         main = paste(lname, "– With Topography")),
    file.path(PLOTS_DIR, paste0(lname, "_topoProfile.png"))
  )
}
cat("Saved", length(mySurvey), "individual topo-profile plots.\n")

# ---- All profiles in one multi-panel plot ----------------------------------
n   <- length(mySurvey)
ncl <- ceiling(sqrt(n))
nrw <- ceiling(n / ncl)

png(file.path(PLOTS_DIR, "all_profiles_topo.png"),
    width = PNG_W * ncl, height = PNG_H * nrw, res = PNG_RES)
par(mfrow = c(nrw, ncl), mar = c(3, 3, 2, 1))
for (i in seq_len(n)) {
  tryCatch(
    plot(mySurvey[[i]], addTopo = TRUE, main = name(mySurvey[[i]])),
    error = function(e) plotFast(mySurvey[[i]])
  )
}
dev.off()
cat("Saved: all_profiles_topo.png\n")

# ---- Interactive 3-D plot (requires rgl) -----------------------------------
# Uncomment to open an interactive OpenGL window.
# If running in a headless environment or Rscript, comment this out.
#
# if (requireNamespace("rgl", quietly = TRUE)) {
#   plot3DRGL(mySurvey, addTopo = TRUE)
# } else {
#   message("Install 'rgl' for the 3-D interactive plot: install.packages('rgl')")
# }

# =============================================================================
# 7. EXPORT SURVEY LINES AS GEOPACKAGE
# =============================================================================

tryCatch({
  exportCoord(mySurvey,
              type  = "SpatialLines",
              fPath = file.path(DATA_DIR, "JuKa_survey_lines.gpkg"))
  cat("Exported survey lines to: JuKa_survey_lines.gpkg\n")
}, error = function(e) {
  warning("Coordinate export failed: ", conditionMessage(e))
})

cat("\n=== Script 02 complete ===\n")
cat("Next: run JuKa_03_timeslices.R\n")
