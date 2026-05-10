"""Structured quiz question shapes and tool payloads for the future quiz-agent."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, TypeAdapter


class QuizMCOption(BaseModel):
    id: str
    label: str


class QuizMultipleChoiceContent(BaseModel):
    stem: str
    options: list[QuizMCOption] = Field(min_length=2)
    correct_option_id: str


class QuizFreeTextContent(BaseModel):
    stem: str
    expected_answer: str = ""
    rubric_hint: str | None = None


class QuizQuestionMultipleChoice(BaseModel):
    type: Literal["multiple_choice"] = "multiple_choice"
    multiple_choice: QuizMultipleChoiceContent


class QuizQuestionFreeText(BaseModel):
    type: Literal["free_text"] = "free_text"
    free_text: QuizFreeTextContent


QuizQuestionStructured = QuizQuestionMultipleChoice | QuizQuestionFreeText
_question_adapter: TypeAdapter[QuizQuestionStructured] = TypeAdapter(QuizQuestionStructured)


def parse_quiz_question_content(content: dict[str, Any]) -> QuizQuestionStructured:
    return _question_adapter.validate_python(content)


class QuizAnswerMultipleChoice(BaseModel):
    selected_option_id: str


class QuizAnswerFreeText(BaseModel):
    text: str


class OutcomePerQuestion(BaseModel):
    question_id: str
    correct: bool
    curriculum_item_ids: list[str] = Field(default_factory=list)


class SessionOutcomeDetails(BaseModel):
    """Structured session outcome for analytics and follow-up agents (not Markdown-only)."""

    per_question: list[OutcomePerQuestion] = Field(default_factory=list)
    weak_curriculum_item_ids: list[str] = Field(default_factory=list)


def build_tool_complete_payload(
    *,
    question_id: str,
    tool_call_id: str,
    preview: dict[str, Any],
) -> dict[str, Any]:
    """Envelope in the stream log / SSE; full body lives on ``quiz_questions``."""
    return {
        "type": "tool_complete",
        "tool_name": "generate_question",
        "tool_call_id": tool_call_id,
        "question_id": question_id,
        "artifact": preview,
    }


def question_wire_preview(q: QuizQuestionStructured) -> dict[str, Any]:
    """Small artifact for stream / widgets; canonical copy remains in `quiz_questions.content`."""
    if q.type == "multiple_choice":
        return {
            "type": "multiple_choice",
            "stem": q.multiple_choice.stem,
            "option_ids": [o.id for o in q.multiple_choice.options],
        }
    return {"type": "free_text", "stem": q.free_text.stem}


def structured_question_to_pb_rows(
    q: QuizQuestionStructured,
) -> tuple[str, dict[str, Any]]:
    """PocketBase `kind` + `content` JSON for `quiz_questions`."""
    body = q.model_dump(mode="json")
    return q.type, body
