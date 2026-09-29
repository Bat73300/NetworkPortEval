# NetworkPortEval — quick user guide

NetworkPortEval helps anyone check a Mac’s network connectivity and send a clear report to IT. Your IT team can prepare a template for you; experienced users can create their own.

## Install

1. Download the latest notarized build from the [GitHub release page](https://github.com/Bat73300/NetworkPortEval/releases).
2. Unzip it and move **NetworkPortEval.app** to **Applications**.
3. Open the app and choose a template.

## Create or import a template

A **template** is a saved test plan. Choose **New template** to create one from scratch, or open **Template files** to import a CSV prepared by your IT team. After importing, rename the template, review its categories and select only the flows you want to run. Imported flows start unchecked.

The optional [endpoint catalogs](ENDPOINT-CATALOG.md) provide Apple, Adobe and Jamf starter examples. They are reference material, not complete firewall allowlists.

## Create and manage flows

A **flow** is one destination and protocol check inside a template. Choose **Add flow** to enter a hostname or IP address, port and protocol: TCP, UDP or HTTPS. Use the edit control to correct a flow, or the trash control to remove an obsolete one. Keep only destinations approved by your IT team.

## Run a check

1. Open **Templates** and review the selected destinations.
2. Select or clear flows as instructed by your IT team.
3. Click **Run tests**.
4. Choose whether to include the optional public Internet checks.
5. Open **Results** to review each outcome.

TCP checks connectivity. UDP needs a response; silence is inconclusive. HTTPS also checks the certificate and requested hostname.

## Understand and share a report

Open **Overview** for the summary and **Results** for details. Use **Export** to create CSV, TXT, PDF or JSON. You can also use **Email report** to open a draft in your configured mail app. Review the report and remove sensitive hostnames, IP addresses, MAC addresses or VPN details before sharing.

## Send a report by email

From the report overview, choose **Email report**, select the intended recipient and confirm the draft. NetworkPortEval opens a message in your configured mail app with the report attached. Check the recipient, subject and attachment before clicking **Send**. The app does not collect email credentials or send the message itself.

## Schedule recurring checks

Open **Scheduled tests**, choose a saved template and interval, then decide whether public Internet checks are enabled. Schedules run while NetworkPortEval is open. A schedule pauses if its template has no valid selected flow; correct the template and enable it again.

## Import a ready-made catalog

Use the optional [endpoint catalogs](ENDPOINT-CATALOG.md) for Apple, Adobe or Jamf examples. They are starting points, not complete allowlists. Imported flows are unchecked so you always choose what to test.

## Privacy

NetworkPortEval has no account, advertising, analytics or telemetry. Reports and settings stay on your Mac. Public checks contact Google, Apple and api.ipify.org only when you choose them. See the [privacy policy](https://github.com/Bat73300/NetworkPortEval/blob/main/docs/privacy.md).

## Need help?

If a test is blocked, it may reflect a firewall, proxy, VPN or service policy rather than an application failure. Send the report and the exact template used to your IT team.
