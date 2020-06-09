# small demo for sinogram TOF MLEM without subsets

import os
import matplotlib.pyplot as py
import pyparallelproj as ppp
import numpy as np
import argparse

#---------------------------------------------------------------------------------
# parse the command line

parser = argparse.ArgumentParser()
parser.add_argument('--ngpus',  help = 'number of GPUs to use', default = 0,   type = int)
parser.add_argument('--counts', help = 'counts to simulate',    default = 1e5, type = float)
parser.add_argument('--niter',  help = 'number of iterations',  default = 28,  type = int)
args = parser.parse_args()

#---------------------------------------------------------------------------------

ngpus     = args.ngpus
counts    = args.counts
niter     = args.niter

np.random.seed(1)

# setup a scanner with one ring
scanner = ppp.RegularPolygonPETScanner(ncrystals_per_module = np.array([16,1]),
                                       nmodules             = np.array([28,1]))

# setup a test image
voxsize = np.array([2.,2.,2.])
n0      = 120
n1      = 120
n2      = max(1,int((scanner.xc2.max() - scanner.xc2.min()) / voxsize[2]))


# setup a random image
img = np.zeros((n0,n1,n2), dtype = np.float32)
img[(n0//4):(3*n0//4),(n1//4):(3*n1//4),:] = 1
img_origin = (-(np.array(img.shape) / 2) +  0.5) * voxsize

# generate sinogram parameters and the projector
sino_params = ppp.PETSinogramParameters(scanner, ntofbins = 17, tofbin_width = 15.)
proj        = ppp.SinogramProjector(scanner, sino_params, img.shape, nsubsets = 1, 
                                    voxsize = voxsize, img_origin = img_origin, ngpus = ngpus,
                                    tof = True, sigma_tof = 60./2.35, n_sigmas = 3.)

img_fwd  = proj.fwd_project(img, subset = 0)

# generate sensitity sinogram (product from attenuation and normalization sinogram)
# this sinogram is usually non TOF! which results in a different shape
sens_sino = 3.4*np.ones(img_fwd.shape[:-1], dtype = np.float32)

# scale sum of fwd image to counts
if counts > 0:
  scale_fac = (counts / img_fwd.sum())
  img_fwd  *= scale_fac 
  img      *= scale_fac 

  # contamination sinogram with scatter and randoms
  # useful to avoid division by 0 in the ratio of data and exprected data
  contam_sino = np.full(img_fwd.shape, 0.2*img_fwd.mean(), dtype = np.float32)
  
  em_sino = np.random.poisson(sens_sino[...,np.newaxis]*img_fwd + contam_sino)
else:
  scale_fac = 1.

  # contamination sinogram with sctter and randoms
  # useful to avoid division by 0 in the ratio of data and exprected data
  contam_sino = np.full(img_fwd.shape, 0.2*img_fwd.mean(), dtype = np.float32)

  em_sino = sens_sino[...,np.newaxis]*img_fwd + contam_sino

#-------------------------------------------------------------------------------------
#-------------------------------------------------------------------------------------
#--- MLEM reconstruction

# initialize recon
recon = np.full((n0,n1,n2), em_sino.sum() / (n0*n1*n2), dtype = np.float32)

py.ion()
fig, ax = py.subplots(1,3, figsize = (12,4))
ax[0].imshow(img[...,n2//2],   vmin = 0, vmax = 1.3*img.max(), cmap = py.cm.Greys)
ax[0].set_title('ground truth')
ir = ax[1].imshow(recon[...,n2//2], vmin = 0, vmax = 1.3*img.max(), cmap = py.cm.Greys)
ax[1].set_title('intial recon')
ib = ax[2].imshow(recon[...,n2//2] - img[...,n2//2], vmin = -0.2*img.max(), vmax = 0.2*img.max(), 
                  cmap = py.cm.bwr)
ax[2].set_title('bias')

fig.tight_layout()
fig.canvas.draw()

# calculate the sensitivity image, we have to repeat the sens sino since it is non TOF
sens_img = proj.back_project(sens_sino.repeat(proj.ntofbins).reshape(sens_sino.shape + 
                             (proj.ntofbins,)), subset = 0) 

# run MLEM iterations
for it in range(niter):
  print(f'iteration {it}')
  exp_sino = sens_sino[...,np.newaxis]*proj.fwd_project(recon, subset = 0) + contam_sino
  ratio    = em_sino / exp_sino
  recon *= (proj.back_project(sens_sino[...,np.newaxis]*ratio, subset = 0) / sens_img) 

  ir.set_data(recon[...,n2//2])
  ib.set_data(recon[...,n2//2] - img[...,n2//2])
  ax[1].set_title(f'itertation {it+1}')
  fig.canvas.draw()