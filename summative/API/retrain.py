"""Retraining logic for the Bedside Anaemia Risk Estimator.

prediction.py calls these functions from the /retrain endpoint.
"""
import io

import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.linear_model import SGDRegressor

# The 18 model inputs, in the exact column order the saved pipeline was trained on
FEATURES = [
    "sex", "temp_gradient", "pallor", "indrawing", "resp_deep", "age_months",
    "fever_high", "waz_low", "tachyc", "refill3", "pulse_vol_weak", "shock",
    "mal_par", "muac2", "dehydration", "oxysat_cat", "jaundice", "coma",
]
TARGET = "hb"

# Same cleaning rules as the notebook, so an uploaded raw CSV becomes model input
yes_values = {"yes", "y", "Yes"}
no_values = {"no", "n", "No"}
binary_cols = ["temp_gradient", "pallor", "indrawing", "resp_deep", "fever_high",
               "tachyc", "refill3", "pulse_vol_weak", "shock", "mal_par",
               "dehydration", "jaundice", "coma"]


def clean_raw(raw: pd.DataFrame) -> pd.DataFrame:
    """Turn the raw yes/no and category columns into 1 and 0."""
    out = raw.copy()
    for c in binary_cols:
        out[c] = out[c].map(lambda v: 1 if v in yes_values else (0 if v in no_values else np.nan))
    out["sex"] = out["sex"].map({"male": 1, "female": 0})
    out["muac2"] = out["muac2"].map({"muac<=11.5cm": 1, "muac>11.5cm": 0})
    out["oxysat_cat"] = out["oxysat_cat"].map({"Oxysat<90%": 1, "Oxysat>90%": 0})
    out["age_months"] = pd.to_numeric(out["age_months"], errors="coerce")
    out[TARGET] = pd.to_numeric(out[TARGET], errors="coerce")
    return out


def read_uploaded_csv(content: bytes) -> pd.DataFrame:
    """Read an uploaded file. The original data is tab separated, so try tabs, then commas."""
    for sep in ("\t", ","):
        try:
            candidate = pd.read_csv(io.BytesIO(content), sep=sep)
        except Exception:
            continue
        if TARGET in candidate.columns:
            return candidate
    raise ValueError("Could not read a CSV file with an 'hb' column.")


def prepare_new_rows(raw: pd.DataFrame) -> pd.DataFrame:
    """Check the columns, clean the rows and keep only rows that have an hb value."""
    missing = [c for c in FEATURES + [TARGET] if c not in raw.columns]
    if missing:
        raise ValueError(f"Missing columns: {missing}")
    new_rows = clean_raw(raw)[FEATURES + [TARGET]].dropna(subset=[TARGET])
    if new_rows.empty:
        raise ValueError("No usable rows with an hb value.")
    return new_rows


def retrain(pipeline, train_data: pd.DataFrame, new_rows: pd.DataFrame):
    """Return (updated pipeline, updated training data).

    SGDRegressor: keep training the saved model on the new rows with partial_fit.
    Any other model: refit a fresh copy on the original data plus the new rows.
    """
    estimator = pipeline.named_steps["model"]

    if isinstance(estimator, SGDRegressor):
        x_new = pipeline.named_steps["scaler"].transform(
            pipeline.named_steps["imputer"].transform(new_rows[FEATURES]))
        estimator.partial_fit(x_new, new_rows[TARGET])
        return pipeline, train_data

    combined = pd.concat([train_data, new_rows], ignore_index=True)
    updated = clone(pipeline)
    updated.fit(combined[FEATURES], combined[TARGET])
    return updated, combined
