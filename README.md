<p align="center">
  <img src="img/logo_horizontal_text_white.svg" alt="Excalibur" width="380">
</p>

<h1 align="center">Chronicler</h1>

<p align="center">
  <strong>The faithful scribe of Camelot</strong> — <em>&ldquo;because even the Knights of the Round Table needed someone to write down what happened.&rdquo;</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-linux-blue" alt="Platform">
  <img src="https://img.shields.io/badge/runtime-docker%20%7C%20kubectl-blue" alt="Runtime">
  <img src="https://img.shields.io/badge/shell-bash%204.0%2B-green" alt="Shell">
  <img src="https://img.shields.io/badge/excalibur%20SAM-v4.0%2B-purple" alt="Excalibur SAM">
  <img src="https://img.shields.io/badge/license-EULA-lightgrey" alt="License">
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> · <a href="#usage">Usage</a> · <a href="#examples">Examples</a> · <a href="#troubleshooting">Troubleshooting</a> · <a href="#support">Support</a>
</p>

---

Excalibur Chronicler exports application logs from an Excalibur v4 SAM (Streamed Access Management) deployment. It queries the embedded Loki log aggregation service, packages the results into a compressed archive, and optionally encrypts the output for secure transfer to Excalibur support.

## Features

- **Minimal dependencies** — requires only `docker` or `kubectl` on the host
- **Automatic container detection** — finds the right container/pod without manual configuration
- **Time-based filtering** — relative durations (`--since 6h`) or absolute date ranges (`--from` / `--to`)
- **Service and level filtering** — narrow the export to a specific service or log level
- **Automatic pagination** — handles large log volumes by batching queries to Loki
- **Size estimation** — shows entry count and estimated size before exporting
- **Encrypted export** — ECDH envelope encryption (AES-256-CBC + EC P-384) using the Excalibur support public key
- **Docker and Kubernetes** — works with both runtimes out of the box

## Compatibility

| Requirement       | Details                           |
| ----------------- | --------------------------------- |
| Excalibur SAM     | v4.0+                             |
| Container runtime | Docker or Kubernetes (`kubectl`)  |
| Shell             | Bash 4.0+                         |
| Host OS           | Linux                             |
| Optional          | `openssl` (for encrypted exports) |

## Prerequisites

- A running **Excalibur v4 SAM** stack with Loki enabled
- **Docker** or **kubectl** installed and available in `PATH`
- _(Optional)_ **openssl** on the host for encrypted exports. If not available, the script uses `openssl` from the `api` container automatically

## Quick Start

Download the script and make it executable:

```bash
curl -fsSL https://raw.githubusercontent.com/excalibur-enterprise/excalibur-v4-chronicler/refs/heads/devel/excalibur-chronicler.sh -o excalibur-chronicler.sh
chmod +x excalibur-chronicler.sh
```

Verify the download integrity:

```bash
echo "76a4b1d7bd1862044496fcacfc4d14df5fe544dacb6ee089659697038a75c3f6  excalibur-chronicler.sh" | sha256sum -c
```

Export logs with default settings:

```bash
./excalibur-chronicler.sh
```

Example output:

```
[2026-03-26 14:15:00] INFO: Chronicler — Excalibur Log Export
[2026-03-26 14:15:00] INFO: ============================================
[2026-03-26 14:15:00] INFO: Auto-detecting api container (has curl + openssl)...
[2026-03-26 14:15:00] INFO: Using container: api
[2026-03-26 14:15:01] INFO: Consulting the Oracle (Loki)...
[2026-03-26 14:15:01] INFO: The Oracle responds.
[2026-03-26 14:15:01] INFO: LogQL query: {product="excalibur-v4"}
[2026-03-26 14:15:01] INFO: Time range: last 2h
[2026-03-26 14:15:01] INFO: Querying log statistics...
[2026-03-26 14:15:02] INFO:
[2026-03-26 14:15:02] INFO: Estimated export:
[2026-03-26 14:15:02] INFO:   Entries:  12847
[2026-03-26 14:15:02] INFO:   Size:     8 MB (uncompressed)
[2026-03-26 14:15:02] INFO:   Batches:  3 (5000 per batch)
[2026-03-26 14:15:02] INFO:
[2026-03-26 14:15:02] INFO:  Proceed with the chronicle? [Y/n] y
[2026-03-26 14:15:03] INFO: Gathering the chronicles...
[2026-03-26 14:15:04] INFO: Page 1: 5000 entries (total: 5000)
[2026-03-26 14:15:05] INFO: Page 2: 5000 entries (total: 10000)
[2026-03-26 14:15:06] INFO: Page 3: 2847 entries (total: 12847)
[2026-03-26 14:15:06] INFO: Fetched 12847 log entries in 3 page(s)
[2026-03-26 14:15:06] INFO: Packaging 3 batch file(s) into archive...
[2026-03-26 14:15:07] INFO: ============================================
[2026-03-26 14:15:07] INFO: The chronicle is complete.
[2026-03-26 14:15:07] INFO: File: ./excalibur-chronicle-20260326-141500.tar.gz
[2026-03-26 14:15:07] INFO: Size: 1 MB
[2026-03-26 14:15:07] INFO:
[2026-03-26 14:15:07] INFO: Send this chronicle to Excalibur support for analysis.
```

