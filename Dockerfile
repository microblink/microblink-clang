FROM microblinkdev/amazonlinux-ninja:1.11.0 as ninja
FROM microblinkdev/amazonlinux-python:3.10.4 as python

FROM amazonlinux:2 AS builder

ARG BUILDPLATFORM
ARG LLVM_VERSION=14.0.4
ARG CMAKE_VERSION=3.23.2
# setup build environment
RUN mkdir /home/build

COPY --from=python /usr/local /usr/local
COPY --from=ninja /usr/local/bin/ninja /usr/local/bin/

ENV NINJA_STATUS="[%f/%t %c/sec] "

RUN echo "BUILDPLATFORM is ${BUILDPLATFORM}"

# install packages required for build
RUN yum -y install tar gzip bzip3 zip unzip libedit-devel libxml2-devel ncurses-devel python-devel swig xz gcc10-c++ binutils-devel git openssl11

# for building the ARM64 image, we need newer kernel headers that provide user_sve_header and sve_vl_valid
# see: https://github.com/llvm/llvm-project/issues/52823
# and: https://github.com/spack/spack/issues/27992

RUN amazon-linux-extras install -y kernel-ng && yum -y update

# download and install CMake
RUN cd /home && \
    if [ "$BUILDPLATFORM" == "linux/arm64" ]; then arch=aarch64; else arch=x86_64; fi && \
    curl -o cmake.tar.gz -L https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-${arch}.tar.gz && \
    tar xf cmake.tar.gz && \
    mv cmake-${CMAKE_VERSION}-linux-${arch} cmake


# setup environment variables - use gcc 10 instead of the default gcc 7 which crashes when building LLVM 13.0.1 on Aarch64
ENV PATH="/home/cmake/bin:${PATH}"  \
    CC="/usr/bin/gcc10-gcc"         \
    CXX="/usr/bin/gcc10-g++"

# clone LLVM
RUN cd /home/build && \
    git clone --depth 1 --branch llvmorg-${LLVM_VERSION} https://github.com/llvm/llvm-project

# build LLVM in two stages
RUN cd /home/build && \
    mkdir llvm-build-stage1 && \
    cd llvm-build-stage1 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        # For some weird reason building libc++abi.so.1 with LTO enabled creates a broken binary
        -DLLVM_ENABLE_LTO=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;compiler-rt;lld" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
        -DLLVM_TARGETS_TO_BUILD="Native" \
        -DLLVM_BINUTILS_INCDIR="/usr/include" \
        -DLLVM_ENABLE_EH=ON \
        -DLLVM_ENABLE_RTTI=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_UNWINDLIB=libgcc \
        -DCLANG_DEFAULT_LINKER=lld \
        -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=YES \
        -DLIBCXX_ABI_VERSION=2 \
        -DLIBCXX_ABI_UNSTABLE=ON \
        -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
        -DLIBCXX_ENABLE_RTTI=OFF \
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_INCLUDE_TESTS=OFF \
        -DLIBCXX_INCLUDE_DOCS=OFF \
        /home/build/llvm-project/llvm && \
    ninja clang compiler-rt unwind cxx lib/LLVMgold.so llvm-ar llvm-ranlib llvm-nm lld

# second stage - use built clang to build entire LLVM

ENV CC="/home/build/llvm-build-stage1/bin/clang"    \
    CXX="/home/build/llvm-build-stage1/bin/clang++" \
    LD_LIBRARY_PATH="/home/build/llvm-build-stage1/lib/x86_64-unknown-linux-gnu:/home/build/llvm-build-stage1/lib/aarch64-unknown-linux-gnu"

# clang-tools-extra will be build only for Intel image. It's slow to build and not needed on aarch64 as currently no developer machines run on this platform and we still
# don't have ARM-based high-end server so we build the image on M1 macOS VM.

RUN cd /home/build && \
    mkdir llvm-build-stage2 && \
    cd llvm-build-stage2 && \
    if [ "$BUILDPLATFORM" != "linux/arm64" ]; then additional_projects=";clang-tools-extra"; fi && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang;lld;lldb;compiler-rt;libcxx;libcxxabi;libunwind;polly${additional_projects}" \
        # -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
        -DLLVM_ENABLE_LTO=Thin \
        # LTO link jobs use lots of RAM which can kill the build server - use 20 jobs (average 6.4 GB per job - some jobs use over 12 GB, but most of them less than 6 GB)
        # with ThinLTO all CPUs are used for LTO, so don't overcommit the CPU with too many parallel LTO jobs
        # there is one monolithic LTO job, so 3 effectively means 2
        -DLLVM_PARALLEL_LINK_JOBS=3 \
        -DLLVM_BINUTILS_INCDIR="/usr/include" \
        -DLLVM_USE_LINKER="lld" \
        -DCMAKE_C_FLAGS="-B/usr/local -fsplit-lto-unit" \
        -DCMAKE_CXX_FLAGS="-B/usr/local -fsplit-lto-unit" \
        -DCMAKE_AR="/home/build/llvm-build-stage1/bin/llvm-ar" \
        -DCMAKE_RANLIB="/home/build/llvm-build-stage1/bin/llvm-ranlib" \
        -DCMAKE_NM="/home/build/llvm-build-stage1/bin/llvm-nm" \
        -DLLVM_ENABLE_EH=OFF \
        -DLLVM_ENABLE_RTTI=OFF \
        -DLLVM_BUILD_LLVM_DYLIB=ON \
        -DCMAKE_INSTALL_PREFIX=/home/llvm \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
        -DCLANG_DEFAULT_UNWINDLIB=libunwind \
        -DLIBCXX_USE_COMPILER_RT=YES \
        -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=YES \
        -DLIBCXXABI_USE_COMPILER_RT=YES \
        -DLIBCXX_ABI_VERSION=2 \
        -DLIBCXX_ABI_UNSTABLE=ON \
        -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
        -DLIBCXX_ENABLE_RTTI=ON \
        -DLLDB_ENABLE_PYTHON=ON \
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
        -DLIBCXX_INCLUDE_TESTS=OFF \
        -DLIBCXX_INCLUDE_DOCS=OFF \
        /home/build/llvm-project/llvm && \
    ninja

# install everything
RUN cd /home/build/llvm-build-stage2 && \
    ninja install

# Stage 2, copy artifacts to new image and prepare environment

FROM amazonlinux:2
COPY --from=python /usr/local /usr/local
COPY --from=builder /home/llvm /usr/local/

# GCC is needed for providing crtbegin.o, crtend.o and friends, that are also used by clang
# Note: G++ is not needed
# ncurses-devel is needed when developing LLVM-based tools
# openssl11 is dependency of python3, which is a dependency of LLDB
RUN yum -y install glibc-devel glibc-static gcc libedit openssl11 ncurses-devel

ENV CC="/usr/local/bin/clang"           \
    CXX="/usr/local/bin/clang++"        \
    AR="/usr/local/bin/llvm-ar"         \
    NM="/usr/local/bin/llvm-nm"         \
    RANLIB="/usr/local/bin/llvm-ranlib"
