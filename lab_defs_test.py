"""Tests for the lab code location."""

import polars as pl

from lab_defs import defs, feature_hash, rolling_mean_3


def test_rolling_mean_is_per_entity():
    """The rolling mean never mixes rows from different entities."""
    frame = pl.DataFrame({"entity": ["a", "a", "a", "b", "b", "b"], "sales": [1, 2, 3, 10, 20, 30]})
    assert rolling_mean_3(frame)["sales_rm3"].to_list() == [None, None, 2.0, None, None, 20.0]


def test_feature_hash_is_stable():
    """Hashing the same function twice gives the same version."""
    assert feature_hash(rolling_mean_3) == feature_hash(rolling_mean_3)


def test_sweep_job_loads():
    """The code location defines the sweep job."""
    assert defs.resolve_job_def("sweep").name == "sweep"
