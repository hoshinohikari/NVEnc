﻿// -----------------------------------------------------------------------------------------
// NVEnc by rigaya
// -----------------------------------------------------------------------------------------
//
// The MIT License
//
// Copyright (c) 2014-2016 rigaya
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
// ------------------------------------------------------------------------------------------

#include <array>
#include <map>
#include "convert_csp.h"
#include "NVEncFilterDenoiseDct.h"
#include "NVEncParam.h"
#pragma warning (push)
#pragma warning (disable: 4819)
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "rgy_cuda_util_kernel.h"
#pragma warning (pop)

#define DENOISE_BLOCK_SIZE_X (8) //ひとつのスレッドブロックの担当するx方向の8x8ブロックの数

#define DENOISE_SHARED_BLOCK_NUM_X (DENOISE_BLOCK_SIZE_X+2) //sharedメモリ上のx方向の8x8ブロックの数
#define DENOISE_SHARED_BLOCK_NUM_Y (2)                      //sharedメモリ上のy方向の8x8ブロックの数

#define DENOISE_LOOP_COUNT_BLOCK (8)

#define DCT3X3_0_0 ( 0.5773502691896258f) /*  1/sqrt(3) */
#define DCT3X3_0_1 ( 0.5773502691896258f) /*  1/sqrt(3) */
#define DCT3X3_0_2 ( 0.5773502691896258f) /*  1/sqrt(3) */
#define DCT3X3_1_0 ( 0.7071067811865475f) /*  1/sqrt(2) */
#define DCT3X3_1_2 (-0.7071067811865475f) /* -1/sqrt(2) */
#define DCT3X3_2_0 ( 0.4082482904638631f) /*  1/sqrt(6) */
#define DCT3X3_2_1 (-0.8164965809277261f) /* -2/sqrt(6) */
#define DCT3X3_2_2 ( 0.4082482904638631f) /*  1/sqrt(6) */

//CUDA Sampleより拝借
#define C_a 1.387039845322148f //!< a = (2^0.5) * cos(    pi / 16);  Used in forward and inverse DCT.
#define C_b 1.306562964876377f //!< b = (2^0.5) * cos(    pi /  8);  Used in forward and inverse DCT.
#define C_c 1.175875602419359f //!< c = (2^0.5) * cos(3 * pi / 16);  Used in forward and inverse DCT.
#define C_d 0.785694958387102f //!< d = (2^0.5) * cos(5 * pi / 16);  Used in forward and inverse DCT.
#define C_e 0.541196100146197f //!< e = (2^0.5) * cos(3 * pi /  8);  Used in forward and inverse DCT.
#define C_f 0.275899379282943f //!< f = (2^0.5) * cos(7 * pi / 16);  Used in forward and inverse DCT.

//Normalization constant that is used in forward and inverse DCT
#define C_norm 0.3535533905932737f // 1 / (8^0.5)

template<typename T> __device__ __inline__ T setval(float val);
template<> __device__ __inline__ float setval(float val) { return val; };
#if ENABLE_CUDA_FP16_HOST
template<> __device__ __inline__ __half2 setval(float val) { return __float2half2_rn(val); }
__device__ __inline__
__half2 fabs(__half2 val) {
    __half2 h;
    RGY_HALF2_TO_UI(h) = RGY_HALF2_TO_UI(val) & 0x7fff7fffu;
    return h;
}
#endif //#if ENABLE_CUDA_FP16_HOST

template<typename T, int Step>
__device__ void CUDAsubroutineInplaceDCT8vector(T *Vect0) {
    T *Vect1 = Vect0 + Step;
    T *Vect2 = Vect1 + Step;
    T *Vect3 = Vect2 + Step;
    T *Vect4 = Vect3 + Step;
    T *Vect5 = Vect4 + Step;
    T *Vect6 = Vect5 + Step;
    T *Vect7 = Vect6 + Step;

    T X07P = (*Vect0) + (*Vect7);
    T X16P = (*Vect1) + (*Vect6);
    T X25P = (*Vect2) + (*Vect5);
    T X34P = (*Vect3) + (*Vect4);

    T X07M = (*Vect0) - (*Vect7);
    T X61M = (*Vect6) - (*Vect1);
    T X25M = (*Vect2) - (*Vect5);
    T X43M = (*Vect4) - (*Vect3);

    T X07P34PP = X07P + X34P;
    T X07P34PM = X07P - X34P;
    T X16P25PP = X16P + X25P;
    T X16P25PM = X16P - X25P;

    (*Vect0) = setval<T>(C_norm) * (X07P34PP + X16P25PP);
    (*Vect2) = setval<T>(C_norm) * (setval<T>(C_b) * X07P34PM + setval<T>(C_e) * X16P25PM);
    (*Vect4) = setval<T>(C_norm) * (X07P34PP - X16P25PP);
    (*Vect6) = setval<T>(C_norm) * (setval<T>(C_e) * X07P34PM - setval<T>(C_b) * X16P25PM);

    (*Vect1) = setval<T>(C_norm) * (setval<T>(C_a) * X07M - setval<T>(C_c) * X61M + setval<T>(C_d) * X25M - setval<T>(C_f) * X43M);
    (*Vect3) = setval<T>(C_norm) * (setval<T>(C_c) * X07M + setval<T>(C_f) * X61M - setval<T>(C_a) * X25M + setval<T>(C_d) * X43M);
    (*Vect5) = setval<T>(C_norm) * (setval<T>(C_d) * X07M + setval<T>(C_a) * X61M + setval<T>(C_f) * X25M - setval<T>(C_c) * X43M);
    (*Vect7) = setval<T>(C_norm) * (setval<T>(C_f) * X07M + setval<T>(C_d) * X61M + setval<T>(C_c) * X25M + setval<T>(C_a) * X43M);
}

