# claw2claude

Bridges OpenClaw and Claude Code CLI — letting your OpenClaw AI act as an **orchestrator** that delegates complex tasks to a local Claude Code session.

### How it works

```
User sends a message
    ↓
OpenClaw AI decides to invoke claw2claude
    ↓
launch.sh starts Claude Code (claude CLI) with the right flags
    ↓
Claude runs in the project directory, reads/writes files, executes code
    ↓
parse_stream.py collects Claude's output; extracts the ---CHAT_SUMMARY--- block
    ↓
OpenClaw AI receives the summary and sends it back to the user via message tool
    ↓
Session ID saved → next turn resumes with full context via --resume
```

### Modes

| Mode | What it does |
|------|-------------|
| `discuss` | Claude explores options and asks clarifying questions (no code written yet) |
| `execute` | Claude implements the task directly |
| `continue` | Resumes the previous session in the same mode |
| `background` | Runs detached; heartbeat.py notifies you when done |

### Requirements

- `claude` CLI on PATH ([Claude Code](https://claude.ai/code))
- `python3` on PATH

### Installation

```bash
cp -r claw2claude ~/.openclaw/skills/
# then restart the OpenClaw gateway
openclaw gateway restart
```

---

## Adding usage rules to your USER.md

Add the following block to your `USER.md` to control when and how the skill fires:

```markdown
## Tool routing with claw2claude

- **Route code tasks to Claude Code** — for any task involving code (reading,
  reviewing, writing, refactoring, architecture design), use the `claw2claude`
  skill to delegate to the local Claude Code CLI. Claude Code has direct
  filesystem access and is purpose-built for these tasks.

- **Check in before starting large projects** — when the user proposes a
  substantial new project (software, business plan, long-form document, etc.),
  ask first: "This looks like a multi-round project — would you like me to set
  up a Claude Code project directory?" Delegate only after the user confirms.

- For tasks within `claw2claude`'s scope, act as a coordinator: clarify the
  request, choose the right mode (discuss / execute), and deliver the result.
  Do not duplicate work that Claude Code will handle.
```

Paste this into your `USER.md` and restart the gateway.
