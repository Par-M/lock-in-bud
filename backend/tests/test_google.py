import time

import pytest
import rsa
from google.auth import crypt, jwt

from app.core.config import settings
from app.services.google import GoogleTokenVerificationError, google_id_token, verify_google_id_token


@pytest.fixture(scope="module")
def google_keys():
    return rsa.newkeys(1024)


@pytest.fixture
def signed_google_token(monkeypatch, google_keys):
    public_key, private_key = google_keys
    monkeypatch.setattr(settings, "google_client_id", "native-client.apps.googleusercontent.com")
    monkeypatch.setattr(settings, "google_web_client_id", "web-client.apps.googleusercontent.com")
    monkeypatch.setattr(google_id_token, "_fetch_certs", lambda *args: {"test-key": public_key.save_pkcs1()})
    signer = crypt.RSASigner.from_string(private_key.save_pkcs1(), key_id="test-key")

    def encode(audience, *, expired=False, issuer="https://accounts.google.com"):
        now = int(time.time())
        return jwt.encode(signer, {
            "iss": issuer, "sub": "google-test-user", "aud": audience,
            "iat": now - 60, "exp": now - 30 if expired else now + 3600,
        }).decode()

    return encode


@pytest.mark.parametrize("client", ["native", "web"])
def test_google_accepts_configured_audiences(signed_google_token, client):
    audience = f"{client}-client.apps.googleusercontent.com"
    claims = verify_google_id_token(signed_google_token(audience))
    assert claims["aud"] == audience
    assert claims["sub"] == "google-test-user"


@pytest.mark.parametrize("failure", ["audience", "expiry", "issuer", "signature"])
def test_google_still_rejects_invalid_tokens(signed_google_token, failure):
    token = signed_google_token(
        "unknown-client.apps.googleusercontent.com" if failure == "audience" else "web-client.apps.googleusercontent.com",
        expired=failure == "expiry",
        issuer="https://evil.example" if failure == "issuer" else "https://accounts.google.com",
    )
    if failure == "signature":
        content, signature = token.rsplit(".", 1)
        token = content + "." + ("A" if signature[0] != "A" else "B") + signature[1:]
    with pytest.raises(GoogleTokenVerificationError):
        verify_google_id_token(token)


def test_google_without_any_audience_fails_closed(monkeypatch):
    monkeypatch.setattr(settings, "google_client_id", "")
    monkeypatch.setattr(settings, "google_web_client_id", "  ")
    with pytest.raises(GoogleTokenVerificationError, match="not configured"):
        verify_google_id_token("untrusted-token")
