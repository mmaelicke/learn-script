from __future__ import annotations

from typing import Annotated

import httpx
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from script_agent.integrations.pocketbase.models import UserRecord
from script_agent.integrations.pocketbase.client import auth_refresh

http_bearer = HTTPBearer(auto_error=True)


class AuthContext(BaseModel):
    user: UserRecord
    token: str


def get_auth_context(
    credentials: Annotated[HTTPAuthorizationCredentials, Depends(http_bearer)],
) -> AuthContext:
    token = credentials.credentials.strip()
    if not token:
        raise HTTPException(status_code=401, detail="Empty bearer token")
    try:
        ar = auth_refresh(token)
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 401:
            raise HTTPException(status_code=401, detail="Invalid or expired token") from e
        raise HTTPException(status_code=502, detail="PocketBase auth refresh failed") from e
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail="PocketBase unreachable") from e
    return AuthContext(user=ar.record, token=token)
