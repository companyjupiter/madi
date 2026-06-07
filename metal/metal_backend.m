// metal_backend.m — Sovereign Engine Metal Backend Implementation
// Objective-C: Metal Framework 래퍼 → C ABI로 노출
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include "metal_backend.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

// ── 글로벌 상태 ──────────────────────────────────────────

static id<MTLDevice>       g_device       = nil;
static id<MTLCommandQueue>  g_queue        = nil;
static id<MTLLibrary>       g_library      = nil;
static id<MTLCommandBuffer>  g_cmdbufs[2]   = { nil, nil };
static id<MTLCommandBuffer>  g_committed_cmdbuf = nil;
static int                  g_active_cmdbuf_idx = 0;
static id<MTLComputeCommandEncoder> g_encoder = nil;

// ── Metal 4 command API 영속 상태 (Phase 1) ──────────────
// classic 경로와 병렬. g_mtl4_init_ok=0 이면 모든 분기 classic 으로 폴백 → OFF시 바이트동일.
static int                          g_mtl4_enabled_env  = -1;   // -1=미확인, 0/1
static int                          g_mtl4_init_ok      = 0;    // 영속 객체 생성 성공
static int                          g_mtl4_active       = 0;    // 현 사이클 MTL4 경로 사용?
static id<MTL4CommandQueue>         g_mtl4_queue        = nil;
static id<MTL4Compiler>             g_mtl4_compiler     = nil;
static id<MTL4CommandAllocator>     g_mtl4_alloc        = nil;
static id<MTL4ArgumentTable>        g_mtl4_argtable     = nil;
static id<MTLResidencySet>          g_mtl4_residency    = nil;
static id<MTLSharedEvent>           g_mtl4_event        = nil;
static id<MTL4CommandBuffer>        g_mtl4_cb           = nil;
static id<MTL4ComputeCommandEncoder> g_mtl4_enc         = nil;
static id<MTLComputePipelineState>  g_mtl4_pipelines[96];       // MAX_FUNCTIONS
static id<MTLBuffer>                g_mtl4_param_buffer = nil;   // 스칼라 인자 ring (setBytes 대체)
static int                          g_mtl4_param_offset = 0;
static uint64_t                     g_mtl4_signal       = 0;     // 단조증가 event 값
static int                          g_mtl4_res_dirty    = 1;     // residency 재빌드 필요?
// dispatch 간 barrier 의 cache-flush 범위. Device(1<<0)=device-coherent flush(보수적/안전),
// None(0)=실행순서만(Apple unified LLC 코히런시 의존). SOV_MTL4_VIS=0 으로 None 실험.
static int                          g_mtl4_vis          = -1;    // -1=미확인
static MTL4VisibilityOptions mtl4_vis(void) {
    if (g_mtl4_vis < 0) {
        const char* e = getenv("SOV_MTL4_VIS");
        // 기본 = Device (안전). SOV_MTL4_VIS=0 이면 None.
        g_mtl4_vis = (e && e[0] == '0') ? 0 : 1;
    }
    return g_mtl4_vis ? MTL4VisibilityOptionDevice : MTL4VisibilityOptionNone;
}

static int mtl4_enabled_env(void) {
    if (g_mtl4_enabled_env < 0) {
        const char* e = getenv("SOV_MTL4");
        g_mtl4_enabled_env = (e && e[0] && e[0] != '0') ? 1 : 0;
    }
    return g_mtl4_enabled_env;
}

// ── verbose 로그 게이트 (--debug / SOV_DEBUG) ──
// 정보성 출력([metal] Device/Loaded/[idx] ...)은 verbose ON 일 때만.
// ERROR/WARNING/FAIL 은 게이트와 무관하게 항상 출력.
// -1=미확인 → 최초 조회 시 env SOV_DEBUG 폴백. mtl_set_verbose() 가 명시 override.
static int g_verbose = -1;
static int verbose_enabled(void) {
    if (g_verbose < 0) {
        const char* e = getenv("SOV_DEBUG");
        g_verbose = (e && e[0] && e[0] != '0') ? 1 : 0;
    }
    return g_verbose;
}
void mtl_set_verbose(int v) { g_verbose = v ? 1 : 0; }

// 정보성 stderr 로그: verbose 일 때만 출력. (ERROR 류는 그냥 fprintf 유지.)
#define MLOG(...) do { if (verbose_enabled()) fprintf(stderr, __VA_ARGS__); } while (0)

// 할당 뮤텍스 (비동기 스레드 업로드 대비)
static pthread_mutex_t g_alloc_mutex = PTHREAD_MUTEX_INITIALIZER;

// 커널 함수 + 파이프라인 캐시 (최대 64개)
#define MAX_FUNCTIONS 96
static id<MTLFunction>              g_functions[MAX_FUNCTIONS];
static id<MTLComputePipelineState>  g_pipelines[MAX_FUNCTIONS];
static int                          g_n_functions = 0;

// ── per-kernel GPU 프로파일링 (env SOV_METAL_PROFILE=1 일 때만) ──
// nsys cuda_gpu_kern_sum 텍스트를 내보내 quark hotpath_v7 / ledger_v7 가 그대로
// 소비하게 한다. profile OFF(기본)면 mtl_dispatch 의 measured 분기는 전부 skip →
// 정상 실행 경로는 바이트 동일. GPUEndTime-GPUStartTime 은 GPU 하드웨어 타임스탬프라
// (CPU commit 오버헤드 불포함) 커널별 격리 dispatch 로도 순수 실행시간이 측정된다.
static int     g_profile_enabled = -1;        // -1=미확인, 0/1=getenv 결과
static int     g_profile_dumped  = 0;          // 1회만 덤프 (cleanup/atexit 이중호출 방지)
static char    g_func_names[MAX_FUNCTIONS][64];
static double  g_prof_total_ns[MAX_FUNCTIONS];
static long    g_prof_calls[MAX_FUNCTIONS];

