"""Пути и настройки. Всё переопределяется через env — тесты обязаны подставлять свои каталоги (tests/conftest.py)."""

import os
from pathlib import Path


def _path(env: str, default: str) -> Path:
    return Path(os.environ.get(env) or default).expanduser()


HOME = _path("LAMBSCAPE_HOME", "~/Library/Application Support/lambscape")
LOGS = _path("LAMBSCAPE_LOGS", "~/Library/Logs/lambscape")
DB = HOME / "lambscape.db"

# реестр ботов — в папке данных (deploy кладёт туда bots.toml из репозитория); нет файла — нет ботов
BOTS_TOML = _path("LAMBSCAPE_BOTS", str(HOME / "bots.toml"))
PORT = int(os.environ.get("LAMBSCAPE_PORT", "5262"))

CLAUDE_SESSIONS_DIR = _path("LAMBSCAPE_CLAUDE_SESSIONS", "~/.claude/sessions")
CLAUDE_PROJECTS_DIR = _path("LAMBSCAPE_CLAUDE_PROJECTS", "~/.claude/projects")
# launchctl подменяется в тестах заглушкой: агентам нельзя трогать настоящие launchd-задания
LAUNCHCTL = os.environ.get("LAMBSCAPE_LAUNCHCTL", "/bin/launchctl")

# корни проектов через двоеточие; LAMBSCAPE_ROOTS переопределяет значение по умолчанию
_ROOTS = "~/Developer:~/Projects:~/projects:~/code:~/Documents/projects:~/Documents/GitHub"
PROJECT_ROOTS = [Path(p).expanduser() for p in os.environ.get("LAMBSCAPE_ROOTS", _ROOTS).split(":") if p]
