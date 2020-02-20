/**
 * @file joseph3d_fwd_tof_lm_cuda.cu
 */

#include<stdio.h>
#include<stdlib.h>
#include<math.h>

#include "tof_utils_cuda.h"

/** @brief 3D listmode tof joseph forward projector kernel
 *
 *  @param xstart array of shape [3*nlors] with the coordinates of the start points of the LORs.
 *                The start coordinates of the n-th LOR are at xstart[n*3 + i] with i = 0,1,2 
 *  @param xend   array of shape [3*nlors] with the coordinates of the end   points of the LORs.
 *                The start coordinates of the n-th LOR are at xstart[n*3 + i] with i = 0,1,2 
 *  @param img    array of shape [n0*n1*n2] containing the 3D image to be projected.
 *                The pixel [i,j,k] ist stored at [n1*n2+i + n2*k + j].
 *  @param img_origin  array [x0_0,x0_1,x0_2] of coordinates of the center of the [0,0,0] voxel
 *  @param voxsize     array [vs0, vs1, vs2] of the voxel sizes
 *  @param p           array of length nlors (output) used to store the projections
 *  @param nlors       number of geomtrical LORs
 *  @param img_dim     array with dimensions of image [n0,n1,n2]
 *  @param n_tofbins        number of TOF bins
 *  @param tofbin_width     width of the TOF bins in spatial units (units of xstart and xend)
 *  @param sigma_tof        array of length nlors with the TOF resolution (sigma) for each LOR in
 *                          spatial units (units of xstart and xend) 
 *  @param tofcenter_offset array of length nlors with the offset of the central TOF bin from the 
 *                          midpoint of each LOR in spatial units (units of xstart and xend) 
 *  @param tof_bin          array containing the TOF bin of each event
 *  @param half_erf_lut     look up table length 6001 for half erf between -3 and 3. 
 *                          The i-th element contains 0.5*erf(-3 + 0.001*i)
 */
