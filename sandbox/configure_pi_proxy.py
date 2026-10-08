#!/usr/bin/env python3
"""Merge sandbox proxy endpoints into pi's private models configuration."""

import json
import os
from pathlib import Path


def main() -> None:
    updates = {
        "openrouter": os.environ.get("SANDBOX_OPENROUTER_BASE_URL", ""),
        "openai": os.environ.get("SANDBOX_OPENAI_BASE_URL", ""),
    }
    updates = {name: url for name, url in updates.items() if url}
    if not updates:
        return

    agent_dir = Path(os.environ["PI_CODING_AGENT_DIR"])
    agent_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = agent_dir / "models.json"
    config = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    providers = config.setdefault("providers", {})
    for name, base_url in updates.items():
        providers.setdefault(name, {})["baseUrl"] = base_url

    temporary_path = path.with_suffix(".json.tmp")
    temporary_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    temporary_path.chmod(0o600)
    temporary_path.replace(path)
    path.chmod(0o600)


if __name__ == "__main__":
    main()
