# Codex plugin installed

Two things before the commands work.

## 1. Codex CLI must be present and authenticated

Hermes cannot check binary prerequisites for you.

```bash
codex --version     # need 0.144 or later — install: npm install -g @openai/codex
codex login         # if it reports unauthenticated
```

## 2. Restart the gateway

```bash
hermes gateway restart
```

Then, from inside Hermes:

```text
/codex-setup
```

That reports Codex availability, authentication, `jq`, `hermes send`, and the state directory. For the full dependency report run `scripts/doctor.sh` from the plugin directory.

## Commands

`/codex-review` · `/codex-adversarial-review` · `/codex-rescue` · `/codex-transfer` · `/codex-status` · `/codex-result` · `/codex-cancel` · `/codex-setup`

Add `--background` to a review or rescue to get a job ID immediately and a notification when it finishes.

The stop-time review gate is **off** by default. Enable it with `/codex-setup --enable-review-gate`; it costs an extra Codex turn per stop and fails open on any error.
