FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.3.13750724
ENV PATH="$PATH:/opt/flutter/bin:/root/.cargo/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools"

# Install system dependencies (matching GitHub Actions runner)
RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    openjdk-17-jdk \
    zlib1g-dev \
    clang \
    libclang-dev \
    libc6-dev-i386 \
    cmake \
    ninja-build \
    pkg-config \
    make \
    && rm -rf /var/lib/apt/lists/*

# Install Flutter 3.32.4 (matching GitHub Actions)
RUN git clone https://github.com/flutter/flutter.git -b stable /opt/flutter \
    && cd /opt/flutter \
    && git checkout 3.32.4 \
    && flutter precache --android

# Install Rust (stable toolchain matching GitHub Actions)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable \
    && . $HOME/.cargo/env \
    && rustup target add aarch64-linux-android

# Install cargo-ndk
RUN . $HOME/.cargo/env && cargo install cargo-ndk

# Install Android SDK command-line tools
RUN mkdir -p $ANDROID_SDK_ROOT/cmdline-tools \
    && cd $ANDROID_SDK_ROOT/cmdline-tools \
    && curl -o commandlinetools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
    && unzip commandlinetools.zip \
    && rm commandlinetools.zip \
    && mv cmdline-tools latest

RUN yes | sdkmanager --licenses \
    && sdkmanager \
        "ndk;27.3.13750724" \
        "platform-tools" \
        "platforms;android-34" \
        "build-tools;34.0.0"

WORKDIR /workspace

CMD ["/bin/bash"]
