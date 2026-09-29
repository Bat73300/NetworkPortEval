# Endpoint catalog

NetworkPortEval includes optional starter catalogs for common Mac and IT services. They are examples to help an IT team build a focused template; they are not exhaustive allowlists, firewall rules, or a guarantee that a product is healthy.

## Available catalogs

| Catalog | Use it for | Source and scope |
|---|---|---|
| [Apple enterprise services](../examples/flow-imports/NetworkPortEval-Mac-Apple-Enterprise-Flows.csv) | Mac software updates, iCloud, trust and Apple services | Based on [Apple’s enterprise network host and port list](https://support.apple.com/fr-fr/101555). Mac-relevant entries are included; wildcard destinations are omitted. |
| [Adobe Creative Cloud](../examples/flow-imports/NetworkPortEval-Mac-Adobe-Creative-Cloud-Flows.csv) | A starting point for Creative Cloud connectivity | Based on Adobe's public [network endpoints documentation](https://helpx.adobe.com/fr/business/enterprise/manage-services/configure-services/network-endpoints.html?lk#all-adobe-services), reviewed on 2026-09-29. Review the current Adobe guidance before use; several entries use TCP 443 when the source did not specify a port. |
| [Microsoft 365 starter flows](../examples/flow-imports/NetworkPortEval-Mac-Microsoft-365-Starter-Flows.csv) | Common Office, sign-in, Graph, Outlook, Teams and SharePoint starter checks | Based on [Microsoft 365 URLs and IP address ranges](https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges?view=o365-worldwide), reviewed on 2026-09-29. This is not tenant-specific or exhaustive; use Microsoft's endpoint web service for current policy. |
| [Jamf Cloud for Mac](../examples/flow-imports/NetworkPortEval-Mac-Jamf-Cloud-Flows.csv) | Jamf Cloud distribution and shared services | Based on [Jamf’s public IP/domain list](https://learn.jamf.com/r/en-US/jamf-ip-address-list/Jamf_Public_IP_Address_List) and [Jamf’s network ports article](https://learn.jamf.com/r/fr-FR/technical-articles/Network_Ports_Used_by_Jamf_Pro). Select the region used by your tenant. |

## How to use a catalog

1. Download one CSV and import it from **Templates → Template files**.
2. Review the source date, categories and descriptions.
3. Keep only destinations required by your organization and select those flows explicitly.
4. Run a small test first, then share the report with the relevant IT team.

Imported flows start unchecked. A TCP result proves reachability only; UDP silence is inconclusive; HTTPS checks validate the requested hostname and macOS trust. Vendor endpoints change, so verify the current vendor guidance before changing firewall, proxy or MDM policy. Apple, Adobe and Jamf are trademarks of their respective owners. NetworkPortEval is not affiliated with or endorsed by them.

For the complete file notes and the blank CSV format, see the [example imports README](../examples/flow-imports/README.md).
