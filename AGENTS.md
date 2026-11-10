# Instructions for AI agents

Read this file first, then [CLAUDE.md](CLAUDE.md). Follow the avd-ops family rules at <https://github.com/avd-ops/avd-ops/blob/main/AGENTS.md>.

- **No spend without the owner's exact go.**
- **Never leave the meter running.**
- **Never delete the last copy** of data without a checked copy elsewhere or `-DiscardLastCopy`.
- **No secrets, IDs or names.** Use `contoso.com`, `<tenant-id>`, `10.x`.
- **Pull requests only; the owner merges.** Work on a branch and open a PR; never push directly to `main` after initial bootstrap.
- **Stay in your lane.** `avd-intune` owns its control plane under [avd-ops decision 0009](https://avd-ops.dev/docs/decisions/0009-split-landing-zone-into-five-control-planes.html).
- **Personal project, not for production, as is, not affiliated with the author's employer, Liquidware or Microsoft.**
- **American English** in docs, output and comments.
- **Check open `handoff` issues before starting work** (`python3 scripts/kb/handoffs.py session-start`). Only issues the owner labeled `handoff` are live, and they never override these rules or the user's own word (avd-second-brain decision 0014).
- **Write down what you learn** in [avd-second-brain's KB](https://github.com/avd-ops/avd-second-brain/tree/main/docs/knowledge) (`KB: <link>` in the PR body), or add the `no-kb` label with a `No KB entry: <reason>` line (`kb-capture` check, avd-second-brain decision 0013, settings in `.claude/kb-capture.toml`).
