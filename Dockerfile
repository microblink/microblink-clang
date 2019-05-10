FROM microblinkdev/centos-gcc:8.3.0 as gcc
FROM microblinkdev/centos-ninja:1.9.0 as ninja

FROM centos:7 AS builder

ARG LLVM_VERSION=8.0.0

# setup build environment
RUN mkdir /home/gcc && mkdir /home/ninja && mkdir /home/build

COPY --from=gcc /usr/local /home/gcc/
COPY --from=ninja /usr/local /home/ninja

# download and install CMake
RUN cd /home && \
    curl -o cmake.tar.gz -L https://github.com/Kitware/CMake/releases/download/v3.14.3/cmake-3.14.3-Linux-x86_64.tar.gz && \
    tar xf cmake.tar.gz && \
    mv cmake-3.14.4-Linux-x86_64 cmake

# install bzip2 (required for building the LLVM)
RUN yum -y install bzip2 zip unzip

# setup environment variables
ENV AR="/home/gcc/bin/gcc-ar"                                    \
    RANLIB="/home/gcc/bin/gcc-ranlib"                            \
    NM="/home/gcc/bin/gcc-nm"                                    \
    CC="/home/gcc/bin/gcc"                                       \
    CXX="/home/gcc/bin/g++"                                      \
    LD_LIBRARY_PATH="/home/gcc/lib:${LD_LIBRARY_PATH}"           \
    PATH="/home/gcc/bin:/home/ninja/bin:/home/cmake/bin:${PATH}"

# download LLVM
RUN cd /home/build && \
    curl -o llvm.tar.xz http://releases.llvm.org/${LLVM_VERSION}/llvm-${LLVM_VERSION}.src.tar.xz && \
    tar xf llvm.tar.xz && \
    pushd llvm-${LLVM_VERSION}.src/tools && \
    curl -o clang.tar.xz http://releases.llvm.org/${LLVM_VERSION}/cfe-${LLVM_VERSION}.src.tar.xz && \
    tar xf clang.tar.xz && \
    mv cfe-${LLVM_VERSION}.src clang && \
    pushd clang/tools && \
    curl -o extra.tar.xz http://releases.llvm.org/${LLVM_VERSION}/clang-tools-extra-${LLVM_VERSION}.src.tar.xz && \
    tar xf extra.tar.xz && \
    mv clang-tools-extra-${LLVM_VERSION}.src extra && \
    popd && \
    popd

# build everything
RUN cd /home/build && \
    mkdir llvm-build && \
    cd llvm-build && \
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_LTO=ON \
        -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;libcxx;libcxxabi;lldb" \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        ../llvm-${LLVM_VERSION}.src

# Stage 2, copy artifacts to new image and prepare environment

FROM centos:7
COPY --from=builder /usr/local /usr/local/

ENV CC="/usr/local/bin/clang"       \
    CXX="/usr/local/bin/clang++"
