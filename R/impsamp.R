#' generate population prediction sample from parameters
#'
#' @param object a fitted \code{mle2} object
#' @param n number of samples to return
#' @param n_imp number of total samples from which to draw, if doing importance sampling
#' @param return_wts return a column giving the weights of the samples, for use in weighted summaries?
#' @param impsamp subsample values (with replacement) based on their weights?
#' @param PDify use Gill and King generalized-inverse procedure to correct non-positive-definite variance-covariance matrix if necessary?
#' @param tol tolerance for detecting small eigenvalues
#' @param fix_params parameters to fix (in addition to parameters that were fixed during estimation)
#'
#' This function combines several sampling tricks to compute 
#' 
#' @references Gill, Jeff, and Gary King. "What to Do When Your Hessian Is Not Invertible: Alternatives to Model Respecification in Nonlinear Estimation." Sociological Methods & Research 33, no. 1 (2004): 54-87.
#' Lande, Russ and Steinar Engen and Bernt-Erik Saether, Stochastic Population Dynamics in Ecology and Conservation. Oxford University Press, 2003.

pop_pred_samp <- function (object, n = 1000, n_imp = n, return_wts = FALSE, impsamp = FALSE, 
                           PDify = FALSE, PDmethod = NULL, tol = 1e-06, return_all = FALSE, 
                           rmvnorm_method = c("mvtnorm", "MASS"), fix_params = NULL, 
                           pseudoVar = FALSE,
                           t_dist = FALSE,
                           diagmat = FALSE,
                           vartimes = 1,
                           sampwts = TRUE
                           
                           ) 
{
  rmvnorm_method <- match.arg(rmvnorm_method)
  min_eval <- function(x) {
    ev <- eigen(x, only.values = TRUE)$values
    if (is.complex(ev)) {
      print(x)
      print(ev)
      stop("covariance matrix with complex eigenvalues (!)")
    }
    min(ev)
  }
  cc_full <- object@fullcoef
  cc <- object@coef
  keep_params <- !names(cc) %in% fix_params
  cc <- cc[keep_params]
  vv <- vcov(object)
  vv <- vv[keep_params, keep_params]
  if (diagmat) {
    vv <- vcov(object)
    vv <- vv[keep_params, keep_params]
    vv <- diag(diag(vv))
  }
  vv <- vv*vartimes
  if(!isSymmetric(vv)){
    vv <- as.matrix(Matrix::nearPD(vv)$mat)
  }
  Lfun <- object@minuslogl
  fixed_pars <- setdiff(names(object@fullcoef), names(cc))
  res <- matrix(NA, nrow = n, ncol = length(cc_full), dimnames = list(NULL, 
                                                                      names(cc_full)))
  if (any(is.na(cc))) 
    return(res)
  bad_vcov <- any(is.na(vv))
  if (!bad_vcov) {
    min_eig <- min_eval(vv)
  }
  else {
    min_eig <- NA
  }
  if (is.na(min_eig) || any(min_eig < 0)) {
    if (!PDify) {
      stop("NA or non-positive definitive variance-covariance matrix ", 
           sprintf("(min eig=%f): ", min_eig), "consider PDify=TRUE (and probably impsamp=TRUE)")
    }
    hh <- object@details$hessian[keep_params, keep_params]
    if (any(is.na(hh))) {
      warning("NA values in Hessian set to zero: check results *very* carefully!")
      hh[is.na(hh)] <- 0
    }
    if ((is.null(PDmethod) && bad_vcov) || identical(PDmethod, 
                                                     "King")) {
      warning("using EXPERIMENTAL King et al method")
      vv <- crossprod(as.matrix(bdsmatrix::gchol(MASS::ginv(hh)), 
                                ones = FALSE))
    }
    else {
      vv <- as.matrix(Matrix::nearPD(vv)$mat)
    }
  }
  hh <- object@details$hessian[keep_params, keep_params]
  if (any(is.na(hh))) {
    warning("NA values in Hessian set to zero: check results *very* carefully!")
    hh[is.na(hh)] <- 0
  }
  if (pseudoVar) {
    warning("using EXPERIMENTAL King et al method")
    vv <- crossprod(as.matrix(bdsmatrix::gchol(MASS::ginv(hh)), 
                              ones = FALSE))
  }
  mv_n <- if (impsamp) 
    n_imp
  else n
  if(!t_dist){
  res[, names(cc)] <- mv_vals <- switch(rmvnorm_method
    , mvtnorm = mvtnorm::rmvnorm(mv_n
      ,mean = cc, sigma = vv)
    , MASS = MASS::mvrnorm(mv_n, mu = cc, Sigma = vv)
    )
  }
  if(t_dist){
    res[, names(cc)] <- mv_vals <- LaplacesDemon::rmvt(mv_n, mu=cc, S=vv, df=3)
  }
  if (length(fixed_pars) > 0) {
    for (p in fixed_pars) {
      res[, p] <- object@fullcoef[p]
    }
  }
  if (!(impsamp || return_wts)) 
    return(res)
  if(!t_dist){
    mv_wts <- mvtnorm::dmvnorm(mv_vals, mean = cc, sigma = vv, 
                             log = TRUE)
  }
  if(t_dist){
    mv_wts <- sapply(1:mv_n,function(x){
      LaplacesDemon::dmvt(mv_vals[x,], mu=cc, S=vv, df=3, log=TRUE)
    })
  }
  if (all(is.na(mv_wts)) && length(mv_wts) == 1) {
    mv_wts <- rep(NA, length(mv_vals))
    warning("can't compute MV sampling probabilities")
  }
  if(!sampwts){
	mv_wts <- 0 
  }
  L_wts0 <- -1 * apply(res, 1, Lfun)
  L_wts <- L_wts0 - mv_wts
  L_wts <- exp(L_wts - max(L_wts, na.rm = TRUE))
  L_wts <- L_wts/sum(L_wts, na.rm = TRUE)
  eff_samp <- 1/sum(L_wts^2, na.rm = TRUE)
  res <- cbind(res, L_wts = L_wts0, samp_wts = mv_wts)
  attr(res, "eff_samp") <- eff_samp
  if (return_all) {
    return(cbind(res, loglik = L_wts0, mvnloglik = mv_wts))
  }
  if (return_wts) 
    return(res)
  res <- res[sample(seq(nrow(res)), size = n, prob = L_wts, 
                    replace = TRUE), ]
  return(res)
}
    
