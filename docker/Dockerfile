FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.3.13750724
ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
ENV PATH="/opt/cargo/bin:/opt/flutter/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

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

# Install Flutter 3.38.3 (matching GitHub Actions)
RUN git clone https://github.com/flutter/flutter.git -b stable /opt/flutter \
    && cd /opt/flutter \
    && git checkout 3.38.3 \
    && flutter precache --android

# Allow non-root users to use flutter
RUN git config --system --add safe.directory /opt/flutter \
    && chmod -R a+w /opt/flutter

# Install Rust (stable toolchain, system-wide for all users)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable \
    && rustup target add aarch64-linux-android \
    && chmod -R a+rx /opt/rustup /opt/cargo

# Install cargo-ndk
RUN cargo install cargo-ndk \
    && chmod -R a+rx /opt/cargo

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
        "platforms;android-35" \
        "platforms;android-36" \
        "build-tools;34.0.0" \
        "build-tools;35.0.0" \
        "cmake;3.22.1"

WORKDIR /workspace

CMD ["/bin/bash"]
