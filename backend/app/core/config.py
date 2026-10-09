from pydantic_settings import BaseSettings
from pydantic_settings import SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env")

    database_url: str
    jwt_secret: str
    gemini_api_key: str = ""

    google_client_id: str = ""
    google_web_client_id: str = ""

    enable_dev_auth: bool = False

    access_token_expire_minutes: int = 15
    refresh_token_expire_days: int = 30

    apns_key_id: str = ""
    apns_team_id: str = ""
    apns_bundle_id: str = ""
    apns_key_path: str = ""
    apns_environment: str = "sandbox"

    # Chat/Assistant settings
    gemini_chat_model: str = "gemini-3.5-flash-lite"
    chat_rate_limit_rpm: int = 10
    chat_rate_limit_rph: int = 60
    chat_rate_limit_rpd: int = 100
    chat_max_context_messages: int = 20
    chat_max_turns: int = 8
    chat_include_context: bool = True
    chat_context_max_chars: int = 4000
    chat_history_max_chars: int = 24000
    chat_turn_timeout_seconds: float = 80.0


settings = Settings()