template<typename T, int Step>
__device__ void CUDAsubroutineInplaceIDCT8vector(T *Vect0) {
    T *Vect1 = Vect0 + Step;
    T *Vect2 = Vect1 + Step;
    T *Vect3 = Vect2 + Step;
    T *Vect4 = Vect3 + Step;
    T *Vect5 = Vect4 + Step;
    T *Vect6 = Vect5 + Step;
    T *Vect7 = Vect6 + Step;

    T Y04P = (*Vect0) + (*Vect4);
    T Y2b6eP = setval<T>(C_b) * (*Vect2) + setval<T>(C_e) * (*Vect6);

    T Y04P2b6ePP = Y04P + Y2b6eP;
    T Y04P2b6ePM = Y04P - Y2b6eP;
    T Y7f1aP3c5dPP = setval<T>(C_f) * (*Vect7) + setval<T>(C_a) * (*Vect1) + setval<T>(C_c) * (*Vect3) + setval<T>(C_d) * (*Vect5);
    T Y7a1fM3d5cMP = setval<T>(C_a) * (*Vect7) - setval<T>(C_f) * (*Vect1) + setval<T>(C_d) * (*Vect3) - setval<T>(C_c) * (*Vect5);

    T Y04M = (*Vect0) - (*Vect4);
    T Y2e6bM = setval<T>(C_e) * (*Vect2) - setval<T>(C_b) * (*Vect6);

    T Y04M2e6bMP = Y04M + Y2e6bM;
    T Y04M2e6bMM = Y04M - Y2e6bM;
    T Y1c7dM3f5aPM = setval<T>(C_c) * (*Vect1) - setval<T>(C_d) * (*Vect7) - setval<T>(C_f) * (*Vect3) - setval<T>(C_a) * (*Vect5);
    T Y1d7cP3a5fMM = setval<T>(C_d) * (*Vect1) + setval<T>(C_c) * (*Vect7) - setval<T>(C_a) * (*Vect3) + setval<T>(C_f) * (*Vect5);

    (*Vect0) = setval<T>(C_norm) * (Y04P2b6ePP + Y7f1aP3c5dPP);
    (*Vect7) = setval<T>(C_norm) * (Y04P2b6ePP - Y7f1aP3c5dPP);
    (*Vect4) = setval<T>(C_norm) * (Y04P2b6ePM + Y7a1fM3d5cMP);
    (*Vect3) = setval<T>(C_norm) * (Y04P2b6ePM - Y7a1fM3d5cMP);

    (*Vect1) = setval<T>(C_norm) * (Y04M2e6bMP + Y1c7dM3f5aPM);
    (*Vect5) = setval<T>(C_norm) * (Y04M2e6bMM - Y1d7cP3a5fMM);
    (*Vect2) = setval<T>(C_norm) * (Y04M2e6bMM + Y1d7cP3a5fMM);
    (*Vect6) = setval<T>(C_norm) * (Y04M2e6bMP - Y1c7dM3f5aPM);
}

template<typename T, int Step>
__device__ void CUDAsubroutineInplaceDCT16vector(T *Vect0) {}

template<typename T, int Step>
__device__ void CUDAsubroutineInplaceIDCT16vector(T *Vect0) {}

template<typename T, int BLOCK_SIZE>
__device__ void dctBlock(T shared_tmp[BLOCK_SIZE][BLOCK_SIZE + 1], int thWorker) {
    static_assert(BLOCK_SIZE == 8 || BLOCK_SIZE == 16, "BLOCK_SIZE must be 8 or 16");
    if (BLOCK_SIZE == 8) {
        CUDAsubroutineInplaceDCT8vector<T, 1>             ((T *)&shared_tmp[thWorker][0]); // row
        CUDAsubroutineInplaceDCT8vector<T, BLOCK_SIZE + 1>((T *)&shared_tmp[0][thWorker]); // column
    } else if (BLOCK_SIZE == 16) {
        CUDAsubroutineInplaceDCT16vector<T, 1>             ((T *)&shared_tmp[thWorker][0]); // row
        CUDAsubroutineInplaceDCT16vector<T, BLOCK_SIZE + 1>((T *)&shared_tmp[0][thWorker]); // column
    }
}

template<typename T, int BLOCK_SIZE>
__device__ void idctBlock(T shared_tmp[BLOCK_SIZE][BLOCK_SIZE + 1], int thWorker) {
    static_assert(BLOCK_SIZE == 8 || BLOCK_SIZE == 16, "BLOCK_SIZE must be 8 or 16");
    if (BLOCK_SIZE == 8) {
        CUDAsubroutineInplaceIDCT8vector<T, BLOCK_SIZE+1>((T *)&shared_tmp[0][thWorker]); // column
        CUDAsubroutineInplaceIDCT8vector<T, 1>           ((T *)&shared_tmp[thWorker][0]); // row
    } else if (BLOCK_SIZE == 16) {
        CUDAsubroutineInplaceIDCT16vector<T, BLOCK_SIZE + 1>((T *)&shared_tmp[0][thWorker]); // column
        CUDAsubroutineInplaceIDCT16vector<T, 1>             ((T *)&shared_tmp[thWorker][0]); // row
    }
}

