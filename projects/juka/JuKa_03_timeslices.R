# =============================================================================
# JuKa - Script 03: Envelope, Time-Slice Interpolation & 3-D Export
# =============================================================================
# Loads topo-corrected processed data from PRC/, handles the zigzag survey
# geometry, computes the signal envelope, and interpolates horizontal time/
# depth slices using Multilevel B-Spline Approximation.  Slices and a 3-D
# data cube are saved as PNG plots and GeoTIFF rasters.
#
# Prerequisites: run 01_recipe_processing.R and JuKa_02_survey.R first.
#
# What this script does:
#   1.  Loads topo-corrected DT1 files from PRC/ into a GPRsurvey.
#   2.  Reverses the even-indexed lines to account for the zigzag pattern
#       (odd lines = left-to-right, even lines = right-to-left).
#   3.  Sets the CRS to RD New Amersfoort (EPSG:28992).
#   4.  Computes the signal envelope (instantaneous amplitude).
#   5.  Interpolates a 3-D data cube with interpSlices().
#   6.  Plots and saves all time slices as PNG.
#   7.  Exports each slice as a GeoTIFF raster.
#   8.  Saves a composite overview of all slices.
# =============================================================================

library(RGPR)

# =============================================================================
# LOAD CONFIGURATION FROM .env
# =============================================================================

source("_config.R")  # Loads DATA_DIR, PLOTS_DIR, PRC_DIR, SLICE_DIR, RASTER_DIR, etc.

# Auto-install raster if missing
if (!requireNamespace("raster", quietly = TRUE)) {
  message("Installing required package 'raster'...")
  install.packages("raster")
  library(raster)
} else {
  library(raster)
}

# MBA is needed by interpSlices() internally – usually a dependency of RGPR.
# If you get an error about 'MBA', install it: install.packages("MBA")
# Interpolation extent type: "chull", "bbox", "obbox", or "buffer"
INTERP_EXTEND <- "chull"
# Buffer distance [m] to extend the interpolation hull (ignored for "chull" without buffer)
INTERP_BUFFER <- 0   # set > 0 to extend beyond the GPR lines

# Time range for slices [ns].
# Set to NULL to use the full available range of the data.
T_MIN_NS <- NULL   # e.g. 0   (NULL = auto)
T_MAX_NS <- NULL   # e.g. 80  (NULL = auto)

# PNG output
PNG_W <- 1200; PNG_H <- 1000; PNG_RES <- 120

# =============================================================================
# SETUP
# =============================================================================

dir.create(PLOTS_DIR,  showWarnings = FALSE, recursive = TRUE)
dir.create(SLICE_DIR,  showWarnings = FALSE, recursive = TRUE)
dir.create(RASTER_DIR, showWarnings = FALSE, recursive = TRUE)

# =============================================================================
# 1. LOAD TOPO-CORRECTED SURVEY
# =============================================================================

# Prefer topo-corrected files; fall back to uncorrected if not yet available.
topo_files <- sort(
  list.files(PRC_DIR, pattern = "_topoCorr\\.DT1$",
             full.names = TRUE, ignore.case = TRUE)
)

if (length(topo_files) == 0) {
  message(
    "No _topoCorr files found. Falling back to standard processed files.\n",
    "Run JuKa_02_survey.R first for topographic correction."
  )
  topo_files <- sort(
    list.files(PRC_DIR, pattern = "^Line[0-9]+-ch2\\.DT1$",
               full.names = TRUE, ignore.case = TRUE)
  )
}

if (length(topo_files) == 0) {
  stop("No DT1 files found in PRC_DIR: ", PRC_DIR,
  "\nPlease run 01_recipe_processing.R (and optionally JuKa_02_survey.R) first.")
}

cat("Loading", length(topo_files), "file(s) into GPRsurvey...\n")
SU <- GPRsurvey(topo_files, verbose = FALSE)
crs(SU) <- CRS_SURVEY
print(SU)

# =============================================================================
# 2. REVERSE EVEN-INDEXED LINES (ZIGZAG CORRECTION)
# =============================================================================
# The survey was recorded in zigzag:
#   - Odd line numbers (Line3, Line5, …) : left-to-right  → keep as-is
#   - Even line numbers (Line4, Line6, …): right-to-left  → reverse
#
# In GPRsurvey the files are sorted by name, so:
#   index 1 = Line3  (odd  file number → L-to-R → keep)
#   index 2 = Line4  (even file number → R-to-L → reverse)
#   index 3 = Line5  → keep, …
#
# The RGPR shortcut id = "zigzag" reverses all even-indexed elements.

cat("\nApplying zigzag reversal (even-indexed lines reversed)...\n")
SU <- reverse(SU, id = "zigzag")
cat("Done.\n")

# =============================================================================
# 3. COMPUTE SIGNAL ENVELOPE
# =============================================================================
# The instantaneous amplitude (envelope) highlights strong reflectors
# irrespective of polarity – recommended for amplitude time-slice maps.

cat("\nComputing signal envelope for all lines...\n")
SU <- papply(SU, prc = list(envelope = NULL))
cat("Envelope computation complete.\n")

# Quick sanity-check plot of the first line
png(file.path(PLOTS_DIR, "envelope_line01.png"),
    width = PNG_W, height = PNG_H, res = PNG_RES)
