FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    git \
    tar \
    sudo \
    libicu-dev \
    libssl-dev \
    docker.io \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /actions-runner

RUN useradd -m runner \
 && chown -R runner:runner /actions-runner

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner

ENV PATH="/actions-runner:${PATH}"

ENTRYPOINT ["/entrypoint.sh"]
