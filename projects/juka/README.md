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

### 3. Run in R

Navigate to this folder, then run the three scripts in order:

```r
setwd("/path/to/Juka")

# Stage 1: Batch processing (time-zero, dewow, filter, gain, deconv, migration)
source("JuKa_01_processing.R")

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
source("JuKa_01_processing.R")
source("JuKa_02_survey.R")
source("JuKa_03_timeslices.R")
```

## Files in This Folder

| File | Purpose |
|------|---------|
| `JuKa_01_processing.R` | Batch processing: loads raw `.DT1` files, applies processing chain (dewow, filtering, gain, etc.), saves to `PRC/` |
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
