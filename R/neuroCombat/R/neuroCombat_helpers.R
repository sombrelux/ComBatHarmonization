# This is a copy of the original code from the standard version of the
# sva package that can be found at
# https://bioconductor.org/packages/release/bioc/html/sva.html 
# The original and present code is under the Artistic License 2.0.
# If using this code, make sure you agree and accept this license.  


.betaNA <- function(yy,designn){
      designn <- designn[!is.na(yy),]
      yy <- yy[!is.na(yy)]
      B <- solve(crossprod(designn), crossprod(designn, yy))
      B
}

.checkNARows <- function(dat){
	nas <- rowSums(is.na(dat))
	ns <- sum(nas==ncol(dat))
	if (ns>0){
	  message <- paste0(ns, " rows (features) were found to have missing values for all samples. Please remove these rows before running ComBat.")
	  stop(message)
	}
}

.checkConstantRows <- function(dat){
	sds <- rowSds(dat, na.rm=TRUE)
	ns <- sum(sds==0)
	if (ns>0){
	  message <- paste0(ns, " rows (features) were found to be constant across samples. Please remove these rows before running ComBat.")
	  stop(message)
	}
}



.checkDesign <- function(design, n.batch){
  # Check if the design is confounded
  if(qr(design)$rank<ncol(design)){
    if(ncol(design)==(n.batch+1)){
      stop("[combat] The covariate is confounded with batch. Remove the covariate and rerun ComBat.")
    }
    if(ncol(design)>(n.batch+1)){
      if((qr(design[,-c(1:n.batch)])$rank<ncol(design[,-c(1:n.batch)]))){
        stop('The covariates are confounded. Please remove one or more of the covariates so the design is not confounded.')
      } else {
        stop("At least one covariate is confounded with batch. Please remove confounded covariates and rerun ComBat.")
      }
    }
  }
  design
}


getDataDict <- function(batch, mod, verbose, mean.only, ref.batch=NULL){
    batch <- as.factor(batch)
    n.batch <- nlevels(batch)
    batches <- lapply(levels(batch), function(x)which(batch==x))
    n.batches <- sapply(batches, length)
    n.array <- sum(n.batches)
    batchmod <- model.matrix(~-1+batch)  
    if (verbose) cat("[combat] Found",nlevels(batch),'batches\n')
    if(any(n.batches==1) & mean.only==FALSE){
      stop("Found one site with only one sample. Consider using the mean.only=TRUE option")
    }
    if (!is.null(ref.batch)){
        if (!(ref.batch%in%levels(batch))) {
            stop("reference level ref.batch is not found in batch")
        }
        if (verbose){
          cat(paste0("[combat] Using batch=",ref.batch, " as a reference batch \n"))
        }
        ref <- which(levels(as.factor(batch))==ref.batch) # find the reference
        batchmod[,ref] <- 1
    } else {
        ref <- NULL
    }
    #combine batch variable and covariates
    design <- cbind(batchmod,mod)
    # check for intercept in covariates, and drop if present
    check  <- apply(design, 2, function(x) all(x == 1))
    if(!is.null(ref)){
        check[ref] <- FALSE
    }
    design <- as.matrix(design[,!check])
    design <- .checkDesign(design, n.batch)
    n.covariates <- ncol(design)-ncol(batchmod)
    if (verbose) cat("[combat] Adjusting for ",n.covariates,' covariate(s) or covariate level(s)\n')
      out <- list()
    out[["batch"]] <- batch
    out[["batches"]] <- batches
    out[["n.batch"]] <- n.batch
    out[["n.batches"]] <- n.batches
    out[["n.array"]] <- n.array
    out[["n.covariates"]] <- n.covariates
    out[["design"]] <- design
    out[["batch.design"]] <- design[,1:n.batch]
    out[["ref"]] <- ref
    out[["ref.batch"]] <- ref.batch
    return(out)
}





