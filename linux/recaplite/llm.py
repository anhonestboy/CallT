"""Motori AI per le note: la CLI `claude` (account di Claude Code, nessuna chiave)
oppure l'API Anthropic con ANTHROPIC_API_KEY. Ogni chiamata è indipendente."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import urllib.request
from pathlib import Path

from .config import CONFIG_DIR, Config

API_MODELS = {"haiku": "claude-haiku-5-5", "sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5"}


class LLMError(RuntimeError):
    pass


def find_claude(cfg: Config) -> str | None:
    if cfg.claude_path:
        return cfg.claude_path if os.access(cfg.claude_path, os.X_OK) else None
    home = Path.home()
    for candidate in (home / ".local/bin/claude", home / ".claude/local/claude",
                      Path("/usr/local/bin/claude"), Path("/usr/bin/claude"),
                      home / ".npm-global/bin/claude", home / ".bun/bin/claude"):
        if os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which("claude")


class Engine:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.claude = find_claude(cfg) if cfg.engine == "claude-cli" else None
        self.api_key = os.environ.get("ANTHROPIC_API_KEY") if cfg.engine in ("api", "claude-cli") else None
        if cfg.engine == "off":
            self.kind = "off"
        elif self.claude:
            self.kind = "claude-cli"
        elif self.api_key:
            self.kind = "api"
        else:
            self.kind = "off"

    @property
    def label(self) -> str:
        return {"claude-cli": "Claude (account locale)", "api": "Claude API",
                "off": "nessuna AI"}[self.kind]

    @property
    def available(self) -> bool:
        return self.kind != "off"

    def complete(self, system: str, prompt: str, tier: str) -> str:
        alias = self.cfg.live_model if tier == "live" else self.cfg.final_model
        if self.kind == "claude-cli":
            return self._cli(system, prompt, alias, effort="low" if tier == "live" else None)
        if self.kind == "api":
            return self._api(system, prompt, API_MODELS.get(alias, alias), tier)
        raise LLMError("nessun motore AI configurato")

    def _cli(self, system: str, prompt: str, model: str, effort: str | None) -> str:
        message = {"type": "user", "message": {"role": "user",
                                               "content": [{"type": "text", "text": prompt}]}}
        cwd = CONFIG_DIR / "claude-cli"
        cwd.mkdir(parents=True, exist_ok=True)
        args = [self.claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                "--verbose", "--model", model, "--tools", "", "--no-session-persistence",
                "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                "--setting-sources", "", "--disable-slash-commands", "--system-prompt", system]
        if effort:
            args += ["--effort", effort]
        env = dict(os.environ)
        env.pop("ANTHROPIC_API_KEY", None)  # usa l'account, non una chiave
        try:
            run = subprocess.run(args, input=json.dumps(message) + "\n", capture_output=True,
                                 text=True, cwd=cwd, env=env, timeout=600)
        except subprocess.TimeoutExpired as error:
            raise LLMError("Claude Code: timeout") from error
        for line in run.stdout.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "result":
                if event.get("is_error"):
                    raise LLMError(f"Claude Code: {event.get('result') or 'errore'}")
                if event.get("result"):
                    return event["result"]
        raise LLMError(f"Claude Code: nessuna risposta ({run.returncode}) {run.stderr.strip()[-200:]}")

    def _api(self, system: str, prompt: str, model: str, tier: str) -> str:
        body = {
            "model": model, "max_tokens": 16000, "system": system,
            "thinking": {"type": "adaptive"},
            "output_config": {"effort": "low" if tier == "live" else "high"},
            "messages": [{"role": "user", "content": prompt}],
        }
        headers = {"x-api-key": self.api_key, "anthropic-version": "2023-06-01",
                   "content-type": "application/json"}
        if "haiku" not in model:
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        request = urllib.request.Request("https://api.anthropic.com/v1/messages",
                                         data=json.dumps(body).encode(), headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                data = json.load(response)
        except urllib.error.HTTPError as error:
            raise LLMError(f"Claude API {error.code}: {error.read()[:300]!r}") from error
        if data.get("stop_reason") == "refusal":
            raise LLMError("Claude API: richiesta rifiutata")
        text = "".join(block.get("text", "") for block in data.get("content", [])
                       if block.get("type") == "text")
        if not text:
            raise LLMError("Claude API: risposta vuota")
        return text