## ## copy (!!) dmvnorm from emdbook to avoid cyclic dependency problems
## dmvnorm <- function (x, mu, Sigma, log = FALSE, tol = 1e-06) {
##     if (is.vector(x)) 
##         x = t(as.matrix(x))
##     n = length(mu)
##     if (is.vector(mu)) {
##         p <- length(mu)
##         if (is.matrix(x)) {
##             mu <- matrix(rep(mu, nrow(x)), ncol = p, byrow = TRUE)
##         }
##     }
##     else {
##         p <- ncol(mu)
##     }
##     if (!all(dim(Sigma) == c(p, p)) || nrow(x) != nrow(mu)) 
##         stop("incompatible arguments")
##     eS <- eigen(Sigma, symmetric = TRUE) 
##     ev <- eS$values
##     if (!all(ev >= -tol * abs(ev[1]))) 
##         warning("Sigma is not positive definite, trying anyway")
##     z = t(x - mu)
##     logdetS = try(determinant(Sigma, logarithm = TRUE)$modulus,
##                   silent=TRUE)
##     if (inherits(logdetS,"try-error")) return(rep(NA,nrow(x)))
##     attributes(logdetS) <- NULL
##     iS = MASS::ginv(Sigma)
##     ssq = diag(t(z) %*% iS %*% z)
##     loglik = -(n * (log(2*pi)) +  logdetS + ssq)/2
##     if (log) loglik else exp(loglik)
##   }