__global__ void joseph3d_fwd_tof_lm_cuda_kernel(float *xstart, 
                                                float *xend, 
                                                float *img,
                                                float *img_origin, 
                                                float *voxsize, 
                                                float *p,
                                                long long nlors, 
                                                unsigned int *img_dim,
		                                            int n_tofbins,
		                                            float tofbin_width,
		                                            float *sigma_tof,
		                                            float *tofcenter_offset,
		                                            int *tof_bin,
                                                float *half_erf_lut)
{
  long long i = blockDim.x * blockIdx.x + threadIdx.x;

  unsigned int n0 = img_dim[0];
  unsigned int n1 = img_dim[1];
  unsigned int n2 = img_dim[2];

  if(i < nlors)
  {
    float d0, d1, d2, d0_sq, d1_sq, d2_sq; 
    float lsq, cos0_sq, cos1_sq, cos2_sq;
    unsigned short direction; 
    unsigned int i0, i1, i2;
    int i0_floor, i1_floor, i2_floor;
    int i0_ceil, i1_ceil, i2_ceil;
    float x_pr0, x_pr1, x_pr2;
    float tmp_0, tmp_1, tmp_2;
   
    float u0, u1, u2, d_norm;
    float x_m0, x_m1, x_m2;    
    float x_v0, x_v1, x_v2;    

    float tw;

    // correction factor for cos(theta) and voxsize
    float cf;

    float toAdd;

    // test whether the ray between the two detectors is most parallel
    // with the 0, 1, or 2 axis
    d0 = xend[i*3 + 0] - xstart[i*3 + 0];
    d1 = xend[i*3 + 1] - xstart[i*3 + 1];
    d2 = xend[i*3 + 2] - xstart[i*3 + 2];

    d0_sq = d0*d0;
    d1_sq = d1*d1;
    d2_sq = d2*d2;

    lsq = d0_sq + d1_sq + d2_sq;

    cos0_sq = d0_sq / lsq;
    cos1_sq = d1_sq / lsq;
    cos2_sq = d2_sq / lsq;

    direction = 0;
    if ((cos1_sq >= cos0_sq) && (cos1_sq >= cos2_sq))
    {
      direction = 1;
    }
    else
    {
      if ((cos2_sq >= cos0_sq) && (cos2_sq >= cos1_sq))
      {
        direction = 2;
      }
    }
 
    //---------------------------------------------------------
    //--- calculate TOF related quantities
    
    // unit vector (u0,u1,u2) that points from xstart to end
    d_norm = sqrt(lsq);
    u0 = d0 / d_norm; 
    u1 = d1 / d_norm; 
    u2 = d2 / d_norm; 

    // calculate mid point of LOR
    x_m0 = 0.5*(xstart[i*3 + 0] + xend[i*3 + 0]);
    x_m1 = 0.5*(xstart[i*3 + 1] + xend[i*3 + 1]);
    x_m2 = 0.5*(xstart[i*3 + 2] + xend[i*3 + 2]);

    //---------------------------------------------------------

    if (direction == 0)
    {
      cf = voxsize[direction] / sqrt(cos0_sq);

      // case where ray is most parallel to the 0 axis
      // we step through the volume along the 0 direction
      for(i0 = 0; i0 < n0; i0++)
      {
        // get the indices where the ray intersects the image plane
        x_pr1 = xstart[i*3 + 1] + (img_origin[direction] + i0*voxsize[direction] - xstart[i*3 + direction])*d1 / d0;
        x_pr2 = xstart[i*3 + 2] + (img_origin[direction] + i0*voxsize[direction] - xstart[i*3 + direction])*d2 / d0;
  
        i1_floor = (int)floor((x_pr1 - img_origin[1])/voxsize[1]);
        i1_ceil  = i1_floor + 1;
  
        i2_floor = (int)floor((x_pr2 - img_origin[2])/voxsize[2]);
        i2_ceil  = i2_floor + 1; 
 
        // calculate the distances to the floor normalized to [0,1]
        // for the bilinear interpolation
        tmp_1 = (x_pr1 - (i1_floor*voxsize[1] + img_origin[1])) / voxsize[1];
        tmp_2 = (x_pr2 - (i2_floor*voxsize[2] + img_origin[2])) / voxsize[2];

	      toAdd = 0;

        if ((i1_floor >= 0) && (i1_floor < n1) && (i2_floor >= 0) && (i2_floor < n2))
        {
          toAdd += img[n1*n2*i0 + n2*i1_floor + i2_floor] * (1 - tmp_1) * (1 - tmp_2);
        }
        if ((i1_ceil >= 0) && (i1_ceil < n1) && (i2_floor >= 0) && (i2_floor < n2))
        {
          toAdd += img[n1*n2*i0 + n2*i1_ceil + i2_floor] * tmp_1 * (1 - tmp_2);
        }
        if ((i1_floor >= 0) && (i1_floor < n1) && (i2_ceil >= 0) && (i2_ceil < n2))
        {
          toAdd += img[n1*n2*i0 + n2*i1_floor + i2_ceil] * (1 - tmp_1) * tmp_2;
        }
        if ((i1_ceil >= 0) && (i1_ceil < n1) && (i2_ceil >= 0) && (i2_ceil < n2))
        {
          toAdd += img[n1*n2*i0 + n2*i1_ceil + i2_ceil] * tmp_1 * tmp_2;
        }

        //--------- TOF related quantities
        // calculate the voxel center needed for TOF weights
        x_v0 = img_origin[0] + i0*voxsize[0];
        x_v1 = x_pr1;
        x_v2 = x_pr2;

        if(toAdd != 0){
          //calculate the TOF weight
          tw = tof_weight_cuda(x_m0, x_m1, x_m2, x_v0, x_v1, x_v2, u0, u1, u2, tof_bin[i], 
		                     tofbin_width, tofcenter_offset[i], sigma_tof[i], half_erf_lut);

          p[i] += (tw * cf * toAdd);
        }
      }
    }

    //--------------------------------------------------------------------------------- 
    if (direction == 1)
    {
      cf = voxsize[direction] / sqrt(cos1_sq);

      // case where ray is most parallel to the 1 axis
      // we step through the volume along the 1 direction
      for (i1 = 0; i1 < n1; i1++)
      {
        // get the indices where the ray intersects the image plane
        x_pr0 = xstart[i*3 + 0] + (img_origin[direction] + i1*voxsize[direction] - xstart[i*3 + direction])*d0 / d1;
        x_pr2 = xstart[i*3 + 2] + (img_origin[direction] + i1*voxsize[direction] - xstart[i*3 + direction])*d2 / d1;
  
        i0_floor = (int)floor((x_pr0 - img_origin[0])/voxsize[0]);
        i0_ceil  = i0_floor + 1; 
  
        i2_floor = (int)floor((x_pr2 - img_origin[2])/voxsize[2]);
        i2_ceil  = i2_floor + 1;
  
        // calculate the distances to the floor normalized to [0,1]
        // for the bilinear interpolation
        tmp_0 = (x_pr0 - (i0_floor*voxsize[0] + img_origin[0])) / voxsize[0];
        tmp_2 = (x_pr2 - (i2_floor*voxsize[2] + img_origin[2])) / voxsize[2];
 
        toAdd = 0;

        if ((i0_floor >= 0) && (i0_floor < n0) && (i2_floor >= 0) && (i2_floor < n2))
        {
          toAdd += img[n1*n2*i0_floor + n2*i1 + i2_floor] * (1 - tmp_0) * (1 - tmp_2);
        }
        if ((i0_ceil >= 0) && (i0_ceil < n0) && (i2_floor >= 0) && (i2_floor < n2))
        {
          toAdd += img[n1*n2*i0_ceil + n2*i1 + i2_floor] * tmp_0 * (1 - tmp_2);
        }
        if ((i0_floor >= 0) && (i0_floor < n0) && (i2_ceil >= 0) && (i2_ceil < n2))
        {
          toAdd += img[n1*n2*i0_floor + n2*i1 + i2_ceil] * (1 - tmp_0) * tmp_2;
        }
        if ((i0_ceil >= 0) && (i0_ceil < n0) && (i2_ceil >= 0) && (i2_ceil < n2))
        {
          toAdd += img[n1*n2*i0_ceil + n2*i1 + i2_ceil] * tmp_0 * tmp_2;
        }

        //--------- TOF related quantities
        // calculate the voxel center needed for TOF weights
        x_v0 = x_pr0;
        x_v1 = img_origin[1] + i1*voxsize[1];
        x_v2 = x_pr2;

        if(toAdd != 0){
          // calculate the TOF weight
          tw = tof_weight_cuda(x_m0, x_m1, x_m2, x_v0, x_v1, x_v2, u0, u1, u2, tof_bin[i], 
		                      tofbin_width, tofcenter_offset[i], sigma_tof[i], half_erf_lut);

          p[i] += (tw * cf * toAdd);
	      }
      }
    }

    //--------------------------------------------------------------------------------- 
    if (direction == 2)
    {
      cf = voxsize[direction] / sqrt(cos2_sq);

      // case where ray is most parallel to the 2 axis
      // we step through the volume along the 2 direction

      for(i2 = 0; i2 < n2; i2++)
      {
        // get the indices where the ray intersects the image plane
        x_pr0 = xstart[i*3 + 0] + (img_origin[direction] + i2*voxsize[direction] - xstart[i*3 + direction])*d0 / d2;
        x_pr1 = xstart[i*3 + 1] + (img_origin[direction] + i2*voxsize[direction] - xstart[i*3 + direction])*d1 / d2;
  
        i0_floor = (int)floor((x_pr0 - img_origin[0])/voxsize[0]);
        i0_ceil  = i0_floor + 1;
  
        i1_floor = (int)floor((x_pr1 - img_origin[1])/voxsize[1]);
        i1_ceil  = i1_floor + 1; 
  
        // calculate the distances to the floor normalized to [0,1]
        // for the bilinear interpolation
        tmp_0 = (x_pr0 - (i0_floor*voxsize[0] + img_origin[0])) / voxsize[0];
        tmp_1 = (x_pr1 - (i1_floor*voxsize[1] + img_origin[1])) / voxsize[1];

        toAdd = 0;

        if ((i0_floor >= 0) && (i0_floor < n0) && (i1_floor >= 0) && (i1_floor < n1))
        {
          toAdd += img[n1*n2*i0_floor + n2*i1_floor + i2] * (1 - tmp_0) * (1 - tmp_1);
        }
        if ((i0_ceil >= 0) && (i0_ceil < n0) && (i1_floor >= 0) && (i1_floor < n1))
        {
          toAdd += img[n1*n2*i0_ceil + n2*i1_floor + i2] * tmp_0 * (1 - tmp_1);
        }
        if ((i0_floor >= 0) && (i0_floor < n0) && (i1_ceil >= 0) & (i1_ceil < n1))
        {
          toAdd += img[n1*n2*i0_floor + n2*i1_ceil + i2] * (1 - tmp_0) * tmp_1;
        }
        if ((i0_ceil >= 0) && (i0_ceil < n0) && (i1_ceil >= 0) && (i1_ceil < n1))
        {
          toAdd += img[n1*n2*i0_ceil + n2*i1_ceil + i2] * tmp_0 * tmp_1;
        }

        //--------- TOF related quantities
        // calculate the voxel center needed for TOF weights
        x_v0 = x_pr0;
        x_v1 = x_pr1;
        x_v2 = img_origin[2] + i2*voxsize[2];

        if(toAdd != 0){
          // calculate the TOF weight
          tw = tof_weight_cuda(x_m0, x_m1, x_m2, x_v0, x_v1, x_v2, u0, u1, u2, tof_bin[i], 
		                      tofbin_width, tofcenter_offset[i], sigma_tof[i], half_erf_lut);

          p[i] += (tw * cf * toAdd);
	      }
      }
    }
  }
}

