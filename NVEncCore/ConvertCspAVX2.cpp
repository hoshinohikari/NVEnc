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

#include <stdint.h>
#include <immintrin.h>

#if _MSC_VER >= 1800 && !defined(__AVX__) && !defined(_DEBUG)
static_assert(false, "do not forget to set /arch:AVX or /arch:AVX2 for this file.");
#endif

template<bool use_stream>
static void __forceinline avx2_memcpy(uint8_t *dst, const uint8_t *src, int size) {
    if (size < 128) {
        for (int i = 0; i < size; i++)
            dst[i] = src[i];
        return;
    }
    uint8_t *dst_fin = dst + size;
    uint8_t *dst_aligned_fin = (uint8_t *)(((size_t)(dst_fin + 31) & ~31) - 128);
    __m256i y0, y1, y2, y3;
    const int start_align_diff = (int)((size_t)dst & 31);
    if (start_align_diff) {
        y0 = _mm256_loadu_si256((__m256i*)src);
        _mm256_storeu_si256((__m256i*)dst, y0);
        dst += 32 - start_align_diff;
        src += 32 - start_align_diff;
    }
#define _mm256_stream_switch_si256(x, ymm) ((use_stream) ? _mm256_stream_si256((x), (ymm)) : _mm256_store_si256((x), (ymm)))
    for ( ; dst < dst_aligned_fin; dst += 128, src += 128) {
        y0 = _mm256_loadu_si256((__m256i*)(src +  0));
        y1 = _mm256_loadu_si256((__m256i*)(src + 32));
        y2 = _mm256_loadu_si256((__m256i*)(src + 64));
        y3 = _mm256_loadu_si256((__m256i*)(src + 96));
        _mm256_stream_switch_si256((__m256i*)(dst +  0), y0);
        _mm256_stream_switch_si256((__m256i*)(dst + 32), y1);
        _mm256_stream_switch_si256((__m256i*)(dst + 64), y2);
        _mm256_stream_switch_si256((__m256i*)(dst + 96), y3);
    }
#undef _mm256_stream_switch_si256
    uint8_t *dst_tmp = dst_fin - 128;
    src -= (dst - dst_tmp);
    y0 = _mm256_loadu_si256((__m256i*)(src +  0));
    y1 = _mm256_loadu_si256((__m256i*)(src + 32));
    y2 = _mm256_loadu_si256((__m256i*)(src + 64));
    y3 = _mm256_loadu_si256((__m256i*)(src + 96));
    _mm256_storeu_si256((__m256i*)(dst_tmp +  0), y0);
    _mm256_storeu_si256((__m256i*)(dst_tmp + 32), y1);
    _mm256_storeu_si256((__m256i*)(dst_tmp + 64), y2);
    _mm256_storeu_si256((__m256i*)(dst_tmp + 96), y3);
    _mm256_zeroupper();
}

//本来の256bit alignr
#define MM_ABS(x) (((x) < 0) ? -(x) : (x))
#define _mm256_alignr256_epi8(a, b, i) ((i<=16) ? _mm256_alignr_epi8(_mm256_permute2x128_si256(a, b, (0x00<<4) + 0x03), b, i) : _mm256_alignr_epi8(a, _mm256_permute2x128_si256(a, b, (0x00<<4) + 0x03), MM_ABS(i-16)))

//_mm256_srli_si256, _mm256_slli_si256は
//単に128bitシフト×2をするだけの命令である
#define _mm256_bsrli_epi128 _mm256_srli_si256
#define _mm256_bslli_epi128 _mm256_slli_si256
//本当の256bitシフト
#define _mm256_srli256_si256(a, i) ((i<=16) ? _mm256_alignr_epi8(_mm256_permute2x128_si256(a, a, (0x08<<4) + 0x03), a, i) : _mm256_bsrli_epi128(_mm256_permute2x128_si256(a, a, (0x08<<4) + 0x03), MM_ABS(i-16)))
#define _mm256_slli256_si256(a, i) ((i<=16) ? _mm256_alignr_epi8(a, _mm256_permute2x128_si256(a, a, (0x00<<4) + 0x08), MM_ABS(16-i)) : _mm256_bslli_epi128(_mm256_permute2x128_si256(a, a, (0x00<<4) + 0x08), MM_ABS(i-16)))

