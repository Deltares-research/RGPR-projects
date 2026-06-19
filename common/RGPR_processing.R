# =============================================================================
# RGPR_processing.R — Shared Recipe-Driven GPR Processing Engine
# =============================================================================
# Defines run_stage1(cfg): batch-processes raw DT1 files using an RGPR-like
# recipe with one call per line. No global variables — all settings in cfg.
#
# Usage from a project folder:
#   source("../../common/RGPR_processing.R")   # load engine
#   source("config.R")                  # defines: cfg <- list(...)
#   run_stage1(cfg)
#
# Recipe syntax (in recipe_steps.txt):
#   dewow(type = "runmed", w = 50)
#   gain(type = "power", alpha = 1.5, te = 200, tcst = 50)
#   fFilter(f = c(75, 325), type = "bandpass", plotSpec = FALSE)
#   migrate(type = "kirchhoff", vel = 0.1)
# =============================================================================

library(RGPR)
library(parallel)

`%||%` <- function(a, b) if (!is.null(a)) a else b

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

  format_one <- function(z) {
    if (is.function(z)) {
      nm <- deparse(substitute(z))
      if (!is.null(nm) && nzchar(nm)) return(nm)
      return("<function>")
    }
    if (is.language(z)) return(paste(deparse(z), collapse = " "))
    if (is.list(z) && !is.null(names(z))) {
      return(paste(vapply(z, format_one, character(1)), collapse = ","))
    }
    paste(as.character(z), collapse = ",")
  }

  vals <- vapply(args, format_one, character(1))
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

plot_path <- function(ctx, fun_name, occ_idx, plots_dir) {
  file.path(plots_dir, sprintf("%s_%s_%02d.png", ctx$lname, safe_key(fun_name), occ_idx))
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
    list(text = line, fun = fun_name, arg_exprs = arg_exprs, arg_names = arg_names)
  })
  parsed
}

