"""Environment-only configuration for the orders service (12-factor)."""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Service configuration, populated exclusively from environment variables."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    port: int = 8080
    database_url: str = "postgresql://ztd:ztd@localhost:5432/ztd"
    catalog_url: str = "http://localhost:8081"
    otel_service_name: str = "orders"
    otel_exporter_otlp_endpoint: str = "http://localhost:4318"


settings = Settings()
