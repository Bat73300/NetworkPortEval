# NetworkPortEval Privacy Notice

This notice describes the current application. It is not legal advice.

**Publisher / operator:** BC performances — Baptiste CRESTANI  
**Privacy contact:** [bcperf@gmail.com](mailto:bcperf@gmail.com)  
**Effective date:** 2026-09-28

## What NetworkPortEval does

NetworkPortEval is a Mac network connectivity diagnostic tool. It tests only the destinations included in the test template that the user selects and runs. A user-provided destination can be a hostname or IP address; the app may send TCP, UDP, or explicitly selected HTTPS test traffic to it. Use it only for systems you are authorized to test.

## Information processed on the Mac

NetworkPortEval stores settings, templates, a report email address book, and completed reports locally, outside the application bundle. Settings and the address book are under `~/Library/Application Support/NetworkPortEval/Settings`; templates are under `~/Library/Application Support/NetworkPortEval/Templates`; reports are under `~/Library/Application Support/NetworkPortEval/Reports` by default or in the folder the user chooses. The address book contains names, email addresses and user-written comments, and remains on this Mac until entries are deleted. Its comments are not added to report emails. Depending on the tests and connection, reports may contain destination names and ports, test results and timestamps, local source IP addresses, the local network interface MAC address, interface/link type, a tunnel/VPN indication, whether a system proxy was used (or that this is unknown), DNS resolver addresses configured by macOS, HTTPS certificate details, and the public egress IP. The app does not record proxy addresses or credentials, upload these reports or the address book to NetworkPortEval, or operate a NetworkPortEval server.

The report folder and exported reports are not encrypted by NetworkPortEval. Users control their Mac account, chosen folder, backups, exported files, and any sharing of reports. Delete reports in the app and remove exported copies or backups separately.

## External diagnostic requests

Before each manual report, NetworkPortEval asks whether to make HTTPS requests to the following public services. Each scheduled test has its own saved setting to include or omit these app-added checks; older schedules retain the previous enabled behavior until edited:

- Google (`www.google.com/generate_204`) to check an expected web response;
- Apple (`www.apple.com/library/test/success.html`) to check an expected web response;
- ipify (`api.ipify.org`) to retrieve the public egress IP.

These services receive the public source IP address and ordinary connection metadata for those requests. The returned public IP is saved in the local report. NetworkPortEval does not send the local MAC address to these services. Their handling of connection data is governed by their own policies: [Google Privacy Policy](https://policies.google.com/privacy), [Apple Privacy Policy](https://www.apple.com/legal/privacy/), [ipify](https://www.ipify.org/).

The selected test destinations also receive the source address and protocol traffic necessary for the test. NetworkPortEval does not send selected reports or template contents to those destinations beyond the test connection or user-configured UDP payload. When the user chooses **Email report**, the selected addresses are handed to macOS's email composition service together with a CSV attachment; NetworkPortEval does not send the message. The user reviews and sends it in the configured mail app.

## Purpose and legal basis

The information is processed to perform network diagnostics requested by the user, display results, and save/export the report. The user chooses the destinations and initiates a run. The app has no analytics, advertising, account, or telemetry service in this version. The operator does not provide a hosted NetworkPortEval service.

## Retention and deletion

Reports, templates and saved email contacts remain on the Mac until the user deletes them or removes their files. The current version has no automatic retention period. Email handoff creates a CSV in an app-owned temporary folder; the app removes it after the macOS sharing service reports completion or failure and removes abandoned app-owned folders older than 30 days on a later launch. Recent drafts and unrelated temporary files are preserved. External services receive request data according to their own retention practices.

## Choices and requests

Users can skip optional external diagnostics on each manual run and configure the same choice per schedule. Users can delete local reports and saved email contacts in the app, and contact [bcperf@gmail.com](mailto:bcperf@gmail.com) for privacy questions or requests concerning data held by the operator. The operator currently does not receive report contents or address-book entries through the app.

## Children, changes, and contact

NetworkPortEval is a general-purpose network utility, not designed to collect information from children. This notice will be updated if data practices change. Questions: [bcperf@gmail.com](mailto:bcperf@gmail.com).