tryCatch(
  plot(SU[[1]], main = paste(name(SU[[1]]), "– Envelope")),
  error = function(e) plotFast(SU[[1]])
)
dev.off()
cat("Saved: envelope_line01.png\n")

# =============================================================================
# 4. SET TIME RANGE FOR SLICES
# =============================================================================

# Determine the actual time axis from the first line
t_axis <- time(SU[[1]])
t_data_min <- min(t_axis)
t_data_max <- max(t_axis)

t_start <- if (is.null(T_MIN_NS)) t_data_min else max(T_MIN_NS, t_data_min)
t_end   <- if (is.null(T_MAX_NS)) t_data_max else min(T_MAX_NS, t_data_max)

cat(sprintf("\nTime range for slices: %.1f – %.1f ns  (step %.1f ns)\n",
            t_start, t_end, DZ))
cat(sprintf("Grid resolution: dx = %.2f m, dy = %.2f m\n", DX, DY))

# =============================================================================
# 5. INTERPOLATE 3-D DATA CUBE
# =============================================================================

cat("\nRunning interpSlices() – this may take a few minutes...\n")
SXY <- interpSlices(SU,
                    dx     = DX,
                    dy     = DY,
                    dz     = DZ,
                    h      = MBA_H,
                    extend = INTERP_EXTEND,
                    buffer = INTERP_BUFFER)
cat("Interpolation complete.\n")
print(SXY)

# =============================================================================
# 6. PLOT ALL TIME SLICES (PNG)
# =============================================================================

n_slices <- dim(SXY)[3]
cat(sprintf("\nSaving %d time-slice plots to: %s\n", n_slices, SLICE_DIR))

# Compute a common colour range across all slices for consistent visualisation
clim <- range(SXY, na.rm = TRUE)

for (k in seq_len(n_slices)) {
  # Slice centre time [ns]
  t_centre <- t_start + (k - 1) * DZ + DZ / 2

  png_path <- file.path(SLICE_DIR,
                         sprintf("slice_%03d_t%05.1fns.png", k, t_centre))
  png(png_path, width = PNG_W, height = PNG_H, res = PNG_RES)
  tryCatch({
    plot(SXY[, , k],
         clim = clim,
         col  = palGPR("slice"),
         asp  = 1,
         main = sprintf("Time slice %.1f ns  (%.2f m at v = %.2f m/ns)",
                        t_centre, t_centre * V_RADAR / 2, V_RADAR))
    # Overlay survey line traces
    lines(SU, col = "white", lwd = 0.8)
  }, error = function(e) message("  Slice ", k, " plot error: ", e$message))
  dev.off()
}
cat("All slice PNGs saved.\n")

# =============================================================================
# 7. COMPOSITE OVERVIEW OF ALL SLICES
# =============================================================================

n_col <- ceiling(sqrt(n_slices))
n_row <- ceiling(n_slices / n_col)

png(file.path(PLOTS_DIR, "timeslice_overview.png"),
    width  = PNG_W * n_col,
    height = PNG_H * n_row,
    res    = PNG_RES)
par(mfrow = c(n_row, n_col), mar = c(2, 2, 2, 1))
for (k in seq_len(n_slices)) {
  t_centre <- t_start + (k - 1) * DZ + DZ / 2
  tryCatch(
    plot(SXY[, , k], clim = clim, col = palGPR("slice"), asp = 1,
         main = sprintf("%.1f ns", t_centre)),
    error = function(e) NULL
  )
}
dev.off()
cat("Saved: timeslice_overview.png\n")

# =============================================================================
# 8. EXPORT SLICES AS GEOTIFF RASTERS
# =============================================================================

if (requireNamespace("raster", quietly = TRUE)) {
  cat(sprintf("\nExporting %d slices as GeoTIFF to: %s\n", n_slices, RASTER_DIR))

  for (k in seq_len(n_slices)) {
    t_centre <- t_start + (k - 1) * DZ + DZ / 2
    tif_path <- file.path(RASTER_DIR,
                           sprintf("slice_%03d_t%05.1fns.tif", k, t_centre))
    tryCatch({
      r <- as.raster(SXY[, , k])
      raster::writeRaster(r, filename = tif_path, overwrite = TRUE)
    }, error = function(e) {
      message("  GeoTIFF export failed for slice ", k, ": ", e$message)
    })
  }
  cat("GeoTIFF export complete.\n")
} else {
  message("Skipping GeoTIFF export – install 'raster': install.packages('raster')")
}

# =============================================================================
# 9. EXPORT SURVEY LINES (for GIS overlay)
# =============================================================================

tryCatch({
  exportCoord(SU,
              type  = "SpatialLines",
              fPath = file.path(DIR, "JuKa_survey_lines_envelope.gpkg"))
  cat("Exported survey lines to: JuKa_survey_lines_envelope.gpkg\n")
}, error = function(e) {
  warning("Coordinate export failed: ", conditionMessage(e))
})

cat("\n=== Script 03 complete ===\n")
cat("Results:\n")
cat("  Slice PNGs    :", SLICE_DIR,  "\n")
cat("  GeoTIFF rasters:", RASTER_DIR, "\n")
cat("  Overview plot  : timeslice_overview.png\n")
