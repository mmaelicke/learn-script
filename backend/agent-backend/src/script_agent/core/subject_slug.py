import re

_SAFE = re.compile(r"[^a-zA-Z0-9_.-]+")


def filesystem_subject_slug(subject: str) -> str:
    """Sanitize subject for Chroma on-disk path (per user/grade/subject scope)."""
    s = subject.strip().replace("/", "_")
    s = _SAFE.sub("_", s)
    s = s.strip("._") or "subject"
    return s[:120]
