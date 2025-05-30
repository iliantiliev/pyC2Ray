#include "raytracing_He.cuh"
#include "memory_He.cuh"
#include "rates.cuh"
#include <exception>
#include <string>
#include <iostream>

// ========================================================================
// Define macros. Could be passed as parameters but are kept as
// compile-time constants for now
// ========================================================================
#define FOURPI 12.566370614359172463991853874177    // 4π
#define INV4PI 0.079577471545947672804111050482     // 1/4π
#define SQRT3 1.73205080757                         // Square root of 3
#define MAX_COLDENSH 2e30                           // Column density limit (rates are set to zero above this)
#define CUDA_BLOCK_SIZE 256                         // Size of blocks used to treat sources

// ========================================================================
// Utility Device Functions
// ========================================================================

// Fortran-type modulo function (C modulo is signed)
inline int modulo(const int & a,const int & b) { return (a%b+b)%b; }
inline __device__ int modulo_gpu(const int & a,const int & b) { return (a%b+b)%b; }

// Sign function on the device
inline __device__ int sign_gpu(const double & x) { if (x>=0) return 1; else return -1;}

// Flat-array index from 3D (i,j,k) indices
inline __device__ int mem_offst_gpu(const int & i,const int & j,const int & k,const int & N) { return N*N*i + N*j + k;}

// Weight function for C2Ray interpolation function (see cinterp_gpu below)
__device__ inline double weightf_gpu(const double & cd, const double & sig) { return 1.0/max(0.6,cd*sig);}

// Mapping from cartesian coordinates of a cell to reduced cache memory space (here N = 2qmax + 1 in general)
__device__ inline int cart2cache(const int & i,const int & j,const int & k,const int & N) { return N*N*int(k<0) + N*i + j; }

// Mapping from linear 1D indices to the cartesian coords of a q-shell in asora
__device__ void linthrd2cart(const int & s,const int & q,int& i,int& j)
{
    if (s == 0)
    {
        i = q;
        j = 0;
    }
    else
    {
        int b = (s - 1) / (2*q);
        int a = (s - 1) % (2*q);

        if (a + 2*b > 2*q)
        {
            a = a + 1;
            b = b - 1 - q;
        }
        i = a + b - q;
        j = b;
    }
}

// When using a GPU with compute capability < 6.0, we must manually define the atomicAdd function for doubles
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ < 600
static __inline__ __device__ double atomicAdd(double *address, double val) {
unsigned long long int* address_as_ull = (unsigned long long int*)address;
unsigned long long int old = *address_as_ull, assumed;
if (val==0.0)
    return __longlong_as_double(old);
do {
    assumed = old;
    old = atomicCAS(address_as_ull, assumed, __double_as_longlong(val +__longlong_as_double(assumed)));
} while (assumed != old);
return __longlong_as_double(old);
}
#endif

