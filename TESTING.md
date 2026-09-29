# NetworkPortEval — Test build 3

Thank you for helping test NetworkPortEval. This guide covers the private, notarized macOS test release `v0.1.0-test.3` (app build 4).

## Before you start

- You need macOS 26 or later and access to the private GitHub repository.
- Choose `NetworkPortEval-arm64.zip` for an Apple silicon Mac (M1 or later), or `NetworkPortEval-x86_64.zip` for an Intel Mac. If you are unsure, choose **Apple menu → About This Mac** and check **Chip** or **Processor**.
- This is a test build. It is not an emergency network diagnostic or a security certification tool.

## Install or update

1. Open the [v0.1.0-test.3 release](https://github.com/Bat73300/NetworkPortEval/releases/tag/v0.1.0-test.3) and download the ZIP for your Mac. The adjacent `.sha256` file can be used to verify the download.
2. Double-click the ZIP to extract `NetworkPortEval.app`.
3. Move the app to **Applications**. If you are replacing an older copy, quit it first and replace that copy. Do not delete the app's Application Support data when updating.
4. Open the app. The notarized build should pass normal macOS Gatekeeper checks. If macOS shows an unexpected security warning, stop and report the exact wording; do not bypass the warning.

Replacing the app does not intentionally remove templates, settings, contacts, or saved reports. Keep backups of anything important during this test.

## Run a basic check

1. On a fresh install, open **Templates** and review the five public HTTPS examples before running them. They contact Google, Apple, Cloudflare, GitHub, and Wikipedia.
2. Select only the checks you want to run, then click **Play**. For a manual run, choose whether to include the public Internet checks when prompted. These contact named public services and `api.ipify.org`; the latter returns your public egress IP.
3. Wait for the run to finish. Review **Overview**, then open **Results** and the saved report. Try exporting a report if useful.
4. If you want to try scheduling, create a schedule with a test template and a short interval. Choose whether to include the app-added public Internet checks. This choice is saved with the schedule, so scheduled runs never need an interactive prompt.

For optional vendor-specific imports, download examples from [`examples/flow-imports`](https://github.com/Bat73300/NetworkPortEval/tree/v0.1.0-test.3/examples/flow-imports). Read its README first. Apple, Adobe and Jamf samples contain many flows; import only the vendor and region you need, then select a small subset for an initial test. The Jamf sample needs your organization’s own Jamf Pro Cloud hostname to test the management server itself.

## Understand the results

- **Open** means a TCP connection was established or a UDP datagram response was received. It does not prove that an application or service is healthy.
- **Closed** means the destination explicitly refused a TCP connection.
- **Inconclusive** usually means there was no response before timeout. UDP silence does not prove a port is closed.
- **Error** reports a DNS resolution or network error; read the detail for the reported cause.
- Only an explicitly selected **HTTPS** flow checks TLS certificate trust and hostname. A TCP check alone does not validate TLS or HTTP health.

Results depend on your network, firewall, VPN, DNS and the remote service. A different result from the app owner is useful feedback; it does not necessarily mean the app is broken.

## Privacy when sharing feedback

Reports can contain tested hostnames, your local IP and MAC addresses, interface and VPN information, configured DNS, public egress IP, and timestamps. App-owned report files use owner-only file permissions, but they are stored locally and are not encrypted by the app. Public Internet checks contact the named services and reveal normal connection metadata to them.

Before sharing a screenshot, export, or report, remove or obscure personal, company, device, hostname and network details. Do not send passwords, certificates, API keys, or other secrets. Share only the minimum information needed to describe a problem.

The app displays a reminder before export or email. Email attachments are placed in a private temporary folder and removed after the macOS sharing service reports completion or failure. Confirm the attached CSV is present in the email draft before sending. If the app exits unexpectedly before macOS reports completion, the app removes its own abandoned temporary attachment folders after 30 days on a later launch; recent drafts are preserved.

## Send feedback

Please report:

- Mac model/chip (Apple silicon or Intel) and macOS version;
- the steps you took and what you expected;
- what happened, including the exact error text if any;
- whether the problem repeats, and whether VPN or a managed network was active.

Use the repository's **Issues** tab or contact [bcperf@gmail.com](mailto:bcperf@gmail.com). Never attach an unredacted report. Tell us if you prefer not to share a report at all; a short description is fine.

## Remove the test build

To remove only the app, quit NetworkPortEval and move `NetworkPortEval.app` from Applications to the Trash. This keeps your reports, templates, schedules and settings.

For a complete reset, quit the app and run [`scripts/uninstall-macos.sh`](scripts/uninstall-macos.sh) from Terminal. It previews the app copies and app-specific settings/data it finds; run it with `--apply` only if you want to permanently delete those settings, templates, schedules and reports. It also checks for data left by the app's former `FluxCheck` name. In a custom report folder, it removes only JSON files whose contents match the app's report or folder-metadata format; unrelated or malformed files and the folder itself are preserved. Recent temporary email drafts are preserved. Back up any reports or settings you may want to keep before proceeding.

After a complete reset, reopen the app. If the saved template file was removed, the app should create a fresh **Public network checks** template with five public HTTPS examples. Existing template data, even an empty template, is loaded as-is and does not trigger that first-run setup.
