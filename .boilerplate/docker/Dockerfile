FROM rust:1-bookworm

LABEL com.boilerplate-compile.managed="true"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        git \
        libfontconfig1-dev \
        libfreetype6-dev \
        libgl1-mesa-dev \
        libssl-dev \
        libudev-dev \
        libwayland-dev \
        libx11-dev \
        libxcb1-dev \
        libxcursor-dev \
        libxi-dev \
        libxkbcommon-dev \
        libxrandr-dev \
        pkg-config \
        procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

ENV CARGO_TARGET_DIR=/workspace/target

CMD ["sleep", "infinity"]
