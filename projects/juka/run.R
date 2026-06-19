# =============================================================================
# Stage 01 — Recipe-driven batch processing
# =============================================================================
# Edit config.R (paths and settings) and recipe_steps.txt (processing steps),
# then run this script.
# =============================================================================

source("../../common/RGPR_processing.R")   # load shared processing engine
source("config.R")                  # defines: cfg <- list(...)
run_stage1(cfg)
