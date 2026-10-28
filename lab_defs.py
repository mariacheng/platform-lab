"""Lab code location: a versioned feature asset and a fan-out hyperparameter sweep."""

import hashlib
import inspect
import os

import dagster as dg
import polars as pl


def rolling_mean_3(frame: pl.DataFrame) -> pl.DataFrame:
    """Feature definition: 3-period rolling mean of sales per entity."""
    return frame.with_columns(pl.col("sales").rolling_mean(3).over("entity").alias("sales_rm3"))


def feature_hash(fn) -> str:
    """Version a feature by hashing its name and source code."""
    return hashlib.sha256(f"{fn.__name__}:{inspect.getsource(fn)}".encode()).hexdigest()[:12]


@dg.asset
def sales_features(context: dg.AssetExecutionContext) -> pl.DataFrame:
    """Compute the feature on toy data and record which code version produced it."""
    frame = pl.DataFrame({"entity": ["a"] * 5 + ["b"] * 5, "sales": [1, 2, 3, 4, 5, 10, 20, 30, 40, 50]})
    result = rolling_mean_3(frame)
    context.add_output_metadata({"feature_hash": feature_hash(rolling_mean_3), "rows": result.height})
    return result


@dg.op(out=dg.DynamicOut(dict))
def candidates():
    """Emit one output per hyperparameter combination; each becomes its own step (its own pod on k8s)."""
    grid = [{"max_depth": d, "learning_rate": lr} for d in (3, 5, 7) for lr in (0.05, 0.2)]
    for index, params in enumerate(grid):
        yield dg.DynamicOutput(params, mapping_key=f"c{index}")


# Reserve one CPU per candidate pod. The tag is ignored when running locally.
@dg.op(tags={"dagster-k8s/config": {"container_config": {"resources": {
    "requests": {"cpu": "1"}, "limits": {"memory": "1Gi"}}}}}
)
def evaluate(context: dg.OpExecutionContext, params: dict) -> dict:
    """Cross-validate one candidate and return its PR-AUC."""
    from sklearn.datasets import load_breast_cancer
    from sklearn.model_selection import cross_val_score
    from xgboost import XGBClassifier

    features, labels = load_breast_cancer(return_X_y=True)
    # A pod sees every host CPU, so without n_jobs XGBoost starts one thread per host CPU in every pod.
    model = XGBClassifier(n_estimators=200, n_jobs=1, **params)
    score = cross_val_score(model, features, labels, cv=5, scoring="average_precision").mean()
    context.log.info(f"{params} pr_auc={score:.4f} pod={os.getenv('HOSTNAME', 'local')}")
    return {**params, "pr_auc": float(score)}


@dg.op
def pick_best(context: dg.OpExecutionContext, results: list[dict]) -> dict:
    """Fan-in: choose the candidate with the highest PR-AUC."""
    best = max(results, key=lambda row: row["pr_auc"])
    context.log.info(f"best candidate {best}")
    return best


def _executor():
    if os.getenv("LAB_ON_K8S") == "true":
        from dagster_k8s import k8s_job_executor

        return k8s_job_executor.configured({"max_concurrent": 6})
    return dg.multiprocess_executor


def _resources():
    """On k8s every step is its own pod, so outputs must go to shared storage (S3), not local disk."""
    if os.getenv("LAB_ON_K8S") == "true":
        from dagster_aws.s3 import S3PickleIOManager, S3Resource

        # LAB_S3_ENDPOINT points at the in-cluster S3 server on kind; leave it unset on real AWS.
        s3 = S3Resource(endpoint_url=os.getenv("LAB_S3_ENDPOINT"))
        return {"io_manager": S3PickleIOManager(s3_resource=s3, s3_bucket=os.environ["LAB_S3_BUCKET"], s3_prefix="lab")}
    return {}


@dg.job(executor_def=_executor())
def sweep():
    """Fan out one evaluate step per candidate, then fan in to pick the best."""
    pick_best(candidates().map(evaluate).collect())


defs = dg.Definitions(assets=[sales_features], jobs=[sweep], resources=_resources())