template<typename TypeTmp, int BLOCK_SIZE>
__device__ void thresholdBlock(TypeTmp shared_tmp[BLOCK_SIZE][BLOCK_SIZE + 1], int thWorker, const float threshold) {
    #pragma unroll
    for (int y = 0; y < BLOCK_SIZE; y++) {
        if (y > 0 || thWorker > 0) {
            TypeTmp *ptr = &shared_tmp[y][thWorker];
            const TypeTmp val = ptr[0];
            if (fabs(val) <= threshold) {
                ptr[0] = 0.0f;
            }
        }
    }
}

#define SHARED_TMP TypeTmp shared_tmp[DENOISE_BLOCK_SIZE_X][BLOCK_SIZE][BLOCK_SIZE + 1]
#define SHARED_OUT TypeTmp shared_out[BLOCK_SIZE * DENOISE_SHARED_BLOCK_NUM_Y][BLOCK_SIZE * DENOISE_SHARED_BLOCK_NUM_X]


template<typename TypeTmp, int BLOCK_SIZE>
__device__ void clearSharedOutLine(
    SHARED_OUT,
    const int local_bx,
    const int thWorker,
    const int sy
) {
    const int y = sy % (BLOCK_SIZE * DENOISE_SHARED_BLOCK_NUM_Y);
    shared_out[y][local_bx * BLOCK_SIZE + thWorker] = 0;
    if (local_bx < (DENOISE_SHARED_BLOCK_NUM_X - BLOCK_SIZE)) {
        shared_out[y][(local_bx + BLOCK_SIZE) * BLOCK_SIZE + thWorker] = 0;
    }
}


template<typename TypeTmp, int BLOCK_SIZE>
__device__ void clearSharedOut(
    SHARED_OUT,
    const int local_bx,
    const int thWorker
) {
    #pragma unroll
    for (int y = 0; y < BLOCK_SIZE * DENOISE_SHARED_BLOCK_NUM_Y; y++) {
        clearSharedOutLine<TypeTmp, BLOCK_SIZE>(shared_out, local_bx, thWorker, y);
    }
}

template<typename TypePixel, typename TypeTmp, int BLOCK_SIZE>
__device__ void loadBlocktmp(
    SHARED_TMP,
    const int local_bx, const int thWorker,
    const char *const __restrict__ ptrSrc, const int srcPitch,
    const int block_x, const int block_y,
    const int width, const int height) {
    #pragma unroll
    for (int y = 0; y < BLOCK_SIZE; y++) {
        const int src_x = wrap_idx(block_x + thWorker, 0, width  - 1);
        const int src_y = wrap_idx(block_y + y,        0, height - 1);
        TypePixel pix = ((const TypePixel *)(ptrSrc + src_y * srcPitch + src_x * sizeof(TypePixel)))[0];
        shared_tmp[local_bx][y][thWorker] = (TypeTmp)pix;
    }
}

template<typename TypeTmp, int BLOCK_SIZE>
__device__ void addBlocktmp(
    SHARED_OUT,
    const int shared_block_x, const int shared_block_y,
    const SHARED_TMP,
    const int local_bx, const int thWorker) {
    #pragma unroll
    for (int y = 0; y < BLOCK_SIZE; y++) {
        shared_out[(shared_block_y + y) % (BLOCK_SIZE * DENOISE_SHARED_BLOCK_NUM_Y)][shared_block_x + thWorker]
            += shared_tmp[local_bx][y][thWorker];
    }
}

// デバッグ用
template<typename TypePixel, typename TypeTmp, int BLOCK_SIZE>
__device__ void directAddBlock(
    SHARED_OUT,
    const int shared_block_x, const int shared_block_y,
    const int thWorker,
    const char *const __restrict__ ptrSrc, const int srcPitch,
    const int block_x, const int block_y,
    const int width, const int height) {
    #pragma unroll
    for (int y = 0; y < BLOCK_SIZE; y++) {
        const int src_x = wrap_idx(block_x + thWorker, 0, width - 1);
        const int src_y = wrap_idx(block_y + y,        0, height - 1);
        TypePixel pix = ((const TypePixel *)(ptrSrc + src_y * srcPitch + src_x * sizeof(TypePixel)))[0];
        shared_out[(shared_block_y + y) % (BLOCK_SIZE * DENOISE_SHARED_BLOCK_NUM_Y)][shared_block_x + thWorker] += pix;
    }
}

template<typename TypePixel, int bit_depth, typename TypeTmp, int BLOCK_SIZE>
__device__ void filter_block(
    const char *const __restrict__ ptrSrc, const int srcPitch,
    SHARED_TMP,
    SHARED_OUT,
    const int local_bx, const int thWorker,
    const int shared_block_x, const int shared_block_y,
    const int block_x, const int block_y,
    const int width, const int height,
    const float threshold) {
#if 1
    loadBlocktmp<TypePixel, TypeTmp, BLOCK_SIZE>(shared_tmp, local_bx, thWorker, ptrSrc, srcPitch, block_x, block_y, width, height);
    dctBlock<TypeTmp, BLOCK_SIZE>(shared_tmp[local_bx], thWorker);
    thresholdBlock<TypeTmp, BLOCK_SIZE>(shared_tmp[local_bx], thWorker, threshold);
    idctBlock<TypeTmp, BLOCK_SIZE>(shared_tmp[local_bx], thWorker);
    addBlocktmp<TypeTmp, BLOCK_SIZE>(shared_out, shared_block_x, shared_block_y, shared_tmp, local_bx, thWorker);
#else
    directAddBlock<TypePixel, TypeTmp, BLOCK_SIZE>(shared_out, shared_block_x, shared_block_y, thWorker, ptrSrc, srcPitch, block_x, block_y, width, height);
#endif
}

