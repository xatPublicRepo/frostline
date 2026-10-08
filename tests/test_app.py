from fastapi.testclient import TestClient

from app.main import app


def test_health_is_ok():
    with TestClient(app) as client:
        response = client.get("/health")

    assert response.status_code == 200

    data = response.json()
    assert data["status"] == "ok"


def test_predict_returns_a_verdict():
    reading = {
        "air_temp_c": 1.5,
        "dew_point_c": -1.0,
        "wind_speed_ms": 0.8,
        "cloud_cover_pct": 10,
    }

    with TestClient(app) as client:
        response = client.post("/predict", json=reading)

    assert response.status_code == 200

    data = response.json()
    assert 0 <= data["frost_probability"] <= 1
    assert data["threshold"] == 0.35


def test_frosty_night_scores_higher_than_mild_one():
    frosty = {
        "air_temp_c": 1.5,
        "dew_point_c": -1.0,
        "wind_speed_ms": 0.8,
        "cloud_cover_pct": 10,
    }

    mild = {
        "air_temp_c": 9.0,
        "dew_point_c": 4.0,
        "wind_speed_ms": 3.5,
        "cloud_cover_pct": 80,
    }

    with TestClient(app) as client:
        frosty_response = client.post("/predict", json=frosty)
        mild_response = client.post("/predict", json=mild)

    assert frosty_response.status_code == 200
    assert mild_response.status_code == 200

    frosty_data = frosty_response.json()
    mild_data = mild_response.json()

    assert frosty_data["frost_probability"] > mild_data["frost_probability"]
    assert frosty_data["alert"] is True
    assert mild_data["alert"] is False


def test_impossible_reading_is_rejected():
    impossible = {
        "air_temp_c": 1.5,
        "dew_point_c": -1.0,
        "wind_speed_ms": -1,
        "cloud_cover_pct": 10,
    }

    with TestClient(app) as client:
        response = client.post("/predict", json=impossible)

    assert response.status_code == 422
