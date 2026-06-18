# JuKa GPR Processing Workflow

This folder contains three R scripts for batch processing GPR data in a three-stage pipeline.

## Quick Start

### 1. Initial Setup (one-time)

```bash
# Navigate to the Juka project folder in your terminal
cd /path/to/Juka

# Copy the example config to your local .env file
cp .env.example .env   # or just copy manually

# Edit .env with your paths and settings
# (use your preferred editor: Notepad++, VS Code, RStudio, etc.)
```

### 2. Edit Configuration

Open `.env` and update at least:
- `DATA_DIR` – path to your raw GPR data (e.g., `/path/to/your/gpr/data`)
- `V_RADAR` – radar wave velocity for your site (e.g., 0.1 m/ns)

All other settings have sensible defaults but can be tuned for your survey.

### 2b. Define Your Processing Recipe

Script 01 is recipe-driven. The processing flow is stored in
[recipe_steps.txt](recipe_steps.txt), with one complete call per line in a
syntax that stays close to RGPR tutorials.

Example recipe:

```r
setTime0(t0 = "header")
plot(main = "Raw")
plot(traces = 1, main = "Trace 1: t0 from header")
firstBreak(w = 5, method = "coppens", thr = 0.08)
firstBreakToTime0()
setTime0(t0 = "fb")
plot(traces = 1, main = "Trace 1: t0 from firstBreak")
abline(v = "tfb", trace = 1, col = "blue", lwd = 2)
time0Cor()
dewow(type = "runmed", w = 50)
gain(type = "power", alpha = 1.5, te = 200, tcst = 50)
fFilter(f = c(75, 325), type = "bandpass", plotSpec = FALSE)
migrate(type = "kirchhoff", vel = 0.1)
deconv(method = "spiking", W = c(2, 30), wtr = 5, nf = 20, mu = 1e-05)
crop(ylim = c(0, 100))
writeGPR(type = "DT1")
```

Rules:

1. Any callable RGPR exported function name is accepted.
2. Invalid order fails immediately.
3. Comments with `#` are allowed.
4. One complete call per line is required.
5. Flow within each file is always sequential.
6. Different files can run in parallel, controlled from `.env`.
7. `writeGPR()` is optional, so a recipe may also be plot-only.
8. `abline(...)` applies to the most recent `plot(...)` call and should appear right after that plot in the recipe.
9. `abline(v = "tfb", trace = k, ...)` draws the first-break time for trace `k` (defaults to trace 1).
10. For RGPR calls, the current GPR object is passed implicitly as the first argument (`x`).
11. If a call returns a non-GPR value, processing continues with the current GPR object unchanged.

Indexing convention in recipes (instead of using `x[...]`):

1. Do not write `x[, 15]`; write `traces = 15`.
2. Do not write `x[16, ]`; write `slices = 16`.
3. Lists/vectors are supported: `traces = c(1, 5, 9)`, `slices = c(10, 20)`.
4. This applies to `plot(...)` and to processing calls where subsetting is useful.

Important `.env` keys for the recipe engine:

1. `RECIPE_FILE`
2. `RECIPE_NAME`
3. `RECIPE_VERSION`
4. `RECIPE_DRY_RUN`
5. `PRINT_RECIPE_PLAN`
6. `FILE_PARALLEL_ENABLED`
7. `FILE_PARALLEL_WORKERS`
8. `STEP_ON_ERROR_DEFAULT`
9. `TEST_MODE`
10. `TEST_MAX_FILES`

Design choice:

1. Global runtime settings stay in `.env`.
2. Step-local processing parameters belong in `recipe_steps.txt`.

Manifest output:

1. Per-file manifest is saved in [plots/manifests](plots/manifests).
2. Includes recipe name/version, executed calls, and effective parameters.

### 3. Run in R

Navigate to this folder, then run the three scripts in order:

```r
setwd("/path/to/Juka")

# Stage 1: Batch processing (time-zero, dewow, filter, gain, deconv, migration)
source("01_recipe_processing.R")

# Stage 2: Survey assembly, coordinate attachment, topographic correction
source("JuKa_02_survey.R")

# Stage 3: Envelope computation, time-slice interpolation, 3-D export
source("JuKa_03_timeslices.R")
```

**Or, if you `cd` into the folder first before launching R, you don't need `setwd()`:**

```bash
cd /path/to/Juka
R  # or Rscript, or open in RStudio
```

