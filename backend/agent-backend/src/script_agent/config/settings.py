from pathlib import Path

from pydantic_settings import BaseSettings
from dotenv import load_dotenv

load_dotenv()


class Settings(BaseSettings):
    """
    **Agents** (LangGraph, prompts, per-agent LLM sampling) live under ``script_agent/agents/``;
    you edit those files. Shared LLM **host + API key** only live here (``SCRIPT_LLM_*``).
    """

    debug: bool = False
    port: int = 8000
    host: str = "0.0.0.0"

    # Comma-separated allowed browser origins (sets CORS + credentials).
    # If empty, dev uses Allow-Origin: * (see factory); set this in production.
    cors_origins: str | None = None

    pocketbase_url: str = "http://127.0.0.1:8090"
    # Local dev: POST auth-with-password as this user (never commit real values).
    pocketbase_dev_identity: str | None = None
    pocketbase_dev_password: str | None = None

    user_folder: Path = Path.home() / ".script_app" / "user_data"
    chroma_summaries_collection: str = "curriculum_summaries"

    # --- Shared across all LLM agents (OpenAI-compatible HTTP) -------------------------
    llm_base_url: str | None = None
    """e.g. https://api.openai.com/v1 or http://localhost:11434/v1 — trailing slash optional."""

    llm_api_key: str | None = None
    """Bearer for the OpenAI-compatible server (every agent may override in its own module dict)."""

    class Config:
        env_prefix = "SCRIPT_"
        env_file = ".env"
        env_file_encoding = "utf-8"


settings = Settings()
settings.user_folder.mkdir(parents=True, exist_ok=True)
