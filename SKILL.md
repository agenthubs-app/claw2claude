---
name: claw2claude
description: "Delegates tasks to the local Claude Code CLI. Activate immediately when the user asks for Claude, requests a stronger model, or mentions an existing project path. Ask the user first whether to create a Claude project when: the task involves building something from scratch, spans multiple parts, requires multiple rounds of iteration, or the user is expressing a direction rather than a concrete single question. Applies to code AND non-code work (business plans, product specs, docs, etc.). Do not start answering directly — ask first."
license: MIT
metadata: {"openclaw": {"os": "darwin", "emoji": "🦞→🤖", "requires": {"bins": ["claude", "python3"]}}}
---

# claw2claude — OpenClaw Orchestrates Claude Code

Delegates the user's task to the local `claude` CLI.
**You (OpenClaw AI) are the orchestrator. Claude Code is the executor.**

---

## Activation

### A. Activate immediately (any one condition is enough)

| Condition | Examples |
|-----------|---------|
| User explicitly asks for Claude | "use Claude for this", "let Claude handle it", "hand it to Claude" |
| User requests a stronger / smarter model | "use a better model", "switch to a more capable AI" |
| Task involves an existing Claude Code project | User mentions a path that contains `.openclaw-claude-session.json` |
| User explicitly mentions claude CLI / Claude Code | "run it with claude", "open a Claude Code session" |

### B. Ask first (when you judge the task has these traits)

Before starting, ask the user whether to create a Claude project if any of the following apply:

| Trait | How to judge |
|-------|-------------|
| **It's an idea or direction** | User says "I want to build/design/plan/write a…" — no concrete single question yet |
| **Multiple parts involved** | Feature modules, document chapters, plan phases — not answerable in one reply |
| **Multiple iterations expected** | Discuss → revise → confirm loop, or clearly not a one-shot Q&A |
| **A clear project concept exists** | App, system, business plan, product spec, docs, course outline, campaign plan, etc. |
| **User already has related material** | Mentions an existing directory, codebase, docs, or prior discussion |

**Fixed phrasing to use when asking:**
> This looks like a task that will need multiple rounds of discussion or iteration.
> Would you like to set up a Claude Code project for this? Benefits:
> - Full conversation history and context that persists across sessions
> - Pick up where you left off at any time
> - All files, plans, and code kept in one working directory
>
> **[Yes, create project]** / **[No, handle it directly]**

- User says **yes**: ask for (or suggest) a project path, then launch in `discuss` or `execute` mode
- User says **no**: handle it yourself; do not invoke this skill

**If none of the above conditions apply, handle the request yourself. Do not invoke this skill.**

---

## Four Modes

| Mode | When to use | Claude permissions |
|------|-------------|-------------------|
| `discuss` | Requirements are unclear; user wants to explore options or plan architecture | `--dangerously-skip-permissions` (all operations allowed) |
| `execute` | Task is clear; user wants code written or changed | `--dangerously-skip-permissions` (fully automatic) |
| `continue` | Resuming the previous session in the same mode | Inherits the previous mode's permissions |
| `background` | User wants Claude to run without waiting for the result | Same as execute (`--dangerously-skip-permissions`) — always runs as execute, cannot use discuss or continue |

**Claude has a 30-minute timeout.** If it expires, the task is aborted — split it into smaller subtasks and retry.

---

## Step 1: Determine the mode

| What the user says | Mode |
|--------------------|------|
| "Help me think through how to design…" / "What are the options?" / "Analyse this…" | `discuss` |
| "Write…" / "Implement…" / "Create…" / "Refactor…" | `execute` |
| "Continue" / "Keep going" / "Do what we discussed" | `continue` |
| After a discussion: "OK, let's build it" / "Go with that plan" | `execute` ← important! |
| "Run it in the background" / "Don't wait, just let it run" | `background` |

> ⚠️ **Use `execute`, not `continue`, when switching from discussion to implementation.**
> `execute` always resumes the last session (`--resume`) if one exists, whether the previous mode was `discuss` or `execute`.
> This keeps all messages to the same project in a single continuous session.
> `continue` also resumes the same session but is reserved for explicit "pick up where we left off" requests.
>
> If the user says "continue" but also adds a new direction, use `execute` mode with the full structured prompt — not `continue`.

---

## Step 2: Confirm the project path (critical — prevents session cross-contamination)

The registry is printed to stderr automatically each time `launch.sh` runs — you do not need a separate call unless you need to inspect it *before* deciding which project to use. If unsure, run:
```bash
python3 "$SKILL_DIR/scripts/projects.py" list
```