getStandardizedData <- function(dat, dataDict, design, hasNAs){
    batches=dataDict$batches
    n.batches=dataDict$n.batches
    n.array=dataDict$n.array
    n.batch=dataDict$n.batch
    ref.batch=dataDict$ref.batch
    ref=dataDict$ref
    .getBetaHat <- function(dat, design, hasNAs){
        if (!hasNAs){
          B.hat <- solve(crossprod(design))
          B.hat <- tcrossprod(B.hat, design)
          B.hat <- tcrossprod(B.hat, dat)
        } else {
          B.hat <- apply(dat, 1, .betaNA, design)
        }
    }
    B.hat <- .getBetaHat(dat=dat, design=design, hasNAs=hasNAs)
    if(!is.null(ref.batch)){
        grand.mean <- t(B.hat[ref, ])
    } else {
        grand.mean <- crossprod(n.batches/n.array, B.hat[1:n.batch,])
    }
    stand.mean <- crossprod(grand.mean, t(rep(1,n.array)))
    if (!hasNAs){
      if (!is.null(ref.batch)){
          ref.dat <- dat[, batches[[ref]]]
          factors <- (n.batches[ref]/(n.batches[ref]-1))
          var.pooled <- rowVars(ref.dat-t(design[batches[[ref]], ]%*%B.hat), na.rm=TRUE)/factors
      } else {
          factors <- (n.array/(n.array-1))
          var.pooled <- rowVars(dat-t(design %*% B.hat), na.rm=TRUE)/factors
      }
    } else {
      if (!is.null(ref.batch)){
          ref.dat <- dat[, batches[[ref]]]  
          ns <- rowSums(!is.na(ref.dat))
          factors <- (ns/(ns-1))
          var.pooled <- rowVars(ref.dat-t(design[batches[[ref]], ]%*%B.hat), na.rm=TRUE)/factors
      } else {
          ns <- rowSums(!is.na(dat))
          factors <- (ns/(ns-1))
          var.pooled <- rowVars(dat-t(design %*% B.hat), na.rm=TRUE)/factors
      }
    }

    if(!is.null(design)){
      tmp <- design
      tmp[,c(1:n.batch)] <- 0
      stand.mean <- stand.mean+t(tmp%*%B.hat)
    } 
    s.data <- (dat-stand.mean)/(tcrossprod(sqrt(var.pooled), rep(1,n.array)))
    return(list(s.data=s.data, 
        stand.mean=stand.mean, 
        var.pooled=var.pooled)
    )
}

# Following four find empirical hyper-prior values
aprior <- function(gamma.hat){
	m=mean(gamma.hat)
	s2=var(gamma.hat)
	(2*s2+m^2)/s2
}
bprior <- function(gamma.hat){
	m=mean(gamma.hat)
	s2=var(gamma.hat)
	(m*s2+m^3)/s2
}
postmean <- function(g.hat,g.bar,n,d.star,t2){
	(t2*n*g.hat+d.star*g.bar)/(t2*n+d.star)
}
postvar <- function(sum2,n,a,b){
	(.5*sum2+b)/(n/2+a-1)
}

apriorMat <- function(gamma.hat) {
  m <- rowMeans2(gamma.hat)
  s2 <- rowVars(gamma.hat)
  return((2*s2+m^2)/s2)
}
bpriorMat <- function(gamma.hat) {
  m <- rowMeans2(gamma.hat)
  s2 <- rowVars(gamma.hat)
  return((m*s2+m^3)/s2)
}
# Pass in entire data set, the design matrix for the entire data, the batch means, the batch variances, priors (m, t2, a, b), columns of the data  matrix for the batch. Uses the EM to find the parametric batch adjustments

# Helper function for parametric adjustements:
it.sol  <- function(sdat,g.hat,d.hat,g.bar,t2,a,b,conv=.0001){
	#n <- apply(!is.na(sdat),1,sum)
	n <- rowSums(!is.na(sdat))
	g.old <- g.hat
	d.old <- d.hat
	change <- 1
	count <- 0
	ones <- rep(1,ncol(sdat))

	while(change>conv){
		g.new  <- postmean(g.hat,g.bar,n,d.old,t2)
		#sum2   <- apply((sdat-g.new%*%t(rep(1,ncol(sdat))))^2, 1, sum,na.rm=T)
		#sum2   <- apply((sdat-tcrossprod(g.new, rep(1,ncol(sdat))))^2, 1, sum,na.rm=T)
		sum2 <- rowSums2((sdat-tcrossprod(g.new, ones))^2, na.rm=TRUE)
		d.new  <- postvar(sum2,n,a,b)
		change <- max(abs(g.new-g.old)/g.old,abs(d.new-d.old)/d.old)
		g.old <- g.new
		d.old <- d.new
		count <- count+1
		}
	#cat("This batch took", count, "iterations until convergence\n")
	adjust <- rbind(g.new, d.new)
	rownames(adjust) <- c("g.star","d.star")
	adjust
}



