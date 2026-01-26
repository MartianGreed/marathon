FROM alpine:3.19 AS builder

RUN apk add --no-cache \
    curl \
    xz \
    tar \
    git

RUN curl -L https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz | tar -xJ -C /opt && \
    ln -s /opt/zig-linux-x86_64-0.13.0/zig /usr/local/bin/zig

WORKDIR /workspace

ENTRYPOINT ["zig"]