template<typename TypePixel, int bit_depth, typename TypeTmp, typename TypeWeight, int BLOCK_SIZE, int STEP>
__device__ void write_output(
    char *const __restrict__ ptrDst, const int dstPitch,
    SHARED_OUT,
    const int width, const int height,
    const int sx, const int sy, 
    const int x, const int y) {
    if (x < width && y < height) {
        TypePixel*dst = (TypePixel*)(ptrDst + y * dstPitch + x * sizeof(TypePixel));
        const TypeTmp *out = &shared_out[sy % (BLOCK_SIZE * DENOISE_SHARED_BLOCK_NUM_Y)][sx];
        const float weight = (1.0f / (float)(BLOCK_SIZE * BLOCK_SIZE / (STEP * STEP)));
        if (bit_depth == 32) {
            dst[0] = out[0] * weight;
        } else {
            dst[0] = (TypePixel)clamp((int)out[0] * weight + 0.5f, 0, (1 << bit_depth) - 1);
        }
    }
}

template<typename TypePixel, int bit_depth, typename TypeTmp, typename TypeWeight, int BLOCK_SIZE, int STEP>
__global__ void kernel_denoise_dct(
    char *const __restrict__ ptrDst,          const int dstPitch,
    const char *const __restrict__ ptrSrc,    const int srcPitch,
    const int width, const int height,
    const float threshold) {
    const int thWorker = threadIdx.x; // BLOCK_SIZE
    const int local_bx = threadIdx.y; // DENOISE_BLOCK_SIZE_X
    const int global_bx = blockIdx.x * DENOISE_BLOCK_SIZE_X + local_bx;
    const int global_by = blockIdx.y * DENOISE_LOOP_COUNT_BLOCK;

    const int block_x = global_bx * BLOCK_SIZE;
    const int block_y = global_by * BLOCK_SIZE;

    __shared__ SHARED_TMP;
    __shared__ SHARED_OUT;

    #define FILTER_BLOCK(SHARED_X, SHARED_Y, X, Y) \
        { filter_block<TypePixel, bit_depth, TypeTmp, BLOCK_SIZE>(ptrSrc, srcPitch, shared_tmp, shared_out, local_bx, thWorker, (SHARED_X), (SHARED_Y), (X), (Y), width, height, threshold); }

    { // SHARED_OUTの初期化
        clearSharedOut<TypeTmp, BLOCK_SIZE>(shared_out, local_bx, thWorker);
        __syncthreads();
    }

    { // y方向の事前計算
        const int block_y_start = (block_y - BLOCK_SIZE) + STEP;
        for (int y = block_y_start; y < block_y; y += STEP) {
            const int shared_y = y - (block_y - BLOCK_SIZE);
            for (int ix_loop = 0; ix_loop < BLOCK_SIZE; ix_loop += STEP) {
                const int x = block_x + ix_loop;
                const int shared_x = local_bx * BLOCK_SIZE + ix_loop;
                if (local_bx < 1) { // x方向の事前計算
                    FILTER_BLOCK(shared_x, shared_y, x - BLOCK_SIZE, y);
                }
                FILTER_BLOCK(shared_x + BLOCK_SIZE, shared_y, x, y);
                __syncthreads();
            }
        }
    }

    { // 本計算
        const int block_y_fin = min(height, block_y + DENOISE_LOOP_COUNT_BLOCK * BLOCK_SIZE);
        for (int y = block_y; y < block_y_fin; y += STEP) {
            const int shared_y = y - (block_y - BLOCK_SIZE);
            for (int ix_loop = 0; ix_loop < BLOCK_SIZE; ix_loop += STEP) {
                const int x = block_x + ix_loop;
                const int shared_x = local_bx * BLOCK_SIZE + ix_loop;
                if (local_bx < 1) { // x方向の事前計算
                    FILTER_BLOCK(shared_x, shared_y, x - BLOCK_SIZE, y);
                }
                FILTER_BLOCK(shared_x + BLOCK_SIZE, shared_y, x, y);
                __syncthreads();
            }
            for (int iy = 0; iy < STEP; iy++) {
                write_output<TypePixel, bit_depth, TypeTmp, TypeWeight, BLOCK_SIZE, STEP>(ptrDst, dstPitch, shared_out, width, height,
                    (local_bx + 1 /*1ブロック分ずれている*/) * BLOCK_SIZE + thWorker, shared_y + iy, block_x + thWorker, y + iy);

                clearSharedOutLine<TypeTmp, BLOCK_SIZE>(shared_out, local_bx, thWorker, shared_y + iy + BLOCK_SIZE /*1ブロック先をクリア*/);
            }
            __syncthreads();
        }
    }
    #undef FILTER_BLOCK
}