// ========================================================================
// Raytrace all sources and add up ionization rates
// ========================================================================
void do_all_sources_gpu(
    const double & R,
    double* coldensh_out_hi,
    double* coldensh_out_hei,
    double* coldensh_out_heii,
    double* sig_hi,       // These now are arrays of the cross section for the three elements
    double* sig_hei,
    double* sig_heii,
    const int & NumBin1,        // and these are the size of the frequency sub-bins (in the original paper this was 1, 26 and 20)
    const int & NumBin2,
    const int & NumBin3,
    const double & dr,
    double* ndens,
    double* xHII_av,
    double* xHeII_av,
    double* xHeIII_av,
    double* phi_ion_HI,
    double* phi_ion_HeI,
    double* phi_ion_HeII,
    double* phi_heat_HI,
    double* phi_heat_HeI,
    double* phi_heat_HeII,
    const int & NumSrc,
    const int & m1,
    const double & minlogtau,
    const double & dlogtau,
    const int & NumTau)
    {   
        
        // Byte-size of grid data
        int meshsize = m1*m1*m1*sizeof(double);

        // Number of frequency bins
        int NumFreq = NUM_FREQ;
        int freqsize = NumFreq*sizeof(double);

        //std::cout << "R: " << R << std::endl;
        // Determine how large the octahedron should be, based on the raytracing radius. Currently, this is set s.t. the radius equals the distance from the source to the middle of the faces of the octahedron. To raytrace the whole box, the octahedron bust be 1.5*N in size
        int max_q = std::ceil(SQRT3 * min(R,SQRT3*m1/2.0));
        //int max_q = std::ceil(SQRT3 * R); //std::ceil(1.5 * m1);
        //std::cout << "max_q: " << max_q << std::endl;

        // CUDA Grid size: since 1 block = 1 source, this sets the number of sources treated in parallel
        dim3 gs(NUM_SRC_PAR);

        // CUDA Block size: more of a tuning parameter (see above), in practice anything ~128 is fine
        dim3 bs(CUDA_BLOCK_SIZE);

        // Here we fill the ionization and heating rate array with zero before raytracing all sources. The LOCALRATES flag is for debugging purposes and will be removed later on
        cudaMemset(phi_HI_dev, 0, meshsize);
        cudaMemset(phi_HeI_dev, 0, meshsize);
        cudaMemset(phi_HeII_dev, 0, meshsize);
        cudaMemset(heat_HI_dev, 0, meshsize);
        cudaMemset(heat_HeI_dev, 0, meshsize);
        cudaMemset(heat_HeII_dev, 0, meshsize);

        // Copy current ionization fraction to the device
        cudaMemcpy(xHI_dev, xHII_av, meshsize, cudaMemcpyHostToDevice);
        cudaMemcpy(xHeI_dev, xHeII_av, meshsize, cudaMemcpyHostToDevice);
        cudaMemcpy(xHeII_dev, xHeIII_av, meshsize, cudaMemcpyHostToDevice);
        cudaMemcpy(sig_hi_dev, sig_hi, freqsize, cudaMemcpyHostToDevice);
        cudaMemcpy(sig_hei_dev, sig_hei, freqsize, cudaMemcpyHostToDevice);
        cudaMemcpy(sig_heii_dev, sig_heii, freqsize, cudaMemcpyHostToDevice);

        // Since the grid is periodic, we limit the maximum size of the raytraced region to a cube as large as the mesh around the source.
        // See line 93 of evolve_source in C2Ray, this size will depend on if the mesh is even or odd.
        // Basically the idea is that you never touch a cell which is outside a cube of length ~N centered on the source
        int last_r = m1/2 - 1 + modulo(m1,2);
        int last_l = -m1/2;

        // flag that indicated the frequency bin for: HI (value 0), HI+HeI (value 1) and HI+HeI+HeII (value 2)
        //int freq_flag=0;

        // Loop over batches of sources
        for (int ns = 0; ns < NumSrc; ns += NUM_SRC_PAR)
        {
            evolve0D_gpu<<<gs,bs>>>(R, max_q, ns, NumSrc, NUM_SRC_PAR, src_pos_dev, src_flux_dev, cdh_dev, cdhei_dev, cdheii_dev, sig_hi_dev, sig_hei_dev, sig_heii_dev, dr, n_dev, xHI_dev, xHeI_dev, xHeII_dev, phi_HI_dev, phi_HeI_dev, phi_HeII_dev, heat_HI_dev, heat_HeI_dev, heat_HeII_dev, m1, photo_thin_table_dev, photo_thick_table_dev, heat_thin_table_dev, heat_thick_table_dev, minlogtau, dlogtau, NumTau, NumBin1, NumBin2, NumBin3, NUM_FREQ, last_l, last_r);

            // Check for errors
            auto error = cudaGetLastError();
            if(error != cudaSuccess) {
                throw std::runtime_error("Error Launching Kernel: " + std::string(cudaGetErrorName(error)) + " - " + std::string(cudaGetErrorString(error)));
            }
            
            // Sync device to be sure (is this required ??)
            cudaDeviceSynchronize();
        }

        // Copy the accumulated ionization fraction and column density back to the host
        auto error1 = cudaMemcpy(phi_ion_HI, phi_HI_dev, meshsize, cudaMemcpyDeviceToHost);
        auto error2 = cudaMemcpy(phi_ion_HeI, phi_HeI_dev, meshsize, cudaMemcpyDeviceToHost);
        auto error3 = cudaMemcpy(phi_ion_HeII, phi_HeII_dev, meshsize, cudaMemcpyDeviceToHost);
        auto error4 = cudaMemcpy(phi_heat_HI, heat_HI_dev, meshsize, cudaMemcpyDeviceToHost);
        auto error5 = cudaMemcpy(phi_heat_HeI, heat_HeI_dev, meshsize, cudaMemcpyDeviceToHost);
        auto error6 = cudaMemcpy(phi_heat_HeII, heat_HeII_dev, meshsize, cudaMemcpyDeviceToHost);
        auto error7 = cudaMemcpy(coldensh_out_hi, cdh_dev, meshsize, cudaMemcpyDeviceToHost);
        auto error8 = cudaMemcpy(coldensh_out_hei, cdhei_dev, meshsize, cudaMemcpyDeviceToHost);
        auto error9 = cudaMemcpy(coldensh_out_heii, cdheii_dev, meshsize, cudaMemcpyDeviceToHost);

    }


