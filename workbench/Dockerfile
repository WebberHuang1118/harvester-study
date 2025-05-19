# ubuntu-workbench/Dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ---- layer 1: system packages ------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git build-essential docker.io && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ---- layer: install Go 1.23.4 ----------------------------------------------
    RUN set -e; \
    url_primary="https://go.dev/dl/go1.23.4.linux-amd64.tar.gz"; \
    url_fallback="https://storage.googleapis.com/golang/go1.23.4.linux-amd64.tar.gz"; \
    curl -fSL --retry 3 -o /tmp/go.tgz "$url_primary" || \
    curl -fSL --retry 3 -o /tmp/go.tgz "$url_fallback"; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz && mkdir -p /workspace


ENV PATH="/usr/local/go/bin:${PATH}"
WORKDIR /workspace     # keep binaries & source here
USER root              # DinD wants real root; remove if you go rootless