template<typename Type, int bit_depth, int BLOCK_SIZE>
RGY_ERR denoise_dct_plane(RGYFrameInfo *pOutputPlane, const RGYFrameInfo *pInputPlane,
    const float threshold, const int step, cudaStream_t stream) {
    dim3 blockSize(BLOCK_SIZE, DENOISE_BLOCK_SIZE_X);
    dim3 gridSize(divCeil(pInputPlane->width, blockSize.x), divCeil(pInputPlane->height, BLOCK_SIZE * DENOISE_LOOP_COUNT_BLOCK));
    switch (step) {
    case 2:  kernel_denoise_dct<Type, bit_depth, float, float, BLOCK_SIZE, 2><<<gridSize, blockSize, 0, stream>>>((char *)pOutputPlane->ptr, pOutputPlane->pitch, (const char *)pInputPlane->ptr, pInputPlane->pitch, pInputPlane->width, pInputPlane->height, threshold); break;
    case 4:  kernel_denoise_dct<Type, bit_depth, float, float, BLOCK_SIZE, 4><<<gridSize, blockSize, 0, stream>>>((char *)pOutputPlane->ptr, pOutputPlane->pitch, (const char *)pInputPlane->ptr, pInputPlane->pitch, pInputPlane->width, pInputPlane->height, threshold); break;
    case 8:  kernel_denoise_dct<Type, bit_depth, float, float, BLOCK_SIZE, 8><<<gridSize, blockSize, 0, stream>>>((char *)pOutputPlane->ptr, pOutputPlane->pitch, (const char *)pInputPlane->ptr, pInputPlane->pitch, pInputPlane->width, pInputPlane->height, threshold); break;
    case 1:
    default: kernel_denoise_dct<Type, bit_depth, float, float, BLOCK_SIZE, 1><<<gridSize, blockSize, 0, stream>>>((char *)pOutputPlane->ptr, pOutputPlane->pitch, (const char *)pInputPlane->ptr, pInputPlane->pitch, pInputPlane->width, pInputPlane->height, threshold); break;
    }
    
    auto err = err_to_rgy(cudaGetLastError());
    if (err != RGY_ERR_NONE) {
        return err;
    }
    return err;
}

template<typename Type, int bit_depth, int BLOCK_SIZE>
static RGY_ERR denoise_frame(RGYFrameInfo *pOutputFrame, const RGYFrameInfo *pInputFrame,
    const float threshold, const int step, cudaStream_t stream) {
    for (int iplane = 0; iplane < RGY_CSP_PLANES[pInputFrame->csp]; iplane++) {
        const auto plane = (RGY_PLANE)iplane;
        const auto planeInput = getPlane(pInputFrame, plane);
        auto planeOutput = getPlane(pOutputFrame, plane);
        auto sts = denoise_dct_plane<Type, bit_depth, BLOCK_SIZE>(
            &planeOutput, &planeInput, threshold, step, stream);
        if (sts != RGY_ERR_NONE) {
            return sts;
        }
    }
    return RGY_ERR_NONE;
}

template<typename Type>
__global__ void kernel_color_decorrelation(
    uint8_t *__restrict__ dst0, uint8_t *__restrict__ dst1, uint8_t *__restrict__ dst2, const int dstPitch,
    const uint8_t *__restrict__ src0, const uint8_t *__restrict__ src1, const uint8_t *__restrict__ src2, const int srcPitch,
    const int width, const int height) {
    const int ix = blockIdx.x * blockDim.x + threadIdx.x;
    const int iy = blockIdx.y * blockDim.y + threadIdx.y;
    if (ix < width && iy < height) {
        const float ptrSrc0 = (float)(((const Type *)(src0 + iy * srcPitch + ix * sizeof(Type)))[0]);
        const float ptrSrc1 = (float)(((const Type *)(src1 + iy * srcPitch + ix * sizeof(Type)))[0]);
        const float ptrSrc2 = (float)(((const Type *)(src2 + iy * srcPitch + ix * sizeof(Type)))[0]);

        const float d0 = ptrSrc0 * DCT3X3_0_0 + ptrSrc1 * DCT3X3_0_1 + ptrSrc2 * DCT3X3_0_2;
        const float d1 = ptrSrc0 * DCT3X3_1_0 +                        ptrSrc2 * DCT3X3_1_2;
        const float d2 = ptrSrc0 * DCT3X3_2_0 + ptrSrc1 * DCT3X3_2_1 + ptrSrc2 * DCT3X3_2_2;

        Type *ptrDst0 = (Type *)(dst0 + iy * dstPitch + ix * sizeof(Type));
        Type *ptrDst1 = (Type *)(dst1 + iy * dstPitch + ix * sizeof(Type));
        Type *ptrDst2 = (Type *)(dst2 + iy * dstPitch + ix * sizeof(Type));
        ptrDst0[0] = d0;
        ptrDst1[0] = d1;
        ptrDst2[0] = d2;
    }
}

