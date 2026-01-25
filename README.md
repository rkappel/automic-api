# automic-api.sh

A robust Bash-based abstraction layer for the Automic REST API, designed to be consumed as a command by higher-level shell scripts.
It provides structured wrappers around selected Automic REST endpoints with consistent error handling, logging, validation, and machine-readable output.

---

## Features

- Command-style interface for Automic REST API calls
- One wrapper function per API endpoint
- Strict argument and configuration validation
- Machine-readable JSON output (default)
- Built-in retries, timeouts, and HTTP error handling
- Function inventory validation (code → JSON definition)
- Daily log rotation with diagnostics
- Designed for automation and scripting, not interactive use

---

## Supported API Functions

- ping              Connectivity check
- system/health     Automic system health status
- execute_object    Execute an AE object
- get_execution     Query execution / process monitoring
- get_object        Validate object existence

---

## Usage

List supported functions;

./automic-api.sh --help

Detailed help for a specific function:


/automic-api.sh --help execute_object

---

## Requirements

- Bash 4.3 or newer
- Linux

Required tools: curl, jq, mktemp, base64, tr, sleep, date, find

---

## Configuration

Configuration file: automic-api.conf
Must be located in the same directory as the script.

---

## License

MIT License
© 2026 René Kappel
