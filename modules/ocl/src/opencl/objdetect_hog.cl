/*M///////////////////////////////////////////////////////////////////////////////////////
//
//  IMPORTANT: READ BEFORE DOWNLOADING, COPYING, INSTALLING OR USING.
//
//  By downloading, copying, installing or using the software you agree to this license.
//  If you do not agree to this license, do not download, install,
//  copy or use the software.
//
//
//                           License Agreement
//                For Open Source Computer Vision Library
//
// Copyright (C) 2010-2012, Multicoreware, Inc., all rights reserved.
// Copyright (C) 2010-2012, Advanced Micro Devices, Inc., all rights reserved.
// Third party copyrights are property of their respective owners.
//
// @Authors
//    Wenju He, wenju@multicorewareinc.com
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
//   * Redistribution's of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//
//   * Redistribution's in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//
//   * The name of the copyright holders may not be used to endorse or promote products
//     derived from this software without specific prior written permission.
//
// This software is provided by the copyright holders and contributors as is and
// any express or implied warranties, including, but not limited to, the implied
// warranties of merchantability and fitness for a particular purpose are disclaimed.
// In no event shall the Intel Corporation or contributors be liable for any direct,
// indirect, incidental, special, exemplary, or consequential damages
// (including, but not limited to, procurement of substitute goods or services;
// loss of use, data, or profits; or business interruption) however caused
// and on any theory of liability, whether in contract, strict liability,
// or tort (including negligence or otherwise) arising in any way out of
// the use of this software, even if advised of the possibility of such damage.
//
//M*/


#define CELL_WIDTH 8
#define CELL_HEIGHT 8
#define CELLS_PER_BLOCK_X 2
#define CELLS_PER_BLOCK_Y 2
#define NTHREADS 256
#define CV_PI_F 3.1415926535897932384626433832795f

