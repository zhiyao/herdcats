FROM debian:bookworm-slim

ARG TARGETARCH
ARG HERDR_VERSION=0.9.1
ARG PI_VERSION=0.87.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git openssh-server tini util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --home-dir /data/home/review --shell /bin/sh review \
    && mkdir -p /run/sshd

RUN case "$TARGETARCH" in \
        amd64) asset=herdr-linux-x86_64 ;; \
        arm64) asset=herdr-linux-aarch64 ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fL --retry 3 \
        "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/${asset}" \
        -o /usr/local/bin/herdr \
    && chmod 755 /usr/local/bin/herdr

RUN case "$TARGETARCH" in \
        amd64) asset=pi-linux-x64.tar.gz ;; \
        arm64) asset=pi-linux-arm64.tar.gz ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fL --retry 3 \
        "https://github.com/earendil-works/pi/releases/download/v${PI_VERSION}/${asset}" \
        -o /tmp/pi.tar.gz \
    && tar -xzf /tmp/pi.tar.gz -C /opt \
    && ln -s /opt/pi/pi /usr/local/bin/pi \
    && rm /tmp/pi.tar.gz

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/review-entrypoint
RUN chmod 755 /usr/local/bin/review-entrypoint

ENV TERM=xterm-256color
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/review-entrypoint"]