eval_recipe_args <- function(call_def, A, ctx) {
  arg_exprs <- call_def$arg_exprs
  arg_names <- call_def$arg_names

  if (length(arg_exprs) == 0) {
    return(list(positional = list(), args = list()))
  }

  eval_env <- new.env(parent = .GlobalEnv)
  eval_env$x <- A
  eval_env$tfb <- ctx$tfb
  eval_env$current_t0 <- ctx$current_t0

  pos <- list()
  named <- list()

  for (i in seq_along(arg_exprs)) {
    nm <- arg_names[i]
    val <- eval(arg_exprs[[i]], envir = eval_env)
    if (is.null(nm) || identical(nm, "")) {
      pos[[length(pos) + 1L]] <- val
    } else {
      named[[nm]] <- val
    }
  }

  list(positional = pos, args = named)
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

write_run_report <- function(ctx, cfg) {
  save_reports <- cfg$save_run_reports %||% cfg$save_manifest %||% TRUE
  if (!isTRUE(save_reports)) return(invisible(NULL))

  report_dir <- cfg$run_reports_dir %||% file.path(cfg$data_dir, "run_reports")
  report_suffix <- cfg$run_report_suffix %||% "_run_report"
  dir.create(report_dir, showWarnings = FALSE, recursive = TRUE)
  mpath <- file.path(report_dir, paste0(ctx$lname, report_suffix, ".txt"))

  lines <- c(
    paste0("recipe_name=", cfg$recipe_name),
    paste0("recipe_version=", cfg$recipe_version),
    paste0("recipe_file=", cfg$recipe_file),
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

run_recipe_call <- function(call_def, A, ctx, occ_idx, cfg) {
  fun <- call_def$fun
  ev <- eval_recipe_args(call_def, A, ctx)
  pos_args <- ev$positional
  args <- ev$args
  on_error <- tolower(as.character(cfg$on_error %||% "abort"))
  if (!on_error %in% c("abort", "skip")) {
    stop("cfg$on_error must be 'abort' or 'skip'")
  }

  out <- tryCatch({
    if (fun == "plot") {
      f <- plot_path(ctx, fun, occ_idx, cfg$plots_dir)

      # Positional plot calls are evaluated against the runtime symbols (x, tfb, ...).
      if (length(pos_args) > 0) {
        png(f, width = cfg$png_w, height = cfg$png_h, res = cfg$png_res)
        ctx$plot_open <- TRUE
        ctx$plot_file <- f
        do.call(plot, c(pos_args, args))
        return(list(A = A, ctx = ctx, param = format_recipe_args(args)))
      }

      traces <- if (!is.null(args[["traces", exact = TRUE]])) args[["traces", exact = TRUE]] else NULL
      slices <- if (!is.null(args[["slices", exact = TRUE]])) args[["slices", exact = TRUE]] else NULL
      trace <- if (!is.null(args[["trace", exact = TRUE]])) as.integer(args[["trace", exact = TRUE]]) else NULL
      traces_for_subset <- traces

      # If a single trace index is provided via traces= and trace= is missing,
      # treat it as a trace plot for RGPR-like convenience.
      if (is.null(trace) && !is.null(traces) && length(traces) == 1L) {
        trace <- 1L
        traces_for_subset <- traces
      }

      args$traces <- NULL
      args$slices <- NULL
      args$trace <- NULL

      A_plot <- subset_gpr(A, traces = traces_for_subset, slices = slices)

      png(f, width = cfg$png_w, height = cfg$png_h, res = cfg$png_res)
      ctx$plot_open <- TRUE
      ctx$plot_file <- f

      if (is.null(trace)) {
        plot_args <- c(list(x = A_plot), args)
        tryCatch(
          do.call(plot, plot_args),
          error = function(e) do.call(plotFast, plot_args)
        )
      } else {
        # A_plot may already be a single-trace object/vector after subsetting.
        trace_data <- A_plot
        if (inherits(A_plot, "GPR")) {
          if (ncol(A_plot) < trace) {
            stop("plot() trace index out of bounds: ", trace, " (available traces: ", ncol(A_plot), ")")
          }
          trace_data <- A_plot[, trace]
        }

        plot_args <- c(list(x = trace_data, relTime0 = FALSE), args)
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
      if (is.character(args[["v", exact = TRUE]]) && length(args[["v", exact = TRUE]]) == 1 && tolower(args[["v", exact = TRUE]]) == "tfb") {
        if (is.null(ctx$tfb)) {
          stop("abline(v='tfb') requires firstBreak output")
        }

        trace_idx <- 1L
        if (!is.null(args[["traces", exact = TRUE]])) trace_idx <- normalize_index(args[["traces", exact = TRUE]])[1]
        if (!is.null(args[["trace", exact = TRUE]])) trace_idx <- as.integer(args[["trace", exact = TRUE]])[1]
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
      ctx$tfb <- invoke_recipe_function("firstBreak", positional_args = c(list(A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "firstBreakToTime0") {
      if (is.null(ctx$tfb)) stop("firstBreakToTime0 requires firstBreak output")
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      ctx$current_t0 <- invoke_recipe_function("firstBreakToTime0", positional_args = c(list(ctx$tfb, A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = ""))
    }

    if (fun == "setTime0") {
      ex <- extract_subset_args(args)
      args <- ex$args
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)

      if (length(pos_args) > 0 && is.null(args$t0)) {
        args$t0 <- pos_args[[1]]
        pos_args <- pos_args[-1]
      }

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
      A <- invoke_recipe_function("setTime0", positional_args = c(list(A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "time0Cor") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("time0Cor", positional_args = c(list(A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "dewow") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("dewow", positional_args = c(list(A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "gain") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("gain", positional_args = c(list(A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "fFilter") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("fFilter", positional_args = c(list(A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "migrate") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      A <- invoke_recipe_function("migrate", positional_args = c(list(A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "deconv") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      dec_out <- invoke_recipe_function("deconv", positional_args = c(list(A_call), pos_args), named_args = ex$args)
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
      A <- invoke_recipe_function("crop", positional_args = c(list(A_call), pos_args), named_args = ex$args)
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    if (fun == "writeGPR") {
      ex <- extract_subset_args(args)
      A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
      out_base <- file.path(cfg$prc_dir, ctx$lname)
      invoke_recipe_function("writeGPR", positional_args = c(list(A_call), pos_args), named_args = c(list(fPath = out_base, overwrite = TRUE), ex$args))
      gp2_candidates <- list.files(dirname(ctx$fpath), pattern = paste0("^", ctx$lname, "\\.gp2$"), full.names = TRUE, ignore.case = TRUE)
      if (length(gp2_candidates) > 0) {
        file.copy(gp2_candidates[1], file.path(cfg$prc_dir, basename(gp2_candidates[1])), overwrite = TRUE)
      }
      return(list(A = A, ctx = ctx, param = format_recipe_args(c(ex$args, list(traces = ex$traces, slices = ex$slices)))))
    }

    # Generic RGPR call: implicit first argument is the current GPR object.
    ex <- extract_subset_args(args)
    A_call <- subset_gpr(A, traces = ex$traces, slices = ex$slices)
    out_any <- invoke_recipe_function(fun, positional_args = c(list(A_call), pos_args), named_args = ex$args)

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

process_one_file <- function(fpath, recipe_calls, cfg) {
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

    res <- run_recipe_call(call_def, A, ctx, occ[[fun]], cfg)
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

  write_run_report(ctx, cfg)
  TRUE
}

run_stage1 <- function(cfg) {
  # ---- validate required cfg fields ----------------------------------------
  if (is.null(cfg$data_dir))  stop("cfg$data_dir is required")
  if (is.null(cfg$plots_dir)) stop("cfg$plots_dir is required")
  if (is.null(cfg$prc_dir))   stop("cfg$prc_dir is required")

  recipe_file <- cfg$recipe_file %||% "recipe_steps.txt"

  # ---- load + validate recipe -----------------------------------------------
  recipe_calls <- parse_recipe(recipe_file)
  validate_recipe(recipe_calls)

  if (isTRUE(cfg$print_plan %||% TRUE)) {
    cat("=== Recipe Loaded ===\n")
    cat("name/version :", cfg$recipe_name %||% "default", "/", cfg$recipe_version %||% "v1", "\n")
    cat("recipe file  :", recipe_file, "\n")
    for (i in seq_along(recipe_calls)) {
      cat(sprintf("  %02d. %s\n", i, recipe_calls[[i]]$text))
    }
    cat("=====================\n\n")
  }

  if (isTRUE(cfg$dry_run)) {
    cat("dry_run = TRUE; stopping before processing.\n")
    return(invisible(NULL))
  }

  # ---- output directories ---------------------------------------------------
  dir.create(cfg$plots_dir, showWarnings = FALSE, recursive = TRUE)
  dir.create(cfg$prc_dir,   showWarnings = FALSE, recursive = TRUE)

  # ---- discover input files -------------------------------------------------
  file_pattern <- cfg$file_pattern %||% "(?i)\\.DT1$"
  dt1_files <- sort(list.files(cfg$data_dir, pattern = file_pattern,
                               full.names = TRUE, ignore.case = TRUE))
  if (length(dt1_files) == 0) {
    stop("No DT1 files found matching pattern '", file_pattern, "' in: ", cfg$data_dir)
  }
  cat("Found", length(dt1_files), "DT1 file(s):\n")
  cat(paste0("  ", basename(dt1_files)), sep = "\n")
  cat("\n")

  if (isTRUE(cfg$test_mode)) {
    keep_n    <- min(as.integer(cfg$test_max %||% 1L), length(dt1_files))
    dt1_files <- dt1_files[seq_len(keep_n)]
    cat("Test mode: processing first", keep_n, "file(s).\n\n")
  }

  # ---- process files --------------------------------------------------------
  if (isTRUE(cfg$parallel) && length(dt1_files) > 1) {
    workers <- max(1L, min(as.integer(cfg$workers %||% 2L), length(dt1_files)))
    cat("Parallel mode: using", workers, "workers.\n")
    cl <- makeCluster(workers)
    on.exit(stopCluster(cl), add = TRUE)
    clusterExport(cl, varlist = ls(envir = .GlobalEnv), envir = .GlobalEnv)
    clusterExport(cl, varlist = c("cfg", "recipe_calls"), envir = environment())
    clusterEvalQ(cl, library(RGPR))
    out <- parLapply(cl, dt1_files,
                     function(fp, rc, c) process_one_file(fp, rc, c),
                     rc = recipe_calls, c = cfg)
    if (!all(unlist(out))) stop("One or more files failed in parallel mode")
  } else {
    for (i in seq_along(dt1_files)) {
      cat(sprintf("[%d/%d]", i, length(dt1_files)))
      process_one_file(dt1_files[i], recipe_calls, cfg)
    }
  }

  cat("\n=== Stage 01 complete. Processed files in:", cfg$prc_dir, "===\n")
  invisible(NULL)
}
