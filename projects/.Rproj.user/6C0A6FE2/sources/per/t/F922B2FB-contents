
if(!require("ggplot2")) install.packages("ggplot2")
library(RGPR)
library(plotly)
library(ggplot2)

zop <- r"(D:\Projects\Radar_VRP_ZOP\ZOP-K3-K4_peilbuizen delft\DATA07\LINE01.DT1)"

x <- readGPR(dsn = zop)
x1 <- traceScaling(x, type="stat")
#plot(x1, col = palGPR("grey"))

ggplotly(x)
#ggplotGPR(x)
