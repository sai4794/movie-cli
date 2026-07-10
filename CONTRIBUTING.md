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

# Install test framework
git submodule update --init --recursive

# Run tests
tests/bats/bin/bats tests/
```

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