With no options, the script:

- Uses **Docker** as the container runtime (`--runtime docker`)
- Auto-detects the `api` container in the running Excalibur stack
- Exports **all log levels** and **all services** from the **last 2 hours**
- Queries Loki at `http://loki:3100` inside the container network
- Saves the archive to the **current directory**

The script produces an `excalibur-chronicle-<timestamp>.tar.gz` archive.

For **Kubernetes** deployments, specify the runtime explicitly:

```bash
./excalibur-chronicler.sh --runtime kubectl
```

## Usage

```
./excalibur-chronicler.sh [OPTIONS]
```

### Options

| Flag                     | Description                                               | Default                           |
| ------------------------ | --------------------------------------------------------- | --------------------------------- |
| `-t`, `--since DURATION` | Time range to export: `30m`, `6h`, `2d`, `1w`             | `2h`                              |
| `--from DATETIME`        | Start of date range (ISO 8601)                            | —                                 |
| `--to DATETIME`          | End of date range. Requires `--from`                      | now                               |
| `-l`, `--level LEVEL`    | Filter by log level: `error`, `warn`, `info`, `debug`     | all                               |
| `-s`, `--service NAME`   | Filter by service name (e.g. `api`, `core`, `repository`) | all                               |
| `-o`, `--output DIR`     | Output directory                                          | `.`                               |
| `-f`, `--file NAME`      | Custom output archive name                                | `excalibur-chronicle-<timestamp>` |
| `-e`, `--encrypt`        | Encrypt with Excalibur support public key                 | off                               |
| `-r`, `--runtime RT`     | Container runtime: `docker` or `kubectl`                  | `docker`                          |
| `-C`, `--container NAME` | Container/pod name to exec into                           | auto-detected                     |
| `-N`, `--namespace NS`   | Kubernetes namespace (ignored for Docker)                 | `excalibur`                       |
| `--loki-url URL`         | Loki URL inside the container network                     | `http://loki:3100`                |
| `-y`, `--yes`            | Skip the confirmation prompt                              | off                               |
| `-v`, `--verbose`        | Enable verbose/debug output                               | off                               |
| `-h`, `--help`           | Show help message                                         | —                                 |

### Duration Format

| Unit    | Suffix | Example | Range  |
| ------- | ------ | ------- | ------ |
| Minutes | `m`    | `30m`   | 1m–30d |
| Hours   | `h`    | `6h`    |        |
| Days    | `d`    | `2d`    |        |
| Weeks   | `w`    | `1w`    |        |

## Examples

### Export last 6 hours of errors

```bash
./excalibur-chronicler.sh --since 6h --level error
```

```
[2026-03-26 14:20:00] INFO: LogQL query: {product="excalibur-v4", level="error"}
[2026-03-26 14:20:00] INFO: Time range: last 6h
[2026-03-26 14:20:01] INFO: Estimated export:
[2026-03-26 14:20:01] INFO:   Entries:  237
[2026-03-26 14:20:01] INFO:   Size:     184 KB (uncompressed)
[2026-03-26 14:20:01] INFO:   Batches:  1 (5000 per batch)
```

### Export a specific date range

```bash
./excalibur-chronicler.sh --from 2026-03-20 --to 2026-03-22
```

```
[2026-03-26 14:22:00] INFO: LogQL query: {product="excalibur-v4"}
[2026-03-26 14:22:00] INFO: Time range: 2026-03-20 to 2026-03-22
```

### Export from a specific date until now

```bash
./excalibur-chronicler.sh --from 2026-03-25T14:00:00
```

```
[2026-03-26 14:23:00] INFO: LogQL query: {product="excalibur-v4"}
[2026-03-26 14:23:00] INFO: Time range: 2026-03-25T14:00:00 to now
```

### Export logs for a single service

```bash
./excalibur-chronicler.sh --service core
```

```
[2026-03-26 14:25:00] INFO: LogQL query: {product="excalibur-v4", appName="core"}
[2026-03-26 14:25:01] INFO: Estimated export:
[2026-03-26 14:25:01] INFO:   Entries:  4210
[2026-03-26 14:25:01] INFO:   Size:     3 MB (uncompressed)
[2026-03-26 14:25:01] INFO:   Batches:  1 (5000 per batch)
```

### Encrypted export for secure transfer

```bash
./excalibur-chronicler.sh --since 6h --encrypt
```

