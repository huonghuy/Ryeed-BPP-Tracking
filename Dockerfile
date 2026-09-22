# syntax=docker/dockerfile:1.7
# -------------------
# The build container
# -------------------
FROM python:3.12-slim-trixie AS build

# Every dependency (shapely, pydantic-core, uvloop, httptools, watchfiles)
# ships manylinux wheels for cp312, so no compilers or -dev headers are needed.
# If a future dependency has no wheel, add a build-essential apt layer here.
COPY predicts/modern/requirements.txt /tmp/requirements.txt

# Install into a self-contained venv so the final stage gets one clean COPY
# with no pip/setuptools cruft. Cache mount speeds up local rebuilds only.
RUN --mount=type=cache,target=/root/.cache/pip \
  python3 -m venv /opt/venv && \
  /opt/venv/bin/pip install --no-warn-script-location -r /tmp/requirements.txt

# Strip bytecode and bundled test suites before copying to the final stage.
RUN find /opt/venv -name "*.pyc" -delete && \
  find /opt/venv -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true && \
  find /opt/venv -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true && \
  find /opt/venv -name "*.so" -exec strip --strip-unneeded {} + 2>/dev/null || true

# -------------------------
# The application container
# -------------------------
FROM python:3.12-slim-trixie
EXPOSE 8000/tcp

# tini is the only runtime package needed; shapely's wheel bundles its own GEOS.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  rm -f /etc/apt/apt.conf.d/docker-clean && \
  apt-get update && \
  apt-get install -y --no-install-recommends tini

# Create a non-root user to run the application.
RUN useradd -r -u 1000 -m -s /bin/false bpp

# --chown bakes ownership into the layer instead of rewriting every file later.
COPY --from=build --chown=bpp:bpp /opt/venv /opt/venv

# Copy in the prediction suite. The launcher scripts (*.bat/*.ps1) and the
# local .venv are excluded by .dockerignore; the .bat workflow is unaffected.
COPY --chown=bpp:bpp predicts /opt/bpp/predicts

WORKDIR /opt/bpp/predicts/modern

# app.py creates these at import time and writes FAA/launch-site caches there.
RUN mkdir -p cache/airspace cache/reference data && chown -R bpp:bpp cache data
VOLUME ["/opt/bpp/predicts/modern/cache"]

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    BPP_PREDICTS_HOST=0.0.0.0 \
    BPP_PREDICTS_PORT=8000

USER bpp

# Use tini as init.
ENTRYPOINT ["/usr/bin/tini", "--"]

# app.py's __main__ block starts uvicorn and honours BPP_PREDICTS_HOST/PORT.
# run_latest.py / run_windows.bat are desktop launchers: they bootstrap a venv
# and open a browser, neither of which applies here.
CMD ["python3", "app.py"]