//------------------------------------------------------------------------------------------
//------------------------------------------------------------------------------------------
//------------------------------------------------------------------------------------------

/** @brief 3D listmode tof joseph forward projector CUDA wrapper
 *
 *  @param h_xstart array of shape [3*nlors] with the coordinates of the start points of the LORs.
 *                  The start coordinates of the n-th LOR are at xstart[n*3 + i] with i = 0,1,2 
 *  @param h_xend   array of shape [3*nlors] with the coordinates of the end   points of the LORs.
 *                  The start coordinates of the n-th LOR are at xstart[n*3 + i] with i = 0,1,2 
 *  @param h_img    array of shape [n0*n1*n2] containing the 3D image to be projected.
 *                  The pixel [i,j,k] ist stored at [n1*n2+i + n2*k + j].
 *  @param h_img_origin  array [x0_0,x0_1,x0_2] of coordinates of the center of the [0,0,0] voxel
 *  @param h_voxsize     array [vs0, vs1, vs2] of the voxel sizes
 *  @param h_p           array of length nlors (output) used to store the projections
 *  @param nlors         number of projections (length of p array)
 *  @param h_img_dim     array with dimensions of image [n0,n1,n2]
 *  @param n_tofbins        number of TOF bins
 *  @param tofbin_width     width of the TOF bins in spatial units (units of xstart and xend)
 *  @param sigma_tof        array of length nlors with the TOF resolution (sigma) for each LOR in
 *                          spatial units (units of xstart and xend) 
 *  @param tofcenter_offset array of length nlors with the offset of the central TOF bin from the 
 *                          midpoint of each LOR in spatial units (units of xstart and xend) 
 *  @param n_sigmas         number of sigmas to consider for calculation of TOF kernel
 *  @param half_erf_lut     look up table length 6001 for half erf between -3 and 3. 
 *                          The i-th element contains 0.5*erf(-3 + 0.001*i)
 *  @param threadsperblock number of threads per block
 *  @param num_devices     number of CUDA devices to use. if set to -1 cudaGetDeviceCount() is used
 */