void mtl_dump_profile(const char* out_path);  // fwd decl

// atexit 핸들러: REPL(main)이 mtl_cleanup 을 호출하지 않으므로 프로세스 종료 시 덤프.
static void profile_atexit(void) {
    const char* op = getenv("SOV_METAL_PROFILE_OUT");
    mtl_dump_profile(op ? op : "/tmp/metal_kern_sum.txt");
}

static int profile_enabled(void) {
    if (g_profile_enabled < 0) {
        const char* e = getenv("SOV_METAL_PROFILE");
        g_profile_enabled = (e && e[0] && e[0] != '0') ? 1 : 0;
        if (g_profile_enabled) atexit(profile_atexit);
    }
    return g_profile_enabled;
}

// 할당된 버퍼 추적 — 해시 테이블 (P3-a: O(1) lookup for 31B models)
#define HASH_BITS 13
#define HASH_SIZE (1 << HASH_BITS)  // 8192 slots
#define HASH_MASK (HASH_SIZE - 1)

typedef struct {
    void*             ptr;     // NULL = empty
    id<MTLBuffer>     buffer;
    size_t            size;
    id<MTLBuffer>     child_resources[8];
    int               n_child_resources;
} BufferEntry;

static BufferEntry g_buf_hash[HASH_SIZE];
static int         g_n_buffers = 0;

static inline uint32_t ptr_hash(const void* p) {
    // Fibonacci hashing — distributes pointer values uniformly
    uint64_t h = (uint64_t)p * 11400714819323198485ULL;
    return (uint32_t)(h >> (64 - HASH_BITS));
}

// ── 내부 헬퍼 ────────────────────────────────────────────

static BufferEntry* find_entry(const void* ptr) {
    uint32_t idx = ptr_hash(ptr);
    for (uint32_t probe = 0; probe < 64; probe++) {  // max 64 probes
        uint32_t i = (idx + probe) & HASH_MASK;
        if (g_buf_hash[i].ptr == ptr) return &g_buf_hash[i];
        if (g_buf_hash[i].ptr == NULL) return NULL;
    }
    return NULL;
}

static id<MTLBuffer> find_buffer(const void* ptr) {
    BufferEntry* entry = find_entry(ptr);
    return entry ? entry->buffer : nil;
}

// Resolve a (possibly mid-buffer) pointer to its base MTLBuffer + byte offset.
// Defined later; forward-declared so the dispatch path can bind offset pointers.
static id<MTLBuffer> resolve_buffer(const void* p, size_t* out_off);

static void insert_buffer(void* ptr, id<MTLBuffer> buf, size_t size) {
    uint32_t idx = ptr_hash(ptr);
    for (uint32_t probe = 0; probe < 64; probe++) {
        uint32_t i = (idx + probe) & HASH_MASK;
        if (g_buf_hash[i].ptr == NULL) {
            g_buf_hash[i].ptr = ptr;
            g_buf_hash[i].buffer = buf;
            g_buf_hash[i].size = size;
            g_n_buffers++;
            return;
        }
    }
    fprintf(stderr, "[metal] ERROR: Hash table full (%d buffers)\n", g_n_buffers);
}

static void remove_buffer(void* ptr) {
    uint32_t idx = ptr_hash(ptr);
    for (uint32_t probe = 0; probe < 64; probe++) {
        uint32_t i = (idx + probe) & HASH_MASK;
        if (g_buf_hash[i].ptr == ptr) {
            g_buf_hash[i].buffer = nil;
            g_buf_hash[i].ptr = NULL;
            g_n_buffers--;
            return;
        }
        if (g_buf_hash[i].ptr == NULL) return;
    }
}

static void ensure_encoder(void) {
    if (g_encoder == nil) {
        if (g_cmdbufs[g_active_cmdbuf_idx] == nil) {
            g_cmdbufs[g_active_cmdbuf_idx] = [g_queue commandBuffer];
        }
        g_encoder = [g_cmdbufs[g_active_cmdbuf_idx] computeCommandEncoder];
    }
}

// ── 초기화 ───────────────────────────────────────────────

int mtl_init(void) {
    @autoreleasepool {
        g_device = MTLCreateSystemDefaultDevice();
        if (g_device == nil) {
            fprintf(stderr, "[metal] ERROR: No Metal device found\n");
            return -1;
        }
        g_queue = [g_device newCommandQueue];
        if (g_queue == nil) {
            fprintf(stderr, "[metal] ERROR: Failed to create command queue\n");
            return -1;
        }
        MLOG("[metal] Device: %s\n", [[g_device name] UTF8String]);
        MLOG("[metal] Unified Memory: %s\n",
                [g_device hasUnifiedMemory] ? "YES" : "NO");
        MLOG("[metal] Max Buffer Size: %lu MB\n",
                (unsigned long)([g_device maxBufferLength] / 1048576));
        return 0;
    }
}

