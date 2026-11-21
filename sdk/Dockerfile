# The SDK as a build image (docs/sdk.md). The build context holds each
# platform's `make sdk` tarball as
# flipbase-my355-sdk-<version>-<amd64|arm64>.tar.gz.
# Debian trixie, as the SDK's host tools were built in.
FROM debian:trixie-slim

ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends make cmake ninja-build git \
      ca-certificates file patch xz-utils \
 && rm -rf /var/lib/apt/lists/*

ADD flipbase-my355-sdk-*-${TARGETARCH}.tar.gz /opt/
RUN /opt/flipbase-my355-sdk/relocate-sdk.sh >/dev/null

ENV FLIPBASE_SDK=/opt/flipbase-my355-sdk
# Enough for a plain `docker run image make`; BASH_ENV adds the rest of
# environment-setup (CC, PKG_CONFIG, ...) in every bash, including the steps of
# a GitHub Actions job with `container:`.
ENV PATH=$FLIPBASE_SDK/bin:$FLIPBASE_SDK/sbin:$PATH \
    CMAKE_TOOLCHAIN_FILE=$FLIPBASE_SDK/share/buildroot/toolchainfile.cmake \
    BASH_ENV=/etc/flipbase-sdk.sh
COPY flipbase-sdk.sh /etc/flipbase-sdk.sh

WORKDIR /src
ENTRYPOINT ["/bin/bash", "-c", "exec \"$@\"", "--"]
CMD ["bash"]