static const _declspec(align(32)) uint8_t  Array_INTERLACE_WEIGHT[2][32] = {
    {1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3},
    {3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1}
};
#define yC_INTERLACE_WEIGHT(i) _mm256_load_si256((__m256i*)Array_INTERLACE_WEIGHT[i])

static __forceinline void separate_low_up(__m256i& x0_return_lower, __m256i& x1_return_upper) {
    __m256i x4, x5;
    const __m256i xMaskLowByte = _mm256_srli_epi16(_mm256_cmpeq_epi8(_mm256_setzero_si256(), _mm256_setzero_si256()), 8);
    x4 = _mm256_srli_epi16(x0_return_lower, 8);
    x5 = _mm256_srli_epi16(x1_return_upper, 8);

    x0_return_lower = _mm256_and_si256(x0_return_lower, xMaskLowByte);
    x1_return_upper = _mm256_and_si256(x1_return_upper, xMaskLowByte);

    x0_return_lower = _mm256_packus_epi16(x0_return_lower, x1_return_upper);
    x1_return_upper = _mm256_packus_epi16(x4, x5);
}

#pragma warning (push)
#pragma warning (disable: 4100)
void convert_yuy2_to_nv12_avx2(void **dst_array, const void **src_array, int width, int src_y_pitch_byte, int src_uv_pitch_byte, int dst_y_pitch_byte, int height, int dst_height, int *crop) {
    const int crop_left   = crop[0];
    const int crop_up     = crop[1];
    const int crop_right  = crop[2];
    const int crop_bottom = crop[3];
    void *dst = dst_array[0];
    const void *src = src_array[0];
    uint8_t *srcLine = (uint8_t *)src + src_y_pitch_byte * crop_up + crop_left;
    uint8_t *dstYLine = (uint8_t *)dst;
    uint8_t *dstCLine = dstYLine + dst_y_pitch_byte * dst_height;
    const int y_fin = height - crop_bottom - crop_up;
    for (int y = 0; y < y_fin; y += 2) {
        uint8_t *p = srcLine;
        uint8_t *pw = p + src_y_pitch_byte;
        const int x_fin = width - crop_right - crop_left;
        __m256i y0, y1, y3;
        for (int x = 0; x < x_fin; x += 32, p += 64, pw += 64) {
            //-----------1行目---------------
            y0 = _mm256_set_m128i(_mm_loadu_si128((__m128i*)(p+32)), _mm_loadu_si128((__m128i*)(p+ 0)));
            y1 = _mm256_set_m128i(_mm_loadu_si128((__m128i*)(p+48)), _mm_loadu_si128((__m128i*)(p+16)));

            separate_low_up(y0, y1);
            y3 = y1;

            _mm256_stream_si256((__m256i *)(dstYLine + x), y0);
            //-----------1行目終了---------------

            //-----------2行目---------------
            y0 = _mm256_set_m128i(_mm_loadu_si128((__m128i*)(pw+32)), _mm_loadu_si128((__m128i*)(pw+ 0)));
            y1 = _mm256_set_m128i(_mm_loadu_si128((__m128i*)(pw+48)), _mm_loadu_si128((__m128i*)(pw+16)));

            separate_low_up(y0, y1);

            _mm256_stream_si256((__m256i *)(dstYLine + dst_y_pitch_byte + x), y0);
            //-----------2行目終了---------------

            y1 = _mm256_avg_epu8(y1, y3);  //VUVUVUVUVUVUVUVU
            _mm256_stream_si256((__m256i *)(dstCLine + x), y1);
        }
        srcLine  += src_y_pitch_byte << 1;
        dstYLine += dst_y_pitch_byte << 1;
        dstCLine += dst_y_pitch_byte;
    }
    _mm256_zeroupper();
}
#pragma warning (push)

