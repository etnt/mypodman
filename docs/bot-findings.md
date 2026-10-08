# Bot findings: could the sandbox run a "Grok Bot"-style agent?

Status: investigation only. No code was changed. Revisit if a concrete use case appears.

## Question

Could we build something like a "Grok Bot" (an autonomous agent that calls an LLM in a loop) using the Podman functionality already in this repo?

## Short answer

Technically yes, with some work. We have not found a use case that justifies the work yet.

## What already exists

- **Sandbox container** (`sandbox/sandbox-wizard.sh`): a Debian Testing container with `--network none`, a non-root `dev` user, and the project directory mounted as home.
- **Credential proxy** (`sandbox/credential-proxy/credential_proxy.py`): holds real API keys outside the container. It forwards only allowlisted HTTP methods and paths to a fixed upstream host. Providers today include OpenAI-style and Anthropic-style APIs.
- **Bridge**: a loopback port inside the container connects to a Unix socket in a shared volume. The proxy listens on that socket. The container never sees the real key or the internet.
- **pi**: the coding agent installed in the image. It already works inside the sandbox.

Together these give the pattern a bot would need: an isolated agent, a controlled path to a model, and no raw secrets in the container.

## What a bot would still need

1. A headless entrypoint. The sandbox currently assumes an interactive session (`podman exec -it`). A bot needs a loop script or a non-interactive pi run.
2. A new provider entry if the model is remote. The proxy's `PROVIDERS` table makes this a small change.
3. Wizard support for a bot mode: a different entrypoint, a restart policy, and config persistence.
4. Docs and tests.

## Key finding: a local model changes the purpose

The proxy exists to hide a real API key. A local model (for example Ollama or llama.cpp) has no key to hide. Two consequences follow:

- The credential proxy and bridge become optional. The model endpoint could be a single allowed socket or route.
- The sandbox's value shifts from protecting a secret to limiting what an autonomous agent can do to the host. That is only worth it if the bot acts on files, runs commands, or processes untrusted input.

The repo has no existing local-model support. The runtime and hardware are not yet chosen.

## Possible use cases (none selected)

1. **Overnight coding agent**: works on a repo copy, runs tests, leaves a diff for review. Needs write access, so isolation matters most.
2. **Watch-and-summarize bot**: reads files or logs from a mounted folder and writes summaries or alerts. Mostly read-only and the simplest option.
3. **Document Q&A bot**: answers questions over a local folder of notes. No tools, only retrieval plus the model.
4. **Untrusted-content processor**: classifies or summarizes emails or web pages. The host fetches the content, and the sandbox limits damage from prompt injection.
5. **Scheduled task runner**: runs one of the above on a timer, using Podman's restart and logging.

## Open questions

- Which use case, if any, is wanted?
- Should the bot act (edit files, run commands, send messages), or only read and report?
- How should it be triggered: interactive, scheduled, or file-watch?
- Which local runtime and hardware are available? Ollama on the macOS host is the simplest default.
- Does it need network access? `--network none` is the safest default.

## Risks noted during investigation

- A bot with a writable mounted workspace can change real host files. Prefer a cloned workspace for any autonomous write.
- Remote-API integrations depend on the provider's endpoint and header behavior, which change over time. A local model avoids this.
- Restarts start a fresh process. Any state must live in a volume or a committed container.
- pi's custom model configuration format must be verified against its docs before relying on it for a bot.
