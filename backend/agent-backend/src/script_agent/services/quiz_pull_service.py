from __future__ import annotations

import hashlib
import json
import random
from datetime import UTC, datetime
from typing import Any

import httpx

from script_agent.core.collections import CURRICULUM_ITEMS, QUIZ_QUESTIONS, QUIZ_SESSIONS
from script_agent.domain import quiz_models
from script_agent.integrations.pocketbase.client import (
    pb_create_json_record,
    pb_get_record,
    pb_list_records,
    pb_patch_json,
)
from script_agent.services import quiz_session_service as qsvc


def _session_owner_id(session: dict[str, Any]) -> str:
    owner = session.get("owner")
    if isinstance(owner, list):
        owner = owner[0] if owner else None
    return str(owner or "")


def _item_ids_from_session(session: dict[str, Any]) -> list[str]:
    raw = session.get("curriculumItemIds") or []
    if not isinstance(raw, list):
        return []
    return [str(v) for v in raw if v]


def _plan_seed(session_id: str) -> int:
    digest = hashlib.sha1(session_id.encode("utf-8")).hexdigest()
    return int(digest[:8], 16)


def _assessment_target(unit_count: int) -> int:
    bounded = max(5, min(12, unit_count + 2))
    return max(unit_count, bounded)


def _target_question_count(session: dict[str, Any], unit_count: int) -> int:
    kind = qsvc.session_kind_from_row(session)
    if kind == "assessment":
        return _assessment_target(unit_count)
    raw = session.get("questionCount")
    if raw is not None:
        try:
            return max(1, int(raw))
        except (TypeError, ValueError):
            pass
    return max(5, unit_count)


def _build_default_plan(*, session_id: str, item_ids: list[str], target_count: int) -> dict[str, Any]:
    if not item_ids:
        raise ValueError("session has no curriculum items")
    allocation = [item_ids[i % len(item_ids)] for i in range(target_count)]
    presentation = list(range(1, target_count + 1))
    rng = random.Random(_plan_seed(session_id))
    rng.shuffle(presentation)
    return {
        "targetQuestionCount": target_count,
        "allocation": allocation,
        "presentationOrder": presentation,
    }


def ensure_plan(*, token: str, session: dict[str, Any], session_id: str) -> dict[str, Any]:
    raw = session.get("questionPlan")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            raw = None
    if isinstance(raw, dict):
        return raw
    item_ids = _item_ids_from_session(session)
    plan = _build_default_plan(
        session_id=session_id,
        item_ids=item_ids,
        target_count=_target_question_count(session, len(item_ids)),
    )
    pb_patch_json(
        f"/api/collections/{QUIZ_SESSIONS}/records/{session_id}",
        token=token,
        json_body={"questionPlan": plan},
    )
    return plan


def _question_sort_key(row: dict[str, Any]) -> tuple[int, str, str]:
    plan_index = row.get("planIndex")
    try:
        idx = int(plan_index)
    except (TypeError, ValueError):
        idx = 10**9
    created = str(row.get("created") or row.get("updated") or "")
    return (idx, created, str(row.get("id") or ""))


def _list_session_questions(*, token: str, session_id: str) -> list[dict[str, Any]]:
    rows = pb_list_records(QUIZ_QUESTIONS, token=token, filter_expr=f'session="{session_id}"')
    return sorted(rows, key=_question_sort_key)


def _question_for_request(*, token: str, session_id: str, request_id: str) -> dict[str, Any] | None:
    rows = pb_list_records(
        QUIZ_QUESTIONS,
        token=token,
        filter_expr=f'session="{session_id}"&&requestId="{request_id}"',
        per_page=1,
    )
    return rows[0] if rows else None


def _normalize_stem(text: str) -> str:
    return " ".join("".join(ch if ch.isalnum() else " " for ch in text.lower()).split())[:600]


def _stem_from_row(row: dict[str, Any]) -> str:
    raw = row.get("content") or {}
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            raw = {}
    try:
        parsed = quiz_models.parse_quiz_question_content(raw)
    except Exception:
        return ""
    if parsed.type == "multiple_choice":
        return parsed.multiple_choice.stem
    return parsed.free_text.stem


def _is_too_similar(norm: str, existing_norms: list[str]) -> bool:
    if not norm:
        return False
    for item in existing_norms:
        if not item:
            continue
        if norm == item:
            return True
        if len(norm) > 32 and (norm in item or item in norm):
            return True
    return False


