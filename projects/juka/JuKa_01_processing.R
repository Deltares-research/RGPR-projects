# =============================================================================
# JuKa - Script 01: Batch GPR Processing Pipeline
# =============================================================================
# Processes all GPR lines (Line3-ch2.DT1 to Line14-ch2.DT1) using a
# pipe-based workflow. Intermediate plots are saved to the 'plots' subfolder.
# Processed data are saved to the 'PRC' subfolder in Sensors & Software format.
#
# Processing steps (in order):
#   1.  Raw plot
#   2.  Time-zero detection
#   3.  Time-zero correction
#   4.  Dewow (running-median high-cut)
#   5.  T-power gain (strong)
#   6.  Bandpass frequency filter
#   7.  Kirchhoff migration  (toggle with MIGRATE_ENABLED)
#   8.  Deconvolution  (toggle with DECONV_ENABLED)
#   9.  Time window crop (0 to 100 ns)
#
# Note: topographic correction requires GPS coordinates and is applied in
#       Script 02 (JuKa_02_survey.R).
#
# Next scripts:
#   JuKa_02_survey.R     – add coordinates, topo correction, survey plots
#   JuKa_03_timeslices.R – envelope, time-slice interpolation, 3-D export
# =============================================================================

library(RGPR)       # also exports %>% and %T>% from magrittr

# =============================================================================
# LOAD CONFIGURATION FROM .env
# =============================================================================
# All parameters (paths, velocities, filter settings, etc.) are loaded from
# .env file in the same directory. Copy .env.example to .env and customize.

source("_config.R")  # Loads DATA_DIR, PLOTS_DIR, PRC_DIR, V_RADAR, etc.

# =============================================================================
# SETUP
# =============================================================================

dir.create(PLOTS_DIR, showWarnings = FALSE, recursive = TRUE)
dir.create(PRC_DIR,   showWarnings = FALSE, recursive = TRUE)

# Discover all ch2 DT1 files (Lines 3–14)
dt1_files <- sort(
  list.files(DATA_DIR, pattern = "^Line[0-9]+-ch2\\.DT1$",
             full.names = TRUE, ignore.case = TRUE)
)

if (length(dt1_files) == 0) {
  stop("No DT1 files matching 'Line*.DT1' found in: ", DATA_DIR)
}
cat("Found", length(dt1_files), "DT1 file(s):\n")
cat(paste0("  ", basename(dt1_files)), sep = "\n"); cat("\n")

# Test mode: run only first file to keep runtime short.
dt1_files <- dt1_files[1]
cat("Test mode: processing only first file:", basename(dt1_files[1]), "\n\n")

# Helper: read antenna frequency from .HD header file
get_frequency_from_header <- function(dt1_path) {
  hd_path <- sub("\\.DT1$", ".HD", dt1_path, ignore.case = TRUE)
  if (!file.exists(hd_path)) {
    return(NA)
  }
  hd_content <- readLines(hd_path)
  freq_line <- grep("NOMINAL FREQUENCY", hd_content, ignore.case = TRUE, value = TRUE)
  if (length(freq_line) > 0) {
    # Extract the numeric part (e.g., "NOMINAL FREQUENCY  = 250" → 250)
    freq_val <- as.numeric(sub(".*=\\s*([0-9.]+).*", "\\1", freq_line[1]))
    if (!is.na(freq_val)) {
      return(freq_val)
    }
  }
  return(NA)
}

# Helper: read one numeric value from .HD by key
get_hd_numeric <- function(dt1_path, key_pattern) {
  hd_path <- sub("\\.DT1$", ".HD", dt1_path, ignore.case = TRUE)
  if (!file.exists(hd_path)) {
    return(NA_real_)
  }
  hd_content <- readLines(hd_path)
  line <- grep(key_pattern, hd_content, ignore.case = TRUE, value = TRUE)
  if (length(line) == 0) {
    return(NA_real_)
  }
  suppressWarnings(as.numeric(sub(".*=\\s*([0-9.]+).*", "\\1", line[1])))
}

# Helper: read header time-zero sample index and convert to ns
get_timezero_from_header <- function(dt1_path) {
  tz_idx <- get_hd_numeric(dt1_path, "TIMEZERO AT POINT")
  npts <- get_hd_numeric(dt1_path, "NUMBER OF PTS/TRC")
  twindow <- get_hd_numeric(dt1_path, "TOTAL TIME WINDOW")

  if (is.na(tz_idx) || is.na(npts) || is.na(twindow) || npts <= 0 || tz_idx < 1) {
    return(list(sample = NA_integer_, t0_ns = NA_real_, dt_ns = NA_real_))
  }

  dt_ns <- twindow / npts
  t0_ns <- tz_idx * dt_ns
  list(sample = as.integer(round(tz_idx)), t0_ns = t0_ns, dt_ns = dt_ns)
}