# Helper function for non-parametric adjustements:
int.eprior <- function(sdat, g.hat, d.hat){
    g.star <- d.star <- NULL
    r <- nrow(sdat)
    for(i in 1:r){
        g <- g.hat[-i]
        d <- d.hat[-i]		
        x <- sdat[i,!is.na(sdat[i,])]
        n <- length(x)
        j <- numeric(n)+1
        dat <- matrix(as.numeric(x), length(g), n, byrow=TRUE)
        resid2 <- (dat-g)^2
        sum2 <- resid2 %*% j
        LH <- 1/(2*pi*d)^(n/2)*exp(-sum2/(2*d))
        LH[LH=="NaN"]=0
        g.star <- c(g.star, sum(g*LH)/sum(LH))
        d.star <- c(d.star, sum(d*LH)/sum(LH))
        ## if(i%%1000==0){cat(i,'\n')}
    }
    adjust <- rbind(g.star,d.star)
    rownames(adjust) <- c("g.star","d.star")
    adjust	
} 


getNaiveEstimators <- function(s.data, dataDict, hasNAs, mean.only){
    batch.design <- dataDict$batch.design
    batches <- dataDict$batches
    if (!hasNAs){
        gamma.hat <- tcrossprod(solve(crossprod(batch.design, batch.design)), batch.design)
        gamma.hat <- tcrossprod(gamma.hat, s.data)
    } else{
        gamma.hat <- apply(s.data, 1, .betaNA, batch.design) 
    }
    delta.hat <- NULL
    for (i in dataDict$batches){
      if (mean.only){
        delta.hat <- rbind(delta.hat,rep(1,nrow(s.data))) 
      } else {
        delta.hat <- rbind(delta.hat,rowVars(s.data, cols=i, na.rm=TRUE))
      }    
    }
    return(list(gamma.hat=gamma.hat, delta.hat=delta.hat))
}


getEbEstimators <- function(naiveEstimators,
      s.data, dataDict,
      parametric=TRUE, 
      mean.only=FALSE
){
      gamma.hat=naiveEstimators[["gamma.hat"]]
      delta.hat=naiveEstimators[["delta.hat"]]
      batches=dataDict$batches
      n.batch=dataDict$n.batch
      ref.batch=dataDict$ref.batch
      ref=dataDict$ref
      .getParametricEstimators <- function(){
            gamma.star <- delta.star <- NULL
            for (i in 1:n.batch){
                if (mean.only){
                  gamma.star <- rbind(gamma.star,postmean(gamma.hat[i,], gamma.bar[i], 1, 1, t2[i]))
                  delta.star <- rbind(delta.star,rep(1, nrow(s.data)))
                } else {
                  temp <- it.sol(s.data[,batches[[i]]],gamma.hat[i,],delta.hat[i,],gamma.bar[i],t2[i],a.prior[i],b.prior[i])
                  gamma.star <- rbind(gamma.star,temp[1,])
                  delta.star <- rbind(delta.star,temp[2,])
                }
            }
            return(list(gamma.star=gamma.star, delta.star=delta.star))
      }
      .getNonParametricEstimators <- function(){
          gamma.star <- delta.star <- NULL
          for (i in 1:n.batch){
              if (mean.only){
                  delta.hat[i, ] = 1
              }
              temp <- int.eprior(as.matrix(s.data[, batches[[i]]]),gamma.hat[i,], delta.hat[i,])
              gamma.star <- rbind(gamma.star,temp[1,])
              delta.star <- rbind(delta.star,temp[2,])
          }
          return(list(gamma.star=gamma.star, delta.star=delta.star))
      }
      gamma.bar <- rowMeans(gamma.hat, na.rm=TRUE)
      t2 <- rowVars(gamma.hat, na.rm=TRUE)
      a.prior <- apriorMat(delta.hat)
      b.prior <- bpriorMat(delta.hat)
      if (parametric){
        temp <- .getParametricEstimators()
      } else {
        temp <- .getNonParametricEstimators()
      }
      if(!is.null(ref.batch)){
        temp[["gamma.star"]][ref,] <- 0  ## set reference batch mean equal to 0
        temp[["delta.star"]][ref,] <- 1  ## set reference batch variance equal to 1
      }
      out <- list()
      out[["gamma.star"]] <- temp[["gamma.star"]]
      out[["delta.star"]] <- temp[["delta.star"]]
      out[["gamma.bar"]] <- gamma.bar
      out[["t2"]] <- t2
      out[["a.prior"]] <- a.prior
      out[["b.prior"]] <- b.prior
      return(out)
}


