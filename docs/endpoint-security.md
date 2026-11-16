# Endpoint Security Policies & Control-Plane Boundary

> Personal project, not for production, as is, not affiliated with the author's employer, Liquidware or Microsoft.

`avd-intune` delivers declarative Microsoft Defender endpoint security policies for Azure Virtual Desktop (AVD) session hosts and Windows 365 Cloud PCs using Intune Settings Catalog JSON templates and platform assignment filters.

## Included Templates

| Template | Purpose | Assignment Filters |
|---|---|---|
| [avd-defender-antivirus-baseline.json](../profiles/settings-catalog/avd-defender-antivirus-baseline.json) | Defender Antivirus baseline tuned for VDI (25% CPU cap, low CPU priority, catch-up scans disabled, randomized scan times, 8-hour signature updates, Network Protection, PUA, cloud protection) | `avd-multisession`, `avd-personal`, `win365-cloudpc` |
| [avd-defender-fslogix-exclusions.json](../profiles/settings-catalog/avd-defender-fslogix-exclusions.json) | FSLogix VHD/VHDX profile containers, Cloud Cache (`%ProgramData%\FSLogix\Cache\*`, `Proxy\*`), FSLogix services, and AVD agent/SxS stack (`%ProgramFiles%\Microsoft RDInfra\*`) exclusions | `avd-multisession`, `avd-personal`, `win365-cloudpc` |
| [avd-defender-asr-rules.json](../profiles/settings-catalog/avd-defender-asr-rules.json) | Attack Surface Reduction (ASR) rules tuned for multi-session VDI (blocks credential theft, Office child/executable/injection/macro abuse, obfuscated scripts, USB executables, ransomware, vulnerable drivers; sets PSExec/WMI to `audit` for VDI management compatibility) | `avd-multisession`, `avd-personal`, `win365-cloudpc` |

All three profiles exclude `physical-desktop` by targeting only `avd-multisession`, `avd-personal`, and `win365-cloudpc` via `targetFilters` when `-DeployAssignmentFilters` (or `-IncludeWin365`) is enabled.

## Control-Plane Boundary

Each AVD control plane owns a distinct layer:

- **`avd-intune` (this repo):** Delivers Intune endpoint security policies (Defender Antivirus baseline, FSLogix/AVD exclusions, VDI-tuned ASR rules), Settings Catalog baselines, and platform assignment filters.
- **`avd-azure` / `avd-landing-zone`:** Owns Azure subscription-level Microsoft Defender for Cloud enablement (`enableDefenderForCloud`) and VM vulnerability assessment coverage.
- **Outside this repo:** Microsoft Defender for Endpoint (MDE) / Microsoft Defender XDR tenant-wide portal administration, RBAC, custom detection rules, and SOAR playbooks stay outside `avd-intune`.

## Passive-Mode & Third-Party AV Coexistence (`agents.coexistence`)

Per `avd-assess` `agents.coexistence`:

- Only one antivirus product actively protects a session host at a time.
- When a third-party antivirus is installed and registers with Windows Security Center (`wscsvc` running), Microsoft Defender Antivirus automatically enters **passive mode** while continuing to receive security intelligence updates.
- When running a third-party antivirus, ensure overlapping real-time scanning functions are disabled in one product and mutual exclusions are configured across both products.

## First-Boot EDR Onboarding (`agents.edr-onboarding`)

Per `avd-assess` `agents.edr-onboarding`:

- **Never onboard the golden image** to Microsoft Defender for Endpoint (or a third-party EDR). Cloning an onboarded image causes duplicate or overwritten device identities in the EDR portal.
- Run the MDE (or third-party EDR) onboarding script **at first boot** from the generalized image so each pooled or reimaged session host registers a single, unique device entry.
- License multi-session session hosts through Defender for Servers (via Defender for Cloud `enableDefenderForCloud`) or eligible per-user VDI licensing.

## Upstream Sources of Truth

To avoid recreating generic Windows baselines or app packaging pipelines:

- **Generic Windows & Cloud PC Settings Catalog baselines:** [SkipToTheEndpoint/OpenIntuneBaseline](https://github.com/SkipToTheEndpoint/OpenIntuneBaseline) (and Microsoft's versioned Intune Security Baselines) — `avd-intune` layers only the AVD/FSLogix/VDI-specific Defender, ASR, and exclusion deltas on top.
- **App lifecycle, Win32 packaging & OS defaults:** [EUCPilots](https://github.com/EUCPilots) (`evergreen-module`, `vcredist`, `packagefactory`, `evergreen-packages`) and [aaronparker/defaults](https://github.com/aaronparker/defaults) / [remediations](https://github.com/aaronparker/remediations).
