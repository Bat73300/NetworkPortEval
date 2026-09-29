# Import flow lists from CSV

Use **Template files → Import flows from CSV…** to add checks to the selected template. Imports add flows; they do not replace the template. Every imported flow starts unchecked, so select the destinations you want before running tests.

## Columns

Required columns:

| Column | Purpose |
| --- | --- |
| `host` | Hostname, IP address or HTTP/HTTPS URL. `hostname`, `host name`, `url`, `ip`, `ip address`, `destination`, and French host headers are also recognized. |
| `port` | Destination port, from 1 to 65535. |

Optional columns:

| Column | Purpose |
| --- | --- |
| `name` | Label shown in the app; maximum 128 bytes. |
| `comment` | Explanation of the destination; maximum 2,000 UTF-8 bytes. |
| `category` | Category label; maximum 128 bytes. A blank value stays uncategorized. If the column is omitted, the app may assign a category to some recognized vendor hostnames locally. |
| `protocol` | `TCP` (default), `UDP`, or `HTTPS`. |
| `payload_hex` | Optional hexadecimal request bytes for a UDP flow. |

Headers are in English. The app accepts comma- or semicolon-delimited CSV, quoted cells, UTF-8 (with or without BOM) and UTF-16. The import limit is 5 MB and 10,000 rows. For a URL, only the hostname is tested; enter the port separately. A URL’s path is not tested.

Imported flows always start unchecked. A `selected` column is ignored, including values such as `true`; select destinations explicitly in Templates before running them.

## Duplicate flows

Destination and port pairs are considered duplicates, regardless of protocol or letter case in the hostname. Existing pairs are skipped and the import summary reports added and skipped rows.

## Choosing a protocol

- `TCP` checks whether a connection can be established. It does not validate TLS or application health.
- `HTTPS` validates the TLS certificate using macOS system trust and the requested hostname. The app sends `HEAD /`; some services may not support this request even when their main application works.
- `UDP` sends a generic probe when `payload_hex` is blank. Many UDP services ignore generic probes, so no response is inconclusive. If a service needs a specific request, supply its bytes in hexadecimal. The built-in DNS example sends a query but does not validate the response contents.

For example:

```csv
name,comment,category,host,port,protocol,payload_hex
Website,Check TLS certificate,Web,example.com,443,HTTPS,
DNS,Ask for example.com A record,Infrastructure,1.1.1.1,53,UDP,123401000001000000000000076578616d706c6503636f6d0000010001
```

See [`examples/flow-imports/`](../../examples/flow-imports/) for Apple, Adobe and Jamf examples and their source/limitations.
