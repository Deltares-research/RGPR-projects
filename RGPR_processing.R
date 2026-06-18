# =============================================================================
# RGPR - Script 01: Recipe-Driven Batch GPR Processing
# =============================================================================
# Processing steps are defined in RECIPE_FILE as one call per line, using an
# RGPR-like syntax without the pipe operator and without the object name.
#
# Example:
#   plot(main = "Raw")
#   firstBreak(w = 5, method = "coppens", thr = 0.08)
#   firstBreakToTime0()
#   setTime0()
#   time0Cor()
#   dewow(type = "runmed", w = 50)
#
# Global runtime settings stay in .env. Step parameters belong in the recipe.
# =============================================================================

library(RGPR)
library(parallel)

if (file.exists("_config.R")) {
  source("_config.R")
} else {
  stop("Could not find _config.R in current working directory. Run this from a project folder.")
}

if (!exists("RECIPE_FILE", envir = .GlobalEnv)) RECIPE_FILE <- "recipe_steps.txt"
if (!exists("RECIPE_NAME", envir = .GlobalEnv)) RECIPE_NAME <- "default"
if (!exists("RECIPE_VERSION", envir = .GlobalEnv)) RECIPE_VERSION <- "v2"
if (!exists("RECIPE_DRY_RUN", envir = .GlobalEnv)) RECIPE_DRY_RUN <- FALSE
if (!exists("PRINT_RECIPE_PLAN", envir = .GlobalEnv)) PRINT_RECIPE_PLAN <- TRUE
if (!exists("TEST_MODE", envir = .GlobalEnv)) TEST_MODE <- TRUE
if (!exists("TEST_MAX_FILES", envir = .GlobalEnv)) TEST_MAX_FILES <- 1
if (!exists("FILE_PARALLEL_ENABLED", envir = .GlobalEnv)) FILE_PARALLEL_ENABLED <- FALSE
if (!exists("FILE_PARALLEL_WORKERS", envir = .GlobalEnv)) FILE_PARALLEL_WORKERS <- 2
if (!exists("STEP_ON_ERROR_DEFAULT", envir = .GlobalEnv)) STEP_ON_ERROR_DEFAULT <- "abort"
if (!exists("SAVE_MANIFEST", envir = .GlobalEnv)) SAVE_MANIFEST <- TRUE

is_true <- function(x) {
  isTRUE(x) || (is.character(x) && toupper(x) == "TRUE")
}

safe_key <- function(x) {
  gsub("[^A-Za-z0-9]+", "_", x)
}

get_hd_numeric <- function(dt1_path, key_pattern) {
  hd_path <- sub("\\.DT1$", ".HD", dt1_path, ignore.case = TRUE)
  if (!file.exists(hd_path)) return(NA_real_)
  hd_content <- readLines(hd_path, warn = FALSE)
  line <- grep(key_pattern, hd_content, ignore.case = TRUE, value = TRUE)
  if (length(line) == 0) return(NA_real_)
  suppressWarnings(as.numeric(sub(".*=\\s*([0-9.]+).*", "\\1", line[1])))
}

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

save_rgpr_plot <- function(x, fpath, ttl = NULL, extra_args = list()) {
  png(fpath, width = PNG_W, height = PNG_H, res = PNG_RES)
  on.exit(dev.off(), add = TRUE)
  args <- c(list(x = x), extra_args)
  if (!is.null(ttl) && is.null(args$main)) args$main <- ttl
  tryCatch(
    do.call(plot, args),
    error = function(e) do.call(plotFast, args)
  )
}

save_trace_plot <- function(x, fpath, trace = 1, ttl = NULL, extra_args = list()) {
  png(fpath, width = PNG_W, height = PNG_H, res = PNG_RES)
  on.exit(dev.off(), add = TRUE)
  args <- c(list(x = x[, trace], relTime0 = FALSE), extra_args)
  if (is.null(args$xlim)) args$xlim <- c(0, min(100, max(time(x))))
  if (!is.null(ttl) && is.null(args$main)) args$main <- ttl
  do.call(plot, args)
}

normalize_index <- function(x) {
  if (is.null(x)) return(NULL)
  if (is.list(x)) x <- unlist(x, recursive = TRUE, use.names = FALSE)
  as.integer(x)
}

subset_gpr <- function(A, traces = NULL, slices = NULL) {
  tr <- normalize_index(traces)
  sl <- normalize_index(slices)
  if (!is.null(sl) && !is.null(tr)) return(A[sl, tr])
  if (!is.null(sl)) return(A[sl, ])
  if (!is.null(tr)) return(A[, tr])
  A
}

