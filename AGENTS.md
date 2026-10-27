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