```
[2026-03-26 14:30:05] INFO: Packaging 1 batch file(s) into archive...
[2026-03-26 14:30:05] INFO: Sealing the chronicle with the Seal of Camelot...
[2026-03-26 14:30:06] INFO: Sealed with enchantment — only Excalibur support holds the key.
[2026-03-26 14:30:06] INFO: ============================================
[2026-03-26 14:30:06] INFO: The chronicle is complete.
[2026-03-26 14:30:06] INFO: File: ./excalibur-chronicle-20260326-143000.tar.gz.enc.tar
[2026-03-26 14:30:06] INFO: Size: 156 KB
```

The encrypted archive (`.enc.tar`) can only be decrypted by Excalibur support.

### Export from a Kubernetes deployment

```bash
./excalibur-chronicler.sh --runtime kubectl --namespace excalibur
```

### Non-interactive export (CI/CD or cron)

```bash
./excalibur-chronicler.sh --since 1w --output /tmp --yes
```

```
[2026-03-26 02:00:00] INFO: Gathering the chronicles...
[2026-03-26 02:00:02] INFO: Page 1: 5000 entries (total: 5000)
[2026-03-26 02:00:04] INFO: Page 2: 5000 entries (total: 10000)
...
[2026-03-26 02:00:38] INFO: Fetched 87431 log entries in 18 page(s)
[2026-03-26 02:00:39] INFO: The chronicle is complete.
[2026-03-26 02:00:39] INFO: File: /tmp/excalibur-chronicle-20260326-020000.tar.gz
[2026-03-26 02:00:39] INFO: Size: 12 MB
```

## Output Format

The script produces a `.tar.gz` archive containing one or more JSON batch files:

```
excalibur-chronicle-20260326-141500.tar.gz
└── excalibur-chronicle-20260326-141500/
    ├── batch-0001.json
    ├── batch-0002.json
    └── batch-0003.json
```

When `--encrypt` is used, the output is a `.tar.gz.enc.tar` file containing the encrypted data and an ephemeral public key. Send the entire `.enc.tar` file to Excalibur support — do not extract or modify it.

## Security and Privacy

The script is designed to be transparent and non-invasive:

- **Read-only** — only reads logs from Loki; does not modify, delete, or write any data to the Excalibur stack
- **No network calls** — does not transmit data anywhere; the exported archive stays on the local filesystem
- **No telemetry** — collects no usage data and does not phone home
- **Encrypted exports** — when `--encrypt` is used, only Excalibur support can decrypt the archive (ECDH envelope encryption with EC P-384 + AES-256-CBC)
- **Ephemeral keys** — the encryption key material is securely deleted immediately after use

If `openssl` is not installed on the host, the script performs encryption inside the `api` container, which has `openssl` pre-installed.

## How It Works

1. **Detect** — locates the `api` container/pod in the running Excalibur stack
2. **Verify** — checks Loki connectivity through the container
3. **Estimate** — queries entry count and byte size to show expected export volume
4. **Gather** — fetches logs using paginated `query_range` requests (5,000 entries per batch)
5. **Package** — compresses all batches into a single `.tar.gz` archive
6. **Seal** _(optional)_ — encrypts the archive using ECDH envelope encryption

## Troubleshooting

### Cannot find the 'api' container/pod

The Excalibur stack is not running, or the container has a non-standard name.

```bash
# Docker — verify the api container is running
docker ps | grep api

# Kubernetes — verify the api pod is running
kubectl -n excalibur get pods -l app=api
```

You can specify the container manually with `--container <name>`.

### Cannot reach Loki

Loki is not running or is not accessible from the `api` container.

```bash
# Verify Loki is running
docker ps | grep loki

# Test connectivity from inside the api container
docker exec api curl -sf http://loki:3100/ready
```

If Loki uses a non-standard URL, specify it with `--loki-url <url>`.

### No log entries found

- Verify the time range covers a period when the system was active
- Check that services are configured to push logs to Loki
- Try a broader filter (remove `--level` or `--service`)
- Use `--verbose` to see the exact LogQL query and Loki responses

### openssl not found

The `--encrypt` flag requires `openssl`. If it is not installed on the host, the script falls back to using `openssl` from the `api` container automatically. No action is needed.

## Support

If you need help or want to submit an exported archive for analysis:

- **Email:** [support@xclbr.com](mailto:support@xclbr.com)
- **Website:** [getexcalibur.com](https://getexcalibur.com)

When contacting support, include the archive file and a brief description of the issue you are investigating. If you used `--encrypt`, the archive can only be read by Excalibur support — no additional encryption is needed for email transfer.

## License

This software is provided under a proprietary EULA. See the [LICENSE](LICENSE) file for the full terms.

Copyright &copy; 2026 Excalibur s.r.o. All rights reserved.
