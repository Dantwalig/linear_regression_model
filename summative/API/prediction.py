"""Bedside Anaemia Risk Estimator API: predicts haemoglobin (g/dL) from bedside signs."""
from contextlib import asynccontextmanager
from pathlib import Path

import joblib
import pandas as pd
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, ConfigDict, Field

from retrain import FEATURES, prepare_new_rows, read_uploaded_csv, retrain

BASE_DIR = Path(__file__).resolve().parent
MODEL_PATH = BASE_DIR / "best_model.pkl"
TRAIN_PATH = BASE_DIR / "training_data.csv"

# The live model and training data live here so /retrain can swap them without a redeploy
state = {"model": None, "train_data": None}


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Load the model from the repository at startup
    state["model"] = joblib.load(MODEL_PATH)
    state["train_data"] = pd.read_csv(TRAIN_PATH)
    yield


app = FastAPI(
    title="Bedside Anaemia Risk Estimator",
    description="Estimates a child's haemoglobin (g/dL) from bedside signs.",
    lifespan=lifespan,
)

# CORS: I allow only the exact browser origins that need this API (the deployed Render
# address and the local Flutter web debug address), only the GET and POST methods the API
# uses, and only the Content-Type and Accept headers. Credentials are off because the API
# uses no cookies or logins. I do not use "*" so a random website cannot call the API from
# a visitor's browser. The mobile app is not a browser, so CORS does not apply to it.
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


@app.get("/", include_in_schema=False)
def root():
    # Send anyone who opens the bare address to the Swagger page
    return RedirectResponse(url="/docs")


@app.post("/predict")
def predict(payload: PatientInput):
    row = pd.DataFrame([payload.model_dump()])[FEATURES]   # keep the training column order
    return {"predicted_hb": round(predict_one_row(row), 2), "unit": "g/dL"}


@app.post("/retrain")
async def retrain_endpoint(file: UploadFile = File(...)):
    content = await file.read()
    try:
        new_rows = prepare_new_rows(read_uploaded_csv(content))
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error))

    # Uploading the file is the only step: retrain, then start using the new model
    updated_model, updated_data = retrain(state["model"], state["train_data"], new_rows)
    state["model"] = updated_model
    state["train_data"] = updated_data
    joblib.dump(updated_model, MODEL_PATH)   # lost if the free Render service restarts

    return {
        "message": "Model retrained",
        "rows_added": int(len(new_rows)),
        "training_rows": int(len(updated_data)),
    }
