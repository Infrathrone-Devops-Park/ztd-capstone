# syntax=docker/dockerfile:1

FROM --platform=linux/amd64 python:3.12-slim AS build
WORKDIR /src
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY pyproject.toml ./
COPY app ./app
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir .

FROM --platform=linux/amd64 python:3.12-slim AS runtime
# Pull in all available Debian security updates so the runtime image does not
# ship fixable OS-package CVEs (the Trivy image gate in ci.yml/pr-checks
# blocks on HIGH/CRITICAL). Anything left after this is genuinely unfixable
# (no upstream Debian patch yet) and is enumerated, with justification, in
# the repo-root .trivyignore.
RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get -y --purge autoremove \
    && rm -rf /var/lib/apt/lists/*
RUN groupadd --system app && useradd --system --gid app --no-create-home app
WORKDIR /app
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1
COPY --from=build /opt/venv /opt/venv
COPY app ./app

USER app
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('PORT','8080')+'/healthz', timeout=2).status == 200 else 1)"]

CMD ["python", "-m", "app.main"]