static __forceinline __m256i yuv422_to_420_i_interpolate(__m256i y_up, __m256i y_down, int i) {
    __m256i y0, y1;
    y0 = _mm256_unpacklo_epi8(y_down, y_up);
    y1 = _mm256_unpackhi_epi8(y_down, y_up);
    y0 = _mm256_maddubs_epi16(y0, yC_INTERLACE_WEIGHT(i));
    y1 = _mm256_maddubs_epi16(y1, yC_INTERLACE_WEIGHT(i));
    y0 = _mm256_add_epi16(y0, _mm256_set1_epi16(2));
    y1 = _mm256_add_epi16(y1, _mm256_set1_epi16(2));
    y0 = _mm256_srai_epi16(y0, 2);
    y1 = _mm256_srai_epi16(y1, 2);
    y0 = _mm256_packus_epi16(y0, y1);
    return y0;
}

void convert_yuy2_to_nv12_i_avx2(void **dst_array, const void **src_array, int width, int src_y_pitch_byte, int src_uv_pitch_byte, int dst_y_pitch_byte, int height, int dst_height, int *crop) {
    const int crop_left   = crop[0];
    const int crop_up     = crop[1];
    const int crop_right  = crop[2];
    const int crop_bottom = crop[3];
    void *dst = dst_array[0];
    const void *src = src_array[0];
    uint8_t *srcLine = (uint8_t *)src + src_y_pitch_byte * crop_up + crop_left;
    uint8_t *dstYLine = (uint8_t *)dst;
    uint8_t *dstCLine = dstYLine + dst_y_pitch_byte * dst_height;
    const int y_fin = height - crop_bottom - crop_up;
    for (int y = 0; y < y_fin; y += 4) {
        for (int i = 0; i < 2; i++) {
            uint8_t *p = srcLine;
            uint8_t *pw = p + (src_y_pitch_byte<<1);
            __m256i y0, y1, y3;
            const int x_fin = width - crop_right - crop_left;
            for (int x = 0; x < x_fin; x += 32, p += 64, pw += 64) {
                //-----------    1+i行目   ---------------
                y0 = _mm256_set_m128i(_mm_loadu_si128((__m128i*)(p+32)), _mm_loadu_si128((__m128i*)(p+ 0)));
                y1 = _mm256_set_m128i(_mm_loadu_si128((__m128i*)(p+48)), _mm_loadu_si128((__m128i*)(p+16)));

                separate_low_up(y0, y1);
                y3 = y1;

                _mm256_stream_si256((__m256i *)(dstYLine + x), y0);
                //-----------1+i行目終了---------------

                //-----------3+i行目---------------
                y0 = _mm256_set_m128i(_mm_loadu_si128((__m128i*)(pw+32)), _mm_loadu_si128((__m128i*)(pw+ 0)));
                y1 = _mm256_set_m128i(_mm_loadu_si128((__m128i*)(pw+48)), _mm_loadu_si128((__m128i*)(pw+16)));

                separate_low_up(y0, y1);

                _mm256_stream_si256((__m256i *)(dstYLine + (dst_y_pitch_byte<<1) + x), y0);
                //-----------3+i行目終了---------------
                y0 = yuv422_to_420_i_interpolate(y3, y1, i);

                _mm256_stream_si256((__m256i *)(dstCLine + x), y0);
            }
            srcLine  += src_y_pitch_byte;
            dstYLine += dst_y_pitch_byte;
            dstCLine += dst_y_pitch_byte;
        }
        srcLine  += src_y_pitch_byte << 1;
        dstYLine += dst_y_pitch_byte << 1;
    }
    _mm256_zeroupper();
}