# Helper: save a radargram plot as PNG and return the GPR object invisibly.
save_plot <- function(x, fpath, ttl = "") {
  png(fpath, width = PNG_W, height = PNG_H, res = PNG_RES)
  tryCatch(
    plot(x, main = ttl),
    error = function(e) plotFast(x, main = ttl)
  )
  dev.off()
  invisible(x)
}

# =============================================================================
# BATCH PROCESSING LOOP
# =============================================================================

for (i in seq_along(dt1_files)) {

  fpath <- dt1_files[i]
  lname <- tools::file_path_sans_ext(basename(fpath))
  cat(sprintf("\n[%d/%d] Processing: %s\n", i, length(dt1_files), lname))

  # ---- Load raw data -------------------------------------------------------
  # readGPR automatically reads the associated .gp2 GPS file if present in
  # the same directory, attaching trace coordinates to the GPR object.
  A <- readGPR(dsn = fpath)
  cat(sprintf("  traces: %d  |  window: %.1f ns", ncol(A), max(time(A))))

  # Try to get frequency from object; fall back to header file
  f_nom <- tryCatch(
    freq(A),
    error = function(e) get_frequency_from_header(fpath)
  )
  if (!is.na(f_nom)) {
    cat(sprintf("  |  freq: %g MHz", f_nom))
  }
  cat("\n")

  tz_info <- get_timezero_from_header(fpath)
  if (is.na(tz_info$sample) || is.na(tz_info$t0_ns)) {
    stop(
      "Could not compute header time-zero from .HD for: ", basename(fpath),
      "\nRequired fields: TIMEZERO AT POINT, NUMBER OF PTS/TRC, TOTAL TIME WINDOW."
    )
  }
  if (tz_info$sample > nrow(A)) {
    stop("Header TIMEZERO AT POINT (", tz_info$sample, ") exceeds number of samples (", nrow(A), ") for: ", basename(fpath))
  }

  # Keep RGPR plotting behavior, but force HD time-zero to be interpreted in ns.
  A_plot <- setTime0(A, rep(tz_info$t0_ns, ncol(A)))
  save_plot(A_plot, file.path(PLOTS_DIR, paste0(lname, "_01_raw.png")),
            ttl = paste(lname, "– Raw"))

  # ---- Time-zero detection ------------------------------------------------

  # Use header-derived t0 as initial estimate: t0 = sample * (TOTAL TIME WINDOW / NPTS)
  t0_init <- rep(tz_info$t0_ns, ncol(A))
  cat(sprintf("  Header TIMEZERO AT POINT: sample %d, dt %.3f ns -> t0 %.2f ns\n",
              tz_info$sample, tz_info$dt_ns, t0_init[1]))

  tfb <- firstBreak(A, w = T0_WINDOW, method = "coppens", thr = T0_THR)
  t0_refined <- firstBreakToTime0(tfb, A)

  # Refine starting t0 from first-break; keep header-based t0 where refinement fails.
  t0 <- t0_init
  good <- is.finite(t0_refined)
  t0[good] <- t0_refined[good]

  # Plot 02a: trace with t0 from header (scope test reference), no extra lines.
  # RGPR depth axis is anchored at the header-derived t0.
  png(file.path(PLOTS_DIR, paste0(lname, "_02a_time0_header.png")),
      width = PNG_W, height = PNG_H, res = PNG_RES)
  plot(A_plot[, 1], relTime0 = FALSE,
       xlim = c(0, min(100, max(time(A)))),
       main = paste(lname, "– Trace 1: t0 from header (", round(tz_info$t0_ns, 2), "ns)"))
  dev.off()

  # Update the object's t0 to the refined first-break value for plot 02b onwards.
  A_t0fb <- setTime0(A, t0)

  # Plot 02b: trace after t0 overwritten with firstBreakToTime0 result.
  # RGPR depth axis now anchored at the refined t0; blue line shows the raw tfb pick.
  png(file.path(PLOTS_DIR, paste0(lname, "_02b_time0_fb.png")),
      width = PNG_W, height = PNG_H, res = PNG_RES)
  plot(A_t0fb[, 1], relTime0 = FALSE,
       xlim = c(0, min(100, max(time(A)))),
       main = paste(lname, "– Trace 1: t0 from firstBreak (", round(t0[1], 2), "ns)"))
  abline(v = tfb[1], col = "blue", lwd = 2)
  legend("topright", legend = "firstBreak (tfb)",
         col = "blue", lwd = 2, bty = "n")
  dev.off()

  # ---- Step 3: time-zero correction ----------------------------------------
  A <- A %>%
    setTime0(t0) %>%
    time0Cor()

  save_plot(A, file.path(PLOTS_DIR, paste0(lname, "_03_time0cor.png")),
            ttl = paste(lname, "– After time-zero correction"))

  # ---- Step 4: dewow -------------------------------------------------------
  A <- dewow(A, type = "runmed", w = DEWOW_W)
  save_plot(A, file.path(PLOTS_DIR, paste0(lname, "_04_dewow.png")),
            ttl = paste(lname, "– After dewow"))

  # ---- Step 5: t-power gain (stronger than default) ------------------------
  alpha_strong <- TPOWER_ALPHA * 1.5
  A <- gain(A, type = "power",
            alpha = alpha_strong, te = TPOWER_TE, tcst = TPOWER_TCST)

  save_plot(A, file.path(PLOTS_DIR, paste0(lname, "_05_tpower.png")),
            ttl = paste(lname, "– After strong t-power gain"))

  # ---- Step 6: bandpass frequency filter -----------------------------------
  # Get nominal frequency for filter scaling
  f_nom <- tryCatch(
    freq(A),
    error = function(e) get_frequency_from_header(fpath)
  )

  if (is.na(f_nom)) {
    stop(
      "Bandpass filter requires antenna frequency, but it could not be determined for: ",
      basename(fpath),
      "\nCheck that the corresponding .HD file exists and contains 'NOMINAL FREQUENCY'."
    )
  } else {
    f_bp  <- c(F_LOW_FRAC * f_nom, F_HIGH_FRAC * f_nom)
    cat(sprintf("  Bandpass filter: %.0f – %.0f MHz\n", f_bp[1], f_bp[2]))
    A <- fFilter(A, f = f_bp, type = "bandpass", plotSpec = FALSE)

    save_plot(A, file.path(PLOTS_DIR, paste0(lname, "_06_filter.png")),
              ttl = paste(lname, "– After bandpass filter"))
  }

  # ---- Step 7: Kirchhoff migration ----------------------------------------
  # Collapses hyperbolic diffraction tails. Requires V_RADAR to be set.
  if (MIGRATE_ENABLED) {
    tryCatch({
      A <- migrate(A, type = "kirchhoff", vel = V_RADAR)
      save_plot(A, file.path(PLOTS_DIR, paste0(lname, "_07_migrated.png")),
                ttl = paste(lname, "– After Kirchhoff migration"))
    }, error = function(e) {
      warning("  migrate() failed for ", lname, ": ", conditionMessage(e),
              "\n  Skipping migration.")
    })
  }

  # ---- Step 8: deconvolution -----------------------------------------------
  # Spiking / Wiener deconvolution to compress the wavelet.
  # See: https://emanuelhuber.github.io/RGPR/10_RGPR_mixed-phase-wavelet-deconvolution/
  if (DECONV_ENABLED) {
    tryCatch({
      # For RGPR 0.0.9, spiking deconvolution requires W, wtr, nf, and mu.
      # After migration, use a short early-time window and conservative nf.
      W <- c(2, min(30, nrow(A) - 1))
      nf_use <- min(20, max(5, nrow(A) - 2))
      dec_out <- deconv(A, method = "spiking", W = W, wtr = 5, nf = nf_use, mu = 1e-5)
      if (is.list(dec_out) && !is.null(dec_out$x)) {
        A <- dec_out$x
      } else {
        A <- dec_out
      }
      save_plot(A, file.path(PLOTS_DIR, paste0(lname, "_08_deconv.png")),
                ttl = paste(lname, "– After deconvolution"))
    }, error = function(e) {
      warning("  deconv() failed for ", lname, ": ", conditionMessage(e),
              "\n  Skipping deconvolution.")
    })
  }

  # ---- Step 9: time window crop (0 to 100 ns) ------------------------------
  A <- crop(A, ylim = c(0, 100))
  save_plot(A, file.path(PLOTS_DIR, paste0(lname, "_09_window_0_100ns.png")),
            ttl = paste(lname, "– Windowed 0 to 100 ns"))

  # ---- Save processed data to PRC in Sensors & Software DT1 format --------
  out_base <- file.path(PRC_DIR, lname)
  writeGPR(A, fPath = out_base, type = "DT1", overwrite = TRUE)
  cat("  Saved processed data to:", paste0(out_base, ".DT1"), "\n")

  # Copy .gp2 GPS file to PRC so coordinates stay alongside the data.
  gp2_candidates <- list.files(
    dirname(fpath),
    pattern = paste0("^", lname, "\\.gp2$"),
    full.names = TRUE, ignore.case = TRUE
  )
  if (length(gp2_candidates) > 0) {
    file.copy(gp2_candidates[1],
              file.path(PRC_DIR, basename(gp2_candidates[1])),
              overwrite = TRUE)
    cat("  Copied GPS file:", basename(gp2_candidates[1]), "\n")
  } else {
    message("  No .gp2 file found for ", lname,
            " – coordinates will need to be added manually in Script 02.")
  }
}

cat("\n=== Script 01 complete. Processed files in:", PRC_DIR, "===\n")
cat("Next: run JuKa_02_survey.R\n")