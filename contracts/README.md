# Contracts for avd-intune

Consumes `entra-manifest.json` device and user group targets and `contracts/cloud-environments.json` (`C26`, `avd-cloud-environments/v1`), and produces `intune-manifest.json` (enrolled policy IDs, compliance baseline state, `cloud` (`"commercial"` | `"usgov"`), `complianceProfile` (`"standard"` | `"itar-cui"`), MDM readiness, optional platform assignment filter IDs, and optional Windows 365 Cloud PC provisioning policy and user settings IDs).

See [avd-ops decision 0009](https://avd-ops.dev/docs/decisions/0009-split-landing-zone-into-five-control-planes.html), [decision 0012](https://avd-ops.dev/docs/decisions/0012-desktop-devops-for-avd-win365-and-intune.html), and [decision 0013](https://avd-ops.dev/docs/decisions/0013-azure-us-government-and-gcc-high-support.html).