#pragma warning (push)
#pragma warning (disable: 4127)
template<bool uv_only>
static void __forceinline convert_yv12_to_nv12_avx2_base(void **dst, const void **src, int width, int src_y_pitch_byte, int src_uv_pitch_byte, int dst_y_pitch_byte, int height, int dst_height, int *crop) {
    const int crop_left   = crop[0];
    const int crop_up     = crop[1];
    const int crop_right  = crop[2];
    const int crop_bottom = crop[3];
    //Y成分のコピー
    if (!uv_only) {
        uint8_t *srcYLine = (uint8_t *)src[0] + src_y_pitch_byte * crop_up + crop_left;
        uint8_t *dstLine = (uint8_t *)dst[0];
        const int y_fin = height - crop_bottom;
        const int y_width = width - crop_right - crop_left;
        for (int y = crop_up; y < y_fin; y++, srcYLine += src_y_pitch_byte, dstLine += dst_y_pitch_byte) {
            avx2_memcpy<false>(dstLine, srcYLine, y_width);
        }
    }
    //UV成分のコピー
    uint8_t *srcULine = (uint8_t *)src[1] + (((src_uv_pitch_byte * crop_up) + crop_left) >> 1);
    uint8_t *srcVLine = (uint8_t *)src[2] + (((src_uv_pitch_byte * crop_up) + crop_left) >> 1);
    uint8_t *dstLine = (uint8_t *)dst[1];
    const int uv_fin = (height - crop_bottom) >> 1;
    for (int y = crop_up >> 1; y < uv_fin; y++, srcULine += src_uv_pitch_byte, srcVLine += src_uv_pitch_byte, dstLine += dst_y_pitch_byte) {
        const int x_fin = width - crop_right;
        uint8_t *src_u_ptr = srcULine;
        uint8_t *src_v_ptr = srcVLine;
        uint8_t *dst_ptr = dstLine;
        __m256i y0, y1, y2;
        for (int x = crop_left; x < x_fin; x += 64, src_u_ptr += 32, src_v_ptr += 32, dst_ptr += 64) {
            y0 = _mm256_loadu_si256((const __m256i *)src_u_ptr);
            y1 = _mm256_loadu_si256((const __m256i *)src_v_ptr);

            y0 = _mm256_permute4x64_epi64(y0, _MM_SHUFFLE(3,1,2,0));
            y1 = _mm256_permute4x64_epi64(y1, _MM_SHUFFLE(3,1,2,0));

            y2 = _mm256_unpackhi_epi8(y0, y1);
            y0 = _mm256_unpacklo_epi8(y0, y1);

            _mm256_storeu_si256((__m256i *)(dst_ptr +  0), y0);
            _mm256_storeu_si256((__m256i *)(dst_ptr + 32), y2);
        }
    }
    _mm256_zeroupper();
}
#pragma warning (pop)

void convert_yv12_to_nv12_avx2(void **dst, const void **src, int width, int src_y_pitch_byte, int src_uv_pitch_byte, int dst_y_pitch_byte, int height, int dst_height, int *crop) {
    convert_yv12_to_nv12_avx2_base<false>(dst, src, width, src_y_pitch_byte, src_uv_pitch_byte, dst_y_pitch_byte, height, dst_height, crop);
}

void convert_uv_yv12_to_nv12_avx2(void **dst, const void **src, int width, int src_y_pitch_byte, int src_uv_pitch_byte, int dst_y_pitch_byte, int height, int dst_height, int *crop) {
    convert_yv12_to_nv12_avx2_base<true>(dst, src, width, src_y_pitch_byte, src_uv_pitch_byte, dst_y_pitch_byte, height, dst_height, crop);
}

void copy_yuv444_to_yuv444_avx2(void **dst, const void **src, int width, int src_y_pitch_byte, int src_uv_pitch_byte, int dst_y_pitch_byte, int height, int dst_height, int *crop) {
    const int crop_left   = crop[0];
    const int crop_up     = crop[1];
    const int crop_right  = crop[2];
    const int crop_bottom = crop[3];
    for (int i = 0; i < 3; i++) {
        uint8_t *srcYLine = (uint8_t *)src[i] + src_y_pitch_byte * crop_up + crop_left;
        uint8_t *dstLine = (uint8_t *)dst[i];
        const int y_fin = height - crop_bottom;
        const int y_width = width - crop_right - crop_left;
        for (int y = crop_up; y < y_fin; y++, srcYLine += src_y_pitch_byte, dstLine += dst_y_pitch_byte) {
            avx2_memcpy<true>(dstLine, srcYLine, y_width);
        }
    }
}

