
suppressPackageStartupMessages(
	library(RGPR, warn.conflicts = FALSE, quietly = TRUE)
)

DIR <- r"(C:\Projects\Universiteit Utrecht - Seismic Field School\data\20240603 - sfs uithof\250 mHz)"
x <- readGPR(dsn = file.path(DIR, "Line1-ch2.DT1"))
plotFast(x)

tfb <- firstBreak(x, w = 10, method = "coppens", thr = 0.05)
plot(x[,1], relTime0 = FALSE, xlim = c(0, 100))

t0 <- firstBreakToTime0(tfb[1], x[,1])
abline(v = c(tfb[1], t0[1]), col = c("green", "blue"))

time0(x) <- t0
x1 <- dcshift(x) 
plotFast(x1)


x2 <- dewow(x1, type = "runmed", w = 50)
plotFast(x2)

x3 <- time0Cor(x2)
plotFast(x3)

x4 <- fFilter(x3, f = c(100, 280), type = "low", plotSpec = FALSE)
plotFast(x4)

x5 <- gain(x4, type = "agc", w =  5)
plotFast(x5)