# avd-intune

Part of [avd-ops](https://avd-ops.dev/), the open toolkit for Azure Virtual Desktop.

Desktop DevOps endpoint configuration and Windows 365 Cloud PC control plane (`avd-intune`), orchestrated by [avd-landing-zone](https://github.com/avd-ops/avd-landing-zone#readme) ([avd-ops docs](https://avd-ops.dev/docs/repos/avd-intune.html), [decision 0009](https://avd-ops.dev/docs/decisions/0009-split-landing-zone-into-five-control-planes.html), [decision 0012](https://avd-ops.dev/docs/decisions/0012-desktop-devops-for-avd-win365-and-intune.html)).

> [!WARNING]
> **Community research project. Use at your own risk. No warranty.**
>
> - This is my own personal project, built on my own time **for research and learning**. It is **not affiliated with, endorsed by or supported by my employer**, Liquidware or Microsoft, and it does not represent their views, products or guidance.
> - Test it first in a dedicated lab subscription and tenant before using it in production; you are responsible for reviewing the code and validating it for your environment.
> - It is provided **"as is", without warranty of any kind**, under the [MIT License](LICENSE). You use it at your own risk.
> - **Contributions and forks are welcome and encouraged.** See [Contributing](#contributing).

## How it connects

| Direction | Repo | Relationship |
|---|---|---|
| Front door | [avd-ops](https://github.com/avd-ops/avd-ops#readme) | Overview, [repo page](https://avd-ops.dev/docs/repos/avd-intune.html), and platform decisions |
| Orchestrator | [avd-landing-zone](https://github.com/avd-ops/avd-landing-zone#readme) | Invokes `avd-intune` in the multi-plane deployment pipeline |
| Upstream | [avd-entra](https://github.com/avd-ops/avd-entra#readme) | Supplies `entra-manifest.json` device and user group targets |
| Downstream | [avd-azure](https://github.com/avd-ops/avd-azure#readme) | Enrolls session hosts into Intune on join via `AADLoginForWindows` |
| Assess & operate | [avd-assess](https://github.com/avd-ops/avd-assess#readme) / [avd-swarm](https://github.com/avd-ops/avd-swarm#readme) | Intune standards (`methods/intune.md`) and policy-as-code agent PRs |

## What it does

- Configures Microsoft Intune MDM auto-enrollment scope and Windows Enterprise multi-session enrollment rules.
- Deploys declarative Settings Catalog profiles for AVD session hosts (FSLogix settings, RDP Shortpath, multimedia redirection, session timeouts, Windows Update rings, and Microsoft Defender Antivirus, FSLogix/AVD exclusions, and VDI-tuned ASR rules).
- Deploys platform assignment filters (`avd-multisession`, `avd-personal`, `win365-cloudpc`, `physical-desktop`) via `-DeployAssignmentFilters` so multi-session, Cloud PC, and physical device policies stay cleanly separated. Defender endpoint security profiles target `avd-multisession`, `avd-personal`, and `win365-cloudpc` without affecting `physical-desktop`.
- Deploys declarative Windows 365 Cloud PC provisioning policies (`enableSingleSignOn: true`) and least-privilege user settings (`localAdminEnabled: false`, 4-hour restore points) via `-IncludeWin365`, and checks Azure Network Connection (`onPremisesConnections`) health.
- Applies session-host and Cloud PC device compliance policies paired with [avd-entra](https://github.com/avd-ops/avd-entra#readme) Conditional Access.
- Assigns core host applications to the dynamic session-host and Cloud PC device groups from [avd-entra](https://github.com/avd-ops/avd-entra#readme).
- Driven from Azure Cloud Shell (`az rest`, PowerShell 7, Bash and Python) using source-controlled Graph JSON templates.

## Contracts

Consumes `entra-manifest.json` device and user group targets and produces `intune-manifest.json` (enrolled policy IDs, compliance baseline state, optional platform `assignmentFilters`, and optional `win365` provisioning policy and user settings IDs).

## Docs

- Endpoint security policies, coexistence, first-boot EDR onboarding, and control-plane boundaries: [docs/endpoint-security.md](docs/endpoint-security.md) (`avd-intune` delivers endpoint policies; Defender for Cloud enablement stays in `avd-azure` / `avd-landing-zone` via `enableDefenderForCloud`; MDE/Defender XDR tenant-wide admin config and SOAR stay outside this repo)
- Agent instructions & guardrails: [AGENTS.md](AGENTS.md)
- Repo page on avd-ops: [avd-ops.dev/docs/repos/avd-intune](https://avd-ops.dev/docs/repos/avd-intune.html)

## Contributing

Fork it, open an issue or a pull request. Follow the family guardrails in [AGENTS.md](AGENTS.md): no tenant IDs, secrets, domains or customer names, and propose changes via pull request only. Contributions are accepted under the [MIT License](LICENSE).

## License and disclaimer

[MIT](LICENSE). Community research project, provided as is, use at your own risk, not affiliated with the author's employer, Liquidware or Microsoft.