#include "convert_const.h"

static __forceinline void gather_y_uv_from_yc48(__m256i& y0, __m256i& y1, __m256i y2) {
    const int MASK_INT_Y  = 0x80 + 0x10 + 0x02;
    const int MASK_INT_UV = 0x40 + 0x20 + 0x01;
    __m256i y3 = y0;
    __m256i y4 = y1;
    __m256i y5 = y2;

    y0 = _mm256_blend_epi32(y3, y4, 0xf0);                    // 384, 0
    y1 = _mm256_permute2x128_si256(y3, y5, (0x02<<4) + 0x01); // 512, 128
    y2 = _mm256_blend_epi32(y4, y5, 0xf0);                    // 640, 256

    y3 = _mm256_blend_epi16(y0, y1, MASK_INT_Y);
    y3 = _mm256_blend_epi16(y3, y2, MASK_INT_Y>>2);

    y1 = _mm256_blend_epi16(y0, y1, MASK_INT_UV);
    y1 = _mm256_blend_epi16(y1, y2, MASK_INT_UV>>2);
    y1 = _mm256_alignr_epi8(y1, y1, 2);
    y1 = _mm256_shuffle_epi32(y1, _MM_SHUFFLE(1, 2, 3, 0));//UV1行目

    y0 = _mm256_shuffle_epi8(y3, yC_SUFFLE_YCP_Y);
}

