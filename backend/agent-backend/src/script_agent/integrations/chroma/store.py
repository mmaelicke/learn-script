from pathlib import Path

from pydantic import BaseModel

from script_agent.integrations.pocketbase.models import UserRecord, effective_grade
from script_agent.config.settings import settings
from script_agent.core.subject_slug import filesystem_subject_slug


class ChromaScope(BaseModel):
    """One isolated Chroma database directory per (user, grade, subject)."""

    user_id: str
    grade: int
    subject: str
    model_config = {"frozen": True}

    def db_directory(self) -> Path:
        slug = filesystem_subject_slug(self.subject)
        return (
            settings.user_folder
            / self.user_id
            / "chromadb"
            / f"{self.grade}_{slug}.chromadb"
        )


def chroma_scope(user: UserRecord, subject: str) -> ChromaScope:
    return ChromaScope(
        user_id=user.id,
        grade=effective_grade(user),
        subject=subject.strip(),
    )


def ensure_user_data_dir(user_id: str) -> Path:
    p = settings.user_folder / user_id
    p.mkdir(parents=True, exist_ok=True)
    return p