def _question_row_by_plan_index(rows: list[dict[str, Any]], plan_index: int) -> dict[str, Any] | None:
    for row in rows:
        try:
            idx = int(row.get("planIndex"))
        except (TypeError, ValueError):
            continue
        if idx == plan_index:
            return row
    return None


def _current_plan_index(plan: dict[str, Any], rows: list[dict[str, Any]]) -> int | None:
    order_raw = plan.get("presentationOrder") or []
    order = [int(v) for v in order_raw if isinstance(v, int) or str(v).isdigit()]
    for pidx in order:
        row = _question_row_by_plan_index(rows, pidx)
        if row is None:
            return pidx
        if row.get("answerPayload") is None:
            return pidx
    return None


def _question_wire(row: dict[str, Any]) -> dict[str, Any]:
    raw = row.get("content") or {}
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            raw = {}
    question = quiz_models.parse_quiz_question_content(raw).model_dump(mode="json")
    return {
        "id": str(row["id"]),
        "planIndex": int(row.get("planIndex") or 0),
        "curriculumItemId": str(row.get("curriculumItemId") or ""),
        "kind": str(row.get("kind") or ""),
        "question": question,
        "answered": row.get("answerPayload") is not None,
    }


def _progress_payload(*, plan: dict[str, Any], rows: list[dict[str, Any]]) -> dict[str, Any]:
    target = int(plan.get("targetQuestionCount") or 0)
    answered = 0
    coverage: dict[str, int] = {}
    for row in rows:
        if row.get("answerPayload") is not None:
            answered += 1
        item_id = str(row.get("curriculumItemId") or "")
        if item_id:
            coverage[item_id] = coverage.get(item_id, 0) + 1
    return {
        "targetQuestions": target,
        "generatedQuestions": len(rows),
        "answeredQuestions": answered,
        "remainingQuestions": max(0, target - answered),
        "coverageByUnit": coverage,
    }


def _criteria_payload(*, session: dict[str, Any], item_ids: list[str]) -> dict[str, Any]:
    kind = qsvc.session_kind_from_row(session)
    return {
        "sessionKind": kind,
        "minQuestions": 5 if kind == "assessment" else 1,
        "maxQuestions": 12 if kind == "assessment" else None,
        "atLeastOnePerUnit": kind == "assessment",
        "unitCount": len(item_ids),
    }


def _build_generation_context(*, token: str, curriculum_item_id: str) -> tuple[str, str]:
    row = pb_get_record(CURRICULUM_ITEMS, curriculum_item_id, token=token)
    title = str(row.get("title") or "").strip() or "(untitled)"
    summary = str(row.get("summaryDocument") or "").strip()
    return title, summary


def _create_question_for_plan_index(
    *,
    token: str,
    session: dict[str, Any],
    session_id: str,
    plan: dict[str, Any],
    plan_index: int,
    request_id: str | None,
    rows: list[dict[str, Any]],
) -> dict[str, Any]:
    existing = _question_row_by_plan_index(rows, plan_index)
    if existing:
        if request_id and not str(existing.get("requestId") or "").strip():
            pb_patch_json(
                f"/api/collections/{QUIZ_QUESTIONS}/records/{existing['id']}",
                token=token,
                json_body={"requestId": request_id},
            )
            existing["requestId"] = request_id
        return existing

    from script_agent.agents import subject_quiz_agent as sq

    allocation = plan.get("allocation") or []
    if plan_index < 1 or plan_index > len(allocation):
        raise ValueError("plan index is out of range")
    curriculum_item_id = str(allocation[plan_index - 1] or "").strip()
    if not curriculum_item_id:
        raise ValueError("plan allocation is missing curriculum item id")
    title, summary = _build_generation_context(token=token, curriculum_item_id=curriculum_item_id)
    asked_stems: list[str] = []
    for row in rows:
        stem = _stem_from_row(row)
        if stem:
            asked_stems.append(stem)
    existing_norms = [_normalize_stem(stem) for stem in asked_stems]

    structured: quiz_models.QuizQuestionStructured | None = None
    for _ in range(2):
        try:
            structured = sq.generate_single_question_for_unit(
                subject=str(session.get("subject") or "").strip(),
                grade=int(session.get("grade") or 0),
                session_kind=qsvc.session_kind_from_row(session),
                question_index=plan_index,
                total_questions=int(plan.get("targetQuestionCount") or 0),
                curriculum_item_title=title,
                curriculum_item_summary=summary,
                asked_stems=asked_stems,
            )
        except Exception:
            structured = qsvc.placeholder_mc_question()
        norm = _normalize_stem(
            structured.multiple_choice.stem
            if structured.type == "multiple_choice"
            else structured.free_text.stem
        )
        if not _is_too_similar(norm, existing_norms):
            break
        asked_stems.append(
            structured.multiple_choice.stem
            if structured.type == "multiple_choice"
            else structured.free_text.stem
        )
        existing_norms.append(norm)

    if structured is None:
        structured = qsvc.placeholder_mc_question()
    kind, content = quiz_models.structured_question_to_pb_rows(structured)
    stem = (
        structured.multiple_choice.stem
        if structured.type == "multiple_choice"
        else structured.free_text.stem
    )
    body: dict[str, Any] = {
        "owner": _session_owner_id(session),
        "session": session_id,
        "toolCallId": f"slot:{plan_index}",
        "kind": kind,
        "content": content,
        "planIndex": plan_index,
        "curriculumItemId": curriculum_item_id,
        "stemNorm": _normalize_stem(stem),
    }
    if request_id:
        body["requestId"] = request_id
    try:
        return pb_create_json_record(QUIZ_QUESTIONS, token=token, body=body)
    except httpx.HTTPStatusError:
        rows_refreshed = _list_session_questions(token=token, session_id=session_id)
        existing_after_race = _question_row_by_plan_index(rows_refreshed, plan_index)
        if existing_after_race:
            return existing_after_race
        raise