extern "C" void joseph3d_fwd_tof_lm_cuda(float *h_xstart, 
                                           float *h_xend, 
                                           float *h_img,
                                           float *h_img_origin, 
                                           float *h_voxsize, 
                                           float *h_p,
                                           unsigned long long nlors, 
                                           unsigned int *h_img_dim,
		                                       int n_tofbins,
		                                       float tofbin_width,
		                                       float *h_sigma_tof,
		                                       float *h_tofcenter_offset,
		                                       int *h_tof_bin,
                                           float *h_half_erf_lut,
                                           unsigned int threadsperblock,
                                           int num_devices)
{
	cudaError_t error;	
  unsigned int blockspergrid;

  dim3 block(threadsperblock);

  // offset for chunk of projections passed to a device 
  unsigned long long dev_offset;
  // number of projections to be calculated on a device
  unsigned long long dev_nlors;

  unsigned int n0 = h_img_dim[0];
  unsigned int n1 = h_img_dim[1];
  unsigned int n2 = h_img_dim[2];

  unsigned long long img_bytes = (n0*n1*n2)*sizeof(float);
  unsigned long long proj_bytes_dev;

  // get number of avilable CUDA devices specified as <=0 in input
  if(num_devices <= 0){cudaGetDeviceCount(&num_devices);}  

  // init the dynamic arrays of device arrays
  float **d_p              = new float * [num_devices];
  float **d_xstart         = new float * [num_devices];
  float **d_xend           = new float * [num_devices];
  float **d_img            = new float * [num_devices];
  float **d_img_origin     = new float * [num_devices];
  float **d_voxsize        = new float * [num_devices];
  unsigned int **d_img_dim = new unsigned int * [num_devices];

  // init the dynamic arrays of TOF device arrays
  float **d_sigma_tof        = new float * [num_devices];
  float **d_tofcenter_offset = new float * [num_devices];
  float **d_half_erf_lut     = new float * [num_devices];
  int **d_tof_bin            = new int * [num_devices];

  printf("\n # CUDA devices: %d \n", num_devices);

  // we split the projections across all CUDA devices
  for (unsigned int i_dev = 0; i_dev < num_devices; i_dev++) 
  {
    cudaSetDevice(i_dev);
    // () are important in integer division!
    dev_offset = i_dev*(nlors/num_devices);
 
    // calculate the number of projections for a device (last chunck can be a bit bigger) 
    dev_nlors = i_dev == (num_devices - 1) ? (nlors - dev_offset) : (nlors/num_devices);

    // calculate the number of bytes for the projection array on the device
    proj_bytes_dev = dev_nlors*sizeof(float);

    // calculate the number of blocks needed for every device (chunk)
    blockspergrid = (unsigned int)ceil((float)dev_nlors / threadsperblock);
    dim3 grid(blockspergrid);

    // allocate the memory for the array containing the projection on the device
    error = cudaMalloc(&d_p[i_dev], proj_bytes_dev);
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemsetAsync(d_p[i_dev], 0, proj_bytes_dev);

    error = cudaMalloc(&d_xstart[i_dev], 3*proj_bytes_dev);
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_xstart[i_dev], h_xstart + 3*dev_offset, 3*proj_bytes_dev, 
                    cudaMemcpyHostToDevice);

    error = cudaMalloc(&d_xend[i_dev], 3*proj_bytes_dev);
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_xend[i_dev], h_xend + 3*dev_offset, 3*proj_bytes_dev, 
                    cudaMemcpyHostToDevice);
   
    error = cudaMalloc(&d_img[i_dev], img_bytes);
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_img[i_dev], h_img, img_bytes, cudaMemcpyHostToDevice);

    error = cudaMalloc(&d_img_origin[i_dev], 3*sizeof(float));
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_img_origin[i_dev], h_img_origin, 3*sizeof(float), 
                    cudaMemcpyHostToDevice);

    error = cudaMalloc(&d_voxsize[i_dev], 3*sizeof(float));
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_voxsize[i_dev], h_voxsize, 3*sizeof(float), cudaMemcpyHostToDevice);

    error = cudaMalloc(&d_img_dim[i_dev], 3*sizeof(unsigned int));
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_img_dim[i_dev], h_img_dim, 3*sizeof(unsigned int), cudaMemcpyHostToDevice);

    // send TOF arrays to device
    error = cudaMalloc(&d_sigma_tof[i_dev], proj_bytes_dev);
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_sigma_tof[i_dev], h_sigma_tof + dev_offset, proj_bytes_dev, cudaMemcpyHostToDevice);

    error = cudaMalloc(&d_tofcenter_offset[i_dev], proj_bytes_dev);
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_tofcenter_offset[i_dev], h_tofcenter_offset + dev_offset, proj_bytes_dev, 
                    cudaMemcpyHostToDevice);

    error = cudaMalloc(&d_half_erf_lut[i_dev], 6001*sizeof(float));
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_half_erf_lut[i_dev], h_half_erf_lut, 6001*sizeof(float), cudaMemcpyHostToDevice);

    error = cudaMalloc(&d_tof_bin[i_dev], dev_nlors*sizeof(int));
	  if (error != cudaSuccess){
        printf("cudaMalloc returned error %s (code %d), line(%d)\n", cudaGetErrorString(error), error, __LINE__);
        exit(EXIT_FAILURE);}
    cudaMemcpyAsync(d_tof_bin[i_dev], h_tof_bin + dev_offset, proj_bytes_dev, cudaMemcpyHostToDevice);

    // call the kernel
    joseph3d_fwd_tof_lm_cuda_kernel<<<grid,block>>>(d_xstart[i_dev], d_xend[i_dev], d_img[i_dev], 
                                                    d_img_origin[i_dev], d_voxsize[i_dev], 
                                                    d_p[i_dev], dev_nlors, d_img_dim[i_dev],
		                                                n_tofbins, tofbin_width, d_sigma_tof[i_dev],
		                                                d_tofcenter_offset[i_dev], d_tof_bin[i_dev], 
                                                    d_half_erf_lut[i_dev]);

    // copy projection back from device to host
    cudaMemcpyAsync(h_p + dev_offset, d_p[i_dev], proj_bytes_dev, cudaMemcpyDeviceToHost);

    // deallocate memory on device
    cudaFree(d_p[i_dev]);
    cudaFree(d_xstart[i_dev]);
    cudaFree(d_xend[i_dev]);
    cudaFree(d_img);
    cudaFree(d_img_origin);
    cudaFree(d_voxsize);

    // deallocate TOF memory on device
    cudaFree(d_sigma_tof[i_dev]);
    cudaFree(d_tofcenter_offset[i_dev]);
    cudaFree(d_half_erf_lut[i_dev]);
    cudaFree(d_tof_bin[i_dev]);
  }

  // make sure that all devices are done before leaving
  for (unsigned int i_dev = 0; i_dev < num_devices; i_dev++){cudaDeviceSynchronize();}
}
