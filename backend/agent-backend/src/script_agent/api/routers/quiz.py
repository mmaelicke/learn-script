"""Exam prep quiz: deterministic pull flow, session lifecycle, finish/outcome."""

from __future__ import annotations

import json
from typing import Annotated, Literal

import httpx
from fastapi import APIRouter, Depends, Form, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from script_agent.api.deps import AuthContext, get_auth_context
from script_agent.core.collections import QUIZ_SESSIONS
from script_agent.domain import quiz_models
from script_agent.integrations.pocketbase.client import (
    pb_create_json_record,
    pb_list_records,
)
from script_agent.integrations.pocketbase.models import effective_grade
from script_agent.services import quiz_session_service as qsvc
from script_agent.services import quiz_pull_service as qp

router = APIRouter(prefix="/api/v1", tags=["quiz"])


class CreateQuizSessionBody(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    subject: str
    curriculum_item_ids: list[str] = Field(
        min_length=1,
        alias="curriculumItemIds",
    )
    question_count: int | None = Field(default=None, alias="questionCount")
    time_limit_seconds: int | None = Field(default=None, alias="timeLimitSeconds")
    session_kind: Literal["assessment", "learn", "deepen"] = Field(
        default="learn",
        alias="sessionKind",
    )
    progress_basis: Literal["questions", "time"] | None = Field(
        default=None,
        alias="progressBasis",
    )


class CreateQuizSessionResponse(BaseModel):
    model_config = ConfigDict(
        populate_by_name=True,
        ser_json_by_alias=True,
    )

    id: str
    status: str
    grade: int
    subject: str
    curriculum_item_ids: list[str] = Field(alias="curriculumItemIds")
    question_count: int | None = Field(default=None, alias="questionCount")
    time_limit_seconds: int | None = Field(default=None, alias="timeLimitSeconds")
    session_kind: str = Field(default="learn", alias="sessionKind")
    progress_basis: str = Field(default="questions", alias="progressBasis")


class PatchQuizSessionBody(BaseModel):
    status: Literal["active", "review", "ended"]


class NextQuizQuestionBody(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    request_id: str = Field(alias="requestId", min_length=1)
    prefetch_count: int = Field(default=0, alias="prefetchCount", ge=0, le=2)


class SubmitQuizAnswerBody(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    question_id: str = Field(alias="questionId")
    selected_option_id: str | None = Field(default=None, alias="selectedOptionId")
    free_text: str | None = Field(default=None, alias="freeText")
    idempotency_key: str | None = Field(default=None, alias="idempotencyKey")


class EvaluateQuizBody(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    request_id: str = Field(alias="requestId", min_length=1)
    label: str | None = None


class FinishQuizBody(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    outcome: quiz_models.SessionOutcomeDetails
    review_text: str | None = Field(default=None, alias="reviewText")
    status: Literal["ended", "review"] = "ended"


def _pb_filter_text(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _same_item_set(left: object, right: list[str]) -> bool:
    if not isinstance(left, list):
        return False
    left_ids = [str(value) for value in left if value]
    return len(left_ids) == len(right) and set(left_ids) == set(right)


def _session_response_from_row(
    row: dict,
    *,
    fallback_grade: int,
    fallback_subject: str,
    fallback_item_ids: list[str],
) -> CreateQuizSessionResponse:
    raw_ids = row.get("curriculumItemIds")
    item_ids = (
        [str(value) for value in raw_ids]
        if isinstance(raw_ids, list)
        else fallback_item_ids
    )
    sk = str(row.get("sessionKind") or "").strip().lower()
    if sk not in ("assessment", "learn", "deepen"):
        sk = "learn"
    pb = str(row.get("progressBasis") or "").strip().lower()
    if pb not in ("questions", "time"):
        pb = "questions"
    return CreateQuizSessionResponse(
        id=row["id"],
        status=str(row.get("status") or "active"),
        grade=int(row.get("grade") or fallback_grade),
        subject=str(row.get("subject") or fallback_subject),
        curriculumItemIds=item_ids,
        questionCount=row.get("questionCount"),
        timeLimitSeconds=row.get("timeLimitSeconds"),
        sessionKind=sk,
        progressBasis=pb,
    )


def create_quiz_session_core(
    body: CreateQuizSessionBody,
    ctx: AuthContext,
) -> CreateQuizSessionResponse:
    subj = body.subject.strip()
    if not subj:
        raise HTTPException(status_code=400, detail="subject is required")
    user = ctx.user
    grade = effective_grade(user)
    item_ids = list(dict.fromkeys(body.curriculum_item_ids))
    try:
        qsvc.validate_curriculum_item_ids(
            token=ctx.token,
            user=user,
            subject=subj,
            grade=grade,
            item_ids=item_ids,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    kind = body.session_kind
    if kind not in ("assessment", "learn", "deepen"):
        kind = "learn"

    q_count = body.question_count
    t_limit = body.time_limit_seconds
    if kind == "assessment":
        q_count = max(3, min(len(item_ids), 12))
        t_limit = None

    if body.progress_basis in ("questions", "time"):
        pbasis: str = body.progress_basis
    else:
        pbasis = (
            "questions"
            if q_count is not None
            else ("time" if t_limit is not None else "questions")
        )

    session_body: dict = {
        "owner": user.id,
        "grade": grade,
        "subject": subj,
        "status": "active",
        "curriculumItemIds": item_ids,
        "sessionKind": kind,
        "progressBasis": pbasis,
    }
    if q_count is not None:
        session_body["questionCount"] = q_count
    if t_limit is not None:
        session_body["timeLimitSeconds"] = t_limit

    existing_rows = pb_list_records(
        QUIZ_SESSIONS,
        token=ctx.token,
        filter_expr=(
            f'owner="{user.id}"&&grade={grade}&&subject="{_pb_filter_text(subj)}"'
            '&&status="active"'
        ),
    )
    for existing in existing_rows:
        if not _same_item_set(existing.get("curriculumItemIds"), item_ids):
            continue
        ex_kind = str(existing.get("sessionKind") or "").strip().lower()
        if ex_kind not in ("assessment", "learn", "deepen"):
            ex_kind = "learn"
        if ex_kind == kind:
            return _session_response_from_row(
                existing,
                fallback_grade=grade,
                fallback_subject=subj,
                fallback_item_ids=item_ids,
            )

    row = pb_create_json_record(QUIZ_SESSIONS, token=ctx.token, body=session_body)
    return _session_response_from_row(
        row,
        fallback_grade=grade,
        fallback_subject=subj,
        fallback_item_ids=item_ids,
    )


@router.post("/learn-deck/sessions", response_model=CreateQuizSessionResponse)
def create_quiz_session(
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
    subject: Annotated[str, Form()],
    curriculum_item_ids: Annotated[str, Form(alias="curriculumItemIds")],
    time_limit_seconds: Annotated[int | None, Form(alias="timeLimitSeconds")] = None,
    question_count: Annotated[int | None, Form(alias="questionCount")] = None,
    session_kind: Annotated[str | None, Form(alias="sessionKind")] = None,
    progress_basis: Annotated[str | None, Form(alias="progressBasis")] = None,
) -> CreateQuizSessionResponse:
    try:
        raw_ids = json.loads(curriculum_item_ids)
    except json.JSONDecodeError as e:
        raise HTTPException(
            status_code=400,
            detail="curriculumItemIds must be a JSON array of strings",
        ) from e
    if not isinstance(raw_ids, list):
        raise HTTPException(
            status_code=400,
            detail="curriculumItemIds must be a JSON array of strings",
        )
    item_ids = [str(x) for x in raw_ids if x]
    raw_body: dict = {
        "subject": subject,
        "curriculumItemIds": item_ids,
        "timeLimitSeconds": time_limit_seconds,
        "questionCount": question_count,
    }
    if session_kind is not None and str(session_kind).strip():
        raw_body["sessionKind"] = str(session_kind).strip().lower()
    if progress_basis is not None and str(progress_basis).strip():
        raw_body["progressBasis"] = str(progress_basis).strip().lower()
    body = CreateQuizSessionBody.model_validate(raw_body)
    return create_quiz_session_core(body, ctx)


@router.post("/learn-deck/sessions/{session_id}/next", response_model=dict)
def next_quiz_question(
    session_id: str,
    body: NextQuizQuestionBody,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> dict:
    try:
        return qp.get_next_question(
            token=ctx.token,
            user_id=ctx.user.id,
            session_id=session_id,
            request_id=body.request_id,
            prefetch_count=body.prefetch_count,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            raise HTTPException(status_code=404, detail="Quiz session not found") from e
        raise HTTPException(status_code=502, detail="PocketBase error") from e
    except KeyError as e:
        raise HTTPException(status_code=404, detail="Quiz session not found") from e


@router.post("/learn-deck/sessions/{session_id}/answer", response_model=dict)
def submit_quiz_answer(
    session_id: str,
    body: SubmitQuizAnswerBody,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> dict:
    try:
        return qp.submit_answer(
            token=ctx.token,
            user_id=ctx.user.id,
            session_id=session_id,
            question_id=body.question_id,
            selected_option_id=body.selected_option_id,
            free_text=body.free_text,
            idempotency_key=body.idempotency_key,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            raise HTTPException(status_code=404, detail="Quiz question not found") from e
        raise HTTPException(status_code=502, detail="PocketBase error") from e
    except KeyError as e:
        raise HTTPException(status_code=404, detail="Quiz question not found") from e


@router.get("/learn-deck/sessions/{session_id}/progress", response_model=dict)
def quiz_session_progress(
    session_id: str,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> dict:
    try:
        return qp.get_progress(token=ctx.token, user_id=ctx.user.id, session_id=session_id)
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            raise HTTPException(status_code=404, detail="Quiz session not found") from e
        raise HTTPException(status_code=502, detail="PocketBase error") from e
    except KeyError as e:
        raise HTTPException(status_code=404, detail="Quiz session not found") from e


@router.post("/learn-deck/sessions/{session_id}/evaluate", response_model=dict)
def evaluate_quiz_session(
    session_id: str,
    body: EvaluateQuizBody,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> dict:
    try:
        return qp.create_evaluation_snapshot(
            token=ctx.token,
            user_id=ctx.user.id,
            session_id=session_id,
            request_id=body.request_id,
            label=body.label,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            raise HTTPException(status_code=404, detail="Quiz session not found") from e
        raise HTTPException(status_code=502, detail="PocketBase error") from e
    except KeyError as e:
        raise HTTPException(status_code=404, detail="Quiz session not found") from e


@router.post("/learn-deck/questions/{question_id}/check", response_model=dict)
def check_quiz_question(
    question_id: str,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> dict:
    try:
        return qsvc.check_quiz_question(
            token=ctx.token,
            user_id=ctx.user.id,
            question_id=question_id,
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            raise HTTPException(status_code=404, detail="Quiz question not found") from e
        raise HTTPException(status_code=502, detail="PocketBase error") from e
    except KeyError as e:
        raise HTTPException(status_code=404, detail="Quiz question not found") from e


@router.patch("/learn-deck/sessions/{session_id}", response_model=dict[str, str])
def patch_quiz_session(
    session_id: str,
    body: PatchQuizSessionBody,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> dict[str, str]:
    try:
        qsvc.patch_session_status(
            token=ctx.token,
            user_id=ctx.user.id,
            session_id=session_id,
            status=body.status,
        )
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            raise HTTPException(status_code=404, detail="Quiz session not found") from e
        raise HTTPException(status_code=502, detail="PocketBase error") from e
    except KeyError as e:
        raise HTTPException(status_code=404, detail="Quiz session not found") from e
    return {"status": body.status}


@router.post("/learn-deck/sessions/{session_id}/finish", response_model=dict[str, str])
def finish_quiz_session(
    session_id: str,
    body: FinishQuizBody,
    ctx: Annotated[AuthContext, Depends(get_auth_context)],
) -> dict[str, str]:
    final = "ended" if body.status == "ended" else "review"
    try:
        qsvc.finish_quiz_session(
            token=ctx.token,
            user_id=ctx.user.id,
            session_id=session_id,
            outcome=body.outcome,
            review_text=body.review_text,
            final_status=final,
        )
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            raise HTTPException(status_code=404, detail="Quiz session not found") from e
        raise HTTPException(status_code=502, detail="PocketBase error") from e
    except KeyError as e:
        raise HTTPException(status_code=404, detail="Quiz session not found") from e
    return {"status": final}
