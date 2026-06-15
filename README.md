# RGPR-projects

Deltares projects using RGPR.

## Windows Quick Install

### Prerequisites

- Install R from CRAN: https://cran.r-project.org/bin/windows/base/
- Install Rtools from CRAN: https://cran.r-project.org/bin/windows/Rtools/
- Install VS Code extension: **R** (by REditorSupport)

### Setup Steps

#### 1) Open R Terminal in VS Code

1. Open the Terminal pane: **Terminal > New Terminal**
2. Click the dropdown arrow next to the **+** button
3. Select **R Terminal**

#### 2) Install RGPR and Dependencies

Run this in the R terminal:

```r
source("setup_packages.R")
```

This installs:
- RGPR (main package)
- jsonlite, rlang, languageserver (required dependencies)

Wait for the success message.

#### 3) Verify Installation

Test that everything loaded correctly:

```r
library(RGPR)
frenkeLine00
plot(frenkeLine00)
```

#### 4) Run Project Scripts

From the R terminal in VS Code:

```r
source("projects/seismic_field_school.R")
```

**Note:** Project scripts have user-specific paths that you may need to adjust.

---

### Troubleshooting

If packages don't load automatically in future sessions, run this at the start of your R session:

```r
.libPaths(c("C:/Users/nieboer/R_packages", .libPaths()))
```
