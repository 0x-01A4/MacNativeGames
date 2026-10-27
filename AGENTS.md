# AGENTS.md

For AI assistants (Codex, Cursor, Copilot, Gemini and others) working in this repository. Claude Code reads
`CLAUDE.md` and finds the skills below by itself; any other assistant should read the file that fits the request and
follow it step by step.

| The player asks to | Read and follow |
|---|---|
| build or install a game with the Builder (a window), or run `make` | `.claude/skills/install-with-builder/SKILL.md` |
| build or install Tears of the Kingdom or Breath of the Wild in Terminal, or fix a `build_app.py` error | `.claude/skills/install-zelda/SKILL.md` |

Changing the code: `CLAUDE.md` (commands, architecture, and the rules every change follows) and `CONTRIBUTING.md`.
Only the player's own game files and keys, never downloaded ones; never print key values.
