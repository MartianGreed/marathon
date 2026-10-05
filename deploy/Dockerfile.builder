FROM rust:1-alpine
RUN apk add --no-cache musl-dev protobuf-dev protoc make gcc
WORKDIR /workspace