static __forceinline __m256i convert_y_range_from_yc48(__m256i y0, __m256i yC_Y_MA_16, int Y_RSH_16, const __m256i& yC_YCC, const __m256i& yC_pw_one) {
    __m256i y7;

    y7 = _mm256_unpackhi_epi16(y0, yC_pw_one);
    y0 = _mm256_unpacklo_epi16(y0, yC_pw_one);

    y0 = _mm256_madd_epi16(y0, yC_Y_MA_16);
    y7 = _mm256_madd_epi16(y7, yC_Y_MA_16);
    y0 = _mm256_srai_epi32(y0, Y_RSH_16);
    y7 = _mm256_srai_epi32(y7, Y_RSH_16);
    y0 = _mm256_add_epi32(y0, yC_YCC);
    y7 = _mm256_add_epi32(y7, yC_YCC);

    y0 = _mm256_packus_epi32(y0, y7);

    return y0;
}
static __forceinline __m256i convert_uv_range_after_adding_offset(__m256i y0, const __m256i& yC_UV_MA_16, int UV_RSH_16, const __m256i& yC_YCC, const __m256i& yC_pw_one) {
    __m256i y7;
    y7 = _mm256_unpackhi_epi16(y0, yC_pw_one);
    y0 = _mm256_unpacklo_epi16(y0, yC_pw_one);

    y0 = _mm256_madd_epi16(y0, yC_UV_MA_16);
    y7 = _mm256_madd_epi16(y7, yC_UV_MA_16);
    y0 = _mm256_srai_epi32(y0, UV_RSH_16);
    y7 = _mm256_srai_epi32(y7, UV_RSH_16);
    y0 = _mm256_add_epi32(y0, yC_YCC);
    y7 = _mm256_add_epi32(y7, yC_YCC);

    y0 = _mm256_packus_epi32(y0, y7);

    return y0;
}
static __forceinline __m256i convert_uv_range_from_yc48(__m256i y0, const __m256i& yC_UV_OFFSET_x1, const __m256i& yC_UV_MA_16, int UV_RSH_16, const __m256i& yC_YCC, const __m256i& yC_pw_one) {
    y0 = _mm256_add_epi16(y0, yC_UV_OFFSET_x1);

    return convert_uv_range_after_adding_offset(y0, yC_UV_MA_16, UV_RSH_16, yC_YCC, yC_pw_one);
}
static __forceinline __m256i convert_uv_range_from_yc48_yuv420p(__m256i y0, __m256i y1, const __m256i& yC_UV_OFFSET_x2, __m256i yC_UV_MA_16, int UV_RSH_16, const __m256i& yC_YCC, const __m256i& yC_pw_one) {
    y0 = _mm256_add_epi16(y0, y1);
    y0 = _mm256_add_epi16(y0, yC_UV_OFFSET_x2);

    return convert_uv_range_after_adding_offset(y0, yC_UV_MA_16, UV_RSH_16, yC_YCC, yC_pw_one);
}
static __forceinline __m256i convert_uv_range_from_yc48_420i(__m256i y0, __m256i y1, const __m256i& yC_UV_OFFSET_x1, const __m256i& yC_UV_MA_16_0, const __m256i& yC_UV_MA_16_1, int UV_RSH_16, const __m256i& yC_YCC, const __m256i& yC_pw_one) {
    __m256i y2, y3, y6, y7;

    y0 = _mm256_add_epi16(y0, yC_UV_OFFSET_x1);
    y1 = _mm256_add_epi16(y1, yC_UV_OFFSET_x1);

    y7 = _mm256_unpackhi_epi16(y0, yC_pw_one);
    y6 = _mm256_unpacklo_epi16(y0, yC_pw_one);
    y3 = _mm256_unpackhi_epi16(y1, yC_pw_one);
    y2 = _mm256_unpacklo_epi16(y1, yC_pw_one);

    y6 = _mm256_madd_epi16(y6, yC_UV_MA_16_0);
    y7 = _mm256_madd_epi16(y7, yC_UV_MA_16_0);
    y2 = _mm256_madd_epi16(y2, yC_UV_MA_16_1);
    y3 = _mm256_madd_epi16(y3, yC_UV_MA_16_1);
    y0 = _mm256_add_epi32(y6, y2);
    y7 = _mm256_add_epi32(y7, y3);
    y0 = _mm256_srai_epi32(y0, UV_RSH_16);
    y7 = _mm256_srai_epi32(y7, UV_RSH_16);
    y0 = _mm256_add_epi32(y0, yC_YCC);
    y7 = _mm256_add_epi32(y7, yC_YCC);

    y0 = _mm256_packus_epi32(y0, y7);

    return y0;
}

void convert_yc48_to_p010_avx2(void **dst, const void **src, int width, int src_y_pitch_byte, int src_uv_pitch_byte, int dst_y_pitch_byte, int height, int dst_height, int *crop) {
    int x, y;
    short *dst_Y = (short *)dst[0];
    short *dst_C = (short *)((uint8_t *)dst[0] + dst_y_pitch_byte * dst_height);
    const void  *pixel = src[0];
    const short *ycp, *ycpw;
    short *Y = NULL, *C = NULL;
    const __m256i yC_pw_one = _mm256_set1_epi16(1);
    const __m256i yC_YCC = _mm256_set1_epi32(1<<LSFT_YCC_16);
    const int dst_y_pitch = dst_y_pitch_byte >> 1;
    __m256i y0, y1, y2, y3;
    for (y = 0; y < height; y += 2) {
        ycp = (short*)pixel + width * y * 3;
        ycpw= ycp + width*3;
        Y   = (short*)dst_Y + dst_y_pitch * y;
        C   = (short*)dst_C + dst_y_pitch * y / 2;
        for (x = 0; x < width; x += 16, ycp += 48, ycpw += 48) {
            y1 = _mm256_loadu_si256((__m256i *)(ycp +  0)); // 128, 0
            y2 = _mm256_loadu_si256((__m256i *)(ycp + 16)); // 384, 256
            y3 = _mm256_loadu_si256((__m256i *)(ycp + 32)); // 640, 512

            gather_y_uv_from_yc48(y1, y2, y3);
            y0 = y2;

            _mm256_storeu_si256((__m256i *)(Y + x), convert_y_range_from_yc48(y1, yC_Y_L_MA_16, Y_L_RSH_16, yC_YCC, yC_pw_one));

            y1 = _mm256_loadu_si256((__m256i *)(ycpw +  0));
            y2 = _mm256_loadu_si256((__m256i *)(ycpw + 16));
            y3 = _mm256_loadu_si256((__m256i *)(ycpw + 32));

            gather_y_uv_from_yc48(y1, y2, y3);

            _mm256_storeu_si256((__m256i *)(Y + x + dst_y_pitch), convert_y_range_from_yc48(y1, yC_Y_L_MA_16, Y_L_RSH_16, yC_YCC, yC_pw_one));

            _mm256_storeu_si256((__m256i *)(C + x), convert_uv_range_from_yc48_yuv420p(y0, y2,  _mm256_set1_epi16(UV_OFFSET_x2), yC_UV_L_MA_16_420P, UV_L_RSH_16_420P, yC_YCC, yC_pw_one));
        }
    }
    _mm256_zeroupper();
}

