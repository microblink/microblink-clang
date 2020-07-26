FROM microblinkdev/centos-ninja:1.10.1 as ninja

FROM microblinkdev/centos-gcc:9.2.0 AS builder

ARG LLVM_VERSION=10.0.1

# setup build environment
RUN mkdir /home/build

COPY --from=ninja /usr/local/bin/ninja /usr/local/bin/

# download and install CMake
RUN cd /home && \
    curl -o cmake.tar.gz -L https://github.com/Kitware/CMake/releases/download/v3.16.3/cmake-3.16.3-Linux-x86_64.tar.gz && \
    tar xf cmake.tar.gz && \
    mv cmake-3.16.3-Linux-x86_64 cmake

# install packages required for build
RUN yum -y install bzip2 zip unzip libedit-devel libxml2-devel ncurses-devel python-devel swig

# setup environment variables
ENV PATH="/home/cmake/bin:${PATH}"

# download LLVM
#https://github.com/llvm/llvm-project/releases/download/llvmorg-8.0.1/llvm-8.0.1.src.tar.xz
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
    mv lld-${LLVM_VERSION}.src lld


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
        ../llvm && \
    ninja clang compiler-rt libunwind.so libc++.so lib/LLVMgold.so llvm-ar llvm-ranlib llvm-nm lld

# second stage - use built clang to build entire LLVM

ENV CC="/home/build/llvm-build-stage1/bin/clang"    \
    CXX="/home/build/llvm-build-stage1/bin/clang++" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/home/build/llvm-build-stage1/lib"

RUN cd /home/build && \
    mkdir llvm-build-stage2 && \
    cd llvm-build-stage2 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;libcxx;libcxxabi;lld;lldb;compiler-rt;libunwind" \
        -DLLVM_TARGETS_TO_BUILD="Native" \
        -DLLVM_BINUTILS_INCDIR="/usr/include" \
        -DLLVM_USE_LINKER="lld" \
        -DCMAKE_C_FLAGS="-B/usr/local" \
        -DCMAKE_CXX_FLAGS="-B/usr/local" \
        -DCMAKE_AR="/home/build/llvm-build-stage1/bin/llvm-ar" \
        -DCMAKE_RANLIB="/home/build/llvm-build-stage1/bin/llvm-ranlib" \
        -DCMAKE_NM="/home/build/llvm-build-stage1/bin/llvm-nm" \
        -DLLVM_ENABLE_EH=ON \
        -DLLVM_ENABLE_RTTI=ON \
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
        ../llvm && \
    ninja

# install everything
RUN cd /home/build/llvm-build-stage2 && \
    mv lib64/* ./lib/ && \
    ninja install

# Stage 2, copy artifacts to new image and prepare environment

FROM centos:7
COPY --from=builder /home/llvm /usr/local/

# GCC is needed for providing crtbegin.o, crtend.o and friends, that are also used by clang
# Note: G++ is not needed
RUN yum -y install glibc-devel glibc-static gcc libedit

ENV CC="/usr/local/bin/clang"           \
    CXX="/usr/local/bin/clang++"        \
    AR="/usr/local/bin/llvm-ar"         \
    NM="/usr/local/bin/llvm-nm"         \
    RANLIB="/usr/local/bin/llvm-ranlib" \
    LD_LIBRARY_PATH="/usr/local/lib"
