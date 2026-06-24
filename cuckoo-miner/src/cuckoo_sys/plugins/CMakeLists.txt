cmake_minimum_required(VERSION 3.2)
project (CuckooMinerPlugins)

set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/plugins)
set (CMAKE_CXX_FLAGS "--std=c++11")

set (OPT "-O3")
set (DOPT "-DPREFETCH")

set (FLAGS "-Wno-format -Wno-deprecated-declarations -D_POSIX_C_SOURCE=200112L ${OPT} ${DOPT} -I. ${CPPFLAGS} -pthread")

# ---- arch detection: Apple Silicon / arm64 vs x86_64 ------------------------
# Added to support a CPU lean Cuckatoo32 plugin on macOS M-series (arm64).
# The upstream flags below are x86-only: -march=native/-m64 and the per-target
# -mno-avx2 / -mavx2 are rejected by clang on arm64. We swap them for the arm64
# equivalents and (further down) skip the x86-SIMD targets on Apple Silicon.
if (CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
	set (MINER_ARM64 TRUE)
	set (ARCH_FLAGS "-mcpu=native")   # arm64: no -march=native / -m64
	set (NOAVX2 "")                   # x86-only flag -> empty on arm64
	# Upstream siphashxN.h only ships x86 SIMD siphash (SSE2/AVX2). macos-arm64/
	# apply-arm64-patches.sh injects a NEON 2-way/4-way siphash (uint64x2_t) that
	# mirrors the SSE2 path bit-for-bit, so arm64 can use NSIPHASH=4 (~2-4x over
	# the old scalar NSIPHASH=1 fallback). NEON is mandatory on ARMv8, so it is
	# always present on Apple Silicon. That same script also guards out the
	# unconditional <immintrin.h> include for arm64. Both run from the build/
	# benchmark scripts. (To force the old scalar path, set LEAN_NSIPHASH=1.)
	set (LEAN_NSIPHASH 4)
	message (STATUS "CuckooMinerPlugins: building for Apple Silicon / arm64 (lean CPU targets only, NEON 4-way siphash)")
else()
	set (MINER_ARM64 FALSE)
	set (ARCH_FLAGS "-march=native -m64")
	set (NOAVX2 "-mno-avx2")
	set (LEAN_NSIPHASH 4)             # x86-64 always has SSE2 -> 4-way siphash
endif()

set (GPP_FLAGS "${ARCH_FLAGS} ${FLAGS}")
set (CFLAGS "-Wno-format -fomit-frame-pointer ${OPT}")
if (MINER_ARM64)
	set (GCC_FLAGS "-std=gnu11 ${CFLAGS}")
else()
	set (GCC_FLAGS "-m64 -std=gnu11 ${CFLAGS}")
endif()

set (CUDA_HOST_COMPILER_OVERRIDE $ENV{CUDA_HOST_COMPILER})
set (SKIP_CUCKATOO_GPU $ENV{SKIP_CUCKATOO_GPU})
set (SKIP_CUCKAROO_GPU $ENV{SKIP_CUCKAROO_GPU})
set (SKIP_CUCKAROOD_GPU $ENV{SKIP_CUCKAROOD_GPU})
set (SKIP_CUCKAROOM_CPU "1")
set (SKIP_CUCKAROOM_GPU $ENV{SKIP_CUCKAROOM_GPU})
set (SKIP_CUCKAROOZ_CPU "1")
set (SKIP_CUCKAROOZ_GPU $ENV{SKIP_CUCKAROOZ_GPU})

#blake2b prerequisite
set (BLAKE_2B "cuckoo/src/crypto/blake2b-ref.c")

#common to all plugins
set (PLUGIN_BUILD_FLAGS "-DC_CALL_CONVENTION=1 -DSQUASH_OUTPUT=1")

#build CPU target
function (build_cpu_target sources target props)
	add_library(${target} SHARED ${sources})
	set_target_properties(${target} PROPERTIES COMPILE_FLAGS "${GPP_FLAGS} ${props} ${PLUGIN_BUILD_FLAGS}" PREFIX "" SUFFIX ".cuckooplugin")
endfunction()

function (build_cuda_target sources target props)
	if (BUILD_CUDA_PLUGINS)
		include("cmake/find_cuda.cmake")
		if (CUDA_FOUND)
			set (CUDA_PROPAGATE_HOST_FLAGS ON)
			cuda_add_library (${target} SHARED ${sources} OPTIONS "${props} ${PLUGIN_BUILD_FLAGS}")
			set_target_properties(${target} PROPERTIES PREFIX "" SUFFIX ".cuckooplugin")
		endif (CUDA_FOUND)
	endif (BUILD_CUDA_PLUGINS)
endfunction()

##################################################################################
### CUCKATOO (Asic Tuned) ########################################################
##################################################################################

### AT LEAN CPU TARGETS  #########################################

set (AT_LEAN_CPU_SRC
			cuckoo/src/cuckatoo/cuckatoo.h
			cuckoo/src/cuckatoo/bitmap.hpp
			cuckoo/src/cuckatoo/graph.hpp
			cuckoo/src/cuckatoo/compress.hpp
			cuckoo/src/threads/barrier.hpp
			cuckoo/src/crypto/siphash.hpp
			cuckoo/src/cuckatoo/lean.hpp
			cuckoo/src/cuckatoo/lean.cpp
			${BLAKE_2B})

build_cpu_target("${AT_LEAN_CPU_SRC}" cuckatoo_lean_cpu_compat_19 "${NOAVX2} -DNSIPHASH=${LEAN_NSIPHASH} -DATOMIC -DEDGEBITS=19")
build_cpu_target("${AT_LEAN_CPU_SRC}" cuckatoo_lean_cpu_compat_31 "${NOAVX2} -DNSIPHASH=${LEAN_NSIPHASH} -DATOMIC -DEDGEBITS=31")
# --- C32 lean CPU plugin (ADDED) --------------------------------------------
# Cuckatoo32 is the network's only live PoW. The lean solver needs ~1 GB RAM
# (vs ~90 GB for a mean solver) so it is the one CPU path that fits a 36 GB box.
# Slow, but correct: the cuckoo source supports EDGEBITS=32 (NEDGES is 64-bit;
# graph.hpp carries an explicit "matches last edge when EDGEBITS==32" note, and
# lean.hpp has a NONPART_BITS==32 guard). NSIPHASH here is ${LEAN_NSIPHASH}: 1 on
# arm64 (scalar siphash, no intrinsics) and 4 on x86 (SSE2, always present), so
# this one target line builds correctly on both.
build_cpu_target("${AT_LEAN_CPU_SRC}" cuckatoo_lean_cpu_compat_32 "${NOAVX2} -DNSIPHASH=${LEAN_NSIPHASH} -DATOMIC -DEDGEBITS=32")
# avx2 variant is x86-only (NSIPHASH=8 uses SSE/AVX); skip on Apple Silicon.
if (NOT MINER_ARM64)
	build_cpu_target("${AT_LEAN_CPU_SRC}" cuckatoo_lean_cpu_avx2_31 "-mavx2 -DNSIPHASH=8 -DATOMIC -DEDGEBITS=31")
endif()

### AT MEAN CPU TARGETS  #########################################

set (AT_MEAN_CPU_SRC
			cuckoo/src/cuckatoo/cuckatoo.h
			cuckoo/src/cuckatoo/bitmap.hpp
			cuckoo/src/cuckatoo/graph.hpp
			cuckoo/src/cuckatoo/compress.hpp
			cuckoo/src/threads/barrier.hpp
			cuckoo/src/crypto/siphash.hpp
			cuckoo/src/cuckatoo/mean.hpp
			cuckoo/src/cuckatoo/mean.cpp
			${BLAKE_2B})

# Mean CPU solvers are x86-SIMD (XBITS bucketing + AVX siphash) and memory-heavy;
# not built on Apple Silicon (use the lean CPU plugin there instead).
if (NOT MINER_ARM64)
	build_cpu_target("${AT_MEAN_CPU_SRC}" cuckatoo_mean_cpu_compat_19 "-mno-avx2 -DXBITS=2 -DNSIPHASH=4 -DSAVEEDGES -DEDGEBITS=19")
	build_cpu_target("${AT_MEAN_CPU_SRC}" cuckatoo_mean_cpu_avx2_19 "-mavx2 -DXBITS=2 -DNSIPHASH=8 -DSAVEEDGES -DEDGEBITS=19")
	build_cpu_target("${AT_MEAN_CPU_SRC}" cuckatoo_mean_cpu_compat_31 "-mno-avx2 -DXBITS=8 -DNSIPHASH=4 -DEXPANDROUND=8 -DCOMPRESSROUND=22 -DSAVEEDGES -DEDGEBITS=31")
	build_cpu_target("${AT_MEAN_CPU_SRC}" cuckatoo_mean_cpu_avx2_31 "-mavx2 -DXBITS=8 -DNSIPHASH=8 -DEXPANDROUND=8 -DCOMPRESSROUND=22 -DSAVEEDGES -DEDGEBITS=31")
endif()

### AT LEAN CUDA TARGETS  #########################################

set (AT_LEAN_CUDA_SRC
			cuckoo/src/crypto/siphash.cuh
			cuckoo/src/cuckatoo/lean.cu
			${BLAKE_2B} )

if (NOT SKIP_CUCKATOO_GPU)
  build_cuda_target("${AT_LEAN_CUDA_SRC}" cuckatoo_lean_cuda_19 "-DEDGEBITS=19")
  build_cuda_target("${AT_LEAN_CUDA_SRC}" cuckatoo_lean_cuda_31 "-DEDGEBITS=31")
endif()

### AT MEAN CUDA TARGETS  #########################################

set (AT_MEAN_CUDA_SRC
			cuckoo/src/crypto/siphash.cuh
			cuckoo/src/cuckatoo/mean.cu
			${BLAKE_2B} )

if (NOT SKIP_CUCKATOO_GPU)
  build_cuda_target("${AT_MEAN_CUDA_SRC}" cuckatoo_mean_cuda_gtx_31 "-DNEPS_A=135 -DNEPS_B=88 -DPART_BITS=1 -DFLUSHA=2 -DEDGEBITS=31")
  build_cuda_target("${AT_MEAN_CUDA_SRC}" cuckatoo_mean_cuda_rtx_31 "-DNEPS_A=135 -DNEPS_B=88 -DPART_BITS=0 -DEDGEBITS=31")
  build_cuda_target("${AT_MEAN_CUDA_SRC}" cuckatoo_mean_cuda_rtx_32 "-DNEPS_A=135 -DNEPS_B=88 -DPART_BITS=1 -DEDGEBITS=32")
endif()

##################################################################################
### CUCKAROO (Asic Resistant)  ###################################################
##################################################################################

### AR CPU BUILDING  #########################################

set (AR_CPU_SRC
			cuckoo/src/cuckaroo/cuckaroo.hpp
			cuckoo/src/cuckaroo/bitmap.hpp
			cuckoo/src/cuckaroo/graph.hpp
			cuckoo/src/threads/barrier.hpp
			cuckoo/src/crypto/siphash.hpp
			cuckoo/src/cuckaroo/mean.hpp
			cuckoo/src/cuckaroo/mean.cpp
			${BLAKE_2B})

### AR CPU TARGETS #########################################

# Cuckaroo* (ASIC-resistant) PoWs were removed from Grin at HF4 (Jan 2021) and
# are x86-SIMD anyway; not built on Apple Silicon.
if (NOT MINER_ARM64)
	build_cpu_target("${AR_CPU_SRC}" cuckaroo_cpu_compat_19 "-mno-avx2 -DXBITS=2 -DNSIPHASH=4 -DEDGEBITS=19 -DSAVEEDGES")
	build_cpu_target("${AR_CPU_SRC}" cuckaroo_cpu_avx2_19 "-mavx2 -DXBITS=2 -DNSIPHASH=8 -DEDGEBITS=19 -DSAVEEDGES")
	build_cpu_target("${AR_CPU_SRC}" cuckaroo_cpu_compat_29 "-mno-avx2 -DNSIPHASH=4 -DEDGEBITS=29 -DSAVEEDGES")
	build_cpu_target("${AR_CPU_SRC}" cuckaroo_cpu_avx2_29 "-mavx2 -DNSIPHASH=8 -DEDGEBITS=29 -DSAVEEDGES")
endif()

### AR CUDA TARGETS #########################################

set (AR_CUDA_SRC cuckoo/src/cuckaroo/mean.cu ${BLAKE_2B} )

if (NOT SKIP_CUCKAROO_GPU)
  build_cuda_target("${AR_CUDA_SRC}" cuckaroo_cuda_19 "-DEPS_A=4 -DEPS_B=3 -DIDXSHIFT=2 -DEDGEBITS=19")
  build_cuda_target("${AR_CUDA_SRC}" cuckaroo_cuda_29 "-DEDGEBITS=29")
endif()

##################################################################################
### CUCKAROOD (Asic Resistant)  ##################################################
##################################################################################

### AR CPU BUILDING  #########################################

set (AR2_CPU_SRC
			cuckoo/src/cuckarood/cuckarood.hpp
			cuckoo/src/cuckarood/bitmap.hpp
			cuckoo/src/cuckarood/graph.hpp
			cuckoo/src/threads/barrier.hpp
			cuckoo/src/crypto/siphash.hpp
			cuckoo/src/crypto/siphashxN.h
			cuckoo/src/cuckarood/mean.hpp
			cuckoo/src/cuckarood/mean.cpp
			${BLAKE_2B})

### AR CPU TARGETS #########################################

# Cuckarood (ASIC-resistant) — removed from Grin at HF4; x86-SIMD; skip on arm64.
if (NOT MINER_ARM64)
	build_cpu_target("${AR2_CPU_SRC}" cuckarood_cpu_compat_19 "-mno-avx2 -DXBITS=2 -DNSIPHASH=4 -DEDGEBITS=19 -DSAVEEDGES")
	build_cpu_target("${AR2_CPU_SRC}" cuckarood_cpu_avx2_19 "-mavx2 -DXBITS=2 -DNSIPHASH=8 -DEDGEBITS=19 -DSAVEEDGES")
	build_cpu_target("${AR2_CPU_SRC}" cuckarood_cpu_compat_29 "-mno-avx2 -DNSIPHASH=4 -DEDGEBITS=29 -DSAVEEDGES")
	build_cpu_target("${AR2_CPU_SRC}" cuckarood_cpu_avx2_29 "-mavx2 -DNSIPHASH=8 -DEDGEBITS=29 -DSAVEEDGES")
endif()

### AR CUDA TARGETS #########################################

set (AR2_CUDA_SRC cuckoo/src/cuckarood/kernel.cuh cuckoo/src/cuckarood/photon.cu ${BLAKE_2B} )

if (NOT SKIP_CUCKAROOD_GPU)
  build_cuda_target("${AR2_CUDA_SRC}" cuckarood_cuda_19 "-DXBITS=1 -DEPS_A=4 -DEPS_B=3 -DIDXSHIFT=8 -DEDGEBITS=19")
  build_cuda_target("${AR2_CUDA_SRC}" cuckarood_cuda_29 "-DEDGEBITS=29")
endif()

##################################################################################
### CUCKAROOM (Asic Resistant)  ##################################################
##################################################################################

### AR CPU BUILDING  #########################################

set (AR2_CPU_SRC
			cuckoo/src/cuckaroom/cuckaroom.hpp
			cuckoo/src/cuckaroom/bitmap.hpp
			cuckoo/src/cuckaroom/graph.hpp
			cuckoo/src/threads/barrier.hpp
			cuckoo/src/crypto/siphash.hpp
			cuckoo/src/crypto/siphashxN.h
			cuckoo/src/cuckaroom/mean.hpp
			cuckoo/src/cuckaroom/mean.cpp
			${BLAKE_2B})

### AR CPU TARGETS #########################################

if (NOT SKIP_CUCKAROOM_CPU)
  build_cpu_target("${AR2_CPU_SRC}" cuckaroom_cpu_compat_19 "-mno-avx2 -DXBITS=2 -DNSIPHASH=4 -DEDGEBITS=19 -DSAVEEDGES")
  build_cpu_target("${AR2_CPU_SRC}" cuckaroom_cpu_avx2_19 "-mavx2 -DXBITS=2 -DNSIPHASH=8 -DEDGEBITS=19 -DSAVEEDGES")
  build_cpu_target("${AR2_CPU_SRC}" cuckaroom_cpu_compat_29 "-mno-avx2 -DNSIPHASH=4 -DEDGEBITS=29 -DSAVEEDGES")
  build_cpu_target("${AR2_CPU_SRC}" cuckaroom_cpu_avx2_29 "-mavx2 -DNSIPHASH=8 -DEDGEBITS=29 -DSAVEEDGES")
endif()

### AR CUDA TARGETS #########################################

set (AR2_CUDA_SRC cuckoo/src/cuckaroom/meaner.cu ${BLAKE_2B} )
set (AR2_CUDA_SRC2 cuckoo/src/cuckaroom/kernel.cuh cuckoo/src/cuckaroom/mean.cu ${BLAKE_2B} )

if (NOT SKIP_CUCKAROOM_GPU)
  build_cuda_target("${AR2_CUDA_SRC}" cuckaroom_cuda_29 "-DEDGEBITS=29")
  build_cuda_target("${AR2_CUDA_SRC2}" cuckaroom_old_cuda_29 "-DEDGEBITS=29")
  build_cuda_target("${AR2_CUDA_SRC2}" cuckaroom_cuda_19 "-DXBITS=1 -DEPS_A=4 -DEPS_B=3 -DIDXSHIFT=8 -DEDGEBITS=19")
endif()

##################################################################################
### CUCKAROOZ (Asic Resistant)  ##################################################
##################################################################################

### AR CPU BUILDING  #########################################

set (AR2_CPU_SRC
			cuckoo/src/cuckarooz/cuckarooz.hpp
			cuckoo/src/cuckarooz/bitmap.hpp
			cuckoo/src/cuckarooz/graph.hpp
			cuckoo/src/threads/barrier.hpp
			cuckoo/src/crypto/siphash.hpp
			cuckoo/src/crypto/siphashxN.h
			cuckoo/src/cuckarooz/mean.hpp
			cuckoo/src/cuckarooz/mean.cpp
			${BLAKE_2B})

### AR CPU TARGETS #########################################

if (NOT SKIP_CUCKAROOZ_CPU)
  build_cpu_target("${AR2_CPU_SRC}" cuckarooz_cpu_compat_19 "-mno-avx2 -DXBITS=2 -DNSIPHASH=4 -DEDGEBITS=19 -DSAVEEDGES")
  build_cpu_target("${AR2_CPU_SRC}" cuckarooz_cpu_avx2_19 "-mavx2 -DXBITS=2 -DNSIPHASH=8 -DEDGEBITS=19 -DSAVEEDGES")
  build_cpu_target("${AR2_CPU_SRC}" cuckarooz_cpu_compat_29 "-mno-avx2 -DNSIPHASH=4 -DEDGEBITS=29 -DSAVEEDGES")
  build_cpu_target("${AR2_CPU_SRC}" cuckarooz_cpu_avx2_29 "-mavx2 -DNSIPHASH=8 -DEDGEBITS=29 -DSAVEEDGES")
endif()

### AR CUDA TARGETS #########################################

set (AR2_CUDA_SRC cuckoo/src/cuckarooz/mean.cu ${BLAKE_2B} )

if (NOT SKIP_CUCKAROOZ_GPU)
  build_cuda_target("${AR2_CUDA_SRC}" cuckarooz_cuda_29 "-DEDGEBITS=29")
endif()