| Situation | Action |
|-----------|--------|
| User specified a path explicitly | Use it directly |
| Registry is empty — brand new project | Generate an English directory name from the task; tell the user: `"I'll create the project at ~/Projects/<name> — let me know if you'd like a different location"` |
| Registry has exactly one project | Use it by default; tell the user: `"Continuing with [project name]"` |
| Registry has multiple projects + user says "continue" but it's ambiguous | **List them and ask the user to choose. Never guess.** |
| Registry has multiple projects + task implies a specific one | Infer and confirm: `"Did you mean [project name]?"` |

---

## Step 3: Build the prompt for Claude

Expand the user's raw description into a structured instruction that Claude can execute efficiently.

**discuss mode** — instruct Claude to act as an architecture advisor, suggestions only, no code:
```
You are an experienced software architect. The user wants to discuss the following:

<user's original request>

Ask clarifying questions, suggest architecture patterns and tech stack options, identify risks.
Do NOT write actual implementation code unless the user explicitly asks for a short example.
```

**execute mode** — instruct Claude to complete the task directly:
```
You are a professional software engineer. Complete the following task:

Goal: <clear description of the end result>
Tech stack: <language/framework — infer if not specified>

Requirements:
- Clean, commented code following best practices
- Proper error handling and edge case coverage
- <any specific requirements the user emphasised>

<list concrete steps if applicable; omit otherwise>
```

**continue mode** — pass the user's new instruction directly; Claude already has the full prior context:
```
<user's new instruction verbatim>
```

---

## Step 4: Launch and notify (required)

**Before invoking Claude Code, tell the user it's starting** (say it in your reply — no extra tool needed):
`"🚀 Launching Claude Code for [project name] — [discuss/execute] mode. This will take a few minutes…"`

Then run with the `exec` tool:
```bash
"$SKILL_DIR/scripts/launch.sh" "<project_path>" "<mode>" "<prompt>" "<session_key>"
```

- `project_path`: absolute path — the script creates the directory and runs `git init` automatically
- `mode`: `discuss` / `execute` / `continue` / `background`
- `prompt`: the structured instruction built in Step 3. If the prompt contains double quotes, escape them as `\"` or wrap in single quotes.
- `session_key`: **optional** — omit it and `launch.sh` will auto-detect the correct channel by finding the most recently active session in the sessions registry. Only pass it explicitly if auto-detection picks the wrong channel.

**background mode**: the script returns immediately; Claude runs in the background. Tell the user:
`"🚀 Claude Code is running in the background. You'll be notified automatically when it's done."`

---

## Step 5: Deliver the result

The exec result already contains a **structured summary written by Claude** (extracted from the `---CHAT_SUMMARY---` block). The full output is in the log file.

The exec call may have taken several minutes and the channel connection may be stale. **Always use the `message` tool explicitly** to guarantee delivery — do not rely on turn-response auto-routing.

### Chunked delivery (required — do not send in one message)

Split the summary into chunks and send each as a **separate `message` call**. Rules:

1. **First message**: one-line confirmation only → `"✅ Claude Code finished · [project name]"`
2. **Body chunks**: split the summary by section headings (`##`, `###`) or at natural paragraph breaks — whichever comes first. Each chunk must be **≤ 500 characters**. If a single paragraph exceeds 500 characters, break it at the nearest sentence boundary.
3. **Last message**: footer line only →
   - discuss mode: `"Ready to start building? Reply and I'll kick off implementation."`
   - execute mode: `"Please verify the result in your project directory."`
   - on timeout: `"⏰ Task timed out (>30 min) — please split it into smaller subtasks and retry."`

Do not rewrite or expand the summary — Claude already wrote it concisely. Send each chunk verbatim.

**Example** (summary has 3 sections):
```
message("✅ Claude Code finished · myapp")
message("## What was done\nAdded JWT middleware to …")
message("## Files changed\n- src/auth.ts\n- src/routes …")
message("## Next steps\nRun `npm test` to verify …")
message("Please verify the result in your project directory.")
```

---

## Examples

```
User: I want to build a video transcription tool but I'm not sure which tech stack to use
→ discuss mode → confirm directory ~/Projects/video-transcriber
→ Claude analyses options

User: OK, let's go with Whisper + FastAPI — start building
→ execute mode (discuss→execute, carries over context via --resume)
→ Claude implements directly based on the discussion, no need to re-explain

User: Add JWT authentication to ~/Projects/myapp
→ execute mode, path is explicit

User: Continue
→ registry has two projects → list them and ask the user to choose
```