// ========================================================================
// Raytracing kernel, adapted from C2Ray. Calculates in/out column density
// to the current cell and finds the photoionization rate
// ========================================================================
__global__ void evolve0D_gpu(
    const double Rmax_LLS,
    const int q_max,    // Is now the size of max q
    const int ns_start,
    const int NumSrc,
    const int num_src_par,
    int* src_pos,
    double* src_flux,
    double* coldensh_out_hi,
    double* coldensh_out_hei,
    double* coldensh_out_heii,
    double* sig_hi,    // This are the cross sections for the three elements at different frequency (frequency loop is outside)
    double* sig_hei,
    double* sig_heii,
    const double dr,
    const double* ndens,
    const double* xHII_av,
    const double* xHeII_av,
    const double* xHeIII_av,
    double* phi_ion_HI,
    double* phi_ion_HeI,
    double* phi_ion_HeII, 
    double* phi_heat_HI,
    double* phi_heat_HeI,
    double* phi_heat_HeII, 
    const int m1,
    const double* photo_thin_table,
    const double* photo_thick_table,
    const double* heat_thin_table,
    const double* heat_thick_table,
    const double minlogtau,
    const double dlogtau,
    const int NumTau,
    const int NumBin1,
    const int NumBin2,
    const int NumBin3,
    const int NumFreq,
    const int last_l,
    const int last_r
)
{   
    /* The raytracing kernel proceeds as follows:
    1. Select the source based on the block number (within the batch = the grid)
    2. Loop over the asora q-cells around the source, up to q_max (loop "A")
    3. Inside each shell, threads independently do all cells, possibly requiring multiple iterations if the block size is smaller than the number of cells in the shell (loop "B")
    4. After each shell, the threads are synchronized to ensure that causality is respected
    */

    //TODO: later need to import this from parameters.ylm
    double abu_he_mass = 0.2486;

    // Source number = Start of batch + block number (each block does one source)
    int ns = ns_start + blockIdx.x;

    // Offset pointer to the outgoing column density array used for interpolation (each block needs its own copy of the array)
    int cdh_offset = blockIdx.x * m1 * m1 * m1;

    // Ensure the source index is valid
    if (ns < NumSrc)
    {   
        // (A) Loop over ASORA q-shells
        for (int q = 0 ; q <= q_max ; q++)
        {   
            // We figure out the number of cells in the shell and determine how many passes the block needs to take to treat all of them
            int num_cells = 4*q*q + 2;
            int Npass = num_cells / blockDim.x + 1;

            /* The threads have 1D indices 0,...,blocksize-1. We map these 1D indices to the 3D positions of the cells inside the shell via the mapping described in the paper. Since in general there are more cells than threads, there is an additional loop here (B) so that all cells are treated. */
            int s_end;
            if (q == 0) {s_end = 1;}
            else {s_end = 4*q*q + 2;}
            int s_end_top = 2*q*(q+1) + 1;
            
            // (B) Loop over cells in the shell
            for (int ipass = 0 ; ipass < Npass ; ipass++)
            {
                // "s" is the index in the 1D-range [0,...,4q^2 + 1] that gets mapped to the cells in the shell
                int s = ipass * blockDim.x +  threadIdx.x;
                int i,j,k;
                int sgn;

                // Ensure the thread maps to a valid cell
                if (s < s_end)
                {
                    // Determine if cell is in top or bottom part of the shell (the mapping is slightly different due to the part that is on the same z-plane as the source)
                    if (s < s_end_top)
                    {
                        sgn = 1;
                        linthrd2cart(s,q,i,j);
                    }
                    else
                    {
                        sgn = -1;
                        linthrd2cart(s-s_end_top,q-1,i,j);
                    }
                    k = sgn*q - sgn*(abs(i) + abs(j));

                    // Only do cell if it is within the (shifted under periodicity) grid, i.e. at most ~N cells away from the source
                    if ((i >= last_l) && (i <= last_r) && (j >= last_l) && (j <= last_r) && (k >= last_l) && (k <= last_r))
                    {
                        // Get source properties
                        int i0 = src_pos[3*ns + 0];
                        int j0 = src_pos[3*ns + 1];
                        int k0 = src_pos[3*ns + 2];
                        double strength = src_flux[ns];

                        // Center to source
                        i += i0;
                        j += j0;
                        k += k0;

                        int pos[3];
                        double path;
                        double coldens_in_hi;            // HI Column density to the cell
                        double coldens_in_hei;           // HeI Column density to the cell
                        double coldens_in_heii;          // HeII Column density to the cell
                        double nHI_p;                    // Local density of HI in the cell
                        double nHeI_p;                   // Local density of HeI in the cell
                        double nHeII_p;                  // Local density of HeII in the cell
                        double xh_av_p;                  // Local hydrogen ionization fraction of cell
                        double xhei_av_p;                // Local helium first ionization fraction of cell
                        double xheii_av_p;               // Local helium second ionization fraction of cell

                        double xs, ys, zs;
                        double dist2;
                        double vol_ph;

                        // When not in periodic mode, only treat cell if its in the grid
                        #if !defined(PERIODIC)
                        if (in_box_gpu(i,j,k,m1))
                        #endif
                        {   
                            // Map to periodic grid
                            pos[0] = modulo_gpu(i,m1);
                            pos[1] = modulo_gpu(j,m1);
                            pos[2] = modulo_gpu(k,m1);

                            // Get local ionization fraction of HII, HeII and HeIII 
                            xh_av_p = xHII_av[mem_offst_gpu(pos[0],pos[1],pos[2],m1)];
                            xheii_av_p = xHeIII_av[mem_offst_gpu(pos[0],pos[1],pos[2],m1)];
                            xhei_av_p = xHeII_av[mem_offst_gpu(pos[0],pos[1],pos[2],m1)];
                            
                            // Get local HI number density
                            nHI_p = ndens[mem_offst_gpu(pos[0],pos[1],pos[2],m1)] * (1.0 - abu_he_mass) * (1.0 - xh_av_p);
                            
                            // Get local HeI number density
                            nHeI_p = ndens[mem_offst_gpu(pos[0],pos[1],pos[2],m1)] * abu_he_mass * (1.0 - xhei_av_p - xheii_av_p);

                            // Get local HeII number density
                            nHeII_p = ndens[mem_offst_gpu(pos[0],pos[1],pos[2],m1)] * abu_he_mass * xhei_av_p;

                            // If its the source cell, just find path (no incoming column density), otherwise if its another cell, do interpolation to find incoming column density
                            if (i == i0 && j == j0 && k == k0)
                            {
                                coldens_in_hi = 0.0;
                                coldens_in_hei = 0.0;
                                coldens_in_heii = 0.0;
                                path = 0.5*dr;
                                // vol_ph = dr*dr*dr / (4*M_PI);
                                vol_ph = dr*dr*dr;
                                dist2 = 0.0;
                            } 
                            else
                            {
                                cinterp_gpu(i, j, k, i0, j0, k0, coldens_in_hi, path, coldensh_out_hi + cdh_offset, sig_hi[0], m1);
                                cinterp_gpu(i, j, k, i0, j0, k0, coldens_in_hei, path, coldensh_out_hei + cdh_offset, sig_hei[0], m1);
                                cinterp_gpu(i, j, k, i0, j0, k0, coldens_in_heii, path, coldensh_out_heii + cdh_offset, sig_heii[0], m1);
                                
                                path *= dr;
                                // Find the distance to the source
                                xs = dr*(i-i0);
                                ys = dr*(j-j0);
                                zs = dr*(k-k0);
                                dist2=xs*xs+ys*ys+zs*zs;
                                // vol_ph = dist2 * path;
                                vol_ph = dist2 * path * FOURPI;
                            }

                            // Compute outgoing column density and add to array for subsequent interpolations
                            double cdo_hi = coldens_in_hi + nHI_p * path;
                            double cdo_hei = coldens_in_hei + nHeI_p * path;
                            double cdo_heii = coldens_in_heii + nHeII_p * path;
                            
                            // Add the computed column density for the three species to the array ATOMICALLY 
                            atomicAdd(coldensh_out_hi + mem_offst_gpu(pos[0],pos[1],pos[2],m1), cdo_hi);
                            atomicAdd(coldensh_out_hei + mem_offst_gpu(pos[0],pos[1],pos[2],m1), cdo_hei);
                            atomicAdd(coldensh_out_heii + mem_offst_gpu(pos[0],pos[1],pos[2],m1), cdo_heii);
                            
                            // Compute photoionization rates from column density. WARNING: for now this is limited to the grey-opacity test case source                            
                            if ((coldens_in_hi <= MAX_COLDENSH) && (coldens_in_hei <= MAX_COLDENSH) && (coldens_in_heii <= MAX_COLDENSH) && (dist2/(dr*dr) <= Rmax_LLS*Rmax_LLS))
                            {   
                                // frequency loop 
                                for (int nf = 0; nf < NumFreq; nf += 1)
                                {
                                    double tau_in_tot;
                                    double tau_out_tot;
                                    double tau_out_hi;
                                    double tau_out_hei;
                                    double tau_out_heii;
                                    
                                    if(nf < NumBin1) // first frequency bin ionizes just HI
                                    {
                                        // Compute optical depth
                                        tau_out_hi = cdo_hi * sig_hi[nf];

                                        // total optical depth
                                        tau_in_tot = coldens_in_hi * sig_hi[nf];
                                        tau_out_tot = tau_out_hi;
                                    }else if((nf >= NumBin1) && (nf < NumBin1+NumBin2)) // second frequency bin ionizes HI and HeI
                                    {

                                        // Compute optical depth
                                        tau_out_hi = cdo_hi * sig_hi[nf];
                                        tau_out_hei = cdo_hei * sig_hei[nf];

                                        // total optical depth
                                        tau_in_tot = coldens_in_hi * sig_hi[nf] + coldens_in_hei * sig_hei[nf];
                                        tau_out_tot = tau_out_hi + tau_out_hei;
                                    }else if((nf >= NumBin1+NumBin2) && (nf < NumBin1+NumBin2+NumBin3)) // third frequency bin ionizes HI, HeI and HeII
                                    {
                                        // Compute optical depth
                                        tau_out_hi = cdo_hi * sig_hi[nf];
                                        tau_out_hei = cdo_hei * sig_hei[nf];
                                        tau_out_heii = cdo_heii * sig_heii[nf];

                                        // total optical depth
                                        tau_in_tot = coldens_in_hi * sig_hi[nf] + coldens_in_hei * sig_hei[nf] + coldens_in_heii * sig_heii[nf];
                                        tau_out_tot = tau_out_hi + tau_out_hei + tau_out_heii;
                                    }

                                    //printf("%i\t%e\t%e\t%e\n", nf, sig_hi[nf], sig_hei[nf], sig_heii[nf]);
                                    //printf("%i\t%.3e\t%.3e\t%e\n", nf, tau_in_tot, tau_out_tot, tau_out_tot-tau_in_tot);
                                                                            
                                    //printf("%lf\n", vol_ph);
                                    double phi = photoion_rates_gpu(strength, tau_in_tot, tau_out_tot, nf, vol_ph, photo_thin_table, photo_thick_table, minlogtau, dlogtau, NumTau, NumFreq);
                                    double heat = photoheat_rates_gpu(strength, tau_in_tot, tau_out_tot, nf, vol_ph, heat_thin_table, heat_thick_table, minlogtau, dlogtau, NumTau, NumFreq);
                                    
                                    // Assign the photo-ionization and heating rates to each element (part of the photon-conserving rate prescription)
                                    double phi_HI = phi * tau_out_hi / tau_out_tot / nHI_p;
                                    double phi_HeI = phi * tau_out_hei / tau_out_tot / nHeI_p;
                                    double phi_HeII = phi * tau_out_heii / tau_out_tot / nHeII_p;
                                    double heat_HI = heat * tau_out_hi / tau_out_tot / nHI_p;
                                    double heat_HeI = heat * tau_out_hei / tau_out_tot / nHeI_p;
                                    double heat_HeII = heat * tau_out_heii / tau_out_tot / nHeII_p;
                            
                                    // Add the computed ionization and heating rate to the array ATOMICALLY since multiple blocks could be writing to the same cell at the same time!
                                    atomicAdd(phi_ion_HI + mem_offst_gpu(pos[0],pos[1],pos[2], m1), phi_HI);
                                    atomicAdd(phi_ion_HeI + mem_offst_gpu(pos[0],pos[1],pos[2], m1), phi_HeI);
                                    atomicAdd(phi_ion_HeII + mem_offst_gpu(pos[0],pos[1],pos[2], m1), phi_HeII);
                                    atomicAdd(phi_heat_HI + mem_offst_gpu(pos[0],pos[1],pos[2], m1), heat_HI);
                                    atomicAdd(phi_heat_HeI + mem_offst_gpu(pos[0],pos[1],pos[2], m1), heat_HeI);
                                    atomicAdd(phi_heat_HeII + mem_offst_gpu(pos[0],pos[1],pos[2], m1), heat_HeII);
                                
                                } // end loop freq
                            }
                            
                       
                        }
                    }
                }
            }
            // IMPORTANT: Sync threads after each shell so that the next only begins when all outgoing column densities of the current shell are available
            __syncthreads();
        }
    }
}


