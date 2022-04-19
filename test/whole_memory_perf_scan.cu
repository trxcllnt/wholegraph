#include <assert.h>
#include <stdio.h>
#include <cuda_runtime_api.h>

#include <experimental/random>
#include <functional>
#include <vector>

#include "whole_memory.h"
#include "whole_memory_test_utils.cuh"
#include "parallel_utils.h"

#define TEST_GPU_COUNT (8)
static const int64_t kMemorySize = 400LL * 1024LL * 1024LL * 1024LL;  // use 400 GB memory
static const size_t total_gather_size = 4 * 1024LL * 1024LL * 1024LL;

template<typename HandleT, typename T, int GroupCount, int OpType>
void DoSingleTest(void *memory_ptr,
                  int64_t *indice_d,
                  void *local_mem,
                  const std::function<void()> &barrier_fn,
                  const std::function<std::vector<double>(double, int)> &all_gather_perf_fn,
                  int rank,
                  bool just_warm_up) {
  int gather_count = total_gather_size / sizeof(T) / GroupCount;
  int64_t entry_count = kMemorySize / sizeof(T) / GroupCount;
  if (just_warm_up) {
    gather_count = std::min(gather_count, 128);
    GroupWholeMemoryTest<HandleT, T, GroupCount, OpType>((T *) local_mem,
                                                         (HandleT *) memory_ptr,
                                                         indice_d,
                                                         gather_count,
                                                         entry_count);
    assert(cudaStreamSynchronize(nullptr) == cudaSuccess);
    return;
  }
  barrier_fn();

  struct timeval tv_s, tv_e;
  gettimeofday(&tv_s, nullptr);
  GroupWholeMemoryTest<HandleT, T, GroupCount, OpType>((T *) local_mem,
                                                       (HandleT *) memory_ptr,
                                                       indice_d,
                                                       gather_count,
                                                       entry_count);
  assert(cudaStreamSynchronize(nullptr) == cudaSuccess);
  gettimeofday(&tv_e, nullptr);
  int time_us = TIME_DIFF_US(tv_s, tv_e);
  double bw = total_gather_size / time_us / 1e3;
  //printf("Rank=%d, elt_size=%d, GroupCount=%d, time used=%d us, BW=%.2lf GB/s\n",
  //    rank, (int)sizeof(T), GroupCount, time_us, bw);

  auto perf_vec = all_gather_perf_fn(bw, rank);
  double min_bw, max_bw, avg_bw;
  min_bw = max_bw = perf_vec[0];
  avg_bw = 0.0;
  for (int i = 0; i < TEST_GPU_COUNT; i++) {
    min_bw = std::min(min_bw, perf_vec[i]);
    max_bw = std::max(max_bw, perf_vec[i]);
    avg_bw += perf_vec[i];
  }
  avg_bw /= TEST_GPU_COUNT;
  std::string op_type_str = "Reading";
  if (OpType == 1) {
    op_type_str = "Writing";
  } else if (OpType == 2) {
    op_type_str = "AtomicAdd";
  }
  if (rank == 0) {
    printf("%s elt_size=%d, GroupCount=%d, minBW=%.2lf GB/s, maxBW=%.2lf GB/s, avgBW=%.2lf GB/s\n",
           op_type_str.c_str(), (int) sizeof(T), GroupCount, min_bw, max_bw, avg_bw);
  }
  barrier_fn();
}

template<bool UseDeviceHandle, typename T, int GroupCount, int OpType>
void SingleTestCommon(void *memory_ptr,
                      int64_t *indice_d,
                      void *local_mem,
                      const std::function<void()> &barrier_fn,
                      const std::function<std::vector<double>(double, int)> &all_gather_perf_fn,
                      int rank,
                      bool just_warm_up) {
  if (UseDeviceHandle) {
    DoSingleTest<whole_memory::WholeChunkedMemoryHandle, T, GroupCount, OpType>(memory_ptr,
                                                                                indice_d,
                                                                                local_mem,
                                                                                barrier_fn,
                                                                                all_gather_perf_fn,
                                                                                rank,
                                                                                just_warm_up);
  } else {
    DoSingleTest<T, T, GroupCount, OpType>(memory_ptr,
                                           indice_d,
                                           local_mem,
                                           barrier_fn,
                                           all_gather_perf_fn,
                                           rank,
                                           just_warm_up);
  }
}

typedef enum {
    SingleProcess = 0,
    MultiProcess = 1,
    ChunkedMultiProcess = 2,
} RunMode;

RunMode run_mode = SingleProcess;

template <bool UseDeviceHandle>
void RankFunc(int rank, int dev_count, void* memory_ptr,
              const std::function<void()> &barrier_fn,
              const std::function<std::vector<double>(double, int)> &all_gather_perf_fn) {
  assert(cudaSetDevice(rank % dev_count) == cudaSuccess);
  int64_t *indice_d = nullptr;
  int64_t *indice_h = nullptr;
  float *output_d = nullptr;
  size_t max_gather_count = total_gather_size / sizeof(float);
  assert(cudaMalloc((void **) &indice_d, max_gather_count * sizeof(int64_t)) == cudaSuccess);
  assert(cudaMallocHost((void **) &indice_h, max_gather_count * sizeof(int64_t)) == cudaSuccess);
  assert(cudaMalloc((void **) &output_d, total_gather_size) == cudaSuccess);
  for (size_t i = 0; i < max_gather_count; i++) {
    indice_h[i] = std::experimental::randint<int64_t>(0, kMemorySize / sizeof(float) - 1);
  }
  assert(cudaMemcpy(indice_d, indice_h, max_gather_count * sizeof(int64_t), cudaMemcpyHostToDevice) == cudaSuccess);
  assert(cudaDeviceSynchronize() == cudaSuccess);
  barrier_fn();
#define RunTypeAndOp(DataType, OpType) \
do { \
    SingleTestCommon<UseDeviceHandle, DataType, 1, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 2, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 4, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 8, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 16, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 32, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 64, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 128, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 256, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 512, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
    SingleTestCommon<UseDeviceHandle, DataType, 1024, OpType>(memory_ptr, indice_d, output_d, barrier_fn, all_gather_perf_fn, rank, just_warm_up); \
} while(0)

  for (int i = 0; i < 2; i++) {
    bool just_warm_up = (i == 0);

    RunTypeAndOp(float, 0);
    RunTypeAndOp(float2, 0);
    RunTypeAndOp(float4, 0);
    RunTypeAndOp(float, 1);
    RunTypeAndOp(float2, 1);
    RunTypeAndOp(float4, 1);
    RunTypeAndOp(float, 2);

    barrier_fn();
  }
}

