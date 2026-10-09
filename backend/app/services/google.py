from google.auth.exceptions import GoogleAuthError
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token as google_id_token

from app.core.config import settings


class GoogleTokenVerificationError(Exception):
    pass


def verify_google_id_token(id_token: str) -> dict:
    audiences = [
        client_id.strip()
        for client_id in (settings.google_client_id, settings.google_web_client_id)
        if client_id.strip()
    ]
    if not audiences:
        raise GoogleTokenVerificationError(
            "GOOGLE_CLIENT_ID is not configured"
        )

    try:
        return google_id_token.verify_oauth2_token(
            id_token,
            google_requests.Request(),
            audience=audiences,
        )
    except (ValueError, GoogleAuthError) as exc:
        raise GoogleTokenVerificationError(str(exc)) from exc