// nsys cuda_gpu_kern_sum 포맷으로 per-kernel GPU 시간을 내보낸다.
// 컬럼: Time(%)  TotalTime(ns)  Instances  Avg  Med  Min  Max  StdDev  Name
// (hotpath_v7 / ledger_v7 파서가 그대로 소비. Med=Avg, Min/Max=0, StdDev=0 로 채움 —
//  우리는 합계+호출수만 추적하므로 분포 통계는 0. share/ranking 에는 영향 없음.)
void mtl_dump_profile(const char* out_path) {
    if (g_profile_dumped) return;   // cleanup + atexit 이중호출 → 첫 호출만 유효
    g_profile_dumped = 1;
    double grand = 0.0;
    for (int i = 0; i < g_n_functions; i++) grand += g_prof_total_ns[i];
    FILE* f = out_path ? fopen(out_path, "w") : stdout;
    if (!f) { fprintf(stderr, "[metal] profile dump: cannot open %s\n", out_path); return; }
    fprintf(f, " Time(%%)  Total Time (ns)  Instances    Avg (ns)    Med (ns)  Min (ns)  Max (ns)  StdDev (ns)  Name\n");
    fprintf(f, " -------  ---------------  ---------  ----------  ----------  --------  --------  -----------  --------------------\n");
    // 큰 순서로 정렬해서 출력 (사람이 봐도, 파서가 봐도 무관하지만 hotpath rank 와 일치)
    for (int pass = 0; pass < g_n_functions; pass++) {
        int best = -1; double bestv = -1;
        for (int i = 0; i < g_n_functions; i++) {
            if (g_prof_calls[i] == 0) continue;
            // 이미 출력한 것 제외 위해 음수 마킹 사용
            if (g_prof_total_ns[i] >= 0 && g_prof_total_ns[i] > bestv) { bestv = g_prof_total_ns[i]; best = i; }
        }
        if (best < 0) break;
        double tot = g_prof_total_ns[best];
        long calls = g_prof_calls[best];
        double pct = grand > 0 ? (tot / grand * 100.0) : 0.0;
        double avg = calls > 0 ? (tot / (double)calls) : 0.0;
        fprintf(f, " %7.1f  %15lld  %9ld  %10.1f  %10.1f  %8d  %8d  %11.1f  %s\n",
                pct, (long long)tot, calls, avg, avg, 0, 0, 0.0, g_func_names[best]);
        g_prof_total_ns[best] = -1.0; // mark emitted
    }
    if (out_path) { fclose(f); fprintf(stderr, "[metal] profile dumped -> %s\n", out_path); }
}

void mtl_cleanup(void) {
    @autoreleasepool {
        if (profile_enabled()) {
            const char* op = getenv("SOV_METAL_PROFILE_OUT");
            mtl_dump_profile(op ? op : "/tmp/metal_kern_sum.txt");
        }
        if (g_encoder) { [g_encoder endEncoding]; g_encoder = nil; }
        g_cmdbufs[0] = nil;
        g_cmdbufs[1] = nil;
        g_committed_cmdbuf = nil;
        g_active_cmdbuf_idx = 0;
        g_library = nil;
        g_queue   = nil;
        g_device  = nil;
        g_n_functions = 0;
        // MTL4 영속 객체 해제
        if (g_mtl4_enc) { [g_mtl4_enc endEncoding]; g_mtl4_enc = nil; }
        g_mtl4_cb = nil;
        g_mtl4_param_buffer = nil;
        g_mtl4_residency = nil;
        g_mtl4_event = nil;
        g_mtl4_argtable = nil;
        g_mtl4_alloc = nil;
        g_mtl4_compiler = nil;
        g_mtl4_queue = nil;
        g_mtl4_active = 0;
        g_mtl4_init_ok = 0;
        // Clear hash table
        memset(g_buf_hash, 0, sizeof(g_buf_hash));
        g_n_buffers = 0;
    }
}

// ── 메모리 관리 ──────────────────────────────────────────

void* mtl_alloc(size_t size) {
    pthread_mutex_lock(&g_alloc_mutex);
    @autoreleasepool {
        if (g_n_buffers >= HASH_SIZE * 3 / 4) {  // 75% load factor limit
            fprintf(stderr, "[metal] ERROR: Buffer hash table load too high (%d)\n", g_n_buffers);
            pthread_mutex_unlock(&g_alloc_mutex);
            return NULL;
        }
        // MTLResourceStorageModeShared = CPU/GPU 공유 (통합 메모리)
        id<MTLBuffer> buf = [g_device newBufferWithLength:size
                                    options:MTLResourceStorageModeShared];
        if (buf == nil) {
            fprintf(stderr, "[metal] ERROR: Failed to allocate %zu bytes\n", size);
            pthread_mutex_unlock(&g_alloc_mutex);
            return NULL;
        }
        void* ptr = [buf contents];
        insert_buffer(ptr, buf, size);
        g_mtl4_res_dirty = 1;   // MTL4 residency 재빌드 필요 (신규 버퍼)
        pthread_mutex_unlock(&g_alloc_mutex);
        return ptr;
    }
}

void mtl_free(void* ptr) {
    pthread_mutex_lock(&g_alloc_mutex);
    remove_buffer(ptr);
    pthread_mutex_unlock(&g_alloc_mutex);
}

void mtl_upload(void* gpu_buf, const void* src, size_t size) {
    // 통합 메모리: 직접 memcpy
    memcpy(gpu_buf, src, size);
}

void mtl_download(void* dst, const void* gpu_buf, size_t size) {
    // 통합 메모리: 직접 memcpy
    memcpy(dst, gpu_buf, size);
}

