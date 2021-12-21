FROM --platform=$BUILDPLATFORM microblinkdev/amazonlinux-ninja:1.10.2 as ninja

FROM --platform=$BUILDPLATFORM amazonlinux:2 AS builder

ARG BUILDPLATFORM
ARG LLVM_VERSION=13.0.0
ARG CMAKE_VERSION=3.22.1
# setup build environment
RUN mkdir /home/build

COPY --from=ninja /usr/local/bin/ninja /usr/local/bin/

ENV NINJA_STATUS="[%f/%t %c/sec] "

RUN echo "BUILDPLATFORM is ${BUILDPLATFORM}"

# install packages required for build
RUN yum -y install tar gzip bzip2 zip unzip libedit-devel libxml2-devel ncurses-devel python-devel swig python3 xz gcc-c++ binutils-devel

# download and install CMake
RUN cd /home && \
    if [ "$BUILDPLATFORM" == "linux/arm64" ]; then arch=aarch64; else arch=x86_64; fi && \
    curl -o cmake.tar.gz -L https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-${arch}.tar.gz && \
    tar xf cmake.tar.gz && \
    mv cmake-${CMAKE_VERSION}-linux-${arch} cmake


# setup environment variables
ENV PATH="/home/cmake/bin:${PATH}"

# download LLVM
RUN cd /home/build && \
    curl -o llvm.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/llvm-${LLVM_VERSION}.src.tar.xz && \
    tar xf llvm.tar.xz && \
    mv llvm-${LLVM_VERSION}.src llvm && \
    curl -o clang.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/clang-${LLVM_VERSION}.src.tar.xz && \
    tar xf clang.tar.xz && \
    mv clang-${LLVM_VERSION}.src clang && \
    curl -o extra.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/clang-tools-extra-${LLVM_VERSION}.src.tar.xz && \
    tar xf extra.tar.xz && \
    mv clang-tools-extra-${LLVM_VERSION}.src clang-tools-extra && \
    curl -o libcxx.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/libcxx-${LLVM_VERSION}.src.tar.xz && \
    tar xf libcxx.tar.xz && \
    mv libcxx-${LLVM_VERSION}.src libcxx && \
    curl -o libcxxabi.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/libcxxabi-${LLVM_VERSION}.src.tar.xz && \
    tar xf libcxxabi.tar.xz && \
    mv libcxxabi-${LLVM_VERSION}.src libcxxabi && \
    curl -o lldb.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/lldb-${LLVM_VERSION}.src.tar.xz && \
    tar xf lldb.tar.xz && \
    mv lldb-${LLVM_VERSION}.src lldb && \
    curl -o compiler-rt.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/compiler-rt-${LLVM_VERSION}.src.tar.xz && \
    tar xf compiler-rt.tar.xz && \
    mv compiler-rt-${LLVM_VERSION}.src compiler-rt && \
    curl -o libunwind.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/libunwind-${LLVM_VERSION}.src.tar.xz && \
    tar xf libunwind.tar.xz && \
    mv libunwind-${LLVM_VERSION}.src libunwind && \
    curl -o lld.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/lld-${LLVM_VERSION}.src.tar.xz && \
    tar xf lld.tar.xz && \
    mv lld-${LLVM_VERSION}.src lld && \
    curl -o openmp.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/openmp-${LLVM_VERSION}.src.tar.xz && \
    tar xf openmp.tar.xz && \
    mv openmp-${LLVM_VERSION}.src openmp && \
    curl -o polly.tar.xz -L https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/polly-${LLVM_VERSION}.src.tar.xz && \
    tar xf polly.tar.xz && \
    mv polly-${LLVM_VERSION}.src polly

# build LLVM in two stages
RUN cd /home/build && \
    mkdir llvm-build-stage1 && \
    cd llvm-build-stage1 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        # For some weird reason building libc++abi.so.1 with LTO enabled creates a broken binary
        -DLLVM_ENABLE_LTO=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;compiler-rt;libunwind;libcxx;libcxxabi;lld" \
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
        ../llvm && \
    ninja clang compiler-rt libunwind.so libc++.so lib/LLVMgold.so llvm-ar llvm-ranlib llvm-nm lld

# second stage - use built clang to build entire LLVM

ENV CC="/home/build/llvm-build-stage1/bin/clang"    \
    CXX="/home/build/llvm-build-stage1/bin/clang++" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/home/build/llvm-build-stage1/lib"

# add additional packages needed to build second stage
RUN yum -y install python3-devel

RUN cd /home/build && \
    mkdir llvm-build-stage2 && \
    cd llvm-build-stage2 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang;libcxx;libcxxabi;lld;lldb;compiler-rt;libunwind;clang-tools-extra;polly" \
        -DLLVM_TARGETS_TO_BUILD="Native" \
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
        ../llvm && \
    ninja

# install everything
RUN cd /home/build/llvm-build-stage2 && \
    ninja install

# Stage 2, copy artifacts to new image and prepare environment

FROM --platform=$BUILDPLATFORM amazonlinux:2
COPY --from=builder /home/llvm /usr/local/

# GCC is needed for providing crtbegin.o, crtend.o and friends, that are also used by clang
# Note: G++ is not needed
RUN yum -y install glibc-devel glibc-static gcc libedit python3

ENV CC="/usr/local/bin/clang"           \
    CXX="/usr/local/bin/clang++"        \
    AR="/usr/local/bin/llvm-ar"         \
    NM="/usr/local/bin/llvm-nm"         \
    RANLIB="/usr/local/bin/llvm-ranlib"
