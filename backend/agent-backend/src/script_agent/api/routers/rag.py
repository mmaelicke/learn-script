from __future__ import annotations

from typing import Annotated, Literal

import httpx
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from pydantic import BaseModel, ConfigDict, Field

from script_agent.agents.curriculum_unit_agent import curriculum_unit_agent_llm_ready
from script_agent.core.collections import CAPTURES, CURRICULUM_ITEMS
from script_agent.api.deps import AuthContext, get_auth_context
from script_agent.core.hierarchy import leaf_item_ids_in_subtree, pb_scope_filter
from script_agent.integrations.chroma import routing as chroma_routing
from script_agent.workers import jobs
from script_agent.integrations.pocketbase.models import effective_grade
from script_agent.integrations.pocketbase.client import pb_create_capture_record, pb_get_record, pb_list_records
from script_agent.integrations.chroma.store import ChromaScope

router = APIRouter(prefix="/api/v1", tags=["curriculum-rag"])


class CaptureIngestResult(BaseModel):
    id: str
    indexingStatus: str


class IngestCapturesResponse(BaseModel):
    captures: list[CaptureIngestResult]
    gradeUsed: int
    subject: str


class SearchRequest(BaseModel):
    subject: str
    query: str
    root_item_id: str | None = None
    n_results: int = 10


class SearchHit(BaseModel):
    item_id: str
    summary: str | None
    capture_ids: list[str]
    distance: float | None = None


class SearchResponse(BaseModel):
    hits: list[SearchHit]


