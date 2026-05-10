from contextlib import asynccontextmanager
import logging
from typing import Any

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.utils import get_openapi
from fastapi.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

_log = logging.getLogger(__name__)


class _InnerErrorMiddleware:
    """Catch unhandled exceptions INSIDE CORSMiddleware so the 500 response
    still carries Access-Control-Allow-Origin headers.

    Starlette's ServerErrorMiddleware is the outermost wrapper; it calls
    `send` directly on the transport, bypassing CORSMiddleware's send wrapper.
    Placing this catcher between CORSMiddleware and ExceptionMiddleware means
    its response goes through the CORS wrapper and browsers receive a proper
    JSON 500 instead of a network-level "Failed to fetch".
    """

    def __init__(self, app: ASGIApp) -> None:
        self._app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return
        try:
            await self._app(scope, receive, send)
        except Exception as exc:
            _log.exception("Unhandled exception: %s", exc)
            response = JSONResponse(
                status_code=500,
                content={"detail": "Internal Server Error"},
            )
            await response(scope, receive, send)

from script_agent.__version__ import __version__
from script_agent.integrations.pocketbase.client import close_pb_client
from script_agent.api.routers.rag import router as rag_router
from script_agent.api.routers.quiz import router as quiz_router
from script_agent.config.settings import settings


def _openapi_patch_file_array_items(node: Any) -> None:
    """Align multipart file array items with OAS 3.0-style ``format: binary`` for Swagger UI.

    FastAPI >= 0.129.1 (pydantic JSON Schema) emits ``contentMediaType: application/octet-stream``
    without ``format: binary`` on ``list[UploadFile]`` items; bundled Swagger UI then shows plain
    string inputs (see https://github.com/fastapi/fastapi/discussions/14975). Upstream fix is the
    same idea: https://github.com/fastapi/fastapi/pull/15069 — remove this patch after that lands
    in your FastAPI version and you upgrade.
    """
    if isinstance(node, dict):
        if node.get("type") == "array":
            items = node.get("items")
            if isinstance(items, dict) and items.get("type") == "string":
                if items.get("contentMediaType") == "application/octet-stream":
                    items["format"] = "binary"
        for v in node.values():
            _openapi_patch_file_array_items(v)
    elif isinstance(node, list):
        for v in node:
            _openapi_patch_file_array_items(v)


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    close_pb_client()


def _configure_cors(app: FastAPI) -> None:
    """Flutter web and other browsers block cross-origin calls without CORS headers."""
    raw = (settings.cors_origins or "").strip()
    if raw:
        origins = [o.strip() for o in raw.split(",") if o.strip()]
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
            allow_private_network=True,
        )
        return
    # Dev default: wildcard works with Bearer auth when the browser does not use
    # credentials=include (Dart http BrowserClient). Regex + credentials=True is
    # stricter and some Flutter web origins still failed with "Failed to fetch".
    # allow_private_network: Chrome sends Access-Control-Request-Private-Network on
    # cross-port localhost (e.g. Flutter web :xxxxx -> API :8000); without this,
    # Starlette returns 400 "Disallowed CORS private-network" on preflight.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
        allow_private_network=True,
    )


def create_app() -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    # add_middleware inserts at index 0 (becomes outermost user middleware).
    # We add _InnerErrorMiddleware first so _configure_cors can then insert
    # CORSMiddleware at index 0 on top of it, making the final stack:
    #   ServerErrorMiddleware → CORSMiddleware → _InnerErrorMiddleware → ExceptionMiddleware → Router
    # This ensures unhandled-exception 500 responses pass through the CORS send wrapper.
    app.add_middleware(_InnerErrorMiddleware)
    _configure_cors(app)
    app.include_router(rag_router)
    app.include_router(quiz_router)

    def custom_openapi() -> dict[str, Any]:
        if app.openapi_schema:
            return app.openapi_schema
        openapi_schema = get_openapi(
            title=app.title,
            version=__version__,
            openapi_version=app.openapi_version,
            routes=app.routes,
        )
        for schema in openapi_schema.get("components", {}).get("schemas", {}).values():
            if isinstance(schema, dict):
                _openapi_patch_file_array_items(schema)
        app.openapi_schema = openapi_schema
        return app.openapi_schema

    app.openapi = custom_openapi  # type: ignore[method-assign]

    @app.get("/")
    def index():
        return {
            "version": __version__,
            "message": "Everything working fine!"
        }

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=settings.host, port=settings.port)
