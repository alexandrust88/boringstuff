# wiz report generator - airgapped-friendly image
# BASE_REGISTRY overrides the base image registry for airgapped builds
# e.g. --build-arg BASE_REGISTRY=registry.example.com/dockerhub

ARG BASE_REGISTRY=docker.io

FROM ${BASE_REGISTRY}/library/python:3.12-slim AS builder

WORKDIR /build

# install deps into a wheel dir so we can copy to distroless
COPY src/requirements.txt .
RUN pip install --no-cache-dir --target=/deps -r requirements.txt

FROM ${BASE_REGISTRY}/library/python:3.12-slim

LABEL org.opencontainers.image.title="wwwz-wiz-report"
LABEL org.opencontainers.image.description="wiz kubernetes vulnerability report generator"
LABEL org.opencontainers.image.source="https://example.com/wwwz"

# create non-root user
RUN groupadd -r wwwz -g 10001 && \
    useradd -r -u 10001 -g wwwz -s /sbin/nologin wwwz && \
    mkdir -p /output && \
    chown -R wwwz:wwwz /output

# copy deps + code
COPY --from=builder /deps /deps
COPY src/wiz_report.py /app/wiz_report.py

ENV PYTHONPATH=/deps
ENV PYTHONUNBUFFERED=1
ENV OUTPUT_DIR=/output

USER 10001:10001
WORKDIR /output

ENTRYPOINT ["python3", "/app/wiz_report.py"]