extract_subset_args <- function(args) {
  traces <- if (!is.null(args$traces)) args$traces else NULL
  slices <- if (!is.null(args$slices)) args$slices else NULL
  args$traces <- NULL
  args$slices <- NULL
  list(args = args, traces = traces, slices = slices)
}

format_recipe_args <- function(args) {
  if (length(args) == 0) return("")
  args <- args[!vapply(args, is.null, logical(1))]
  if (length(args) == 0) return("")
  vals <- vapply(args, function(z) paste(z, collapse = ","), character(1))
  paste(names(vals), vals, sep = "=", collapse = ";")
}

invoke_recipe_function <- function(fun_name, positional_args = list(), named_args = list()) {
  eval_env <- new.env(parent = .GlobalEnv)
  call_parts <- list(as.name(fun_name))
  names(call_parts) <- ""

  if (length(positional_args) > 0) {
    for (i in seq_along(positional_args)) {
      nm <- paste0("pos_", i)
      assign(nm, positional_args[[i]], envir = eval_env)
      call_parts[[length(call_parts) + 1L]] <- as.name(nm)
      names(call_parts)[length(call_parts)] <- ""
    }
  }

  if (length(named_args) > 0) {
    for (nm in names(named_args)) {
      obj_name <- paste0("arg_", safe_key(nm))
      assign(obj_name, named_args[[nm]], envir = eval_env)
      call_parts[[length(call_parts) + 1L]] <- as.name(obj_name)
      names(call_parts)[length(call_parts)] <- nm
    }
  }

  eval(as.call(call_parts), envir = eval_env)
}

plot_path <- function(ctx, fun_name, occ_idx) {
  file.path(PLOTS_DIR, sprintf("%s_%02d_%s_%02d.png", ctx$lname, ctx$step_index, safe_key(fun_name), occ_idx))
}

parse_recipe <- function(path) {
  if (!file.exists(path)) stop("Recipe file not found: ", path)
  raw_lines <- readLines(path, warn = FALSE)
  raw_lines <- trimws(raw_lines)
  raw_lines <- raw_lines[raw_lines != ""]
  raw_lines <- raw_lines[!grepl("^#", raw_lines)]
  if (length(raw_lines) == 0) stop("Recipe file is empty: ", path)

  parsed <- lapply(raw_lines, function(line) {
    expr <- parse(text = line, keep.source = FALSE)[[1]]
    if (!is.call(expr)) stop("Recipe line is not a call: ", line)
    fun_name <- as.character(expr[[1]])
    arg_exprs <- as.list(expr[-1])
    arg_names <- names(arg_exprs)
    values <- list()
    for (i in seq_along(arg_exprs)) {
      nm <- arg_names[i]
      if (is.null(nm) || identical(nm, "")) {
        stop("All recipe arguments must be named: ", line)
      }
      values[[nm]] <- eval(arg_exprs[[i]], envir = baseenv())
    }
    list(text = line, fun = fun_name, args = values)
  })
  parsed
}

get_recipe_function_catalog <- function() {
  ns <- asNamespace("RGPR")
  ex <- sort(getNamespaceExports("RGPR"))
  ex <- ex[grepl("^[A-Za-z][A-Za-z0-9._]*$", ex)]
  ex <- ex[!grepl("<$|>$", ex)]
  ex <- ex[vapply(ex, function(nm) exists(nm, envir = ns, inherits = FALSE) && is.function(get(nm, envir = ns)), logical(1))]
  unique(c(
    "plot",
    "abline",
    "firstBreak",
    "firstBreakToTime0",
    "setTime0",
    ex
  ))
}

validate_recipe <- function(recipe_calls) {
  valid <- get_recipe_function_catalog()

  funs <- vapply(recipe_calls, `[[`, character(1), "fun")
  unknown <- setdiff(unique(funs), valid)
  if (length(unknown) > 0) {
    stop("Unknown recipe function(s): ", paste(unknown, collapse = ", "))
  }

  require_before <- function(step, required_before) {
    idx <- which(funs == step)
    if (length(idx) == 0) return(invisible(NULL))
    for (i in idx) {
      prior <- if (i > 1) funs[1:(i - 1)] else character(0)
      miss <- setdiff(required_before, prior)
      if (length(miss) > 0) {
        stop("Invalid recipe order: '", step, "' requires prior step(s): ", paste(miss, collapse = ", "))
      }
    }
  }

  require_before("firstBreakToTime0", c("firstBreak"))
  require_before("time0Cor", c("setTime0"))
}

