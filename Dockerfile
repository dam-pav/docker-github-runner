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

# health-check script to validate docker socket access for the runner user
COPY docker-socket-check.sh /usr/local/bin/docker-socket-check.sh
RUN chmod +x /usr/local/bin/docker-socket-check.sh
ENV PATH="/actions-runner:${PATH}"

ENTRYPOINT ["/entrypoint.sh"]
