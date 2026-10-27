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

Session-host MDM enrollment and endpoint configuration control plane (`avd-intune`), orchestrated by [avd-landing-zone](https://github.com/avd-ops/avd-landing-zone) ([decision 0009](https://avd-ops.dev/docs/decisions/0009-split-landing-zone-into-five-control-planes.html)).

## What it does

- Configures Microsoft Intune MDM auto-enrollment scope and Windows Enterprise multi-session enrollment rules.
- Deploys declarative Settings Catalog profiles for AVD session hosts (FSLogix settings, RDP Shortpath, multimedia redirection, session timeouts, Windows Update rings).
- Applies session-host device compliance policies paired with `avd-entra` Conditional Access.
- Assigns core host applications to the dynamic session-host device groups from `avd-entra`.
- Driven from Azure Cloud Shell (`az rest`, PowerShell 7, Bash and Python) using source-controlled Graph JSON templates.

## Contracts

Consumes `entra-manifest.json` device and user group targets and produces `intune-manifest.json` (enrolled policy IDs, compliance baseline state, and MDM readiness).

## Contributing

Fork it, open an issue or a pull request. Follow the family guardrails in [AGENTS.md](AGENTS.md): no tenant IDs, secrets, domains or customer names, and propose changes via pull request only. Contributions are accepted under the [MIT License](LICENSE).

## License and disclaimer

[MIT](LICENSE). Personal project, not for production, provided as is, not affiliated with the author's employer, Liquidware or Microsoft.
