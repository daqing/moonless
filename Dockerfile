# Shared image for all moonless platform services (R1, R3): a version-pinned
# moon toolchain plus the prebuilt native service binaries. Builder and runner
# differ only in the entry point, which docker-compose.yml selects per service.

FROM ubuntu:24.04

ARG MOONBIT_VERSION=0.10.14+7d59c7ec9

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gcc \
      git \
      libc6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s -- "$MOONBIT_VERSION"
ENV PATH="/root/.moon/bin:${PATH}"
RUN moon version --all

WORKDIR /app
COPY . .
RUN moon update \
 && moon build --target native --release cmd/gateway cmd/builder cmd/runner cmd/scheduler cmd/moonless \
 && mkdir -p /app/bin \
 && cp _build/native/release/build/cmd/gateway/gateway.exe /app/bin/gateway \
 && cp _build/native/release/build/cmd/builder/builder.exe /app/bin/builder \
 && cp _build/native/release/build/cmd/runner/runner.exe /app/bin/runner \
 && cp _build/native/release/build/cmd/scheduler/scheduler.exe /app/bin/scheduler \
 && cp _build/native/release/build/cmd/moonless/moonless.exe /app/bin/moonless

# Shared state lives on a named volume mounted at /var/lib/moonless. Services
# create the {functions,builds,logs,registry} subdirectories on demand: baking
# them into the image races Docker's volume copy-up when several containers
# first mount the same empty volume concurrently.
ENV MOONLESS_DATA=/var/lib/moonless
