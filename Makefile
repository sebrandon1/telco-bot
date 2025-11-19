.PHONY: lint
lint:
	@echo "Running shfmt on scripts folder..."
	shfmt -d scripts

.PHONY: format
format:
	@echo "Formatting shell scripts in scripts folder..."
	shfmt -w scripts

.PHONY: fix-lint
fix-lint: format
	@echo "Linting fixes applied!"

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  lint     - Check shell script formatting (same as CI)"
	@echo "  format   - Fix shell script formatting"
	@echo "  fix-lint - Fix shell script formatting (alias for format)"
	@echo "  help     - Show this help message"