getNonEbEstimators <- function(naiveEstimators,dataDict){
  out <- list()
  out[["gamma.star"]] <- naiveEstimators[["gamma.hat"]]
  out[["delta.star"]] <- naiveEstimators[["delta.hat"]]
  out[["gamma.bar"]]  <- NULL
  out[["t2"]] <- NULL
  out[["a.prior"]] <- NULL
  out[["b.prior"]] <- NULL
  ref.batch=dataDict$ref.batch
  ref=dataDict$ref
  if(!is.null(ref.batch)){
    out[["gamma.star"]][ref,] <- 0  ## set reference batch mean equal to 0
    out[["delta.star"]][ref,] <- 1  ## set reference batch variance equal to 1
  }
  return(out)
}


getCorrectedData <- function(dat, 
  s.data, 
  dataDict, 
  estimators, 
  naiveEstimators,
  stdObjects,
  eb=TRUE){
  var.pooled=stdObjects$var.pooled
  stand.mean=stdObjects$stand.mean
  batches <- dataDict$batches
  batch.design <- dataDict$batch.design
  n.batches <- dataDict$n.batches
  n.array <- dataDict$n.array
  ref.batch <- dataDict$ref.batch
  ref <- dataDict$ref
  if (eb){
    gamma.star <- estimators[["gamma.star"]]
    delta.star <- estimators[["delta.star"]]
  } else {
    gamma.star <- naiveEstimators[["gamma.hat"]]
    delta.star <- naiveEstimators[["delta.hat"]]
  }
  bayesdata <- s.data
  j <- 1
  for (i in batches){
      top <- bayesdata[,i]-t(batch.design[i,]%*%gamma.star)
      bottom <- tcrossprod(sqrt(delta.star[j,]), rep(1,n.batches[j]))
      bayesdata[,i] <- top/bottom
      j <- j+1
  }
  bayesdata <- (bayesdata*(tcrossprod(sqrt(var.pooled), rep(1,n.array))))+stand.mean
  if(!is.null(ref.batch)){
        bayesdata[, batches[[ref]]] <- dat[, batches[[ref]]]
  }
  return(bayesdata)
}





# Create indices for matched samples across sites, for one covariate.
#batch: site, study or scanner covariate
#x: continuous covariate
#xmin: minimum value for x to be considered
#xmax: maximum value for x to be considered
#step=1: step for the grid; must be a positive integer
# createMatchingIndices <- function(x, batch, xmin=NULL, xmax=NULL, step=1){

# 	stopifnot(length(x)==length(batch))
# 	batches <- unique(batch)
# 	n.batches <- length(batches)
# 	x_per_batch <- split(x, f=batch)[batches]
# 	if (is.null(xmin)) xmin <- min(x)
# 	if (is.null(xmax)) xmax <- max(x)
# 	grid <- seq(xmin,xmax,step)
# 	n.bins <- length(grid)-1

# 	# Creating count matrix:
# 	counts <- matrix(0, n.bins, n.batches)
# 	for (i in 1:n.bins){
# 		counts[i,] <- unlist(lapply(x_per_batch, function(temp){
# 			sum(temp >= grid[i] & temp < grid[i+1])
# 		}))
# 	}
# 	mins <- unlist(apply(counts,1,min)) #Minimal count
# 	indices <- c()

# 	# Creating indices:
# 	for (i in 1:n.bins){
# 		for (j in 1:n.batches){
# 			min <- mins[i]
# 			if (min!=0){
# 				cand <- which(x >= grid[i] & x < grid[i+1] & batch==batches[j])

# 				if (length(cand) !=1){
# 					cand <- sample(cand,min) # Sampling at random	
# 				} 


# 				indices <- c(indices, cand)
# 			}
# 		}
# 	}
# 	return(indices)
# }