void* mtl_create_argument_buffer(const void** ptrs, int n_buffers, int pipeline_id, int buffer_index) {
    @autoreleasepool {
        if (pipeline_id < 0 || pipeline_id >= g_n_functions) {
            fprintf(stderr, "[metal] ERROR: Invalid pipeline_id %d\n", pipeline_id);
            return NULL;
        }
        id<MTLFunction> func = g_functions[pipeline_id];
        if (func == nil) {
            fprintf(stderr, "[metal] ERROR: No function cache at index %d\n", pipeline_id);
            return NULL;
        }
        
        // MTLArgumentEncoder 생성
        id<MTLArgumentEncoder> encoder = [func newArgumentEncoderWithBufferIndex:buffer_index];
        if (encoder == nil) {
            fprintf(stderr, "[metal] ERROR: Failed to create argument encoder for function index %d at buffer index %d\n", pipeline_id, buffer_index);
            return NULL;
        }
        
        // Argument Buffer를 담을 MTLBuffer 생성
        id<MTLBuffer> argBuffer = [g_device newBufferWithLength:[encoder encodedLength] options:MTLResourceStorageModeShared];
        if (argBuffer == nil) {
            fprintf(stderr, "[metal] ERROR: Failed to allocate argument buffer (length=%zu)\n", [encoder encodedLength]);
            return NULL;
        }
        
        [encoder setArgumentBuffer:argBuffer offset:0];
        
        // 자식 리소스들을 담을 임시 배열
        id<MTLBuffer> children[8];
        int n_children = 0;
        
        // 각 포인터를 MTLBuffer로 찾아서 Argument Buffer 내부에 바인딩
        for (int i = 0; i < n_buffers; i++) {
            if (ptrs[i] != NULL) {
                id<MTLBuffer> buf = find_buffer(ptrs[i]);
                if (buf != nil) {
                    [encoder setBuffer:buf offset:0 atIndex:i];
                    if (n_children < 8) {
                        children[n_children++] = buf;
                    }
                } else {
                    fprintf(stderr, "[metal] WARNING: Pointer %p not found in buffer hash table during argument encoding\n", ptrs[i]);
                }
            }
        }
        
        void* arg_ptr = [argBuffer contents];
        
        pthread_mutex_lock(&g_alloc_mutex);
        if (g_n_buffers >= HASH_SIZE * 3 / 4) {
            fprintf(stderr, "[metal] ERROR: Hash table full while saving argument buffer\n");
            pthread_mutex_unlock(&g_alloc_mutex);
            return NULL;
        }
        
        // 해시 테이블에 수동으로 자식 리소스 정보를 포함해서 입력
        uint32_t idx = ptr_hash(arg_ptr);
        for (uint32_t probe = 0; probe < 64; probe++) {
            uint32_t i = (idx + probe) & HASH_MASK;
            if (g_buf_hash[i].ptr == NULL) {
                g_buf_hash[i].ptr = arg_ptr;
                g_buf_hash[i].buffer = argBuffer;
                g_buf_hash[i].size = [argBuffer length];
                g_buf_hash[i].n_child_resources = n_children;
                for (int c = 0; c < n_children; c++) {
                    g_buf_hash[i].child_resources[c] = children[c];
                }
                g_n_buffers++;
                break;
            }
        }
        g_mtl4_res_dirty = 1;   // arg buffer 도 MTL4 residency 대상
        pthread_mutex_unlock(&g_alloc_mutex);

        return arg_ptr;
    }
}

// ── Metal 4 영속 객체 생성 (SOV_MTL4=1, mtl_load_library 에서 1회) ─────
// g_library 가 로드된 후 호출. 실패 시 g_mtl4_init_ok=0 유지 → classic 폴백.
static void mtl4_init_persistent(void) {
    @autoreleasepool {
        NSError* err = nil;
        g_mtl4_queue = [g_device newMTL4CommandQueue];
        if (!g_mtl4_queue) { fprintf(stderr, "[MTL4] queue FAIL\n"); return; }

        MTL4CompilerDescriptor* cd = [MTL4CompilerDescriptor new];
        g_mtl4_compiler = [g_device newCompilerWithDescriptor:cd error:&err];
        if (!g_mtl4_compiler) { fprintf(stderr, "[MTL4] compiler FAIL: %s\n", err?[[err localizedDescription] UTF8String]:"?"); return; }

        g_mtl4_alloc = [g_device newCommandAllocator];
        if (!g_mtl4_alloc) { fprintf(stderr, "[MTL4] allocator FAIL\n"); return; }

        MTL4ArgumentTableDescriptor* atd = [MTL4ArgumentTableDescriptor new];
        atd.maxBufferBindCount = 31;   // 현 커널 최대 바인딩 수
        g_mtl4_argtable = [g_device newArgumentTableWithDescriptor:atd error:&err];
        if (!g_mtl4_argtable) { fprintf(stderr, "[MTL4] argtable FAIL: %s\n", err?[[err localizedDescription] UTF8String]:"?"); return; }

        MTLResidencySetDescriptor* rsd = [MTLResidencySetDescriptor new];
        g_mtl4_residency = [g_device newResidencySetWithDescriptor:rsd error:&err];
        if (!g_mtl4_residency) { fprintf(stderr, "[MTL4] residency FAIL: %s\n", err?[[err localizedDescription] UTF8String]:"?"); return; }
        [g_mtl4_queue addResidencySet:g_mtl4_residency];

        g_mtl4_event = [g_device newSharedEvent];
        if (!g_mtl4_event) { fprintf(stderr, "[MTL4] event FAIL\n"); return; }

        // 스칼라 인자 ring — MTL4 는 setBytes 가 없어 작은 shared 버퍼에 써넣고 gpuAddress 바인딩.
        g_mtl4_param_buffer = [g_device newBufferWithLength:4 * 1024 * 1024 options:MTLResourceStorageModeShared];
        if (!g_mtl4_param_buffer) { fprintf(stderr, "[MTL4] param-ring FAIL\n"); return; }

        g_mtl4_init_ok = 1;
        g_mtl4_res_dirty = 1;
        MLOG("[MTL4] persistent objects ready (queue/compiler/allocator/argtable/residency/event)\n");
    }
}

