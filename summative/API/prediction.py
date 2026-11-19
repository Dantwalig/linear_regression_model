import io
from contextlib import asynccontextmanager
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, ConfigDict, Field
from sklearn.base import clone
from sklearn.linear_model import SGDRegressor

BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "best_model.pkl"
TRAIN_PATH = BASE_DIR / "training_data.csv"

FEATURES = [
    "sex", "temp_gradient", "pallor", "indrawing", "resp_deep", "age_months",
    "fever_high", "waz_low", "tachyc", "refill3", "pulse_vol_weak", "shock",
    "mal_par", "muac2", "dehydration", "oxysat_cat", "jaundice", "coma",
]

yes_values = {"yes", "y", "Yes"}
no_values = {"no", "n", "No"}
binary_cols = ["temp_gradient", "pallor", "indrawing", "resp_deep", "fever_high",
               "tachyc", "refill3", "pulse_vol_weak", "shock", "mal_par",
               "dehydration", "jaundice", "coma"]


def clean_raw(raw: pd.DataFrame) -> pd.DataFrame:
    out = raw.copy()
    for c in binary_cols:
        out[c] = out[c].map(lambda v: 1 if v in yes_values else (0 if v in no_values else np.nan))
    out["sex"] = out["sex"].map({"male": 1, "female": 0})
    out["muac2"] = out["muac2"].map({"muac<=11.5cm": 1, "muac>11.5cm": 0})
    out["oxysat_cat"] = out["oxysat_cat"].map({"Oxysat<90%": 1, "Oxysat>90%": 0})
    out["age_months"] = pd.to_numeric(out["age_months"], errors="coerce")
    out["hb"] = pd.to_numeric(out["hb"], errors="coerce")
    return out
state = {"model": None, "train_data": None}


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Load the model from the repo at startup
    state["model"] = joblib.load(MODEL_PATH)
    state["train_data"] = pd.read_csv(TRAIN_PATH)
    yield


app = FastAPI(
    title="Bedside Anaemia Risk Estimator",
    description="Estimates a child's haemoglobin (g/dL) from bedside signs.",
    lifespan=lifespan,
)

ALLOWED_ORIGINS = [
    "https://anaemia-risk-api.onrender.com",
    "http://localhost:5000",
    "http://127.0.0.1:5000",
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "Accept"],
    allow_credentials=False,
)


def flag(description: str):
    """A yes or no input: an integer that must be 0 or 1."""
    return Field(..., ge=0, le=1, description=description)


class PatientInput(BaseModel):
    # strict=True means "1" (text) or 1.0 (decimal) is rejected where an integer is required
    model_config = ConfigDict(
        strict=True,
        extra="forbid",
        json_schema_extra={"example": {
            "sex": 1, "temp_gradient": 0, "pallor": 1, "indrawing": 0, "resp_deep": 0,
            "age_months": 24.0, "fever_high": 0, "waz_low": 0, "tachyc": 1, "refill3": 0,
            "pulse_vol_weak": 0, "shock": 0, "mal_par": 1, "muac2": 0, "dehydration": 0,
            "oxysat_cat": 0, "jaundice": 0, "coma": 0,
        }},
    )

    sex: int = flag("1 = male, 0 = female")
    temp_gradient: int = flag("Temperature gradient between limbs: 1 = yes, 0 = no")
    pallor: int = flag("Pallor (pale palms or lips): 1 = yes, 0 = no")
    indrawing: int = flag("Chest indrawing: 1 = yes, 0 = no")
    resp_deep: int = flag("Deep breathing: 1 = yes, 0 = no")
    # The training data covers ages 2.0 to 179.4 months, so the range stops at 180
    age_months: float = Field(..., ge=2.0, le=180.0, description="Age in months (2 to 180)")
    fever_high: int = flag("High fever: 1 = yes, 0 = no")
    waz_low: int = flag("Low weight for age: 1 = yes, 0 = no")
    tachyc: int = flag("Fast heart rate: 1 = yes, 0 = no")
    refill3: int = flag("Capillary refill longer than 3 seconds: 1 = yes, 0 = no")
    pulse_vol_weak: int = flag("Weak pulse volume: 1 = yes, 0 = no")
    shock: int = flag("Shock: 1 = yes, 0 = no")
    mal_par: int = flag("Malaria parasites on a rapid test: 1 = yes, 0 = no")
    muac2: int = flag("Arm circumference 11.5 cm or less: 1 = yes, 0 = no")
    dehydration: int = flag("Dehydration: 1 = yes, 0 = no")
    oxysat_cat: int = flag("Oxygen saturation below 90 percent: 1 = yes, 0 = no")
    jaundice: int = flag("Jaundice: 1 = yes, 0 = no")
    coma: int = flag("Coma: 1 = yes, 0 = no")


def predict_one_row(row_df: pd.DataFrame) -> float:
    """Same idea as the notebook function, but using the model loaded at startup."""
    return float(state["model"].predict(row_df)[0])


@app.post("/predict")
def predict(payload: PatientInput):
    row = pd.DataFrame([payload.model_dump()])[FEATURES]   # keep the training column order
    return {"predicted_hb": round(predict_one_row(row), 2), "unit": "g/dL"}

@app.post("/retrain")
async def retrain(file: UploadFile = File(...)):
    content = await file.read()

    # The original file is tab separated, so try tabs first, then commas
    raw = None
    for sep in ("\t", ","):
        try:
            candidate = pd.read_csv(io.BytesIO(content), sep=sep)
        except Exception:
            continue
        if "hb" in candidate.columns:
            raw = candidate
            break
    if raw is None:
        raise HTTPException(status_code=400, detail="Could not read a CSV with an 'hb' column.")

    missing = [c for c in FEATURES + ["hb"] if c not in raw.columns]
    if missing:
        raise HTTPException(status_code=400, detail=f"Missing columns: {missing}")

    new = clean_raw(raw)[FEATURES + ["hb"]].dropna(subset=["hb"])
    if new.empty:
        raise HTTPException(status_code=400, detail="No usable rows with an hb value.")

    pipeline = state["model"]
    estimator = pipeline.named_steps["model"]

    if isinstance(estimator, SGDRegressor):
        # Continue training the saved model on the new rows only
        X_new = pipeline.named_steps["scaler"].transform(
            pipeline.named_steps["imputer"].transform(new[FEATURES]))
        estimator.partial_fit(X_new, new["hb"])
        updated = pipeline
    else:
        # Any other model: refit on the original data plus the new rows
        combined = pd.concat([state["train_data"], new], ignore_index=True)
        updated = clone(pipeline)
        updated.fit(combined[FEATURES], combined["hb"])
        state["train_data"] = combined

    state["model"] = updated            # /predict now uses the new model, no redeploy
    joblib.dump(updated, MODEL_PATH)    # lost if the free Render service restarts
    return {
        "message": "Model retrained",
        "rows_added": int(len(new)),
        "training_rows": int(len(state["train_data"])),
    }
