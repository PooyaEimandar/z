# Stage 1: Build the Zig binary
FROM ubuntu:latest AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV ZIG_VERSION=0.14.1

# Install build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    ca-certificates \
    liburing-dev \
    && rm -rf /var/lib/apt/lists/*

# Detect architecture and set download URL
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        echo "x86_64" > /arch.txt; \
    elif [ "$ARCH" = "aarch64" ]; then \
        echo "aarch64" > /arch.txt; \
    else \
        echo "Unsupported architecture: $ARCH"; exit 1; \
    fi

# Download and extract Zig
WORKDIR /opt
RUN ARCH=$(cat /arch.txt) && \
    curl -LO https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz && \
    tar -xf zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz && \
    mv zig-${ARCH}-linux-${ZIG_VERSION} zig

# Copy source code
WORKDIR /app
COPY ./ .

RUN /opt/zig/zig build -Doptimize=ReleaseFast

EXPOSE 8080
CMD ["zig-out/bin/z"]