void SingleProcessFunc(int size) {
  whole_memory::WholeMemoryInit();

  int dev_count = 0;
  assert(cudaGetDeviceCount(&dev_count) == cudaSuccess);

  void* memory_ptr = nullptr;

  whole_memory::WmspMalloc((void**)&memory_ptr, kMemorySize);

  pthread_barrier_t barrier;
  pthread_barrier_init(&barrier, nullptr, TEST_GPU_COUNT);
  std::vector<double> perf_vec(TEST_GPU_COUNT, 0.0f);

  auto barrier_fn = [&barrier]() -> void {
    pthread_barrier_wait(&barrier);
  };
  auto all_gather_fn = [&barrier, &perf_vec](double bw, int rank) -> std::vector<double> {
    pthread_barrier_wait(&barrier);
    perf_vec[rank] = bw;
    pthread_barrier_wait(&barrier);
    return perf_vec;
  };

  MultiThreadRun(size, [=](int rank, int size) {
    assert(cudaSetDevice(rank % dev_count) == cudaSuccess);
    RankFunc<false>(rank, dev_count, memory_ptr, barrier_fn, all_gather_fn);
  });

  pthread_barrier_destroy(&barrier);

  whole_memory::WmspFree(memory_ptr);

  whole_memory::WholeMemoryFinalize();
}

std::vector<double> AllGatherMultiProcess(double data, int rank, int size) {
  std::vector<double> gvec(size, data);
  std::vector<double> recv_vec(size);
  whole_memory::WmmpAllToAll(gvec.data(), sizeof(double), recv_vec.data(), sizeof(double));
  return recv_vec;
}

void MultiProcessFunc(int size) {
  MultiProcessRun(size, [](int rank, int size) {
    whole_memory::WholeMemoryInit();
    int dev_count = 0;
    assert(cudaGetDeviceCount(&dev_count) == cudaSuccess);
    assert(cudaSetDevice(rank % dev_count) == cudaSuccess);
    whole_memory::WmmpInit(rank, size, nullptr);

    void* memory_ptr = nullptr;

    whole_memory::WmmpMalloc((void**)&memory_ptr, kMemorySize);

    auto barrier_fn = []() -> void {
      whole_memory::WmmpBarrier();
    };
    auto all_gather_fn = [=](double bw, int rank) -> std::vector<double> {
      return AllGatherMultiProcess(bw, rank, size);
    };
    RankFunc<false>(rank, dev_count, memory_ptr, barrier_fn, all_gather_fn);

    whole_memory::WmmpFree(memory_ptr);

    whole_memory::WholeMemoryFinalize();
  });
}

void ChunkedMultiProcessFunc(int size) {
  MultiProcessRun(size, [](int rank, int size) {
    whole_memory::WholeMemoryInit();
    int dev_count = 0;
    assert(cudaGetDeviceCount(&dev_count) == cudaSuccess);
    int dev_id = rank % dev_count;
    assert(cudaSetDevice(dev_id) == cudaSuccess);
    whole_memory::WmmpInit(rank, size, nullptr);

    whole_memory::WholeChunkedMemory_t wcm;

    whole_memory::WcmmpMalloc(&wcm, kMemorySize, 2 * 1024 * 1024);
    whole_memory::WholeChunkedMemoryHandle* memory_ptr = whole_memory::GetDeviceChunkedHandle(wcm, dev_id);

    auto barrier_fn = []() -> void {
      whole_memory::WmmpBarrier();
    };
    auto all_gather_fn = [=](double bw, int rank) -> std::vector<double> {
      return AllGatherMultiProcess(bw, rank, size);
    };
    RankFunc<true>(rank, dev_count, memory_ptr, barrier_fn, all_gather_fn);

    whole_memory::WcmmpFree(wcm);

    whole_memory::WholeMemoryFinalize();
  });
}

int main(int argc, char** argv) {
  std::string usage = "Usage: ";
  usage += argv[0];
  usage += " mode[s|m|c]\n\ts(default): single process, m: multi-process, c: chunked multi-process.\n";
  if (argc > 2) {
    printf("%s\n", usage.c_str());
    return -1;
  }
  std::string mode_str = "s";
  if (argc >= 2) {
    mode_str = argv[1];
  }
  if (mode_str == "s") {
    run_mode = SingleProcess;
  } else if (mode_str == "m") {
    run_mode = MultiProcess;
  } else if (mode_str == "c") {
    run_mode = ChunkedMultiProcess;
  } else {
    printf("%s\n", usage.c_str());
    return -1;
  }

  if (run_mode == SingleProcess) {
    SingleProcessFunc(TEST_GPU_COUNT);
  } else if (run_mode == MultiProcess) {
    MultiProcessFunc(TEST_GPU_COUNT);
  } else {
    ChunkedMultiProcessFunc(TEST_GPU_COUNT);
  }

  return 0;
}