class NotifyItemChangedBody(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    structural_only: bool = Field(default=False, alias="structuralOnly")


class StartCaptureProcessingResponse(BaseModel):
    status: Literal["enqueued", "skipped"]
    reason: str | None = None
    mode: Literal["reindex_items", "ingest_new"] | None = None
    curriculum_item_ids: list[str] = Field(default_factory=list)


@router.post("/ingest/captures", response_model=IngestCapturesResponse)
async def ingest_captures(
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
    subject: Annotated[str, Form()],
    files: list[UploadFile] = File(...),
) -> IngestCapturesResponse:
    subj = subject.strip()
    if not subj:
        raise HTTPException(status_code=400, detail="subject is required")
    if not files:
        raise HTTPException(status_code=400, detail="At least one file is required")

    user = ctx.user
    grade = effective_grade(user)
    created: list[CaptureIngestResult] = []
    capture_ids: list[str] = []

    for i, uf in enumerate(files):
        raw = await uf.read()
        if not raw:
            raise HTTPException(status_code=400, detail=f"Empty file: {uf.filename!r}")
        name = uf.filename or f"page_{i}.bin"
        # PocketBase rejects sortOrder 0 as blank (zero-value validation).
        row = pb_create_capture_record(
            token=ctx.token,
            owner_id=user.id,
            grade=grade,
            subject=subj,
            sort_order=i + 1,
            transcript="",
            indexing_status="pending",
            file_name=name,
            file_content=raw,
            content_type=uf.content_type,
        )
        cid = row["id"]
        capture_ids.append(cid)
        created.append(
            CaptureIngestResult(
                id=cid,
                indexingStatus=str(row.get("indexingStatus") or row.get("indexing_status") or "pending"),
            ),
        )

    await jobs.enqueue_post_ingest(
        token=ctx.token,
        user=user,
        subject=subj,
        capture_ids=capture_ids,
        grade=grade,
    )

    return IngestCapturesResponse(
        captures=created,
        gradeUsed=grade,
        subject=subj,
    )


@router.post(
    "/captures/{capture_id}/start-processing",
    response_model=StartCaptureProcessingResponse,
)
async def start_capture_processing(
    capture_id: str,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> StartCaptureProcessingResponse:
    """Re-run the unit agent for one page: existing curriculum rows → reindex; none → ingest-style."""
    try:
        row = pb_get_record(CAPTURES, capture_id, token=ctx.token)
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            raise HTTPException(status_code=404, detail="Capture not found") from e
        raise HTTPException(status_code=502, detail="PocketBase read failed") from e

    raw_o = row.get("owner")
    if isinstance(raw_o, list):
        owner = str(raw_o[0]) if raw_o else None
    else:
        owner = str(raw_o) if raw_o is not None else None
    if owner != ctx.user.id:
        raise HTTPException(status_code=404, detail="Capture not found")

    subj = str(row.get("subject") or "").strip()
    if not subj:
        raise HTTPException(status_code=400, detail="Capture has no subject")
    try:
        g = int(row.get("grade"))
    except (TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail="Capture has invalid grade") from e

    if not curriculum_unit_agent_llm_ready():
        return StartCaptureProcessingResponse(
            status="skipped",
            reason="llm_not_configured",
        )

    scope = ChromaScope(user_id=ctx.user.id, grade=g, subject=subj)
    item_ids = jobs.curriculum_item_ids_linking_capture(
        token=ctx.token,
        scope=scope,
        capture_id=capture_id,
    )
    mode: Literal["reindex_items", "ingest_new"] = (
        "reindex_items" if item_ids else "ingest_new"
    )
    await jobs.enqueue_capture_processing(
        token=ctx.token,
        user=ctx.user,
        capture_id=capture_id,
    )
    return StartCaptureProcessingResponse(
        status="enqueued",
        mode=mode,
        curriculum_item_ids=item_ids,
    )


@router.post("/search/curriculum-rag", response_model=SearchResponse)
def search_curriculum_rag(
    body: SearchRequest,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> SearchResponse:
    subj = body.subject.strip()
    if not subj:
        raise HTTPException(status_code=400, detail="subject is required")
    if not body.query.strip():
        raise HTTPException(status_code=400, detail="query is required")

    user = ctx.user
    grade = effective_grade(user)
    leaf_ids: list[str] | None = None

    if body.root_item_id:
        root = pb_get_record(CURRICULUM_ITEMS, body.root_item_id, token=ctx.token)
        owner = root.get("owner")
        if isinstance(owner, list):
            owner = owner[0] if owner else None
        if str(owner) != user.id:
            raise HTTPException(status_code=404, detail="root_item_id not found")
        r_subj = str(root.get("subject") or "").strip()
        if r_subj != subj:
            raise HTTPException(
                status_code=400,
                detail="subject must match the subtree root curriculum item",
            )
        try:
            grade = int(root.get("grade"))
        except (TypeError, ValueError) as e:
            raise HTTPException(status_code=400, detail="root item has invalid grade") from e
        flt = pb_scope_filter(owner_id=user.id, subject=subj, grade=grade)
        items = pb_list_records(CURRICULUM_ITEMS, token=ctx.token, filter_expr=flt)
        leaf_ids = leaf_item_ids_in_subtree(items, body.root_item_id)

    scope = ChromaScope(user_id=user.id, grade=grade, subject=subj)

    try:
        raw = chroma_routing.query_summaries(
            scope,
            query_text=body.query,
            n_results=body.n_results,
            leaf_item_ids=leaf_ids,
        )
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Chroma query failed: {e!s}") from e

    hits: list[SearchHit] = []
    ids_batch = raw.get("ids") or [[]]
    docs_batch = raw.get("documents") or [[]]
    meta_batch = raw.get("metadatas") or [[]]
    dist_batch = raw.get("distances") or [[]]
    if not ids_batch:
        return SearchResponse(hits=[])
    ids0 = ids_batch[0] or []
    docs0 = docs_batch[0] if docs_batch else []
    meta0 = meta_batch[0] if meta_batch else []
    dist0 = dist_batch[0] if dist_batch else []
    for i, vid in enumerate(ids0):
        meta = meta0[i] if i < len(meta0) and meta0 else None
        doc = docs0[i] if i < len(docs0) else None
        dist = dist0[i] if i < len(dist0) else None
        cap_raw = (meta or {}).get("capture_ids") or ""
        cap_ids = [c for c in str(cap_raw).split(",") if c]
        iid = str((meta or {}).get("item_id") or vid)
        hits.append(
            SearchHit(
                item_id=iid,
                summary=doc,
                capture_ids=cap_ids,
                distance=float(dist) if dist is not None else None,
            ),
        )
    return SearchResponse(hits=hits)


@router.post("/curriculum/items/{item_id}/notify-changed")
async def notify_item_changed(
    item_id: str,
    body: NotifyItemChangedBody,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> dict[str, str]:
    row = pb_get_record(CURRICULUM_ITEMS, item_id, token=ctx.token)
    owner = row.get("owner")
    if isinstance(owner, list):
        owner = owner[0] if owner else None
    if str(owner) != ctx.user.id:
        raise HTTPException(status_code=404, detail="Item not found")
    subj = str(row.get("subject") or "").strip()
    if not subj:
        raise HTTPException(status_code=400, detail="Item has no subject")
    try:
        g = int(row.get("grade"))
    except (TypeError, ValueError) as e:
        raise HTTPException(status_code=400, detail="Item has invalid grade") from e

    scope = ChromaScope(user_id=ctx.user.id, grade=g, subject=subj)
    await jobs.enqueue_item_reindex(
        token=ctx.token,
        scope=scope,
        item_id=item_id,
        structural_only=body.structural_only,
    )
    return {"status": "enqueued"}