RGY_ERR NVEncFilterDenoiseDct::colorDecorrelation(RGYFrameInfo *pOutputFrame, const RGYFrameInfo *pInputFrame, cudaStream_t stream) {
    const auto planeInputR = getPlane(pInputFrame, RGY_PLANE_R);
    const auto planeInputG = getPlane(pInputFrame, RGY_PLANE_G);
    const auto planeInputB = getPlane(pInputFrame, RGY_PLANE_B);
    auto planeOutputR = getPlane(pOutputFrame, RGY_PLANE_R);
    auto planeOutputG = getPlane(pOutputFrame, RGY_PLANE_G);
    auto planeOutputB = getPlane(pOutputFrame, RGY_PLANE_B);
    if (   cmpFrameInfoCspResolution(&planeInputR, &planeOutputR)
        || cmpFrameInfoCspResolution(&planeInputG, &planeOutputG)
        || cmpFrameInfoCspResolution(&planeInputB, &planeOutputB)
        || cmpFrameInfoCspResolution(&planeInputR, &planeInputG)
        || cmpFrameInfoCspResolution(&planeInputR, &planeInputB)) {
        return RGY_ERR_UNKNOWN;
    }
    if (planeInputR.pitch != planeInputG.pitch || planeInputR.pitch != planeInputB.pitch
        || planeOutputR.pitch != planeOutputG.pitch || planeOutputR.pitch != planeOutputB.pitch) {
        return RGY_ERR_UNKNOWN;
    }
    dim3 blockSize(64, 8);
    dim3 gridSize(divCeil(planeInputR.width, blockSize.x), divCeil(planeInputR.height, blockSize.y));
    kernel_color_decorrelation<float> << <gridSize, blockSize, 0, stream >> > (
        planeOutputR.ptr, planeOutputG.ptr, planeOutputB.ptr, planeOutputR.pitch,
        planeInputR.ptr, planeInputG.ptr, planeInputB.ptr, planeInputR.pitch,
        planeInputR.width, planeInputR.height);
    auto err = err_to_rgy(cudaGetLastError());
    if (err != RGY_ERR_NONE) {
        return err;
    }
    return err;
}


template<typename Type>
__global__ void kernel_color_correlation(
    uint8_t *__restrict__ dst0, uint8_t *__restrict__ dst1, uint8_t *__restrict__ dst2, const int dstPitch,
    const uint8_t *__restrict__ src0, const uint8_t *__restrict__ src1, const uint8_t *__restrict__ src2, const int srcPitch,
    const int width, const int height) {
    const int ix = blockIdx.x * blockDim.x + threadIdx.x;
    const int iy = blockIdx.y * blockDim.y + threadIdx.y;
    if (ix < width && iy < height) {
        const float ptrSrc0 = (float)(((const Type *)(src0 + iy * srcPitch + ix * sizeof(Type)))[0]);
        const float ptrSrc1 = (float)(((const Type *)(src1 + iy * srcPitch + ix * sizeof(Type)))[0]);
        const float ptrSrc2 = (float)(((const Type *)(src2 + iy * srcPitch + ix * sizeof(Type)))[0]);

        const float d0 = ptrSrc0 * DCT3X3_0_0 + ptrSrc1 * DCT3X3_1_0 + ptrSrc2 * DCT3X3_2_0;
        const float d1 = ptrSrc0 * DCT3X3_0_1                        + ptrSrc2 * DCT3X3_2_1;
        const float d2 = ptrSrc0 * DCT3X3_0_2 + ptrSrc1 * DCT3X3_1_2 + ptrSrc2 * DCT3X3_2_2;

        Type *ptrDst0 = (Type *)(dst0 + iy * dstPitch + ix * sizeof(Type));
        Type *ptrDst1 = (Type *)(dst1 + iy * dstPitch + ix * sizeof(Type));
        Type *ptrDst2 = (Type *)(dst2 + iy * dstPitch + ix * sizeof(Type));
        ptrDst0[0] = d0;
        ptrDst1[0] = d1;
        ptrDst2[0] = d2;
    }
}

RGY_ERR NVEncFilterDenoiseDct::colorCorrelation(RGYFrameInfo *pOutputFrame, const RGYFrameInfo *pInputFrame, cudaStream_t stream) {
    const auto planeInputR = getPlane(pInputFrame, RGY_PLANE_R);
    const auto planeInputG = getPlane(pInputFrame, RGY_PLANE_G);
    const auto planeInputB = getPlane(pInputFrame, RGY_PLANE_B);
    auto planeOutputR = getPlane(pOutputFrame, RGY_PLANE_R);
    auto planeOutputG = getPlane(pOutputFrame, RGY_PLANE_G);
    auto planeOutputB = getPlane(pOutputFrame, RGY_PLANE_B);
    if (   cmpFrameInfoCspResolution(&planeInputR, &planeOutputR)
        || cmpFrameInfoCspResolution(&planeInputG, &planeOutputG)
        || cmpFrameInfoCspResolution(&planeInputB, &planeOutputB)
        || cmpFrameInfoCspResolution(&planeInputR, &planeInputG)
        || cmpFrameInfoCspResolution(&planeInputR, &planeInputB)) {
        return RGY_ERR_UNKNOWN;
    }
    if (planeInputR.pitch != planeInputG.pitch || planeInputR.pitch != planeInputB.pitch
        || planeOutputR.pitch != planeOutputG.pitch || planeOutputR.pitch != planeOutputB.pitch) {
        return RGY_ERR_UNKNOWN;
    }
    dim3 blockSize(64, 8);
    dim3 gridSize(divCeil(planeInputR.width, blockSize.x), divCeil(planeInputR.height, blockSize.y));
    kernel_color_correlation<float><<<gridSize, blockSize, 0, stream >>> (
        planeOutputR.ptr, planeOutputG.ptr, planeOutputB.ptr, planeOutputR.pitch,
        planeInputR.ptr, planeInputG.ptr, planeInputB.ptr, planeInputR.pitch,
        planeInputR.width, planeInputR.height);
    auto err = err_to_rgy(cudaGetLastError());
    if (err != RGY_ERR_NONE) {
        return err;
    }
    return err;
}

