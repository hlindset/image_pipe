# syntax=docker/dockerfile:1
#
# Builds the image_pipe_server release. Build from the repository root, since
# the server depends on the sibling image_pipe and image_pipe_url projects:
#
#     docker build -f image_pipe_server/Dockerfile -t image_pipe_server .
#     docker build -f image_pipe_server/Dockerfile --build-arg IMAGE_VISION=1 \
#       -t image_pipe_server:vision .
#
# IMAGE_VISION=1 bundles the default detector (image_vision with ONNX Runtime)
# and bakes its models into the image.

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20260918-slim
ARG RUNTIME_IMAGE=debian:trixie-20260918-slim

FROM ${ELIXIR_IMAGE} AS build

# libvips is built from source for JPEG XL decoding, which the libvips bundled
# with the precompiled vix NIF lacks, and PNG palette quantization. Loaders for
# families ImagePipe rejects are disabled explicitly, so a dependency appearing
# in the base image can't add one.
ARG VIPS_VERSION=8.18.7
ARG VIPS_SHA256=5baaead3b0bb20ffdb9e9ff09aa9fda08620923df77b63b436654cb5e0b3bf94

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential meson ninja-build pkg-config curl ca-certificates git xz-utils \
      libglib2.0-dev libexpat1-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
      libtiff-dev libgif-dev libheif-dev liborc-0.4-dev liblcms2-dev \
      libjxl-dev libcgif-dev libexif-dev libimagequant-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/vips.tar.xz \
      "https://github.com/libvips/libvips/releases/download/v${VIPS_VERSION}/vips-${VIPS_VERSION}.tar.xz" \
    && echo "${VIPS_SHA256}  /tmp/vips.tar.xz" | sha256sum --check --strict \
    && tar -xJf /tmp/vips.tar.xz -C /tmp \
    && cd "/tmp/vips-${VIPS_VERSION}" \
    && meson setup build --prefix=/usr/local --libdir=lib --buildtype=release \
         -Dimagequant=enabled -Dmodules=disabled \
         -Dmagick=disabled -Dpoppler=disabled -Dpdfium=disabled -Drsvg=disabled \
         -Draw=disabled -Dopenslide=disabled -Dopenexr=disabled -Dcfitsio=disabled \
         -Dmatio=disabled -Dnifti=disabled -Dppm=false -Danalyze=false -Dradiance=false \
    && meson compile -C build \
    && meson install -C build \
    && ldconfig \
    && vips -l | grep -q jxlload \
    && ! vips -l | grep -Eq 'svgload|magickload|pdfload|dcrawload|ppmload' \
    && rm -rf /tmp/vips*

# The Debian packages the runtime image needs for libvips' shared libraries.
RUN ldd /usr/local/lib/libvips.so.42 | awk '/=> \// { print $3 }' \
      | xargs -r realpath | xargs -r dpkg -S 2>/dev/null | cut -d: -f1 \
      | sort -u > /usr/local/lib/vips-runtime-packages

ARG IMAGE_VISION=0
ENV IMAGE_VISION=${IMAGE_VISION}

# ortex compiles its NIF from Rust source.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:${PATH}
RUN if [ "${IMAGE_VISION}" = "1" ]; then \
      curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable; \
    fi

ENV MIX_ENV=prod VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS
WORKDIR /src
RUN mix local.hex --force && mix local.rebar --force

COPY image_pipe_url/mix.exs image_pipe_url/mix.lock image_pipe_url/
COPY image_pipe/mix.exs image_pipe/mix.lock image_pipe/
COPY image_pipe_server/mix.exs image_pipe_server/mix.lock image_pipe_server/
COPY image_pipe_server/config image_pipe_server/config
WORKDIR /src/image_pipe_server
RUN mix deps.get --only prod && mix deps.compile

COPY image_pipe_url/lib /src/image_pipe_url/lib
COPY image_pipe/lib /src/image_pipe/lib
COPY image_pipe/priv/icc /src/image_pipe/priv/icc
COPY image_pipe_server/lib lib
COPY image_pipe_server/rel rel
RUN mix compile && mix release

# Models land under $XDG_CACHE_HOME/image_vision, which the runtime keeps.
ENV XDG_CACHE_HOME=/opt/image_pipe/cache
RUN mkdir -p "${XDG_CACHE_HOME}" \
    && if [ "${IMAGE_VISION}" = "1" ]; then \
      _build/prod/rel/image_pipe_server/bin/image_pipe_server eval ' \
        {:ok, _apps} = Application.ensure_all_started([:image_pipe, :image_vision]); \
        detector = ImagePipe.Transform.resolve_detector(:default); \
        :ok = ImagePipe.Transform.Detector.warmup(detector, classes: :all)'; \
    fi

FROM ${RUNTIME_IMAGE}

COPY --from=build /usr/local/lib/vips-runtime-packages /tmp/vips-runtime-packages
# OTP's socket support loads libsctp at startup and logs a warning without it.
RUN apt-get update && apt-get install -y --no-install-recommends \
      $(cat /tmp/vips-runtime-packages) \
      libheif-plugin-aomdec libheif-plugin-aomenc \
      libstdc++6 libncurses6 libsctp1 openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/* /tmp/vips-runtime-packages

COPY --from=build /usr/local/lib/libvips* /usr/local/lib/
RUN ldconfig

RUN useradd --uid 10001 --no-create-home --home-dir /app --shell /usr/sbin/nologin image_pipe \
    && mkdir -p /var/cache/image_pipe /etc/image_pipe \
    && chown image_pipe /var/cache/image_pipe

COPY --from=build --chown=image_pipe /src/image_pipe_server/_build/prod/rel/image_pipe_server /app
COPY --from=build /opt/image_pipe/cache /opt/image_pipe/cache

# Everything the release writes goes to /tmp, so the root filesystem can be
# read-only; mount cache directories as volumes.
ENV LANG=C.UTF-8 \
    TMPDIR=/tmp \
    RELEASE_TMP=/tmp \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump \
    XDG_CACHE_HOME=/opt/image_pipe/cache

# Fail the build when a library the release loads is missing.
RUN ! find /app /usr/local/lib -name '*.so*' -type f -exec ldd {} + 2>/dev/null | grep 'not found'

USER image_pipe
WORKDIR /app
EXPOSE 8080
VOLUME ["/var/cache/image_pipe"]

# The check reads the server's configuration, so it follows the port and bind
# address wherever they're set.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s \
  CMD ["/app/bin/image_pipe_server", "eval", "ImagePipeServer.Health.check()"]

ENTRYPOINT ["/app/bin/image_pipe_server"]
CMD ["start"]
