FROM microblinkdev/amazonlinux-ninja:1.11.1-al2022 as ninja
FROM microblinkdev/amazonlinux-python:3.11.3 as python

FROM amazonlinux:2022 AS builder

ARG BUILDPLATFORM
ARG LLVM_VERSION=16.0.4
ARG CMAKE_VERSION=3.26.3
# setup build environment
RUN mkdir /home/build

COPY --from=python /usr/local /usr/local
COPY --from=ninja /usr/local/bin/ninja /usr/local/bin/

ENV NINJA_STATUS="[%f/%t %c/sec] "

RUN echo "BUILDPLATFORM is ${BUILDPLATFORM}"

# install packages required for build
RUN yum -y update
RUN yum -y install tar gzip bzip2 zip unzip libedit-devel libxml2-devel ncurses-devel python-devel swig xz gcc-c++ binutils-devel git openssl glibc-langpack-en

# download and install CMake
RUN cd /home && \
    if [ "$BUILDPLATFORM" == "linux/arm64" ]; then arch=aarch64; else arch=x86_64; fi && \
    curl -o cmake.tar.gz -L https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-${arch}.tar.gz && \
    tar xf cmake.tar.gz && \
    mv cmake-${CMAKE_VERSION}-linux-${arch} cmake


# setup environment variables - use gcc 10 instead of the default gcc 7 which crashes when building LLVM 13.0.1 on Aarch64
ENV PATH="/home/cmake/bin:${PATH}"

# clone LLVM
RUN cd /home/build && \
    git clone --depth 1 --branch microblink-llvmorg-${LLVM_VERSION} https://github.com/microblink/llvm-project

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
    LD_LIBRARY_PATH="/home/build/llvm-build-stage1/lib/x86_64-unknown-linux-gnu:/home/build/llvm-build-stage1/lib/aarch64-unknown-linux-gnu" \
    LIBRARY_PATH="/usr/lib/gcc/aarch64-amazon-linux/11:/usr/lib/gcc/x86_64-amazon-linux/11"

RUN cd /home/build && \
    if [ "$BUILDPLATFORM" == "linux/arm64" ]; then additional_flags="-Ofast"; else additional_flags="-Ofast -mavx"; fi && \
    mkdir llvm-build-stage2 && \
    cd llvm-build-stage2 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang;lld;lldb;compiler-rt;polly;clang-tools-extra" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
        -DLLVM_TARGETS_TO_BUILD="AArch64;ARM;WebAssembly;X86" \
        -DLLVM_ENABLE_LTO=Thin \
        -DLLVM_PARALLEL_LINK_JOBS=3 \
        -DLLVM_BINUTILS_INCDIR="/usr/include" \
        -DLLVM_USE_LINKER="lld" \
        -DCMAKE_C_FLAGS="-B/usr/local -fsplit-lto-unit $additional_flags" \
        -DCMAKE_CXX_FLAGS="-B/usr/local -fsplit-lto-unit $additional_flags" \
        -DCMAKE_AR="/home/build/llvm-build-stage1/bin/llvm-ar" \
        -DCMAKE_RANLIB="/home/build/llvm-build-stage1/bin/llvm-ranlib" \
        -DCMAKE_NM="/home/build/llvm-build-stage1/bin/llvm-nm" \
        -DLLVM_ENABLE_EH=OFF \
        -DLLVM_ENABLE_RTTI=OFF \
        -DLLVM_BUILD_LLVM_DYLIB=ON \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON \
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
        -DLIBUNWIND_ENABLE_ASSERTIONS=OFF \
        /home/build/llvm-project/llvm && \
    ninja

# install everything
RUN cd /home/build/llvm-build-stage2 && \
    ninja install

# Stage 2, copy artifacts to new image and prepare environment

FROM amazonlinux:2022
COPY --from=python /usr/local /usr/local
COPY --from=builder /home/llvm /usr/local/

# GCC is needed for providing crtbegin.o, crtend.o and friends, that are also used by clang
# Note: G++ is not needed
# ncurses-devel is needed when developing LLVM-based tools
# openssl11 is dependency of python3, which is a dependency of LLDB
RUN yum -y install glibc-devel glibc-static gcc libedit openssl ncurses-devel glibc-langpack-en

ENV CC="/usr/local/bin/clang"           \
    CXX="/usr/local/bin/clang++"        \
    AR="/usr/local/bin/llvm-ar"         \
    NM="/usr/local/bin/llvm-nm"         \
    RANLIB="/usr/local/bin/llvm-ranlib" \
    LIBRARY_PATH="/usr/lib/gcc/aarch64-amazon-linux/11:/usr/lib/gcc/x86_64-amazon-linux/11"