def _prefetch_plan_indices(*, plan: dict[str, Any], current_index: int, rows: list[dict[str, Any]], count: int) -> list[int]:
    if count <= 0:
        return []
    order_raw = plan.get("presentationOrder") or []
    order = [int(v) for v in order_raw if isinstance(v, int) or str(v).isdigit()]
    if current_index not in order:
        return []
    start = order.index(current_index) + 1
    result: list[int] = []
    for idx in order[start:]:
        if _question_row_by_plan_index(rows, idx) is not None:
            continue
        result.append(idx)
        if len(result) >= count:
            return result
    return result


def get_next_question(
    *,
    token: str,
    user_id: str,
    session_id: str,
    request_id: str,
    prefetch_count: int = 0,
) -> dict[str, Any]:
    if not request_id.strip():
        raise ValueError("request_id is required")
    session = qsvc.load_quiz_session(token=token, session_id=session_id, user_id=user_id)
    plan = ensure_plan(token=token, session=session, session_id=session_id)

    existing_by_request = _question_for_request(
        token=token, session_id=session_id, request_id=request_id
    )
    rows = _list_session_questions(token=token, session_id=session_id)
    if existing_by_request:
        progress = _progress_payload(plan=plan, rows=rows)
        return {
            "question": _question_wire(existing_by_request),
            "progress": progress,
            "criteria": _criteria_payload(session=session, item_ids=_item_ids_from_session(session)),
            "done": progress["remainingQuestions"] == 0,
            "idempotent": True,
            "prefetched": [],
        }

    current_index = _current_plan_index(plan, rows)
    if current_index is None:
        progress = _progress_payload(plan=plan, rows=rows)
        return {
            "question": None,
            "progress": progress,
            "criteria": _criteria_payload(session=session, item_ids=_item_ids_from_session(session)),
            "done": True,
            "idempotent": False,
            "prefetched": [],
        }

    current_row = _create_question_for_plan_index(
        token=token,
        session=session,
        session_id=session_id,
        plan=plan,
        plan_index=current_index,
        request_id=request_id,
        rows=rows,
    )
    rows = _list_session_questions(token=token, session_id=session_id)
    prefetched: list[dict[str, Any]] = []
    for idx in _prefetch_plan_indices(
        plan=plan,
        current_index=current_index,
        rows=rows,
        count=max(0, min(prefetch_count, 2)),
    ):
        prefetched_row = _create_question_for_plan_index(
            token=token,
            session=session,
            session_id=session_id,
            plan=plan,
            plan_index=idx,
            request_id=None,
            rows=rows,
        )
        prefetched.append(_question_wire(prefetched_row))
        rows = _list_session_questions(token=token, session_id=session_id)

    progress = _progress_payload(plan=plan, rows=rows)
    return {
        "question": _question_wire(current_row),
        "progress": progress,
        "criteria": _criteria_payload(session=session, item_ids=_item_ids_from_session(session)),
        "done": progress["remainingQuestions"] == 0,
        "idempotent": False,
        "prefetched": prefetched,
    }


