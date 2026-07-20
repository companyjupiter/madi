// metal_backend.h — Sovereign Engine Metal Backend C API
// Zig ↔ Objective-C 브릿지: Zig에서 C ABI로 호출 가능한 Metal 래퍼
#ifndef METAL_BACKEND_H
#define METAL_BACKEND_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── 초기화 ──────────────────────────────────────────────
// Metal 디바이스 + 커맨드 큐 생성. 성공 시 0 반환.
int mtl_init(void);
void mtl_cleanup(void);

// ── 메모리 관리 (Unified Memory) ─────────────────────────
// Apple Silicon 통합 메모리: CPU/GPU 포인터가 동일
// 반환값: CPU/GPU 공유 포인터 (직접 memcpy 가능)
void* mtl_alloc(size_t size);
void  mtl_free(void* ptr);
// Deterministic registry invariant test: deleting one colliding key must not
// hide later keys in the same open-addressing probe chain. Returns 0 on pass.
int mtl_test_buffer_hash_delete_chain(void);

// 통합 메모리이므로 직접 포인터 접근 가능하지만,
// GPU 캐시 플러시가 필요한 경우 사용
void mtl_upload(void* gpu_buf, const void* src, size_t size);
void mtl_download(void* dst, const void* gpu_buf, size_t size);

// Argument Buffer 생성 및 바인딩 C API
void* mtl_create_argument_buffer(const void** ptrs, int n_buffers, int pipeline_id, int buffer_index);

// ── 커널 로드 ────────────────────────────────────────────
// .metallib 파일에서 모든 커널 함수를 로드
// 성공 시 0, 실패 시 -1
int mtl_load_library(const char* metallib_path);

// 메모리 blob(@embedFile 한 metallib 바이트)에서 라이브러리 로드 → 단일 자체완결 바이너리.
// 성공 시 0, 실패 시 -1
int mtl_load_library_data(const void* data, unsigned long len);

// 커널 이름으로 함수 핸들(인덱스) 가져오기
// 성공 시 0, out_id에 함수 인덱스 저장
int mtl_get_function(const char* name, int* out_id);

// ── 커널 실행 ────────────────────────────────────────────
// CUDA의 cuLaunchKernel에 대응
// args: 각 인자의 포인터 배열 (예: &buffer_ptr, &scalar_val)
// arg_sizes: 각 인자의 크기 배열 (예: sizeof(void*), sizeof(uint32_t))
// n_args: 인자 개수
int mtl_dispatch(int func_id,
                 uint32_t grid_x, uint32_t grid_y, uint32_t grid_z,
                 uint32_t block_x, uint32_t block_y, uint32_t block_z,
                 const void** args, const size_t* arg_sizes, int n_args);

// 현재 인코딩 중인 Compute Command Encoder만 endEncoding 처리 (CPU 블록 없음)
void mtl_flush(void);

// 현재 커맨드 버퍼의 모든 커널 실행 완료 대기
int mtl_sync(void);

// ── 커맨드 버퍼 관리 ─────────────────────────────────────
// 새로운 커맨드 버퍼 시작 (배치 디스패치용)
int mtl_begin_command_buffer(void);

// 현재 커맨드 버퍼 제출 (비동기 실행 시작)
int mtl_commit_command_buffer(void);

// ── Metal 4 command API (Phase 1) ────────────────────────
// SOV_MTL4=1 환경에서 mtl_load_library 시 MTL4 영속 객체(queue/compiler/allocator/
// argtable/residency/event/param-ring) + 전 커널 MTL4 pipeline 생성. 1이면 사용가능.
int mtl_mtl4_enabled(void);
// 다음 begin/dispatch/commit/sync 사이클을 MTL4 경로로 실행할지 설정.
// on!=0 이고 mtl4 init 성공한 경우에만 활성. classic 경로는 토글 OFF시 바이트 동일 보존.
void mtl_set_mtl4(int on);

// ── 프로파일 ─────────────────────────────────────────────
// SOV_METAL_PROFILE=1 일 때 mtl_dispatch 가 커널별 GPU 시간을 누적.
// 종료 시 atexit 로 nsys cuda_gpu_kern_sum 포맷 덤프 (out_path=NULL → stdout).
void mtl_dump_profile(const char* out_path);

// ── 디버그 ───────────────────────────────────────────────
// GPU 이름, 통합 메모리 상태 등 출력
void mtl_print_device_info(void);

// verbose 로그 게이트. v!=0 이면 [metal] Device/Loaded/[idx] 등 정보성 출력 ON.
// 기본 OFF(에러/경고만). 호출 안 하면 env SOV_DEBUG 로 폴백 결정.
// (앱은 --debug / SOV_DEBUG → Backend.setVerbose() 로 mtl_init 전 설정.)
void mtl_set_verbose(int v);

// ── MPS matmul (row-major F32) ───────────────────────────
// C[M][N] = alpha * A[M][K] @ B[K][N] + beta * C. Self-contained: own command
// buffer, blocks until done. Commit/sync pending dispatches before calling.
// A/B/C must be mtl_alloc pointers. Returns 0 on success.
int mtl_matmul_f32(const void* A, const void* B, void* C,
                   int M, int N, int K, float alpha, float beta);
// Batched variant: encodes onto the active command buffer (no commit/wait).
// Caller wraps with begin/commit/sync. Preserves order with dispatches.
int mtl_matmul_f32_enc(const void* A, const void* B, void* C,
                       int M, int N, int K, float alpha, float beta);
int mtl_matmul_f16_enc(const void* A, const void* B, void* C,
                       int M, int N, int K, float alpha, float beta);

// ── Metal 버퍼 핸들 (Zig에서 직접 포인터로 사용) ────────
// 통합 메모리에서는 void*가 곧 GPU 포인터
// mtl_alloc()으로 할당한 포인터를 커널 인자로 그대로 전달

#ifdef __cplusplus
}
#endif

#endif // METAL_BACKEND_H