RGY_ERR NVEncFilterDenoiseDct::denoise(RGYFrameInfo *pOutputFrame, const RGYFrameInfo *pInputFrame, cudaStream_t stream) {
    if (m_pParam->frameOut.csp != m_pParam->frameIn.csp) {
        AddMessage(RGY_LOG_ERROR, _T("csp does not match.\n"));
        return RGY_ERR_INVALID_PARAM;
    }
    auto prm = std::dynamic_pointer_cast<NVEncFilterParamDenoiseDct>(m_pParam);
    if (!prm) {
        AddMessage(RGY_LOG_ERROR, _T("Invalid parameter type.\n"));
        return RGY_ERR_INVALID_PARAM;
    }
    CUFrameBuf *bufDst = m_bufImg[0].get();
    {
        RGYFrameInfo srcImgInfo = m_srcCrop->GetFilterParam()->frameOut;
        int cropFilterOutputNum = 0;
        RGYFrameInfo *outInfo[1] = { &bufDst->frame };
        RGYFrameInfo cropInput = *pInputFrame;
        auto sts_filter = m_srcCrop->filter(&cropInput, (RGYFrameInfo **)&outInfo, &cropFilterOutputNum, stream);
        if (outInfo[0] == nullptr || cropFilterOutputNum != 1) {
            AddMessage(RGY_LOG_ERROR, _T("Unknown behavior \"%s\".\n"), m_srcCrop->name().c_str());
            return sts_filter;
        }
        if (sts_filter != RGY_ERR_NONE || cropFilterOutputNum != 1) {
            AddMessage(RGY_LOG_ERROR, _T("Error while running filter \"%s\".\n"), m_srcCrop->name().c_str());
            return sts_filter;
        }
    }
    CUFrameBuf *bufSrc = bufDst;
    bufDst = m_bufImg[1].get();
    auto sts = colorDecorrelation(&bufDst->frame, &bufSrc->frame, stream);
    if (sts != RGY_ERR_NONE) {
        return sts;
    }
#if 1
    std::swap(bufSrc, bufDst);
    static const std::map<int, decltype(denoise_frame<float, 32, 8>)*> func_list = {
        { 8,  denoise_frame<float, 32, 8>  },
        //{ 16, denoise_frame<uint16_t, 16, 16> },
    };
    if (func_list.count(prm->dct.block_size) == 0) {
        AddMessage(RGY_LOG_ERROR, _T("unsupported block_size %d.\n"), prm->dct.block_size);
        return RGY_ERR_UNSUPPORTED;
    }
    sts = func_list.at(prm->dct.block_size)(&bufDst->frame, &bufSrc->frame, m_threshold, m_step, stream);
    if (sts != RGY_ERR_NONE) {
        return sts;
    }
#endif
    std::swap(bufSrc, bufDst);
    sts = colorCorrelation(&bufDst->frame, &bufSrc->frame, stream);
    if (sts != RGY_ERR_NONE) {
        return sts;
    }
    std::swap(bufSrc, bufDst);
    {
        int cropFilterOutputNum = 0;
        RGYFrameInfo *outInfo[1] = { pOutputFrame };
        auto sts_filter = m_dstCrop->filter(&bufSrc->frame, outInfo, &cropFilterOutputNum, stream);
        if (outInfo[0] == nullptr || cropFilterOutputNum != 1) {
            AddMessage(RGY_LOG_ERROR, _T("Unknown behavior \"%s\".\n"), m_dstCrop->name().c_str());
            return sts_filter;
        }
    }
    return RGY_ERR_NONE;
}

NVEncFilterDenoiseDct::NVEncFilterDenoiseDct() :
    m_bInterlacedWarn(false),
    m_threshold(0.0f),
    m_step(0),
    m_srcCrop(),
    m_dstCrop(),
    m_bufImg() {
    m_sFilterName = _T("denoise-dct");
}

NVEncFilterDenoiseDct::~NVEncFilterDenoiseDct() {
    close();
}

RGY_ERR NVEncFilterDenoiseDct::checkParam(const NVEncFilterParamDenoiseDct *prm) {
    //パラメータチェック
    if (prm->frameOut.height <= 0 || prm->frameOut.width <= 0) {
        AddMessage(RGY_LOG_ERROR, _T("Invalid parameter.\n"));
        return RGY_ERR_INVALID_PARAM;
    }
    if (prm->dct.sigma < 0.0f) {
        AddMessage(RGY_LOG_ERROR, _T("Invalid parameter, sigma must be a positive value.\n"));
        return RGY_ERR_INVALID_PARAM;
    }
    if (get_cx_index(list_vpp_denoise_dct_block_size, prm->dct.block_size) < 0) {
        AddMessage(RGY_LOG_ERROR, _T("Invalid block_size.\n"));
        return RGY_ERR_INVALID_PARAM;
    }
    return RGY_ERR_NONE;
}