def submit_answer(
    *,
    token: str,
    user_id: str,
    session_id: str,
    question_id: str,
    selected_option_id: str | None,
    free_text: str | None,
    idempotency_key: str | None,
) -> dict[str, Any]:
    session = qsvc.load_quiz_session(token=token, session_id=session_id, user_id=user_id)
    row = pb_get_record(QUIZ_QUESTIONS, question_id, token=token)
    q_sess = row.get("session")
    if isinstance(q_sess, list):
        q_sess = q_sess[0] if q_sess else None
    if str(q_sess) != session_id:
        raise KeyError("quiz question not found")
    existing = qsvc.fetch_answer_for_question(
        token=token, session_id=session_id, question_id=question_id
    )
    if existing:
        rows = _list_session_questions(token=token, session_id=session_id)
        plan = ensure_plan(token=token, session=session, session_id=session_id)
        return {
            "status": "answer_idempotent",
            "questionId": question_id,
            "progress": _progress_payload(plan=plan, rows=rows),
        }

    raw_content = row.get("content") or {}
    if isinstance(raw_content, str):
        raw_content = json.loads(raw_content)
    structured = quiz_models.parse_quiz_question_content(raw_content)
    if structured.type == "multiple_choice":
        selected = str(selected_option_id or "").strip()
        if not selected:
            raise ValueError("selected_option_id is required for multiple_choice")
        payload: dict[str, Any] = {"selectedOptionId": selected}
        correct = selected == structured.multiple_choice.correct_option_id
    else:
        text = str(free_text or "").strip()
        if not text:
            raise ValueError("free_text is required for free_text question")
        payload = {"text": text}
        correct = None

    qsvc.persist_answer(
        token=token,
        session_id=session_id,
        question_id=question_id,
        payload=payload,
        correct=correct,
        idempotency_key=idempotency_key,
    )
    rows = _list_session_questions(token=token, session_id=session_id)
    plan = ensure_plan(token=token, session=session, session_id=session_id)
    return {
        "status": "ok",
        "questionId": question_id,
        "progress": _progress_payload(plan=plan, rows=rows),
    }


def get_progress(*, token: str, user_id: str, session_id: str) -> dict[str, Any]:
    session = qsvc.load_quiz_session(token=token, session_id=session_id, user_id=user_id)
    plan = ensure_plan(token=token, session=session, session_id=session_id)
    rows = _list_session_questions(token=token, session_id=session_id)
    current_index = _current_plan_index(plan, rows)
    current_row = _question_row_by_plan_index(rows, current_index) if current_index else None
    return {
        "progress": _progress_payload(plan=plan, rows=rows),
        "criteria": _criteria_payload(session=session, item_ids=_item_ids_from_session(session)),
        "currentQuestion": _question_wire(current_row) if current_row else None,
        "done": current_index is None,
    }


def create_evaluation_snapshot(
    *,
    token: str,
    user_id: str,
    session_id: str,
    request_id: str,
    label: str | None,
) -> dict[str, Any]:
    if not request_id.strip():
        raise ValueError("request_id is required")
    session = qsvc.load_quiz_session(token=token, session_id=session_id, user_id=user_id)
    rows = _list_session_questions(token=token, session_id=session_id)
    plan = ensure_plan(token=token, session=session, session_id=session_id)
    raw = session.get("evaluationSnapshots") or []
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            raw = []
    snapshots = raw if isinstance(raw, list) else []
    for snap in snapshots:
        if isinstance(snap, dict) and str(snap.get("requestId") or "") == request_id:
            return {"evaluation": snap, "idempotent": True}

    from script_agent.agents import subject_quiz_agent as sq

    qa_summary = sq._build_qa_summary(token=token, session_id=session_id)
    if sq.subject_quiz_agent_llm_ready():
        try:
            review = sq.generate_evaluation_from_qa_summary(
                session_kind=qsvc.session_kind_from_row(session),
                qa_summary=qa_summary,
            )
        except Exception as e:
            review = f"Evaluation temporarily unavailable: {str(e)[:300]}"
    else:
        review = "Evaluation not available (LLM not configured)."

    answered_count = sum(1 for row in rows if row.get("answerPayload") is not None)
    snapshot = {
        "requestId": request_id,
        "label": (label or "").strip() or "evaluation",
        "text": review,
        "answeredCount": answered_count,
        "targetQuestionCount": int(plan.get("targetQuestionCount") or 0),
        "createdAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
    }
    snapshots.append(snapshot)
    pb_patch_json(
        f"/api/collections/{QUIZ_SESSIONS}/records/{session_id}",
        token=token,
        json_body={"evaluationSnapshots": snapshots},
    )
    return {"evaluation": snapshot, "idempotent": False}