//----------------------------------------------------------------------------
// Histogram computation
// 12 threads for a cell, 12x4 threads per block
__kernel void compute_hists_kernel(
    const int cblock_stride_x, const int cblock_stride_y,
    const int cnbins, const int cblock_hist_size, const int img_block_width,
    const int blocks_in_group, const int blocks_total,
    const int grad_quadstep, const int qangle_step,
    __global const float* grad, __global const uchar* qangle,
    const float scale, __global float* block_hists, __local float* smem)
{
    const int lx = get_local_id(0);
    const int lp = lx / 24; /* local group id */
    const int gid = get_group_id(0) * blocks_in_group + lp;/* global group id */
    const int gidY = gid / img_block_width;
    const int gidX = gid - gidY * img_block_width;

    const int lidX = lx - lp * 24;
    const int lidY = get_local_id(1);

    const int cell_x = lidX / 12;
    const int cell_y = lidY;
    const int cell_thread_x = lidX - cell_x * 12;

    __local float* hists = smem + lp * cnbins * (CELLS_PER_BLOCK_X *
        CELLS_PER_BLOCK_Y * 12 + CELLS_PER_BLOCK_X * CELLS_PER_BLOCK_Y);
    __local float* final_hist = hists + cnbins *
        (CELLS_PER_BLOCK_X * CELLS_PER_BLOCK_Y * 12);

    const int offset_x = gidX * cblock_stride_x + (cell_x << 2) + cell_thread_x;
    const int offset_y = gidY * cblock_stride_y + (cell_y << 2);

    __global const float* grad_ptr = (gid < blocks_total) ?
        grad + offset_y * grad_quadstep + (offset_x << 1) : grad;
    __global const uchar* qangle_ptr = (gid < blocks_total) ?
        qangle + offset_y * qangle_step + (offset_x << 1) : qangle;

    __local float* hist = hists + 12 * (cell_y * CELLS_PER_BLOCK_Y + cell_x) +
        cell_thread_x;
    for (int bin_id = 0; bin_id < cnbins; ++bin_id)
        hist[bin_id * 48] = 0.f;

    const int dist_x = -4 + cell_thread_x - 4 * cell_x;
    const int dist_center_x = dist_x - 4 * (1 - 2 * cell_x);

    const int dist_y_begin = -4 - 4 * lidY;
    for (int dist_y = dist_y_begin; dist_y < dist_y_begin + 12; ++dist_y)
    {
        float2 vote = (float2) (grad_ptr[0], grad_ptr[1]);
        uchar2 bin = (uchar2) (qangle_ptr[0], qangle_ptr[1]);

        grad_ptr += grad_quadstep;
        qangle_ptr += qangle_step;

        int dist_center_y = dist_y - 4 * (1 - 2 * cell_y);

        float gaussian = exp(-(dist_center_y * dist_center_y + dist_center_x *
            dist_center_x) * scale);
        float interp_weight = (8.f - fabs(dist_y + 0.5f)) *
            (8.f - fabs(dist_x + 0.5f)) / 64.f;

        hist[bin.x * 48] += gaussian * interp_weight * vote.x;
        hist[bin.y * 48] += gaussian * interp_weight * vote.y;
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    volatile __local float* hist_ = hist;
    for (int bin_id = 0; bin_id < cnbins; ++bin_id, hist_ += 48)
    {
        if (cell_thread_x < 6)
            hist_[0] += hist_[6];
        barrier(CLK_LOCAL_MEM_FENCE);
        if (cell_thread_x < 3)
            hist_[0] += hist_[3];
#ifdef WAVE_SIZE_1
        barrier(CLK_LOCAL_MEM_FENCE);
#endif
        if (cell_thread_x == 0)
            final_hist[(cell_x * 2 + cell_y) * cnbins + bin_id] =
                hist_[0] + hist_[1] + hist_[2];
    }
#ifdef WAVE_SIZE_1
    barrier(CLK_LOCAL_MEM_FENCE);
#endif

    int tid = (cell_y * CELLS_PER_BLOCK_Y + cell_x) * 12 + cell_thread_x;
    if ((tid < cblock_hist_size) && (gid < blocks_total))
    {
        __global float* block_hist = block_hists +
            (gidY * img_block_width + gidX) * cblock_hist_size;
        block_hist[tid] = final_hist[tid];
    }
}

//-------------------------------------------------------------
//  Normalization of histograms via L2Hys_norm
//
float reduce_smem(volatile __local float* smem, int size)
{
    unsigned int tid = get_local_id(0);
    float sum = smem[tid];

    if (size >= 512)
    {
        if (tid < 256) smem[tid] = sum = sum + smem[tid + 256];
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    if (size >= 256)
    {
        if (tid < 128) smem[tid] = sum = sum + smem[tid + 128];
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    if (size >= 128)
    {
        if (tid < 64) smem[tid] = sum = sum + smem[tid + 64];
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (tid < 32)
    {
        if (size >= 64) smem[tid] = sum = sum + smem[tid + 32];
#if defined(WAVE_SIZE_16) || defined(WAVE_SIZE_1)
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 16)
    {
#endif
        if (size >= 32) smem[tid] = sum = sum + smem[tid + 16];
#ifdef WAVE_SIZE_1
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 8)
    {
#endif
        if (size >= 16) smem[tid] = sum = sum + smem[tid + 8];
#ifdef WAVE_SIZE_1
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 4)
    {
#endif
        if (size >= 8) smem[tid] = sum = sum + smem[tid + 4];
#ifdef WAVE_SIZE_1
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 2)
    {
#endif
        if (size >= 4) smem[tid] = sum = sum + smem[tid + 2];
#ifdef WAVE_SIZE_1
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 1)
    {
#endif
        if (size >= 2) smem[tid] = sum = sum + smem[tid + 1];
    }

    barrier(CLK_LOCAL_MEM_FENCE);
    sum = smem[0];

    return sum;
}

__kernel void normalize_hists_kernel(const int nthreads, const int block_hist_size, const int img_block_width,
                                     __global float* block_hists, const float threshold, __local float *squares)
{
    const int tid = get_local_id(0);
    const int gidX = get_group_id(0);
    const int gidY = get_group_id(1);

    __global float* hist = block_hists + (gidY * img_block_width + gidX) * block_hist_size + tid;

    float elem = 0.f;
    if (tid < block_hist_size)
        elem = hist[0];

    squares[tid] = elem * elem;

    barrier(CLK_LOCAL_MEM_FENCE);
    float sum = reduce_smem(squares, nthreads);

    float scale = 1.0f / (sqrt(sum) + 0.1f * block_hist_size);
    elem = min(elem * scale, threshold);

    barrier(CLK_LOCAL_MEM_FENCE);
    squares[tid] = elem * elem;

    barrier(CLK_LOCAL_MEM_FENCE);
    sum = reduce_smem(squares, nthreads);
    scale = 1.0f / (sqrt(sum) + 1e-3f);

    if (tid < block_hist_size)
        hist[0] = elem * scale;
}

//---------------------------------------------------------------------
//  Linear SVM based classification
//
__kernel void classify_hists_kernel(const int cblock_hist_size, const int cdescr_size, const int cdescr_width,
                                    const int img_win_width, const int img_block_width,
                                    const int win_block_stride_x, const int win_block_stride_y,
                                    __global const float * block_hists, __global const float* coefs,
                                    float free_coef, float threshold, __global uchar* labels)
{
    const int tid = get_local_id(0);
    const int gidX = get_group_id(0);
    const int gidY = get_group_id(1);

    __global const float* hist = block_hists + (gidY * win_block_stride_y * img_block_width + gidX * win_block_stride_x) * cblock_hist_size;

    float product = 0.f;
    for (int i = tid; i < cdescr_size; i += NTHREADS)
    {
        int offset_y = i / cdescr_width;
        int offset_x = i - offset_y * cdescr_width;
        product += coefs[i] * hist[offset_y * img_block_width * cblock_hist_size + offset_x];
    }

    __local float products[NTHREADS];

    products[tid] = product;

    barrier(CLK_LOCAL_MEM_FENCE);

    if (tid < 128) products[tid] = product = product + products[tid + 128];
    barrier(CLK_LOCAL_MEM_FENCE);

    if (tid < 64) products[tid] = product = product + products[tid + 64];
    barrier(CLK_LOCAL_MEM_FENCE);

    volatile __local float* smem = products;
    if (tid < 32)
    {
        smem[tid] = product = product + smem[tid + 32];
#if defined(WAVE_SIZE_16) || defined(WAVE_SIZE_1)
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 16)
    {
#endif
        smem[tid] = product = product + smem[tid + 16];
#ifdef WAVE_SIZE_1
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 8)
    {
#endif
        smem[tid] = product = product + smem[tid + 8];
#ifdef WAVE_SIZE_1
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 4)
    {
#endif
        smem[tid] = product = product + smem[tid + 4];
#ifdef WAVE_SIZE_1
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 2)
    {
#endif
        smem[tid] = product = product + smem[tid + 2];
#ifdef WAVE_SIZE_1
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    if (tid < 1)
    {
#endif
        smem[tid] = product = product + smem[tid + 1];
    }

    if (tid == 0)
        labels[gidY * img_win_width + gidX] = (product + free_coef >= threshold);
}

//----------------------------------------------------------------------------
// Extract descriptors

__kernel void extract_descrs_by_rows_kernel(const int cblock_hist_size, const int descriptors_quadstep, const int cdescr_size, const int cdescr_width,
        const int img_block_width, const int win_block_stride_x, const int win_block_stride_y,
        __global const float* block_hists, __global float* descriptors)
{
    int tid = get_local_id(0);
    int gidX = get_group_id(0);
    int gidY = get_group_id(1);

    // Get left top corner of the window in src
    __global const float* hist = block_hists + (gidY * win_block_stride_y * img_block_width + gidX * win_block_stride_x) * cblock_hist_size;

    // Get left top corner of the window in dst
    __global float* descriptor = descriptors + (gidY * get_num_groups(0) + gidX) * descriptors_quadstep;

    // Copy elements from src to dst
    for (int i = tid; i < cdescr_size; i += NTHREADS)
    {
        int offset_y = i / cdescr_width;
        int offset_x = i - offset_y * cdescr_width;
        descriptor[i] = hist[offset_y * img_block_width * cblock_hist_size + offset_x];
    }
}

__kernel void extract_descrs_by_cols_kernel(const int cblock_hist_size, const int descriptors_quadstep, const int cdescr_size,
        const int cnblocks_win_x, const int cnblocks_win_y, const int img_block_width, const int win_block_stride_x,
        const int win_block_stride_y, __global const float* block_hists, __global float* descriptors)
{
    int tid = get_local_id(0);
    int gidX = get_group_id(0);
    int gidY = get_group_id(1);

    // Get left top corner of the window in src
    __global const float* hist = block_hists + (gidY * win_block_stride_y * img_block_width + gidX * win_block_stride_x) * cblock_hist_size;

    // Get left top corner of the window in dst
    __global float* descriptor = descriptors + (gidY * get_num_groups(0) + gidX) * descriptors_quadstep;

    // Copy elements from src to dst
    for (int i = tid; i < cdescr_size; i += NTHREADS)
    {
        int block_idx = i / cblock_hist_size;
        int idx_in_block = i - block_idx * cblock_hist_size;

        int y = block_idx / cnblocks_win_x;
        int x = block_idx - y * cnblocks_win_x;

        descriptor[(x * cnblocks_win_y + y) * cblock_hist_size + idx_in_block] = hist[(y * img_block_width  + x) * cblock_hist_size + idx_in_block];
    }
}

//----------------------------------------------------------------------------
// Gradients computation

__kernel void compute_gradients_8UC4_kernel(const int height, const int width, const int img_step, const int grad_quadstep, const int qangle_step,
        const __global uchar4 * img, __global float * grad, __global uchar * qangle,
        const float angle_scale, const char correct_gamma, const int cnbins)
{
    const int x = get_global_id(0);
    const int tid = get_local_id(0);
    const int gSizeX = get_local_size(0);
    const int gidX = get_group_id(0);
    const int gidY = get_group_id(1);

    __global const uchar4* row = img + gidY * img_step;

    __local float sh_row[(NTHREADS + 2) * 3];

    uchar4 val;
    if (x < width)
        val = row[x];
    else
        val = row[width - 2];

    sh_row[tid + 1] = val.x;
    sh_row[tid + 1 + (NTHREADS + 2)] = val.y;
    sh_row[tid + 1 + 2 * (NTHREADS + 2)] = val.z;

    if (tid == 0)
    {
        val = row[max(x - 1, 1)];
        sh_row[0] = val.x;
        sh_row[(NTHREADS + 2)] = val.y;
        sh_row[2 * (NTHREADS + 2)] = val.z;
    }

    if (tid == gSizeX - 1)
    {
        val = row[min(x + 1, width - 2)];
        sh_row[gSizeX + 1] = val.x;
        sh_row[gSizeX + 1 + (NTHREADS + 2)] = val.y;
        sh_row[gSizeX + 1 + 2 * (NTHREADS + 2)] = val.z;
    }

    barrier(CLK_LOCAL_MEM_FENCE);
    if (x < width)
    {
        float3 a = (float3) (sh_row[tid], sh_row[tid + (NTHREADS + 2)], sh_row[tid + 2 * (NTHREADS + 2)]);
        float3 b = (float3) (sh_row[tid + 2], sh_row[tid + 2 + (NTHREADS + 2)], sh_row[tid + 2 + 2 * (NTHREADS + 2)]);

        float3 dx;
        if (correct_gamma == 1)
            dx = sqrt(b) - sqrt(a);
        else
            dx = b - a;

        float3 dy = (float3) 0.f;

        if (gidY > 0 && gidY < height - 1)
        {
            a = convert_float3(img[(gidY - 1) * img_step + x].xyz);
            b = convert_float3(img[(gidY + 1) * img_step + x].xyz);

            if (correct_gamma == 1)
                dy = sqrt(b) - sqrt(a);
            else
                dy = b - a;
        }

        float best_dx = dx.x;
        float best_dy = dy.x;

        float mag0 = dx.x * dx.x + dy.x * dy.x;
        float mag1 = dx.y * dx.y + dy.y * dy.y;
        if (mag0 < mag1)
        {
            best_dx = dx.y;
            best_dy = dy.y;
            mag0 = mag1;
        }

        mag1 = dx.z * dx.z + dy.z * dy.z;
        if (mag0 < mag1)
        {
            best_dx = dx.z;
            best_dy = dy.z;
            mag0 = mag1;
        }

        mag0 = sqrt(mag0);

        float ang = (atan2(best_dy, best_dx) + CV_PI_F) * angle_scale - 0.5f;
        int hidx = (int)floor(ang);
        ang -= hidx;
        hidx = (hidx + cnbins) % cnbins;

        qangle[(gidY * qangle_step + x) << 1] = hidx;
        qangle[((gidY * qangle_step + x) << 1) + 1] = (hidx + 1) % cnbins;
        grad[(gidY * grad_quadstep + x) << 1] = mag0 * (1.f - ang);
        grad[((gidY * grad_quadstep + x) << 1) + 1] = mag0 * ang;
    }
}

__kernel void compute_gradients_8UC1_kernel(const int height, const int width, const int img_step, const int grad_quadstep, const int qangle_step,
        __global const uchar * img, __global float * grad, __global uchar * qangle,
        const float angle_scale, const char correct_gamma, const int cnbins)
{
    const int x = get_global_id(0);
    const int tid = get_local_id(0);
    const int gSizeX = get_local_size(0);
    const int gidX = get_group_id(0);
    const int gidY = get_group_id(1);

    __global const uchar* row = img + gidY * img_step;

    __local float sh_row[NTHREADS + 2];

    if (x < width)
        sh_row[tid + 1] = row[x];
    else
        sh_row[tid + 1] = row[width - 2];

    if (tid == 0)
        sh_row[0] = row[max(x - 1, 1)];

    if (tid == gSizeX - 1)
        sh_row[gSizeX + 1] = row[min(x + 1, width - 2)];

    barrier(CLK_LOCAL_MEM_FENCE);
    if (x < width)
    {
        float dx;

        if (correct_gamma == 1)
            dx = sqrt(sh_row[tid + 2]) - sqrt(sh_row[tid]);
        else
            dx = sh_row[tid + 2] - sh_row[tid];

        float dy = 0.f;
        if (gidY > 0 && gidY < height - 1)
        {
            float a = (float) img[ (gidY + 1) * img_step + x ];
            float b = (float) img[ (gidY - 1) * img_step + x ];
            if (correct_gamma == 1)
                dy = sqrt(a) - sqrt(b);
            else
                dy = a - b;
        }
        float mag = sqrt(dx * dx + dy * dy);

        float ang = (atan2(dy, dx) + CV_PI_F) * angle_scale - 0.5f;
        int hidx = (int)floor(ang);
        ang -= hidx;
        hidx = (hidx + cnbins) % cnbins;

        qangle[ (gidY * qangle_step + x) << 1 ]     = hidx;
        qangle[ ((gidY * qangle_step + x) << 1) + 1 ] = (hidx + 1) % cnbins;
        grad[ (gidY * grad_quadstep + x) << 1 ]       = mag * (1.f - ang);
        grad[ ((gidY * grad_quadstep + x) << 1) + 1 ]   = mag * ang;
    }
}

//----------------------------------------------------------------------------
// Resize

__kernel void resize_8UC4_kernel(__global uchar4 * dst, __global const uchar4 * src,
                                 int dst_offset, int src_offset, int dst_step, int src_step,
                                 int src_cols, int src_rows, int dst_cols, int dst_rows, float ifx, float ify )
{
    int dx = get_global_id(0);
    int dy = get_global_id(1);

    int sx = (int)floor(dx*ifx+0.5f);
    int sy = (int)floor(dy*ify+0.5f);
    sx = min(sx, src_cols-1);
    sy = min(sy, src_rows-1);
    int dpos = (dst_offset>>2) + dy * (dst_step>>2) + dx;
    int spos = (src_offset>>2) + sy * (src_step>>2) + sx;

    if(dx<dst_cols && dy<dst_rows)
        dst[dpos] = src[spos];
}

__kernel void resize_8UC1_kernel(__global uchar * dst, __global const uchar * src,
                                 int dst_offset, int src_offset, int dst_step, int src_step,
                                 int src_cols, int src_rows, int dst_cols, int dst_rows, float ifx, float ify )
{
    int dx = get_global_id(0);
    int dy = get_global_id(1);

    int sx = (int)floor(dx*ifx+0.5f);
    int sy = (int)floor(dy*ify+0.5f);
    sx = min(sx, src_cols-1);
    sy = min(sy, src_rows-1);
    int dpos = dst_offset + dy * dst_step + dx;
    int spos = src_offset + sy * src_step + sx;

    if(dx<dst_cols && dy<dst_rows)
        dst[dpos] = src[spos];
}