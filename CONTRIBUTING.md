# Contributing to movie-cli

Thank you for your interest in contributing!

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch
4. Make your changes
5. Run tests
6. Submit a pull request

## Development Setup

```bash
# Clone
git clone https://github.com/your-fork/movie-cli.git
cd movie-cli

# Install test framework (bats-core + helpers)
git clone --depth 1 https://github.com/bats-core/bats-core.git tests/bats
git clone --depth 1 https://github.com/bats-core/bats-support.git tests/bats-support
git clone --depth 1 https://github.com/bats-core/bats-assert.git tests/bats-assert

# Run tests
tests/bats/bin/bats tests/*.sh
```

### Dependencies

| Dependency | Required | Purpose |
|-----------|----------|---------|
| `curl` | Yes | HTTP requests |
| `jq` | Yes | JSON processing |
| `mpv` | Yes | Video player |
| `python3` | Yes | Regex extraction |
| `openssl` | Yes | URL signing |
| `socat` | Yes | MPV progress tracking |
| `fzf` | No | Fuzzy selection |
| `shellcheck` | No | Linting |

## Code Style

- Use `shellcheck` for linting
- Follow existing patterns in `lib/`
- Keep functions focused (single responsibility)
- Use descriptive variable names
- Add comments for complex logic

## Plugin Development

See `plugins/_template.sh` for the interface contract.

### Required Functions

- `plugin_search(query, quality)` — Returns JSON array
- `plugin_get_url(id, quality)` — Returns video URL

### Plugin Metadata

```bash
PLUGIN_NAME="MyPlugin"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie")
PLUGIN_REQUIRES=("curl" "jq")
```

## Testing

```bash
# Run all tests
tests/bats/bin/bats tests/*.sh

# Run a specific test file
tests/bats/bin/bats tests/test_core.sh

# Run a specific test by name
tests/bats/bin/bats --filter "VERSION is set" tests/test_core.sh
```

- Write tests for new functions
- Mock external services
- Test edge cases
- Ensure all tests pass before submitting

## Pull Requests

- Keep PRs focused on one change
- Include tests for new functionality
- Update documentation if needed
- Follow existing code style

## Issues

- Use GitHub Issues for bugs and feature requests
- Include reproduction steps for bugs
- Specify your OS and bash version

## License

By contributing, you agree that your contributions will be licensed under MIT.