write_manifest <- function(ctx) {
  if (!is_true(SAVE_MANIFEST)) return(invisible(NULL))
  mdir <- file.path(PLOTS_DIR, "manifests")
  dir.create(mdir, showWarnings = FALSE, recursive = TRUE)
  mpath <- file.path(mdir, paste0(ctx$lname, "_manifest.txt"))

  lines <- c(
    paste0("recipe_name=", RECIPE_NAME),
    paste0("recipe_version=", RECIPE_VERSION),
    paste0("recipe_file=", RECIPE_FILE),
    paste0("file=", basename(ctx$fpath)),
    paste0("header_timezero_sample=", ctx$tz_info$sample),
    paste0("header_timezero_ns=", format(ctx$tz_info$t0_ns, scientific = FALSE)),
    "",
    "calls=",
    ctx$manifest_calls,
    "",
    "call_parameters=",
    ctx$manifest_params
  )
  writeLines(lines, mpath)
}

run_recipe_call <- function(call_def, A, ctx, occ_idx) {
  fun <- call_def$fun
  args <- call_def$args
  on_error <- tolower(as.character(STEP_ON_ERROR_DEFAULT))
  if (!on_error %in% c("abort", "skip")) {
    stop("STEP_ON_ERROR_DEFAULT must be 'abort' or 'skip'")
  }

  out <- tryCatch({
    if (fun == "plot") {
      f <- plot_path(ctx, fun, occ_idx)
      traces <- if (!is.null(args$traces)) args$traces else NULL
      slices <- if (!is.null(args$slices)) args$slices else NULL
      trace <- if (!is.null(args$trace)) as.integer(args$trace) else NULL
      args$traces <- NULL
      args$slices <- NULL
      args$trace <- NULL

      A_plot <- subset_gpr(A, traces = traces, slices = slices)

      png(f, width = PNG_W, height = PNG_H, res = PNG_RES)
      ctx$plot_open <- TRUE
      ctx$plot_file <- f

      if (is.null(trace)) {
        plot_args <- c(list(x = A_plot), args)
        tryCatch(
          do.call(plot, plot_args),
          error = function(e) do.call(plotFast, plot_args)
        )
      } else {
        plot_args <- c(list(x = A_plot[, trace], relTime0 = FALSE), args)
        if (is.null(plot_args$xlim)) plot_args$xlim <- c(0, min(100, max(time(A_plot))))
        do.call(plot, plot_args)
      }
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(args, list(traces = traces, slices = slices, trace = trace)))))
    }

    if (fun == "abline") {
      if (is.null(ctx$plot_open) || !isTRUE(ctx$plot_open)) {
        stop("abline() requires an active plot() call immediately before it")
      }
      param <- NULL

      # Allow explicit symbolic overlay: abline(v = "tfb", trace = 1)
      if (is.character(args$v) && length(args$v) == 1 && tolower(args$v) == "tfb") {
        if (is.null(ctx$tfb)) {
          stop("abline(v='tfb') requires firstBreak output")
        }

        trace_idx <- 1L
        if (!is.null(args$traces)) trace_idx <- normalize_index(args$traces)[1]
        if (!is.null(args$trace)) trace_idx <- as.integer(args$trace)[1]
        if (!is.finite(trace_idx) || trace_idx < 1L) {
          stop("abline(v='tfb') requires a valid positive trace index")
        }
        if (trace_idx > length(ctx$tfb)) {
          stop("abline(v='tfb') trace index exceeds firstBreak output length")
        }

        args$v <- as.numeric(ctx$tfb[trace_idx])
        args$trace <- NULL
        args$traces <- NULL
        param <- paste0("v=tfb;trace=", trace_idx, ";resolved_v=", format(args$v, scientific = FALSE))
      }

      do.call(abline, args)
      if (is.null(param)) param <- format_recipe_args(args)
      return(list(A = A, ctx = ctx, param = param))
    }

    if (fun == "firstBreak") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      ctx$tfb <- invoke_recipe_function("firstBreak", positional_args = list(A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "firstBreakToTime0") {
      if (is.null(ctx$tfb)) stop("firstBreakToTime0 requires firstBreak output")
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      ctx$current_t0 <- invoke_recipe_function("firstBreakToTime0", positional_args = list(ctx$tfb, A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = ""))
    }

    if (fun == "setTime0") {
      ex <- extract_subset_args(args)
      args <- ex$args
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)

      if (is.null(args$t0)) {
        if (is.null(ctx$current_t0)) stop("setTime0() requires current t0 (run firstBreakToTime0 first or pass t0='header')")
        A <- setTime0(A_call, ctx$current_t0)
        return(list(A = A, ctx = ctx, param = paste0("t0=fb;value[1]=", round(ctx$current_t0[1], 4), ";", format_recipe_args(list(traces = ex$traces, slices = ex$slices)))))
      }

      if (is.character(args$t0) && length(args$t0) == 1) {
        key <- tolower(args$t0)
        if (key == "header") {
          A <- setTime0(A_call, ctx$header_t0)
          return(list(A = A, ctx = ctx, param = paste0("t0=header;value[1]=", round(ctx$header_t0[1], 4), ";", format_recipe_args(list(traces = ex$traces, slices = ex$slices)))))
        }
        if (key == "fb") {
          if (is.null(ctx$current_t0)) stop("setTime0(t0='fb') requires firstBreakToTime0 output")
          A <- setTime0(A_call, ctx$current_t0)
          return(list(A = A, ctx = ctx, param = paste0("t0=fb;value[1]=", round(ctx$current_t0[1], 4), ";", format_recipe_args(list(traces = ex$traces, slices = ex$slices)))))
        }
        stop("setTime0 t0 keyword must be 'header' or 'fb'")
      }

      # Numeric/manual t0, passed directly to RGPR.
      A <- invoke_recipe_function("setTime0", positional_args = list(A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "time0Cor") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("time0Cor", positional_args = list(A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "dewow") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("dewow", positional_args = list(A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "gain") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("gain", positional_args = list(A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "fFilter") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("fFilter", positional_args = list(A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "migrate") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("migrate", positional_args = list(A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "deconv") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      dec_out <- invoke_recipe_function("deconv", positional_args = list(A_call), named_args = ex$args)
      if (is.list(dec_out) && !is.null(dec_out$x)) {
        A <- dec_out$x
      } else {
        A <- dec_out
      }
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "crop") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("crop", positional_args = list(A_call), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "writeGPR") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      out_base <- file.path(PRC_DIR, ctx$lname)
      invoke_recipe_function("writeGPR", positional_args = list(A_call), named_args = c(list(fPath = out_base, overwrite = TRUE), ex$args))
      gp2_candidates <- list.files(dirname(ctx$fpath), pattern = paste0("^", ctx$lname, "\\.gp2$"), full.names = TRUE, ignore.case = TRUE)
      if (length(gp2_candidates) > 0) {
        file.copy(gp2_candidates[1], file.path(PRC_DIR, basename(gp2_candidates[1])), overwrite = TRUE)
      }
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    # Generic RGPR call: implicit first argument is the current GPR object.
    ex <- extract_subset_args(args)
    A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
    out_any <- invoke_recipe_function(fun, positional_args = list(A_call), named_args = ex$args)

    if (inherits(out_any, "GPR")) {
      A <- out_any
    } else if (is.list(out_any) && !is.null(out_any$x) && inherits(out_any$x, "GPR")) {
      A <- out_any$x
    } else {
      ctx$last_value <- out_any
    }

    return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
  }, error = function(e) list(error = e))

  if (!is.null(out$error)) {
    msg <- conditionMessage(out$error)
    if (on_error == "skip") {
      warning("Recipe call failed and was skipped: ", call_def$text, " | ", msg)
      ctx$manifest_calls <- c(ctx$manifest_calls, paste0(call_def$text, " [SKIPPED]"))
      ctx$manifest_params <- c(ctx$manifest_params, paste0("error=", msg))
      return(list(A = A, ctx = ctx))
    }
    stop("Recipe call failed: ", call_def$text, " | ", msg)
  }

  out
}

process_one_file <- function(fpath, recipe_calls) {
  lname <- tools::file_path_sans_ext(basename(fpath))
  cat("\nProcessing:", lname, "\n")

  A <- readGPR(dsn = fpath)
  cat(sprintf("  traces: %d | window: %.1f ns\n", ncol(A), max(time(A))))

  tz_info <- get_timezero_from_header(fpath)
  if (is.na(tz_info$sample) || is.na(tz_info$t0_ns)) {
    stop("Could not compute header time-zero from .HD for: ", basename(fpath))
  }
  if (tz_info$sample > nrow(A)) {
    stop("Header TIMEZERO AT POINT (", tz_info$sample, ") exceeds number of samples (", nrow(A), ") for: ", basename(fpath))
  }

  cat(sprintf("  Header TIMEZERO AT POINT: sample %d, dt %.3f ns -> t0 %.2f ns\n", tz_info$sample, tz_info$dt_ns, tz_info$t0_ns))

  ctx <- list(
    fpath = fpath,
    lname = lname,
    tz_info = tz_info,
    header_t0 = rep(tz_info$t0_ns, ncol(A)),
    current_t0 = NULL,
    tfb = NULL,
    plot_open = FALSE,
    plot_file = NULL,
    step_index = 0L,
    manifest_calls = character(0),
    manifest_params = character(0),
    last_value = NULL
  )

  occ <- list()
  for (i in seq_along(recipe_calls)) {
    call_def <- recipe_calls[[i]]
    fun <- call_def$fun
    if (is.null(occ[[fun]])) {
      occ[[fun]] <- 1L
    } else {
      occ[[fun]] <- occ[[fun]] + 1L
    }
    ctx$step_index <- i

    if (isTRUE(ctx$plot_open) && recipe_calls[[i]]$fun != "abline") {
      dev.off()
      ctx$plot_open <- FALSE
      ctx$plot_file <- NULL
    }

    res <- run_recipe_call(call_def, A, ctx, occ[[fun]])
    A <- res$A
    ctx <- res$ctx
    if (!is.null(res$param)) {
      ctx$manifest_calls <- c(ctx$manifest_calls, call_def$text)
      ctx$manifest_params <- c(ctx$manifest_params, res$param)
    }
  }

  if (isTRUE(ctx$plot_open)) {
    dev.off()
    ctx$plot_open <- FALSE
    ctx$plot_file <- NULL
  }

  write_manifest(ctx)
  TRUE
}

recipe_calls <- parse_recipe(RECIPE_FILE)
validate_recipe(recipe_calls)

if (is_true(PRINT_RECIPE_PLAN)) {
  cat("=== Recipe Loaded ===\n")
  cat("name/version :", RECIPE_NAME, "/", RECIPE_VERSION, "\n")
  cat("recipe file  :", RECIPE_FILE, "\n")
  for (i in seq_along(recipe_calls)) {
    cat(sprintf("  %02d. %s\n", i, recipe_calls[[i]]$text))
  }
  cat("=====================\n\n")
}

if (is_true(RECIPE_DRY_RUN)) {
  cat("RECIPE_DRY_RUN=TRUE; stopping before processing.\n")
  quit(save = "no")
}

dir.create(PLOTS_DIR, showWarnings = FALSE, recursive = TRUE)
dir.create(PRC_DIR, showWarnings = FALSE, recursive = TRUE)

dt1_files <- sort(list.files(DATA_DIR, pattern = "^Line[0-9]+-ch2\\.DT1$", full.names = TRUE, ignore.case = TRUE))
if (length(dt1_files) == 0) {
  stop("No DT1 files matching 'Line*-ch2.DT1' found in: ", DATA_DIR)
}

cat("Found", length(dt1_files), "DT1 file(s):\n")
cat(paste0("  ", basename(dt1_files)), sep = "\n")
cat("\n")

if (is_true(TEST_MODE)) {
  keep_n <- min(as.integer(TEST_MAX_FILES), length(dt1_files))
  dt1_files <- dt1_files[seq_len(keep_n)]
  cat("Test mode: processing first", keep_n, "file(s).\n\n")
}

if (is_true(FILE_PARALLEL_ENABLED) && length(dt1_files) > 1) {
  workers <- max(1L, min(as.integer(FILE_PARALLEL_WORKERS), length(dt1_files)))
  cat("Parallel mode: using", workers, "workers.\n")
  cl <- makeCluster(workers)
  on.exit(stopCluster(cl), add = TRUE)
  clusterExport(cl, varlist = ls(), envir = environment())
  clusterEvalQ(cl, { library(RGPR); NULL })
  out <- parLapply(cl, dt1_files, function(fp, rc) process_one_file(fp, rc), rc = recipe_calls)
  if (!all(unlist(out))) stop("One or more files failed in parallel mode")
} else {
  for (i in seq_along(dt1_files)) {
    cat(sprintf("[%d/%d]", i, length(dt1_files)))
    process_one_file(dt1_files[i], recipe_calls)
  }
}

cat("\n=== Script 01 complete. Processed files in:", PRC_DIR, "===\n")
cat("Next: run your project survey script (for JuKa: JuKa_02_survey.R).\n")