RGY_ERR NVEncFilterDenoiseDct::init(shared_ptr<NVEncFilterParam> pParam, shared_ptr<RGYLog> pPrintMes) {
    RGY_ERR sts = RGY_ERR_NONE;
    m_pPrintMes = pPrintMes;
    auto prm = std::dynamic_pointer_cast<NVEncFilterParamDenoiseDct>(pParam);
    if (!prm) {
        AddMessage(RGY_LOG_ERROR, _T("Invalid parameter type.\n"));
        return RGY_ERR_INVALID_PARAM;
    }
    if ((sts = checkParam(prm.get())) != RGY_ERR_NONE) {
        return sts;
    }
    if (!m_pParam || m_pParam != pParam) {
        {
            AddMessage(RGY_LOG_DEBUG, _T("Create input csp conversion filter.\n"));
            unique_ptr<NVEncFilterCspCrop> filter(new NVEncFilterCspCrop());
            shared_ptr<NVEncFilterParamCrop> paramCrop(new NVEncFilterParamCrop());
            paramCrop->frameIn = pParam->frameIn;
            paramCrop->frameOut = paramCrop->frameIn;
            paramCrop->frameOut.csp = RGY_CSP_RGB_F32;
            paramCrop->baseFps = pParam->baseFps;
            paramCrop->frameIn.deivce_mem = true;
            paramCrop->frameOut.deivce_mem = true;
            paramCrop->bOutOverwrite = false;
            sts = filter->init(paramCrop, m_pPrintMes);
            if (sts != RGY_ERR_NONE) {
                return sts;
            }
            m_srcCrop = std::move(filter);
            AddMessage(RGY_LOG_DEBUG, _T("created %s.\n"), m_srcCrop->GetInputMessage().c_str());
        }
        {
            AddMessage(RGY_LOG_DEBUG, _T("Create output csp conversion filter.\n"));
            unique_ptr<NVEncFilterCspCrop> filter(new NVEncFilterCspCrop());
            shared_ptr<NVEncFilterParamCrop> paramCrop(new NVEncFilterParamCrop());
            paramCrop->frameIn = m_srcCrop->GetFilterParam()->frameOut;
            paramCrop->frameOut = pParam->frameOut;
            paramCrop->baseFps = pParam->baseFps;
            paramCrop->frameIn.deivce_mem = true;
            paramCrop->frameOut.deivce_mem = true;
            paramCrop->bOutOverwrite = false;
            sts = filter->init(paramCrop, m_pPrintMes);
            if (sts != RGY_ERR_NONE) {
                return sts;
            }
            m_dstCrop = std::move(filter);
            AddMessage(RGY_LOG_DEBUG, _T("created %s.\n"), m_dstCrop->GetInputMessage().c_str());
        }
        for (auto& buf : m_bufImg) {
            if (!buf || cmpFrameInfoCspResolution(&buf->frame, &m_srcCrop->GetFilterParam()->frameOut)) {
                buf = std::make_unique<CUFrameBuf>(m_srcCrop->GetFilterParam()->frameOut);
                if ((sts = err_to_rgy(buf->alloc())) != RGY_ERR_NONE) {
                    return sts;
                }
            }
        }

        auto cudaerr = AllocFrameBuf(prm->frameOut, 1);
        if (cudaerr != cudaSuccess) {
            AddMessage(RGY_LOG_ERROR, _T("failed to allocate memory: %s.\n"), char_to_tstring(cudaGetErrorName(cudaerr)).c_str());
            return RGY_ERR_MEMORY_ALLOC;
        }
        prm->frameOut.pitch = m_pFrameBuf[0]->frame.pitch;

        m_step = prm->dct.step;
        m_threshold = prm->dct.sigma * 3.0f / 255.0f;
    }

    setFilterInfo(pParam->print());
    m_pParam = pParam;
    return sts;
}

tstring NVEncFilterParamDenoiseDct::print() const {
    return dct.print();
}

RGY_ERR NVEncFilterDenoiseDct::run_filter(const RGYFrameInfo *pInputFrame, RGYFrameInfo **ppOutputFrames, int *pOutputFrameNum, cudaStream_t stream) {
    RGY_ERR sts = RGY_ERR_NONE;
    if (pInputFrame->ptr == nullptr) {
        return sts;
    }

    *pOutputFrameNum = 1;
    if (ppOutputFrames[0] == nullptr) {
        auto pOutFrame = m_pFrameBuf[m_nFrameIdx].get();
        ppOutputFrames[0] = &pOutFrame->frame;
        m_nFrameIdx = (m_nFrameIdx + 1) % m_pFrameBuf.size();
    }
    ppOutputFrames[0]->picstruct = pInputFrame->picstruct;
    //if (interlaced(*pInputFrame)) {
    //    return filter_as_interlaced_pair(pInputFrame, ppOutputFrames[0], cudaStreamDefault);
    //}
    const auto memcpyKind = getCudaMemcpyKind(pInputFrame->deivce_mem, ppOutputFrames[0]->deivce_mem);
    if (memcpyKind != cudaMemcpyDeviceToDevice) {
        AddMessage(RGY_LOG_ERROR, _T("only supported on device memory.\n"));
        return RGY_ERR_INVALID_PARAM;
    }
    if (m_pParam->frameOut.csp != m_pParam->frameIn.csp) {
        AddMessage(RGY_LOG_ERROR, _T("csp does not match.\n"));
        return RGY_ERR_INVALID_PARAM;
    }
    sts = denoise(ppOutputFrames[0], pInputFrame, stream);
    if (sts != RGY_ERR_NONE) {
        AddMessage(RGY_LOG_ERROR, _T("error at denoise: %s.\n"),
            RGY_CSP_NAMES[pInputFrame->csp],
            get_err_mes(sts));
        return sts;
    }
    return sts;
}

void NVEncFilterDenoiseDct::close() {
    m_pFrameBuf.clear();
    m_bInterlacedWarn = false;
}