// 모든 alloc 버퍼 + arg buffer + param ring 을 residency set 에 등록 후 resident 요청.
// dirty(신규 alloc 발생) 일 때만 재빌드. 모델 로드 완료 후 첫 forward 에서 1회 수렴.
static void mtl4_rebuild_residency(void) {
    if (!g_mtl4_init_ok || !g_mtl4_res_dirty) return;
    @autoreleasepool {
        pthread_mutex_lock(&g_alloc_mutex);
        for (int i = 0; i < HASH_SIZE; i++) {
            if (g_buf_hash[i].ptr != NULL && g_buf_hash[i].buffer != nil) {
                [g_mtl4_residency addAllocation:g_buf_hash[i].buffer];
            }
        }
        pthread_mutex_unlock(&g_alloc_mutex);
        [g_mtl4_residency addAllocation:g_mtl4_param_buffer];
        [g_mtl4_residency commit];
        [g_mtl4_residency requestResidency];
        g_mtl4_res_dirty = 0;
    }
}

int mtl_mtl4_enabled(void) { return g_mtl4_init_ok; }

void mtl_set_mtl4(int on) {
    g_mtl4_active = (on && g_mtl4_init_ok) ? 1 : 0;
}

// ── 커널 로드 ────────────────────────────────────────────

int mtl_load_library(const char* metallib_path) {
    @autoreleasepool {
        NSError* error = nil;
        NSString* path = [NSString stringWithUTF8String:metallib_path];
        NSURL* url = [NSURL fileURLWithPath:path];
        
        g_library = [g_device newLibraryWithURL:url error:&error];
        if (g_library == nil) {
            fprintf(stderr, "[metal] ERROR: Failed to load metallib: %s\n",
                    [[error localizedDescription] UTF8String]);
            return -1;
        }
        
        NSArray* names = [g_library functionNames];
        MLOG("[metal] Loaded %lu functions from %s\n",
                (unsigned long)[names count], metallib_path);
        if (mtl4_enabled_env()) mtl4_init_persistent();   // Phase 1: 영속 MTL4 객체
        return 0;
    }
}

