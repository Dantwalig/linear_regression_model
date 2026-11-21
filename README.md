# Bedside Anaemia Risk Estimator

## 1. Mission and problem

My mission is to help clinics without a laboratory find the sickest children quickly.
The problem: a nurse needs to know how low a child's haemoglobin is, but cannot test it.
This project estimates haemoglobin (g/dL) from bedside signs, so children with the lowest estimates are referred first.
It is a screening aid and a blood test confirms the result.

## 2. Dataset and source

The model is trained on admission records for 29,226 children admitted to the paediatric ward of Kilifi County Hospital, Kenya, from 2002 to 2009 (31 columns, numeric and categorical). The target is `hb`, the haemoglobin at admission. The data is public domain (CC0).

Source: https://doi.org/10.6084/m9.figshare.7635908.v1

Citation: Maitland K, Ohuma EO, Mpoya A, Uyoga S, Hassall O, Williams TN (2019). Admission records, including haemoglobin measurements, for 29,226 children admitted to a paediatric ward in a rural Kenyan hospital for the period 2002 to 2009. Figshare.

## 3. Public Swagger UI

https://anaemia-risk-api.onrender.com/docs

The free Render plan sleeps after 15 minutes without use, so the first request can take up to a minute.

## 4. YouTube demo

PASTE_YOUR_YOUTUBE_LINK_HERE

## 5. Run the mobile app

The app runs on an Android emulator or an Android phone (not as a web app).

1. Install Flutter (https://docs.flutter.dev/get-started/install) and Android Studio, then run `flutter doctor` until the Android toolchain has a tick. Accept licences with `flutter doctor --android-licenses`.
2. Start an Android emulator from Android Studio's Device Manager, or connect a phone with USB debugging turned on.
3. Clone the repository: `git clone https://github.com/Dantwalig/linear_regression_model.git`
4. Open the app folder: `cd linear_regression_model/summative/FlutterApp`
5. Install packages: `flutter pub get`
6. Check the device is detected: `flutter devices`
7. Run the app on the Android device: `flutter run -d DEVICE_ID`
8. Fill in all 18 fields (1 for yes and 0 for no, age in months from 2 to 180) and press **Predict**. The estimated haemoglobin appears in the display area. A missing, wrong type or out of range value shows an error message there.
9. The app calls the public API above. If the first prediction is slow, the service is waking up, so wait a minute and try again.

To run the API locally: `cd summative/API`, then `uv sync --locked`, then `uv run uvicorn prediction:app --reload`.
