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
#
# IMAGE_PIPE_LIBS=hex builds against the image_pipe version the server
# releases with (@image_pipe_version in mix.exs) from Hex instead of the
# sibling projects. Release images build this way.

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20260918-slim
ARG RUNTIME_IMAGE=debian:trixie-20260918-slim
ARG IMAGE_PIPE_LIBS=path

FROM ${ELIXIR_IMAGE} AS toolchain

# libvips is built from source for JPEG XL decoding, which the libvips bundled
# with the precompiled vix NIF lacks, PNG palette quantization, and highway
# SIMD (about twice as fast resizing and blurring as the orc fallback). Loaders for
# families ImagePipe rejects are disabled explicitly, so a dependency appearing
# in the base image can't add one.
ARG VIPS_VERSION=8.18.7
ARG VIPS_SHA256=5baaead3b0bb20ffdb9e9ff09aa9fda08620923df77b63b436654cb5e0b3bf94

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential meson ninja-build cmake nasm pkg-config curl ca-certificates git xz-utils \
      libglib2.0-dev libexpat1-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
      libtiff-dev libgif-dev libheif-dev liborc-0.4-dev liblcms2-dev \
      libjxl-dev libcgif-dev libexif-dev libimagequant-dev libhwy-dev \
    && rm -rf /var/lib/apt/lists/*

# zlib-ng, libpng and libjpeg-turbo are built from source too, and replace
# Debian's older versions for libvips and every library it loads: zlib-ng
# compresses and decompresses PNG about twice as fast as zlib. They install to
# /usr/local/lib, which 00-local.conf puts ahead of Debian's library
# directories.
ARG ZLIB_NG_VERSION=2.3.3
ARG ZLIB_NG_SHA256=f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1
ARG LIBPNG_VERSION=1.6.59
ARG LIBPNG_SHA256=d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389
ARG LIBJPEG_TURBO_VERSION=3.2.0
ARG LIBJPEG_TURBO_SHA256=6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e

RUN echo /usr/local/lib > /etc/ld.so.conf.d/00-local.conf \
    && cmake_install() { \
         dir=$1 && shift \
         && cmake -S "$dir" -B "$dir/build" -DCMAKE_BUILD_TYPE=Release \
           -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_INSTALL_LIBDIR=lib "$@" \
         && cmake --build "$dir/build" -j "$(nproc)" && cmake --install "$dir/build"; \
       } \
    && fetch() { \
         curl -fsSL -o "/tmp/$1.tar" "$2" \
         && echo "$3  /tmp/$1.tar" | sha256sum --check --strict \
         && mkdir "/tmp/$1" && tar -xf "/tmp/$1.tar" -C "/tmp/$1" --strip-components=1; \
       } \
    && fetch zlib-ng "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${ZLIB_NG_VERSION}.tar.gz" \
         "${ZLIB_NG_SHA256}" \
    && cmake_install /tmp/zlib-ng -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DWITH_GTEST=OFF \
    && ldconfig \
    && fetch libpng "https://download.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz" \
         "${LIBPNG_SHA256}" \
    && cmake_install /tmp/libpng -DZLIB_ROOT=/usr/local -DPNG_STATIC=OFF -DPNG_TESTS=OFF \
         -DPNG_TOOLS=OFF \
    && fetch libjpeg-turbo \
         "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_TURBO_VERSION}/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz" \
         "${LIBJPEG_TURBO_SHA256}" \
    && cmake_install /tmp/libjpeg-turbo -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF \
    && ldconfig \
    && rm -rf /tmp/zlib-ng* /tmp/libpng* /tmp/libjpeg-turbo*

RUN curl -fsSL -o /tmp/vips.tar.xz \
      "https://github.com/libvips/libvips/releases/download/v${VIPS_VERSION}/vips-${VIPS_VERSION}.tar.xz" \
    && echo "${VIPS_SHA256}  /tmp/vips.tar.xz" | sha256sum --check --strict \
    && tar -xJf /tmp/vips.tar.xz -C /tmp \
    && cd "/tmp/vips-${VIPS_VERSION}" \
    && meson setup build --prefix=/usr/local --libdir=lib --buildtype=release \
         -Dimagequant=enabled -Dhighway=enabled -Dmodules=disabled \
         -Dmagick=disabled -Dpoppler=disabled -Dpdfium=disabled -Drsvg=disabled \
         -Draw=disabled -Dopenslide=disabled -Dopenexr=disabled -Dcfitsio=disabled \
         -Dmatio=disabled -Dnifti=disabled -Dppm=false -Danalyze=false -Dradiance=false \
    && meson compile -C build \
    && meson install -C build \
    && ldconfig \
    && vips -l | grep -q jxlload \
    && ! ldd /usr/local/lib/libvips.so.42 | grep -E 'lib(z|png16|jpeg)\.so' | grep -v ' /usr/local/lib/' \
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

# Only the stages IMAGE_PIPE_LIBS selects are built. Each mode adds the
# library manifests before fetching dependencies and the library sources after
# compiling them, so a library source change doesn't recompile dependencies.
FROM toolchain AS manifests-path
COPY image_pipe_url/mix.exs image_pipe_url/mix.lock image_pipe_url/
COPY image_pipe/mix.exs image_pipe/mix.lock image_pipe/

FROM toolchain AS manifests-hex
ENV IMAGE_PIPE_LIBS=hex

FROM manifests-${IMAGE_PIPE_LIBS} AS deps
COPY image_pipe_server/mix.exs image_pipe_server/mix.lock image_pipe_server/
COPY image_pipe_server/config image_pipe_server/config
WORKDIR /src/image_pipe_server
RUN mix deps.get --only prod && mix deps.compile

FROM deps AS sources-path
COPY image_pipe_url/lib /src/image_pipe_url/lib
COPY image_pipe/lib /src/image_pipe/lib
COPY image_pipe/priv/icc /src/image_pipe/priv/icc

FROM deps AS sources-hex

FROM sources-${IMAGE_PIPE_LIBS} AS build
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
# libheif decodes AVIF with dav1d when its plugin is present, faster than aom.
RUN apt-get update && apt-get install -y --no-install-recommends \
      $(cat /tmp/vips-runtime-packages) \
      libheif-plugin-aomdec libheif-plugin-aomenc libheif-plugin-dav1d \
      libstdc++6 libncurses6 libsctp1 openssl ca-certificates curl libjemalloc2 \
    && rm -rf /var/lib/apt/lists/* /tmp/vips-runtime-packages

# rel/env.sh preloads jemalloc from this path, which is the same on every
# architecture.
RUN ln -s "$(dpkg -L libjemalloc2 | grep '/libjemalloc.so.2$')" /usr/local/lib/libjemalloc.so.2 \
    && LD_PRELOAD=/usr/local/lib/libjemalloc.so.2 /bin/true

COPY --from=build /usr/local/lib/libvips* /usr/local/lib/libz.so.1* \
  /usr/local/lib/libpng16.so.16* /usr/local/lib/libjpeg.so.62* /usr/local/lib/
RUN echo /usr/local/lib > /etc/ld.so.conf.d/00-local.conf && ldconfig \
    && ! ldd /usr/local/lib/libvips.so.42 | grep -E 'lib(z|png16|jpeg)\.so' | grep -v ' /usr/local/lib/'

RUN useradd --uid 10001 --no-create-home --home-dir /app --shell /usr/sbin/nologin image_pipe \
    && mkdir -p /var/cache/image_pipe /etc/image_pipe \
    && chown image_pipe /var/cache/image_pipe

# The release stays root-owned, so the server can't rewrite its own code.
COPY --from=build /src/image_pipe_server/_build/prod/rel/image_pipe_server /app
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

# Readiness, checked often enough that the container reports unhealthy
# within the default 5-second shutdown_delay, so proxies that follow Docker's
# health status stop routing to it before it stops listening. A fixed
# health_port takes the check off the image listener, so load can't fail it.
HEALTHCHECK --interval=2s --timeout=2s --start-period=10s --retries=2 \
  CMD port="${IPS_SERVER__HEALTH_PORT:-0}"; \
      [ "$port" != 0 ] || port="${IPS_SERVER__PORT:-8080}"; \
      curl -fsS "http://127.0.0.1:${port}/health/ready" || exit 1

ENTRYPOINT ["/app/bin/image_pipe_server"]
CMD ["start"]