// 메모리 blob(@embedFile)에서 라이브러리 로드. 단일 자체완결 바이너리(.metallib 파일 불필요).
int mtl_load_library_data(const void* data, unsigned long len) {
    @autoreleasepool {
        NSError* error = nil;
        // DISPATCH_DATA_DESTRUCTOR_DEFAULT = blob 을 자체 복사(임베드 정적데이터라 free 금지) → 안전.
        dispatch_data_t dd = dispatch_data_create(data, (size_t)len,
                                                  dispatch_get_global_queue(0, 0),
                                                  DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        g_library = [g_device newLibraryWithData:dd error:&error];
        // ARC(-fobjc-arc)+OS_OBJECT 라 dispatch_data 는 ARC 관리 → 명시 release 불필요.
        if (g_library == nil) {
            fprintf(stderr, "[metal] ERROR: Failed to load metallib from data: %s\n",
                    [[error localizedDescription] UTF8String]);
            return -1;
        }
        NSArray* names = [g_library functionNames];
        MLOG("[metal] Loaded %lu functions from embedded metallib (%lu bytes)\n",
                (unsigned long)[names count], len);
        if (mtl4_enabled_env()) mtl4_init_persistent();
        return 0;
    }
}

int mtl_get_function(const char* name, int* out_id) {
    @autoreleasepool {
        if (g_n_functions >= MAX_FUNCTIONS) return -1;
        
        NSString* ns_name = [NSString stringWithUTF8String:name];
        id<MTLFunction> func = [g_library newFunctionWithName:ns_name];
        if (func == nil) {
            fprintf(stderr, "[metal] ERROR: Function not found: %s\n", name);
            return -1;
        }
        
        NSError* error = nil;
        id<MTLComputePipelineState> pipeline =
            [g_device newComputePipelineStateWithFunction:func error:&error];
        if (pipeline == nil) {
            fprintf(stderr, "[metal] ERROR: Pipeline creation failed for %s: %s\n",
                    name, [[error localizedDescription] UTF8String]);
            return -1;
        }
        
        int idx = g_n_functions;
        g_functions[idx] = func;
        g_pipelines[idx] = pipeline;
        snprintf(g_func_names[idx], sizeof(g_func_names[idx]), "%s", name);

        // Phase 1: 동일 g_library 함수로 MTL4 pipeline 도 생성 (셰이더 재컴파일 0).
        // 실패 시 해당 슬롯 nil → mtl4_dispatch 에서 classic 폴백 가드.
        if (g_mtl4_init_ok) {
            NSError* e4 = nil;
            MTL4LibraryFunctionDescriptor* fd = [MTL4LibraryFunctionDescriptor new];
            fd.library = g_library; fd.name = ns_name;
            MTL4ComputePipelineDescriptor* pd = [MTL4ComputePipelineDescriptor new];
            pd.computeFunctionDescriptor = fd;
            id<MTLComputePipelineState> p4 = [g_mtl4_compiler newComputePipelineStateWithDescriptor:pd compilerTaskOptions:nil error:&e4];
            if (!p4) {
                fprintf(stderr, "[MTL4] pipeline FAIL for %s: %s\n", name, e4?[[e4 localizedDescription] UTF8String]:"?");
            }
            g_mtl4_pipelines[idx] = p4;
        }

        g_n_functions++;
        *out_id = idx;
        
        MLOG("[metal]   [%d] %s (maxThreadsPerThreadgroup=%lu)\n",
                idx, name, (unsigned long)[pipeline maxTotalThreadsPerThreadgroup]);
        return 0;
    }
}

// ── 커널 실행 ────────────────────────────────────────────

int mtl_dispatch(int func_id,
                 uint32_t grid_x, uint32_t grid_y, uint32_t grid_z,
                 uint32_t block_x, uint32_t block_y, uint32_t block_z,
                 const void** args, const size_t* arg_sizes, int n_args) {
    @autoreleasepool {
        if (func_id < 0 || func_id >= g_n_functions) return -1;
        
        MTLSize threadgroupSize  = MTLSizeMake(block_x, block_y, block_z);
        MTLSize threadgroupCount = MTLSizeMake(grid_x,  grid_y,  grid_z);

        // ── MTL4 경로 (Phase 1): argtable + stage barrier. begin 에서 enc 생성됨.
        if (g_mtl4_active && g_mtl4_init_ok) {
            id<MTLComputePipelineState> pso = g_mtl4_pipelines[func_id];
            if (pso == nil) { fprintf(stderr, "[MTL4] no pipeline func_id %d\n", func_id); return -1; }
            if (g_mtl4_enc == nil && g_mtl4_cb != nil) {   // flush 후 재진입 가드(decode 미사용)
                g_mtl4_enc = [g_mtl4_cb computeCommandEncoder];
            }
            [g_mtl4_enc setComputePipelineState:pso];
            for (int i = 0; i < n_args; i++) {
                int is_buf = 0;
                if (arg_sizes[i] == sizeof(void*)) {
                    void* ptr = *(void**)args[i];
                    BufferEntry* entry = find_entry(ptr);
                    if (entry != NULL && entry->buffer != nil) {
                        [g_mtl4_argtable setAddress:entry->buffer.gpuAddress atIndex:i];
                        is_buf = 1;
                    }
                }
                if (!is_buf) {
                    // 스칼라(또는 미등록 포인터=null 버퍼) → ring 에 복사 후 주소 바인딩 (setBytes 대체)
                    int off = g_mtl4_param_offset;
                    memcpy(((char*)[g_mtl4_param_buffer contents]) + off, args[i], arg_sizes[i]);
                    [g_mtl4_argtable setAddress:(g_mtl4_param_buffer.gpuAddress + (MTLGPUAddress)off) atIndex:i];
                    g_mtl4_param_offset = (off + (int)arg_sizes[i] + 255) & ~255;
                }
            }
            [g_mtl4_enc setArgumentTable:g_mtl4_argtable];
            [g_mtl4_enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadgroupSize];
            // 보수적 정합성 우선: 매 dispatch 뒤 device-visible barrier (classic serial-dispatch 등가).
            // Phase1 게이트(1081) 통과 후 독립 op barrier 생략으로 최적화 예정.
            [g_mtl4_enc barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:mtl4_vis()];
            return 0;
        }

        // ── PROFILE 모드: 이 dispatch 하나만 독립 cmdbuf 로 격리 측정 후 early-return.
        // 공유 encoder/cmdbuf 상태머신 안 건드림. profile OFF면 skip.
        if (profile_enabled()) {
            id<MTLCommandBuffer> pcb = [g_queue commandBuffer];
            id<MTLComputeCommandEncoder> penc = [pcb computeCommandEncoder];
            [penc setComputePipelineState:g_pipelines[func_id]];
            for (int i = 0; i < n_args; i++) {
                if (arg_sizes[i] == sizeof(void*)) {
                    void* ptr = *(void**)args[i];
                    BufferEntry* entry = find_entry(ptr);
                    if (entry != NULL && entry->buffer != nil) {
                        [penc setBuffer:entry->buffer offset:0 atIndex:i];
                        for (int r = 0; r < entry->n_child_resources; r++) {
                            if (entry->child_resources[r] != nil) {
                                [penc useResource:entry->child_resources[r] usage:MTLResourceUsageRead];
                            }
                        }
                    } else {
                        [penc setBytes:args[i] length:arg_sizes[i] atIndex:i];
                    }
                } else {
                    [penc setBytes:args[i] length:arg_sizes[i] atIndex:i];
                }
            }
            [penc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadgroupSize];
            [penc endEncoding];
            [pcb commit];
            [pcb waitUntilCompleted];
            double gpu_ms = ([pcb GPUEndTime] - [pcb GPUStartTime]) * 1000.0;
            if (gpu_ms < 0) gpu_ms = 0;
            g_prof_total_ns[func_id] += gpu_ms * 1.0e6;
            g_prof_calls[func_id]++;
            return 0;
        }

        ensure_encoder();
        
        [g_encoder setComputePipelineState:g_pipelines[func_id]];
        
        // 인자 바인딩
        for (int i = 0; i < n_args; i++) {
            if (arg_sizes[i] == sizeof(void*)) {
                // 포인터 인자 → MTLBuffer로 변환
                void* ptr = *(void**)args[i];
                BufferEntry* entry = find_entry(ptr);
                if (entry != NULL && entry->buffer != nil) {
                    [g_encoder setBuffer:entry->buffer offset:0 atIndex:i];
                    // 간접 참조 리소스들 (Argument Buffer) 드라이버 활성화
                    for (int r = 0; r < entry->n_child_resources; r++) {
                        if (entry->child_resources[r] != nil) {
                            [g_encoder useResource:entry->child_resources[r] usage:MTLResourceUsageRead];
                        }
                    }
                } else {
                    // mid-buffer (offset) pointer → bind containing buffer + offset.
                    // The Whisper port indexes into stacked buffers (e.g. QKV,
                    // KV-cache), so pointer args are frequently non-base.
                    size_t off = 0;
                    id<MTLBuffer> cbuf = resolve_buffer(ptr, &off);
                    if (cbuf != nil) {
                        [g_encoder setBuffer:cbuf offset:off atIndex:i];
                    } else {
                        // genuinely not a buffer → pass as bytes
                        [g_encoder setBytes:args[i] length:arg_sizes[i] atIndex:i];
                    }
                }
            } else {
                // 스칼라 인자 (u32, f32 등) → bytes로 전달
                [g_encoder setBytes:args[i] length:arg_sizes[i] atIndex:i];
            }
        }
        
        // CUDA 그리드/블록 → Metal threadgroups
        // CUDA: grid = (gridDimX blocks, ...), block = (blockDimX threads, ...)
        // Metal: threadgroups = gridDim, threadsPerThreadgroup = blockDim
        [g_encoder dispatchThreadgroups:threadgroupCount
                  threadsPerThreadgroup:threadgroupSize];
        
        return 0;
    }
}

void mtl_flush(void) {
    @autoreleasepool {
        if (g_mtl4_active && g_mtl4_init_ok) {
            if (g_mtl4_enc) { [g_mtl4_enc endEncoding]; g_mtl4_enc = nil; }
            return;
        }
        if (g_encoder) {
            [g_encoder endEncoding];
            g_encoder = nil;
        }
    }
}

int mtl_sync(void) {
    @autoreleasepool {
        if (g_mtl4_active && g_mtl4_init_ok) {
            if (g_mtl4_enc) { [g_mtl4_enc endEncoding]; g_mtl4_enc = nil; }
            if (g_mtl4_signal > 0) {
                BOOL ok = [g_mtl4_event waitUntilSignaledValue:g_mtl4_signal timeoutMS:10000];
                if (!ok) { fprintf(stderr, "[MTL4] sync TIMEOUT at signal %llu\n", (unsigned long long)g_mtl4_signal); return -1; }
            }
            return 0;
        }
        if (g_encoder) { [g_encoder endEncoding]; g_encoder = nil; }
        
        if (g_committed_cmdbuf != nil) {
            [g_committed_cmdbuf waitUntilCompleted];
            if ([g_committed_cmdbuf status] == MTLCommandBufferStatusError) {
                fprintf(stderr, "[metal] ERROR: Committed command buffer execution failed: %s\n",
                        [[g_committed_cmdbuf.error localizedDescription] UTF8String]);
                g_committed_cmdbuf = nil;
                return -1;
            }
            g_committed_cmdbuf = nil;
        }
        
        id<MTLCommandBuffer> active_buf = g_cmdbufs[g_active_cmdbuf_idx];
        if (active_buf != nil) {
            [active_buf commit];
            [active_buf waitUntilCompleted];
            if ([active_buf status] == MTLCommandBufferStatusError) {
                fprintf(stderr, "[metal] ERROR: Active command buffer execution failed: %s\n",
                        [[active_buf.error localizedDescription] UTF8String]);
                g_cmdbufs[g_active_cmdbuf_idx] = nil;
                return -1;
            }
            g_cmdbufs[g_active_cmdbuf_idx] = nil;
        }
        return 0;
    }
}

// ── 커맨드 버퍼 관리 ─────────────────────────────────────

int mtl_begin_command_buffer(void) {
    @autoreleasepool {
        if (g_mtl4_active && g_mtl4_init_ok) {
            if (g_mtl4_enc) { [g_mtl4_enc endEncoding]; g_mtl4_enc = nil; }
            mtl4_rebuild_residency();          // 신규 alloc 반영 (모델 로드후 1회 수렴)
            [g_mtl4_alloc reset];              // 직전 cb 는 sync 로 완료됨 → 안전
            g_mtl4_cb = [g_device newCommandBuffer];
            [g_mtl4_cb beginCommandBufferWithAllocator:g_mtl4_alloc];
            [g_mtl4_cb useResidencySet:g_mtl4_residency];
            g_mtl4_enc = [g_mtl4_cb computeCommandEncoder];
            [g_mtl4_enc setArgumentTable:g_mtl4_argtable];
            g_mtl4_param_offset = 0;
            return (g_mtl4_cb != nil) ? 0 : -1;
        }
        if (g_encoder) { [g_encoder endEncoding]; g_encoder = nil; }
        g_active_cmdbuf_idx = (g_active_cmdbuf_idx + 1) & 1;
        g_cmdbufs[g_active_cmdbuf_idx] = [g_queue commandBuffer];
        return (g_cmdbufs[g_active_cmdbuf_idx] != nil) ? 0 : -1;
    }
}

int mtl_commit_command_buffer(void) {
    @autoreleasepool {
        if (g_mtl4_active && g_mtl4_init_ok) {
            if (g_mtl4_enc) { [g_mtl4_enc endEncoding]; g_mtl4_enc = nil; }
            if (g_mtl4_cb) {
                [g_mtl4_cb endCommandBuffer];
                const id<MTL4CommandBuffer> cbs[1] = { g_mtl4_cb };
                [g_mtl4_queue commit:cbs count:1];
                g_mtl4_signal++;
                [g_mtl4_queue signalEvent:g_mtl4_event value:g_mtl4_signal];
                g_mtl4_cb = nil;
                return 0;
            }
            return -1;
        }
        if (g_encoder) { [g_encoder endEncoding]; g_encoder = nil; }
        id<MTLCommandBuffer> buf = g_cmdbufs[g_active_cmdbuf_idx];
        if (buf != nil) {
            [buf commit];
            g_committed_cmdbuf = buf;
            g_cmdbufs[g_active_cmdbuf_idx] = nil;
            return 0;
        }
        return -1;
    }
}

// ── 디버그 ───────────────────────────────────────────────

void mtl_print_device_info(void) {
    @autoreleasepool {
        if (g_device == nil) { printf("[metal] No device initialized\n"); return; }
        printf("=== Metal Device Info ===\n");
        printf("  Name:           %s\n", [[g_device name] UTF8String]);
        printf("  Unified Memory: %s\n", [g_device hasUnifiedMemory] ? "YES" : "NO");
        printf("  Max Buffer:     %lu MB\n",
               (unsigned long)([g_device maxBufferLength] / 1048576));
        printf("  Max Threads/TG: %lu\n",
               (unsigned long)[g_device maxThreadsPerThreadgroup].width);
    }
}

// ── MPS matmul (row-major F32) ──────────────────────────────────────
// C[M][N] = alpha * A[M][K] @ B[K][N] + beta * C, all row-major F32.
// Self-contained: runs on its own command buffer and blocks until done
// (matches the reference's per-GEMM cuSync). The caller must have committed
// any pending compute dispatches (e.g. via mtl_sync) before calling.
// A/B/C must be pointers returned by mtl_alloc. Returns 0 on success.
// Resolve a (possibly mid-buffer) pointer to its base MTLBuffer + byte offset.
// Linear scan over the hash — find the entry whose [base, base+size) contains p.
static id<MTLBuffer> resolve_buffer(const void* p, size_t* out_off) {
    // fast path: exact base pointer
    BufferEntry* e = find_entry(p);
    if (e != NULL && e->buffer != nil) { *out_off = 0; return e->buffer; }
    const uintptr_t up = (uintptr_t)p;
    for (uint32_t i = 0; i < HASH_SIZE; i++) {
        BufferEntry* b = &g_buf_hash[i];
        if (b->ptr == NULL || b->buffer == nil) continue;
        uintptr_t base = (uintptr_t)b->ptr;
        if (up >= base && up < base + b->size) { *out_off = (size_t)(up - base); return b->buffer; }
    }
    return nil;
}

// Shared MPS encode helper: builds the matrices + op and encodes onto `cb`.
// f16 != 0 → all matrices MPSDataTypeFloat16 (half element size); else Float32.
static int mps_encode_dt(id<MTLCommandBuffer> cb, const void* A, const void* B, void* C,
                         int M, int N, int K, float alpha, float beta, int f16) {
    size_t offA = 0, offB = 0, offC = 0;
    id<MTLBuffer> bufA = resolve_buffer(A, &offA);
    id<MTLBuffer> bufB = resolve_buffer(B, &offB);
    id<MTLBuffer> bufC = resolve_buffer(C, &offC);
    if (bufA == nil || bufB == nil || bufC == nil) {
        fprintf(stderr, "[mps] matmul: unregistered buffer (A=%p B=%p C=%p)\n", A, B, C);
        return -1;
    }
    const NSUInteger es = f16 ? 2 : 4;
    const MPSDataType dt = f16 ? MPSDataTypeFloat16 : MPSDataTypeFloat32;
    MPSMatrixDescriptor* dA = [MPSMatrixDescriptor matrixDescriptorWithRows:M columns:K rowBytes:(K * es) dataType:dt];
    MPSMatrixDescriptor* dB = [MPSMatrixDescriptor matrixDescriptorWithRows:K columns:N rowBytes:(N * es) dataType:dt];
    MPSMatrixDescriptor* dC = [MPSMatrixDescriptor matrixDescriptorWithRows:M columns:N rowBytes:(N * es) dataType:dt];
    MPSMatrix* mA = [[MPSMatrix alloc] initWithBuffer:bufA offset:offA descriptor:dA];
    MPSMatrix* mB = [[MPSMatrix alloc] initWithBuffer:bufB offset:offB descriptor:dB];
    MPSMatrix* mC = [[MPSMatrix alloc] initWithBuffer:bufC offset:offC descriptor:dC];
    MPSMatrixMultiplication* mm = [[MPSMatrixMultiplication alloc]
        initWithDevice:g_device transposeLeft:NO transposeRight:NO
        resultRows:M resultColumns:N interiorColumns:K alpha:alpha beta:beta];
    [mm encodeToCommandBuffer:cb leftMatrix:mA rightMatrix:mB resultMatrix:mC];
    return 0;
}
static int mps_encode(id<MTLCommandBuffer> cb, const void* A, const void* B, void* C,
                      int M, int N, int K, float alpha, float beta) {
    return mps_encode_dt(cb, A, B, C, M, N, K, alpha, beta, 0);
}

// Self-contained: own command buffer, blocks until done. For tests / one-offs.
int mtl_matmul_f32(const void* A, const void* B, void* C,
                   int M, int N, int K, float alpha, float beta) {
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        if (mps_encode(cb, A, B, C, M, N, K, alpha, beta) != 0) return -1;
        [cb commit];
        [cb waitUntilCompleted];
        return (cb.status == MTLCommandBufferStatusCompleted) ? 0 : -1;
    }
}

