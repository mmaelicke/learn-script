"""Quiz LLM helpers for deterministic pull flow."""

from __future__ import annotations

import json
from typing import Any

from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_openai import ChatOpenAI

from script_agent.config.settings import settings
from script_agent.core.collections import QUIZ_QUESTIONS
from script_agent.domain import quiz_models
from script_agent.integrations.pocketbase.client import pb_list_records

SUBJECT_QUIZ_AGENT_LLM: dict[str, Any] = {
    "model": "markus",
    "temperature": 0.35,
    "max_tokens": 2048,
    "recursion_limit": 24,
    "api_key": None,
    "base_url": None,
}


def _resolved_api_key() -> str:
    raw = SUBJECT_QUIZ_AGENT_LLM.get("api_key")
    if raw is not None and str(raw).strip():
        return str(raw).strip()
    key = (settings.llm_api_key or "").strip()
    if not key:
        raise ValueError(
            "No API key: set SUBJECT_QUIZ_AGENT_LLM['api_key'] or SCRIPT_LLM_API_KEY",
        )
    return key


def _resolved_base_url() -> str | None:
    raw = SUBJECT_QUIZ_AGENT_LLM.get("base_url")
    if raw is not None and str(raw).strip():
        return str(raw).strip().rstrip("/")
    base_url = (settings.llm_base_url or "").strip().rstrip("/")
    return base_url or None


def subject_quiz_agent_llm_ready() -> bool:
    try:
        _resolved_api_key()
        return True
    except ValueError:
        return False


def _chat_model() -> ChatOpenAI:
    kwargs: dict[str, Any] = {
        "model": str(SUBJECT_QUIZ_AGENT_LLM["model"]),
        "api_key": _resolved_api_key(),
        "temperature": float(SUBJECT_QUIZ_AGENT_LLM["temperature"]),
        "max_tokens": int(SUBJECT_QUIZ_AGENT_LLM["max_tokens"]),
    }
    base = _resolved_base_url()
    if base:
        kwargs["base_url"] = base
    return ChatOpenAI(**kwargs)


def _ai_text(message: AIMessage) -> str:
    content = message.content
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                parts.append(str(part.get("text") or ""))
            elif isinstance(part, str):
                parts.append(part)
        return "".join(parts)
    return str(content or "")


def _build_qa_summary(*, token: str, session_id: str) -> str:
    questions = pb_list_records(
        QUIZ_QUESTIONS,
        token=token,
        filter_expr=f'session="{session_id}"',
    )
    lines: list[str] = []
    for i, q_row in enumerate(questions, 1):
        raw_content = q_row.get("content") or {}
        if isinstance(raw_content, str):
            try:
                raw_content = json.loads(raw_content)
            except json.JSONDecodeError:
                raw_content = {}
        try:
            structured = quiz_models.parse_quiz_question_content(raw_content)
            if structured.type == "multiple_choice":
                stem = structured.multiple_choice.stem
                options_text = " / ".join(
                    f"{o.id}) {o.label}" for o in structured.multiple_choice.options
                )
                correct_id = structured.multiple_choice.correct_option_id
            else:
                stem = structured.free_text.stem
                options_text = None
                correct_id = structured.free_text.expected_answer or None
        except Exception:
            stem = "(question unavailable)"
            options_text = None
            correct_id = None

        answer_text = "(not answered)"
        verdict = ""
        payload = q_row.get("answerPayload")
        if payload is not None:
            if isinstance(payload, str):
                try:
                    payload = json.loads(payload)
                except Exception:
                    payload = {}
            if isinstance(payload, dict):
                if "selectedOptionId" in payload:
                    answer_text = f"option {payload['selectedOptionId']}"
                elif "text" in payload:
                    answer_text = f'"{payload["text"]}"'
            correct = q_row.get("answerCorrect")
            if correct is True:
                verdict = " [correct]"
            elif correct is False:
                verdict = " [incorrect]"

        line = f"Q{i}: {stem}"
        if options_text:
            line += f"\n  Options: {options_text}"
        if correct_id:
            label = "Expected answer" if options_text is None else "Correct answer"
            line += f"\n  {label}: {correct_id}"
        line += f"\n  Student answered: {answer_text}{verdict}"
        comment = str(q_row.get("answerComment") or "").strip()
        score = q_row.get("answerScore")
        if comment:
            line += f"\n  Check comment: {comment}"
        if score is not None:
            line += f"\n  Check score: {score}"
        lines.append(line)
    return "\n\n".join(lines) if lines else "(no questions recorded)"


