# frostline

A small FastAPI service that scores an evening weather reading from a greenhouse
and says whether to raise a frost alert tonight.

    GET  /health    {"status": "ok", "model_version": "...", "git_sha": "..."}
    POST /predict   {"air_temp_c": 1.5, "dew_point_c": -1.0, "wind_speed_ms": 0.8, "cloud_cover_pct": 10}
                    -> {"frost_probability": 0.6411, "alert": true, "threshold": 0.35, "model_version": "..."}

The model is a logistic regression stored as plain numbers in `model/frost_model.json`.
The service reads it once, at startup.

Run it locally:

    python3 -m venv .venv
    .venv/bin/pip install -r requirements.txt
    .venv/bin/uvicorn app.main:app --port 8000

The service runs on AWS ECS Fargate in us-west-2, as `frostline-api` in the cluster
`frostline-cluster`. `infra/bootstrap-service.sh` creates that service once.
