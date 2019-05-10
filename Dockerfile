FROM microblinkdev/centos-gcc:8.3.0 as gcc
FROM microblinkdev/centos-ninja:1.9.0 as ninja

FROM centos:7 AS builder

ARG LLVM_VERSION=8.0.0

# setup build environment
RUN mkdir /home/build

COPY --from=gcc /usr/local /usr/local/
COPY --from=ninja /usr/local /usr/local/

# download and install CMake
RUN cd /home && \
    curl -o cmake.tar.gz -L https://github.com/Kitware/CMake/releases/download/v3.14.3/cmake-3.14.3-Linux-x86_64.tar.gz && \
    tar xf cmake.tar.gz && \
    mv cmake-3.14.3-Linux-x86_64 cmake

# install packages required for build
RUN yum -y install bzip2 zip unzip glibc-devel libedit-devel libxml2-devel ncurses-devel python-devel swig

# setup environment variables
ENV AR="/usr/local/bin/gcc-ar"                           \
    RANLIB="/usr/local/bin/gcc-ranlib"                   \
    NM="/usr/local/bin/gcc-nm"                           \
    CC="/usr/local/bin/gcc"                              \
    CXX="/usr/local/bin/g++"                             \
    LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH}" \
    PATH="/home/cmake/bin:${PATH}"

# download LLVM
RUN cd /home/build && \
    curl -o llvm.tar.xz http://releases.llvm.org/${LLVM_VERSION}/llvm-${LLVM_VERSION}.src.tar.xz && \
    tar xf llvm.tar.xz && \
    mv llvm-${LLVM_VERSION}.src llvm && \
    curl -o clang.tar.xz http://releases.llvm.org/${LLVM_VERSION}/cfe-${LLVM_VERSION}.src.tar.xz && \
    tar xf clang.tar.xz && \
    mv cfe-${LLVM_VERSION}.src clang && \
    curl -o extra.tar.xz http://releases.llvm.org/${LLVM_VERSION}/clang-tools-extra-${LLVM_VERSION}.src.tar.xz && \
    tar xf extra.tar.xz && \
    mv clang-tools-extra-${LLVM_VERSION}.src clang-tools-extra && \
    curl -o libcxx.tar.xz http://releases.llvm.org/${LLVM_VERSION}/libcxx-${LLVM_VERSION}.src.tar.xz && \
    tar xf libcxx.tar.xz && \
    mv libcxx-${LLVM_VERSION}.src libcxx && \
    curl -o libcxxabi.tar.xz http://releases.llvm.org/${LLVM_VERSION}/libcxxabi-${LLVM_VERSION}.src.tar.xz && \
    tar xf libcxxabi.tar.xz && \
    mv libcxxabi-${LLVM_VERSION}.src libcxxabi && \
    curl -o lldb.tar.xz http://releases.llvm.org/${LLVM_VERSION}/lldb-${LLVM_VERSION}.src.tar.xz && \
    tar xf lldb.tar.xz && \
    mv lldb-${LLVM_VERSION}.src lldb

# build stage 1 (bootstrap clang with gcc)
RUN cd /home/build && \
    mkdir llvm-build-stage1 && \
    cd llvm-build-stage1 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_LTO=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;libcxx;libcxxabi" \
        -DLLVM_TARGETS_TO_BUILD="X86" \
        -DCMAKE_INSTALL_PREFIX=/home/llvm-stage1 \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCMAKE_AR=${AR} \
        -DCMAKE_RANLIB=${RANLIB} \
        -DCMAKE_NM=${NM} \
        -DCMAKE_CXX_LINK_FLAGS="-Wl,-rpath,/usr/local/lib64 -L/usr/local/lib64" \
        ../llvm && \
    ninja

# build stage 2 (build entire LLVM with clang)
ENV CC="/home/build/llvm-build-stage1/bin/clang"    \
    CXX="/home/build/llvm-build-stage1/bin/clang++" \
    LD_LIBRARY_PATH="/home/build/llvm-build-stage1/lib:${LD_LIBRARY_PATH}"

RUN cd /home/build && \
    mkdir llvm-build-stage2 && \
    cd llvm-build-stage2 && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_LTO=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;libcxx;libcxxabi;lldb" \
        -DLLVM_TARGETS_TO_BUILD="X86" \
        -DCMAKE_INSTALL_PREFIX=/home/llvm \
        -DCMAKE_CXX_FLAGS="-stdlib=libc++ --gcc-toolchain=/usr/local" \
        -DCMAKE_CXX_LINK_FLAGS="--gcc-toolchain=/usr/local" \
        -DCMAKE_C_FLAGS="--gcc-toolchain=/usr/local" \
        -DCMAKE_C_LINK_FLAGS="--gcc-toolchain=/usr/local" \
        ../llvm && \
    ninja

# install everything
RUN cd /home/build/llvm-build && \
    mv lib64/* ./lib/ && \
    ninja install

# Stage 2, copy artifacts to new image and prepare environment

FROM centos:7
COPY --from=builder /home/llvm /usr/local/
COPY --from=builder /usr/local/lib64/libstdc++.so.6 /lib64/

RUN yum -y install glibc-devel

ENV CC="/usr/local/bin/clang"       \
    CXX="/usr/local/bin/clang++"
