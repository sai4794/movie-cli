# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT** open a public GitHub issue
2. Email: security@example.com (or use GitHub Security Advisories)
3. Include: description, steps to reproduce, potential impact
4. Allow 48 hours for initial response

## Scope

In scope:
- Command injection via user input
- Path traversal in file operations
- Plugin abuse (malicious plugins)
- Credential leakage
- Cache poisoning

Out of scope:
- Issues in third-party dependencies (report upstream)
- Issues requiring physical access to the machine

## Security Design

### Input Validation
- All user queries are sanitized before API calls
- Shell metacharacters are stripped
- Query length is limited to 200 characters

### Configuration Safety
- Config files are loaded via key=value parser (NOT `source`)
- Token files have `chmod 600` permissions
- Core configurations and logs do not record user tokens/secrets

### Plugin Isolation
- Plugins are validated before loading
- Required functions and metadata are checked
- API version compatibility is verified

### Network Security
- All API calls use HTTPS only (`--proto '=https'`)
- Curl timeouts prevent hung connections
- No plaintext HTTP connections

### File System Security
- Cache keys are SHA256 hashes (no special characters)
- Temp files use `mktemp -d` with trap cleanup
- `umask 077` ensures restrictive permissions

## Known Limitations

- Plugins execute in the same shell namespace (no sandboxing)
- Self-update uses SHA256 checksums (no GPG signing yet)
- Token management relies on file permissions
- Dynamic API signature parameters and HMAC keys are stored inside client-side plugin modules

## Dependencies

- `curl` — HTTP client
- `jq` — JSON processing
- `mpv`/`vlc`/`iina` — video playback
- `fzf` — fuzzy selection (optional)
