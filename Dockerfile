FROM ghcr.io/astral-sh/uv:0.9.7-python3.13-trixie-slim
WORKDIR /app
RUN uv pip install --system --no-cache dagster==1.13.26 dagster-k8s==0.29.26 dagster-postgres==0.29.26 \
    dagster-aws==0.29.26 "sqlalchemy>=2.0,<2.1" polars xgboost scikit-learn
COPY lab_defs.py /app/lab_defs.py
ENV LAB_ON_K8S=true
RUN useradd --uid 10001 --create-home lab \
    && mkdir -p /opt/dagster/dagster_home && chown -R 10001:10001 /opt/dagster
USER 10001