// Batched: encode onto the ACTIVE command buffer (shared with dispatches), no
// commit/wait. Ends the current compute encoder first so encoder order — and
// thus data dependencies — is preserved within the command buffer. The caller
// drives begin/commit/sync. This collapses the per-GEMM GPU round-trips.
int mtl_matmul_f32_enc(const void* A, const void* B, void* C,
                       int M, int N, int K, float alpha, float beta) {
    @autoreleasepool {
        if (g_encoder != nil) { [g_encoder endEncoding]; g_encoder = nil; }
        if (g_cmdbufs[g_active_cmdbuf_idx] == nil) {
            g_cmdbufs[g_active_cmdbuf_idx] = [g_queue commandBuffer];
        }
        return mps_encode(g_cmdbufs[g_active_cmdbuf_idx], A, B, C, M, N, K, alpha, beta);
    }
}

// Batched F16 matmul (A/B/C all half) onto the active command buffer.
int mtl_matmul_f16_enc(const void* A, const void* B, void* C,
                       int M, int N, int K, float alpha, float beta) {
    @autoreleasepool {
        if (g_encoder != nil) { [g_encoder endEncoding]; g_encoder = nil; }
        if (g_cmdbufs[g_active_cmdbuf_idx] == nil) {
            g_cmdbufs[g_active_cmdbuf_idx] = [g_queue commandBuffer];
        }
        return mps_encode_dt(g_cmdbufs[g_active_cmdbuf_idx], A, B, C, M, N, K, alpha, beta, 1);
    }
}
