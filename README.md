# avd-intune

Part of [avd-ops](https://avd-ops.dev/), the open toolkit for Azure Virtual Desktop.

> [!WARNING]
> **Personal project. Research and learning only. Not for production. No warranty.**
>
> - This is my own personal project, built on my own time **for research and learning**. It is **not affiliated with, endorsed by or supported by my employer**, Liquidware or Microsoft, and it does not represent their views, products or guidance.
> - **Do not run any of it in production** or against subscriptions and tenants that matter. Test it first in a dedicated lab subscription and tenant.
> - It is provided **"as is", without warranty of any kind**, under the [MIT License](LICENSE). You use it at your own risk.
> - **Contributions and forks are welcome and encouraged.** See [Contributing](#contributing).

## Role in avd-ops

Desktop DevOps endpoint configuration and Windows 365 Cloud PC control plane (`avd-intune`), orchestrated by [avd-landing-zone](https://github.com/avd-ops/avd-landing-zone) ([decision 0009](https://avd-ops.dev/docs/decisions/0009-split-landing-zone-into-five-control-planes.html), [decision 0012](https://avd-ops.dev/docs/decisions/0012-desktop-devops-for-avd-win365-and-intune.html)).

## What it does

- Configures Microsoft Intune MDM auto-enrollment scope and Windows Enterprise multi-session enrollment rules.
- Deploys declarative Settings Catalog profiles for AVD session hosts (FSLogix settings, RDP Shortpath, multimedia redirection, session timeouts, Windows Update rings).
- Deploys platform assignment filters (`avd-multisession`, `avd-personal`, `win365-cloudpc`, `physical-desktop`) via `-DeployAssignmentFilters` so multi-session, Cloud PC, and physical device policies stay cleanly separated.
- Deploys declarative Windows 365 Cloud PC provisioning policies (`enableSingleSignOn: true`) and least-privilege user settings (`localAdminEnabled: false`, 4-hour restore points) via `-IncludeWin365`, and checks Azure Network Connection (`onPremisesConnections`) health.
- Applies session-host and Cloud PC device compliance policies paired with `avd-entra` Conditional Access.
- Assigns core host applications to the dynamic session-host and Cloud PC device groups from `avd-entra`.
- Driven from Azure Cloud Shell (`az rest`, PowerShell 7, Bash and Python) using source-controlled Graph JSON templates.

## Contracts

Consumes `entra-manifest.json` device and user group targets and produces `intune-manifest.json` (enrolled policy IDs, compliance baseline state, optional platform `assignmentFilters`, and optional `win365` provisioning policy and user settings IDs).

## Contributing

Fork it, open an issue or a pull request. Follow the family guardrails in [AGENTS.md](AGENTS.md): no tenant IDs, secrets, domains or customer names, and propose changes via pull request only. Contributions are accepted under the [MIT License](LICENSE).

## License and disclaimer

[MIT](LICENSE). Personal project, not for production, provided as is, not affiliated with the author's employer, Liquidware or Microsoft.
