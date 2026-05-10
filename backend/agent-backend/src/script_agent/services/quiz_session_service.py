"""Quiz session validation, persistence, and answer checking."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

import httpx

from script_agent.core.collections import (
    CURRICULUM_ITEMS,
    QUIZ_QUESTIONS,
    QUIZ_SESSION_OUTCOMES,
    QUIZ_SESSIONS,
)
from script_agent.domain import quiz_models
from script_agent.integrations.pocketbase.client import (
    pb_create_json_record,
    pb_get_record,
    pb_list_records,
    pb_patch_json,
)
from script_agent.integrations.pocketbase.models import UserRecord


def validate_curriculum_item_ids(
    *,
    token: str,
    user: UserRecord,
    subject: str,
    grade: int,
    item_ids: list[str],
) -> None:
    """Raises ValueError if any id is missing or out of owner/subject/grade scope."""
    if not item_ids:
        raise ValueError("curriculum_item_ids must be non-empty")
    subj = subject.strip()
    for iid in item_ids:
        row = pb_get_record(CURRICULUM_ITEMS, iid, token=token)
        owner = row.get("owner")
        if isinstance(owner, list):
            owner = owner[0] if owner else None
        if str(owner) != user.id:
            raise ValueError(f"curriculum_item not found: {iid}")
        r_subj = str(row.get("subject") or "").strip()
        if r_subj != subj:
            raise ValueError(f"subject mismatch for curriculum item {iid}")
        try:
            g = int(row.get("grade"))
        except (TypeError, ValueError) as e:
            raise ValueError(f"invalid grade on curriculum item {iid}") from e
        if g != grade:
            raise ValueError(f"grade mismatch for curriculum item {iid}")


def load_quiz_session(*, token: str, session_id: str, user_id: str) -> dict[str, Any]:
    row = pb_get_record(QUIZ_SESSIONS, session_id, token=token)
    owner = row.get("owner")
    if isinstance(owner, list):
        owner = owner[0] if owner else None
    if str(owner) != user_id:
        raise KeyError("quiz session not found")
    return row


def fetch_answer_for_question(
    *, token: str, session_id: str, question_id: str
) -> dict[str, Any] | None:
    try:
        row = pb_get_record(QUIZ_QUESTIONS, question_id, token=token)
    except httpx.HTTPStatusError as e:
        if e.response is not None and e.response.status_code == 404:
            return None
        raise
    q_sess = row.get("session")
    if isinstance(q_sess, list):
        q_sess = q_sess[0] if q_sess else None
    if str(q_sess) != session_id:
        return None
    if row.get("answerPayload") is None:
        return None
    return row


def persist_answer(
    *,
    token: str,
    session_id: str,
    question_id: str,
    payload: dict[str, Any],
    correct: bool | None,
    idempotency_key: str | None,
) -> dict[str, Any]:
    existing = fetch_answer_for_question(
        token=token, session_id=session_id, question_id=question_id
    )
    if existing:
        return existing
    answered_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    body: dict[str, Any] = {
        "answerPayload": payload,
        "answeredAt": answered_at,
    }
    if correct is not None:
        body["answerCorrect"] = correct
    if idempotency_key:
        body["answerIdempotencyKey"] = idempotency_key
    return pb_patch_json(
        f"/api/collections/{QUIZ_QUESTIONS}/records/{question_id}",
        token=token,
        json_body=body,
    )


def placeholder_mc_question() -> quiz_models.QuizQuestionMultipleChoice:
    return quiz_models.QuizQuestionMultipleChoice(
        multiple_choice=quiz_models.QuizMultipleChoiceContent(
            stem="Sample exam prep question (placeholder): 2 + 2 = ?",
            options=[
                quiz_models.QuizMCOption(id="a", label="3"),
                quiz_models.QuizMCOption(id="b", label="4"),
                quiz_models.QuizMCOption(id="c", label="5"),
            ],
            correct_option_id="b",
        ),
    )


def session_kind_from_row(row: dict[str, Any]) -> str:
    raw = str(row.get("sessionKind") or "").strip().lower()
    if raw in ("assessment", "learn", "deepen"):
        return raw
    return "learn"


def patch_session_status(
    *,
    token: str,
    user_id: str,
    session_id: str,
    status: str,
) -> dict[str, Any]:
    load_quiz_session(token=token, session_id=session_id, user_id=user_id)
    path = f"/api/collections/{QUIZ_SESSIONS}/records/{session_id}"
    return pb_patch_json(path, token=token, json_body={"status": status})


def finish_quiz_session(
    *,
    token: str,
    user_id: str,
    session_id: str,
    outcome: quiz_models.SessionOutcomeDetails,
    review_text: str | None,
    final_status: str = "ended",
) -> dict[str, Any]:
    load_quiz_session(token=token, session_id=session_id, user_id=user_id)
    details = outcome.model_dump(mode="json")
    try:
        pb_create_json_record(
            QUIZ_SESSION_OUTCOMES,
            token=token,
            body={"session": session_id, "details": details},
        )
    except httpx.HTTPStatusError:
        rows = pb_list_records(
            QUIZ_SESSION_OUTCOMES,
            token=token,
            filter_expr=f'session="{session_id}"',
            per_page=1,
        )
        if rows:
            oid = rows[0]["id"]
            pb_patch_json(
                f"/api/collections/{QUIZ_SESSION_OUTCOMES}/records/{oid}",
                token=token,
                json_body={"details": details},
            )
        else:
            raise

    path = f"/api/collections/{QUIZ_SESSIONS}/records/{session_id}"
    return pb_patch_json(path, token=token, json_body={"status": final_status})


def check_quiz_question(
    *,
    token: str,
    user_id: str,
    question_id: str,
) -> dict[str, Any]:
    q_row = pb_get_record(QUIZ_QUESTIONS, question_id, token=token)
    q_sess = q_row.get("session")
    if isinstance(q_sess, list):
        q_sess = q_sess[0] if q_sess else None
    session_id = str(q_sess or "")
    if not session_id:
        raise KeyError("quiz session not found")
    load_quiz_session(token=token, session_id=session_id, user_id=user_id)

    payload = q_row.get("answerPayload")
    if payload is None:
        raise ValueError("question has no saved answer")
    if isinstance(payload, str):
        payload = json.loads(payload)
    if not isinstance(payload, dict):
        raise ValueError("question answer payload is invalid")

    raw_content: Any = q_row.get("content")
    if isinstance(raw_content, str):
        raw_content = json.loads(raw_content)
    if not isinstance(raw_content, dict):
        raise ValueError("question content is invalid")
    structured = quiz_models.parse_quiz_question_content(raw_content)
    checked_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")

    if structured.type == "multiple_choice":
        selected = str(payload.get("selectedOptionId") or "")
        if not selected:
            raise ValueError("multiple choice answer is missing selectedOptionId")
        correct = selected == structured.multiple_choice.correct_option_id
        label = next(
            (
                option.label
                for option in structured.multiple_choice.options
                if option.id == structured.multiple_choice.correct_option_id
            ),
            structured.multiple_choice.correct_option_id,
        )
        body = {
            "answerCorrect": correct,
            "answerScore": 1 if correct else 0,
            "answerComment": "Richtig." if correct else f"Nicht ganz. Richtig ist: {label}",
            "checkedAt": checked_at,
            "checkerKind": "rule",
            "checkError": "",
        }
    else:
        text = str(payload.get("text") or "").strip()
        if not text:
            raise ValueError("free text answer is empty")
        from script_agent.agents import subject_quiz_agent as sq

        try:
            result = sq.check_free_text_answer(
                stem=structured.free_text.stem,
                expected_answer=structured.free_text.expected_answer,
                rubric_hint=structured.free_text.rubric_hint,
                student_answer=text,
            )
        except Exception as e:
            body = {
                "checkedAt": checked_at,
                "checkerKind": "llm",
                "checkError": str(e)[:2000],
            }
            row = pb_patch_json(
                f"/api/collections/{QUIZ_QUESTIONS}/records/{question_id}",
                token=token,
                json_body=body,
            )
            return {"status": "error", "question": row}
        body = {
            "answerCorrect": result["correct"],
            "answerScore": result["score"],
            "answerComment": result["comment"],
            "checkedAt": checked_at,
            "checkerKind": "llm",
            "checkError": "",
        }

    row = pb_patch_json(
        f"/api/collections/{QUIZ_QUESTIONS}/records/{question_id}",
        token=token,
        json_body=body,
    )
    return {"status": "checked", "question": row}
