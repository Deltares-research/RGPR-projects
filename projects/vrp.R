if(!require("ggplot2")) install.packages("ggplot2")
if(!require("imager")) install.packages("imager")
if(!require("akima")) install.packages("akima")

library(ggplot2)
library(RGPR)
library(imager)
library(akima)

DIR <- r"(D:\Projects\Radar_VRP_ZOP\VRP - Walgeren_noordstraat21\DATA06)"
setwd(DIR)

vrp10 <- "LINE10.DT1"
vrp11 <- "LINE11.DT1"
vrp12 <- "LINE12.DT1"
vrp13 <- "LINE13.DT1"
vrp14 <- "LINE14.DT1"
vrp99 <- "LINE99.DT1"

x <- readGPR(dsn = vrp14)

new_x <- seq(min(x@depth), max(x@depth), length.out = 1500)
new_y <- seq(min(x@traces), max(x@traces), length.out = 162)


interpolated_data <- with(akima::interp(x = x@depth, y = x@traces, z = as.vector(x@data), 
                                        xo = new_x, yo = new_y))

plot(interpolated_data)

#attributes(x)

resize <- imager::resize(as.cimg(x@data), 2*dim(x)[1], 2*dim(x)[2], interpolation_type = 2)

plot(resize)

plot(x)
plot(x2)



#ggplotGPR(x2)


#x1 <- dewow(x, type = "runmed", w = 100)     # dewowing
#plot(x) 

#plot(x1 - x) # difference between dewowed and original data

#x2 <- fFilter(x1, f = c(5, 20, 200, 300), type = "bandpass", plotSpec = TRUE)

#x3 <- traceScaling(x2, type="stat")

#plot(x, col = palGPR("grey"))