// ========================================================================
// Short-characteristics interpolation function
// ========================================================================
__device__ void cinterp_gpu(
    const int i,
    const int j,
    const int k,
    const int i0,
    const int j0,
    const int k0,
    double & cdensi,
    double & path,
    double* coldensh_out,
    const double sigma_at_freq,     // This is now considered for any elements at any frequency
    const int & m1)
{
    int idel,jdel,kdel;
    int idela,jdela,kdela;
    int im,jm,km;
    unsigned int ip,imp,jp,jmp,kp,kmp;
    int sgni,sgnj,sgnk;
    double alam,xc,yc,zc,dx,dy,dz,s1,s2,s3,s4;
    double c1,c2,c3,c4;
    double w1,w2,w3,w4;
    double di,dj,dk;

    // calculate the distance between the source point (i0,j0,k0) and the destination point (i,j,k)
    idel = i-i0;
    jdel = j-j0;
    kdel = k-k0;
    idela = abs(idel);
    jdela = abs(jdel);
    kdela = abs(kdel);
    
    // Find coordinates of points closer to source
    sgni = sign_gpu(idel);
    sgnj = sign_gpu(jdel);
    sgnk = sign_gpu(kdel);
    im = i-sgni;
    jm = j-sgnj;
    km = k-sgnk;
    di = double(idel);
    dj = double(jdel);
    dk = double(kdel);

    // Z plane (bottom and top face) crossing
    // we find the central (c) point (xc,xy) where the ray crosses the z-plane below or above the destination (d) point, find the column density there through interpolation, and add the contribution of the neutral material between the c-point and the destination point.
    if (kdela >= jdela && kdela >= idela) {
        // alam is the parameter which expresses distance along the line s to d
        // add 0.5 to get to the interface of the d cell.
        alam = (double(km-k0)+sgnk*0.5)/dk;
            
        xc = alam*di+double(i0); // x of crossing point on z-plane 
        yc = alam*dj+double(j0); // y of crossing point on z-plane
        
        dx = 2.0*abs(xc-(double(im)+0.5*sgni)); // distances from c-point to
        dy = 2.0*abs(yc-(double(jm)+0.5*sgnj)); // the corners.
        
        s1 = (1.-dx)*(1.-dy);    // interpolation weights of
        s2 = (1.-dy)*dx;         // corner points to c-point
        s3 = (1.-dx)*dy;
        s4 = dx*dy;

        ip = modulo_gpu(i, m1);
        imp = modulo_gpu(im, m1);
        jp = modulo_gpu(j, m1);
        jmp = modulo_gpu(jm, m1);
        kmp = modulo_gpu(km, m1);
        
        c1 = coldensh_out[mem_offst_gpu(imp,jmp,kmp,m1)];
        c2 = coldensh_out[mem_offst_gpu(ip,jmp,kmp,m1)];
        c3 = coldensh_out[mem_offst_gpu(imp,jp,kmp,m1)];
        c4 = coldensh_out[mem_offst_gpu(ip,jp,kmp,m1)];

        // extra weights for better fit to analytical solution
        w1 = s1*weightf_gpu(c1,sigma_at_freq);
        w2 = s2*weightf_gpu(c2,sigma_at_freq);
        w3 = s3*weightf_gpu(c3,sigma_at_freq);
        w4 = s4*weightf_gpu(c4,sigma_at_freq);
        
        // column density at the crossing point
        cdensi = (c1*w1 + c2*w2 + c3*w3 + c4*w4)/(w1 + w2 + w3 + w4);

        // Take care of diagonals
        if (kdela == 1 && (idela == 1||jdela == 1))
        {
            if (idela == 1 && jdela == 1)
            {
                cdensi = 1.73205080757*cdensi;
            }
            else
            {
                cdensi = 1.41421356237*cdensi;
            }
        }

        // Path length from c through d to other side cell.
        path = sqrt((di*di+dj*dj)/(dk*dk)+1.0);
    }
    else if (jdela >= idela && jdela >= kdela)
    {
        alam = (double(jm-j0)+sgnj*0.5)/dj;
        zc = alam*dk+double(k0);
        xc = alam*di+double(i0);
        dz = 2.0*abs(zc-(double(km)+0.5*sgnk));
        dx = 2.0*abs(xc-(double(im)+0.5*sgni));
        s1 = (1.-dx)*(1.-dz);
        s2 = (1.-dz)*dx;
        s3 = (1.-dx)*dz;
        s4 = dx*dz;

        ip  = modulo_gpu(i, m1);
        imp = modulo_gpu(im, m1);
        jmp = modulo_gpu(jm, m1);
        kp  = modulo_gpu(k, m1);
        kmp = modulo_gpu(km, m1);

        c1 = coldensh_out[mem_offst_gpu(imp,jmp,kmp,m1)];
        c2 = coldensh_out[mem_offst_gpu(ip,jmp,kmp,m1)];
        c3 = coldensh_out[mem_offst_gpu(imp,jmp,kp,m1)];
        c4 = coldensh_out[mem_offst_gpu(ip,jmp,kp,m1)];

        // extra weights for better fit to analytical solution
        w1 = s1*weightf_gpu(c1,sigma_at_freq);
        w2 = s2*weightf_gpu(c2,sigma_at_freq);
        w3 = s3*weightf_gpu(c3,sigma_at_freq);
        w4 = s4*weightf_gpu(c4,sigma_at_freq);

        cdensi = (c1*w1 + c2*w2 + c3*w3 + c4*w4)/(w1 + w2 + w3 + w4);

        // Take care of diagonals
        if (jdela == 1 && (idela == 1||kdela == 1))
        {
            if (idela == 1 && kdela == 1)
            {
                cdensi = 1.73205080757*cdensi;
            }
            else
            {
                cdensi = 1.41421356237*cdensi;
            }
        }
        path = sqrt((di*di+dk*dk)/(dj*dj)+1.0);
    }
    else
    {
        alam = (double(im-i0)+sgni*0.5)/di;
        zc = alam*dk+double(k0);
        yc = alam*dj+double(j0);
        dz = 2.0*abs(zc-(double(km)+0.5*sgnk));
        dy = 2.0*abs(yc-(double(jm)+0.5*sgnj));
        s1 = (1.-dz)*(1.-dy);
        s2 = (1.-dz)*dy;
        s3 = (1.-dy)*dz;
        s4 = dy*dz;

        imp = modulo_gpu(im, m1);
        jp = modulo_gpu(j, m1);
        jmp = modulo_gpu(jm, m1);
        kp = modulo_gpu(k, m1);
        kmp = modulo_gpu(km, m1);

        c1 = coldensh_out[mem_offst_gpu(imp,jmp,kmp,m1)];
        c2 = coldensh_out[mem_offst_gpu(imp,jp,kmp,m1)];
        c3 = coldensh_out[mem_offst_gpu(imp,jmp,kp,m1)];
        c4 = coldensh_out[mem_offst_gpu(imp,jp,kp,m1)];

        // extra weights for better fit to analytical solution
        w1 = s1*weightf_gpu(c1,sigma_at_freq);
        w2 = s2*weightf_gpu(c2,sigma_at_freq);
        w3 = s3*weightf_gpu(c3,sigma_at_freq);
        w4 = s4*weightf_gpu(c4,sigma_at_freq);

        cdensi = (c1*w1 + c2*w2 + c3*w3 + c4*w4)/(w1 + w2 + w3 + w4);

        if ( idela == 1  &&  ( jdela == 1 || kdela == 1 ) )
        {
            if ( jdela == 1  &&  kdela == 1 )
            {
                cdensi = 1.73205080757*cdensi;
            }
            else
            {
                cdensi = 1.41421356237*cdensi;
            }
        }
        path = sqrt(1.0+(dj*dj+dk*dk)/(di*di));
    }
}
