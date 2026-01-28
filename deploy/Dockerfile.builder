ARG ALPINE_VERSION=3.19
ARG ZIG_VERSION=0.15.2

FROM alpine:${ALPINE_VERSION} AS builder

ARG ZIG_VERSION

RUN apk add --no-cache \
    curl \
    xz \
    tar \
    git

RUN curl -L https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz | tar -xJ -C /opt && \
    ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /workspace

ENTRYPOINT ["zig"]
