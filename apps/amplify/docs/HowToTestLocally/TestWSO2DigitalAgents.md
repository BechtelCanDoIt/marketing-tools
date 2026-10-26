# Test WSO2 Digital Agents locally

`projects/wso2-digital-agents` is the repo for the WSO2 Digital team's internal AI agents (your fork is `BechtelCanDoIt/wso2-digital-agents`). Today it holds **one agent, `po-agent` (Novera)**. This guide covers the repo as a whole: layout, the shared local setup, how to test a change, and the checklist for adding a new agent. For running Novera itself, see **[TestNovera.md](TestNovera.md)**.

Surveyed on 2026-10-16 (`main` at `6bc9fa2`).

```
wso2-digital-agents/
├── README.md                 # two lines, no setup notes
├── issue_template.md         # standard WSO2 template
├── pull_request_template.md  # standard WSO2 template: fill in "Automation tests", "Security checks", "Test environment"
├── LICENSE
└── po-agent/                 # Novera: Node 20 / TypeScript / Express / MySQL / Anthropic / Asgardeo
    ├── CLAUDE.md             # the real quick start and rules
    ├── ARCHITECTURE.md  RUNBOOK.md  SECURITY.md  docs/google-setup.md
    ├── .env.example  Dockerfile  .dockerignore  .choreo/{component.yaml,openapi.yaml}
    ├── scripts/              # prod ops only (backfill-dm-spaces.mjs)
    └── src/                  # agent/ chat/ auth/ db/ tools/ policy/ training/ issues/ …
```

There's no root workspace, shared package or monorepo tooling. Each agent folder stands on its own, with its own `package.json`, `Dockerfile`, `.choreo/` and docs.

---

## 1. One-time setup on your machine

| Need | Why | Status here |
| --- | --- | --- |
| Node 20 (or 22) | po-agent runs on `node:20-alpine` | Node 22.23.2 installed |
| MySQL 8 (Docker `mysql:8.4`) | Agent state, linked tokens, audit | Homebrew MySQL 9.7 installed. Docker preferred |
| Docker | Build the same image Choreo runs (UID 10000–20000) | Docker 29 installed |
| Non-prod **Asgardeo** app | Users link their WSO2 identity to the agent | Ask the team, or create one in a free org |
| Anthropic API key (or a mock via `ANTHROPIC_BASE_URL`) | LLM calls | — |
| Non-prod **GCP project** + test service account | Signed Chat webhook tokens and Chat API sends, kept away from the production add-on | — |
| `gcloud` CLI | Mint Google ID tokens to call `/webhook` locally | **Not installed:** `brew install --cask google-cloud-sdk` |
| cloudflared / ngrok | Only for end-to-end tests in real Google Chat | Not installed |

**Ports:** po-agent defaults to 3000, which clashes with One WSO2 and the People Ops webapps. Use `PORT=3001` for agents.

## 2. How to test a change

There's **no test framework** in the repo (no `test` or `lint` script), and po-agent's CLAUDE.md says not to make one up. A change is tested like this:

1. **Type-check and build:** `npm run build` (tsc) in the agent folder.
2. **Boot it:** `npm run dev`, then `curl localhost:3001/health`.
3. **Exercise the change with signed requests.** Mint a Google ID token for your test service account and `POST /webhook` with a sample Chat event. The full recipe is in [TestNovera.md §5](TestNovera.md#5-call-the-webhook-without-google-chat). The middleware has no bypass flag. Don't add one, and don't commit a local patch.
4. **Check the side effects in MySQL:** tables such as `agent_user_tokens`, `agent_dm_spaces` and the audit tables. Audit rows must not contain message payloads.
5. **Build the image:** `docker build` + `docker run --env-file .env` + `/health`. That's what Choreo deploys.
6. **Optional, end to end:** tunnel + a **test** add-on deployment in the non-prod GCP project. Never repoint production.
7. **Fill in the PR template's** "Automation tests" (say "manual: …" until a framework exists), "Security checks" and "Test environment" sections with what you actually ran.

If you add a test framework, propose it in its own PR so the team can agree on it. Don't bundle it into a feature change.

## 3. Rules that apply to every agent

These come from po-agent's CLAUDE.md and SECURITY.md, and are worth keeping for any new agent:

- **Fail fast on config.** Every required env var is checked at startup. Ship a complete `.env.example` with placeholders and a comment for each feature.
- **Verify every inbound caller.** Google-signed ID token (issuer, audience, caller email) for Chat; gateway subscription for internal endpoints.
- **Identity guards on every tool call.** Compare the user's id_token email with the linked user before calling a backend on their behalf.
- **Encrypt stored tokens** (AES-256-GCM, a 64-hex key) and never rotate the key casually: rotating it wipes the linked sessions.
- **Don't keep payloads.** Audit logs record actions, not content. Respect the hourly and daily purge timers.
- **Images:** a non-root UID in 10000–20000, `--env-file` (never bake `.env` in), and a `/health` endpoint.
- **Per-user LLM quotas** (`USER_TOKEN_QUOTA_PER_DAY`), and prompt caching where the agent supports it.

## 4. Adding a new agent to the repo

The Amplify agent (`amplify-agent` plus a classifier) is **later-phase work** (see `architecture/solution/Phase 1/phase1-domains.md`). If one gets added here:

1. Create a new top-level folder (`<name>-agent/`) with the same set of files as po-agent: `CLAUDE.md`, `ARCHITECTURE.md`, `RUNBOOK.md`, `SECURITY.md`, `.env.example`, `Dockerfile`, `.dockerignore`, `.choreo/component.yaml` and `openapi.yaml`, plus the WSO2 license header on every source file.
2. Pick its own default `PORT` and its own MySQL database or schema, so it can run next to Novera locally.
3. Follow the rules in §3. Copy po-agent's `verifyChatRequest`, crypto and identity-guard code rather than writing them again.
4. **If it runs on the WSO2 Agent Manager (AMP)**, which is the plan for later Amplify agents: model calls go through the AMP LLM gateway (no provider keys in the agent), and identity is ThunderID. Use the `manage-agent` skill / `amctl` CLI to create, deploy and watch builds, and to pull logs, metrics and traces. Locally you still run it with `npm run dev`. AMP is where it's deployed.
5. Add a `docs/HowToTestLocally/Test<Agent>.md` alongside this one.

## 5. Related guides

- [TestNovera.md](TestNovera.md) — run and test po-agent.
- [TestOneWSO2.md](TestOneWSO2.md) — the web app where Novera's "Ask Novera ⌘K" pill lives.
- [TestPeopleOpsSuite.md](TestPeopleOpsSuite.md) — the leave, menu and people backends Novera calls.
- [TestWSO2Coin.md](TestWSO2Coin.md) — the Coin services.