Then in R:
```r
source("01_recipe_processing.R")
source("JuKa_02_survey.R")
source("JuKa_03_timeslices.R")
```

## Files in This Folder

| File | Purpose |
|------|---------|
| `01_recipe_processing.R` | Stage 01 entrypoint in this project; delegates to shared recipe engine in `../../RGPR_processing.R` |
| `JuKa_02_survey.R` | Survey assembly: reads from `PRC/`, attaches GPS coordinates from `.gp2` files, applies topographic correction |
| `JuKa_03_timeslices.R` | Envelope & slicing: computes signal envelope, interpolates 3-D data cube, exports slices as PNG and GeoTIFF |
| `.env.example` | Template configuration file – copy to `.env` and customize |
| `_config.R` | Configuration loader – reads `.env` and sets all global variables |

## Configuration (`.env`)

All user-facing settings are in `.env`:

- **Paths** (`DATA_DIR`, etc.)
- **Physics** (`V_RADAR`, `DECONV_ENABLED`, `MIGRATE_ENABLED`)
- **Filters** (`F_LOW_FRAC`, `F_HIGH_FRAC`, `DEWOW_W`)
- **Gain** (`TPOWER_ALPHA`, `TPOWER_TE`, `TPOWER_TCST`)
- **Time-slicing** (`DX`, `DY`, `DZ`, `MBA_H`)
- **Output** (`PNG_W`, `PNG_H`, `PNG_RES`)

`.env` is **not** committed to git (see `.gitignore`), so your local paths and settings stay private.

## Input Data Structure

Your raw GPR data folder (set in `DATA_DIR` in `.env`) should contain:

```
your_gpr_data_folder/
  Line3-ch2.DT1
  Line3-ch2.HD
  Line3-ch2.gp2
  Line4-ch2.DT1
  Line4-ch2.HD
  Line4-ch2.gp2
  ...
  Line14-ch2.DT1
  Line14-ch2.HD
  Line14-ch2.gp2
```

The scripts auto-discover all `Line*-ch2.DT1` files and process them in batch.

## Output Structure

After running all three scripts, outputs are created under your `DATA_DIR`:

```
your_gpr_data_folder/
  PRC/
    Line3-ch2.DT1          (processed)
    Line3-ch2_topoCorr.DT1 (topo-corrected)
    ...
  plots/
    Line3-ch2_01_raw.png
    Line3-ch2_02_dewow.png
    ...
    survey_planview.png
    all_profiles_topo.png
    slices/
      slice_001_t00.5ns.png
      slice_002_t02.5ns.png
      ...
    rasters/
      slice_001_t00.5ns.tif
      ...
```

## Troubleshooting

### "Configuration file '.env' not found"
→ Copy `.env.example` to `.env` and edit it.

### "No DT1 files found in …"
→ Check `DATA_DIR` in `.env` – make sure the path is correct and the files exist.

### "Package 'raster' not found" (Script 03)
→ The script auto-installs `raster` if missing. If the install fails, run manually:
```r
install.packages("raster")
```

### Zigzag direction reversed?
→ In `JuKa_03_timeslices.R`, find the line `reverse(SU, id = "zigzag")` and change `id` if needed:
- `id = "zigzag"` → reverses even-indexed lines (default)
- `id = seq(1, length(SU), by = 2)` → reverses odd-indexed lines instead

## Notes

- **Scripts are idempotent**: you can re-run them without losing data (output files are overwritten).
- **Processing is sequential**: always run Script 01 first, then 02, then 03.
- **GPS coordinates**: The scripts expect `.gp2` (Sensors & Software GPS) files alongside the `.DT1` files. If missing, Script 02 will warn but continue.
- **Radar velocity**: Adjust `V_RADAR` in `.env` based on your site soil/geology (typical: 0.06–0.13 m/ns).

## References

RGPR tutorials:  
- [Processing with pipe operator](https://emanuelhuber.github.io/RGPR/03_RGPR_tutorial_processing-GPR-data-with-pipe-operator/)
- [Add coordinates & survey](https://emanuelhuber.github.io/RGPR/04_RGPR_tutorial_GPR-data-survey/)
- [Time/depth slice interpolation](https://emanuelhuber.github.io/RGPR/05_RGPR_tutorial_GPR-data-time-slice-interpolation-3D/)
- [Deconvolution](https://emanuelhuber.github.io/RGPR/10_RGPR_mixed-phase-wavelet-deconvolution/)