def generate_single_question_for_unit(
    *,
    subject: str,
    grade: int,
    session_kind: str,
    question_index: int,
    total_questions: int | None,
    curriculum_item_title: str,
    curriculum_item_summary: str,
    asked_stems: list[str],
) -> quiz_models.QuizQuestionStructured:
    kind = "multiple_choice" if session_kind == "assessment" else "mixed"
    asked_block = "\n".join(f"- {s}" for s in asked_stems[-14:]) or "- (none yet)"
    total_text = str(total_questions) if total_questions else "unknown"
    prompt = (
        "Create exactly one quiz question as valid JSON.\n"
        "Output only JSON. No Markdown.\n\n"
        f"Subject: {subject}\n"
        f"Grade: {grade}\n"
        f"Session kind: {session_kind}\n"
        f"Question number: {question_index} of {total_text}\n"
        f"Target unit title: {curriculum_item_title}\n"
        f"Target unit summary:\n{curriculum_item_summary.strip() or '(no summary available)'}\n\n"
        f"Question type policy: {kind}\n"
        "If multiple_choice, use 3-4 short options with ids like a/b/c/d and exactly one correct option id.\n"
        "If free_text, provide expected_answer and optional rubric_hint.\n"
        "Keep it concise and answerable quickly.\n\n"
        "Avoid repeating or paraphrasing these prior question stems:\n"
        f"{asked_block}\n\n"
        "JSON schema:\n"
        '{"type":"multiple_choice","multiple_choice":{"stem":"...","options":[{"id":"a","label":"..."},{"id":"b","label":"..."}],"correct_option_id":"a"}}\n'
        "or\n"
        '{"type":"free_text","free_text":{"stem":"...","expected_answer":"...","rubric_hint":null}}'
    )
    model = _chat_model()
    resp = model.invoke(
        [
            SystemMessage(
                content=(
                    "You are a precise tutor-question generator. "
                    "Return only valid JSON matching the requested schema."
                ),
            ),
            HumanMessage(content=prompt),
        ]
    )
    text = _ai_text(resp) if isinstance(resp, AIMessage) else str(resp.content or "")
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`").strip()
        if cleaned.lower().startswith("json"):
            cleaned = cleaned[4:].strip()
    raw = json.loads(cleaned)
    parsed = quiz_models.parse_quiz_question_content(raw)
    if session_kind == "assessment" and parsed.type != "multiple_choice":
        raise ValueError("assessment generation must return multiple_choice")
    return parsed


def generate_evaluation_from_qa_summary(
    *,
    session_kind: str,
    qa_summary: str,
) -> str:
    prompt = (
        "Write a positive narrative evaluation for the student based on this quiz transcript.\n"
        "Highlight what the student achieved, mention weaker topics gently, and encourage focused review.\n"
        "Do not produce markdown tables or a strict report template.\n\n"
        f"Session kind: {session_kind}\n\n"
        "Q&A transcript:\n"
        f"{qa_summary}"
    )
    model = _chat_model()
    resp = model.invoke(
        [
            SystemMessage(
                content=(
                    "You are an encouraging tutor. Keep the evaluation practical and concise."
                ),
            ),
            HumanMessage(content=prompt),
        ]
    )
    return _ai_text(resp) if isinstance(resp, AIMessage) else str(resp.content or "")


def check_free_text_answer(
    *,
    stem: str,
    expected_answer: str,
    student_answer: str,
    rubric_hint: str | None = None,
) -> dict[str, Any]:
    prompt = (
        "Check this student's free-text answer against the expected answer. "
        "Judge whether it aligns in correctness and Umfang. "
        "Return only JSON with keys correct (boolean), score (number 0..1), comment (short German feedback).\n\n"
        f"Question:\n{stem}\n\n"
        f"Expected answer:\n{expected_answer}\n\n"
        f"Rubric hint:\n{rubric_hint or ''}\n\n"
        f"Student answer:\n{student_answer}"
    )
    model = _chat_model()
    resp = model.invoke(
        [
            SystemMessage(
                content=(
                    "You are a strict but encouraging answer checker. "
                    "You only emit valid JSON, no Markdown."
                ),
            ),
            HumanMessage(content=prompt),
        ]
    )
    text = _ai_text(resp) if isinstance(resp, AIMessage) else str(resp.content or "")
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.strip("`").strip()
        if cleaned.lower().startswith("json"):
            cleaned = cleaned[4:].strip()
    data = json.loads(cleaned)
    score = float(data.get("score", 0.0))
    return {
        "correct": bool(data.get("correct")),
        "score": max(0.0, min(1.0, score)),
        "comment": str(data.get("comment") or "").strip()[:4000],
    }