void convert_yc48_to_p010_i_avx2(void **dst, const void **src, int width, int src_y_pitch_byte, int src_uv_pitch_byte, int dst_y_pitch_byte, int height, int dst_height, int *crop) {
    int x, y, i;
    short *dst_Y = (short *)dst[0];
    short *dst_C = (short *)((uint8_t *)dst[0] + dst_y_pitch_byte * dst_height);
    const void  *pixel = src[0];
    const short *ycp, *ycpw;
    short *Y = NULL, *C = NULL;
    const __m256i yC_pw_one = _mm256_set1_epi16(1);
    const __m256i yC_YCC = _mm256_set1_epi32(1<<LSFT_YCC_16);
    const int dst_y_pitch = dst_y_pitch_byte >> 1;
    __m256i y0, y1, y2, y3;
    for (y = 0; y < height; y += 4) {
        for (i = 0; i < 2; i++) {
            ycp = (short*)pixel + width * (y + i) * 3;
            ycpw= ycp + width*2*3;
            Y   = (short*)dst_Y + dst_y_pitch * (y + i);
            C   = (short*)dst_C + dst_y_pitch * (y + i*2) / 2;
            for (x = 0; x < width; x += 16, ycp += 48, ycpw += 48) {
                y1 = _mm256_loadu_si256((__m256i *)(ycp +  0)); // 128, 0
                y2 = _mm256_loadu_si256((__m256i *)(ycp + 16)); // 384, 256
                y3 = _mm256_loadu_si256((__m256i *)(ycp + 32)); // 640, 512

                gather_y_uv_from_yc48(y1, y2, y3);
                y0 = y2;

                _mm256_storeu_si256((__m256i *)(Y + x), convert_y_range_from_yc48(y1, yC_Y_L_MA_16, Y_L_RSH_16, yC_YCC, yC_pw_one));

                y1 = _mm256_loadu_si256((__m256i *)(ycpw +  0));
                y2 = _mm256_loadu_si256((__m256i *)(ycpw + 16));
                y3 = _mm256_loadu_si256((__m256i *)(ycpw + 32));

                gather_y_uv_from_yc48(y1, y2, y3);

                _mm256_storeu_si256((__m256i *)(Y + x + dst_y_pitch*2), convert_y_range_from_yc48(y1, yC_Y_L_MA_16, Y_L_RSH_16, yC_YCC, yC_pw_one));

                _mm256_storeu_si256((__m256i *)(C + x), convert_uv_range_from_yc48_420i(y0, y2, _mm256_set1_epi16(UV_OFFSET_x1), yC_UV_L_MA_16_420I(i), yC_UV_L_MA_16_420I((i+1)&0x01), UV_L_RSH_16_420I, yC_YCC, yC_pw_one));
            }
        }
    }
    _mm256_zeroupper();
}
