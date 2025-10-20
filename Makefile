.PHONY: lint
lint:
	@echo "Running shfmt on scripts folder..."
	shfmt -d scripts

.PHONY: format
format:
	@echo "Formatting shell scripts in scripts folder..."
	shfmt -w scripts

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  lint   - Check shell script formatting (same as CI)"
	@echo "  format - Fix shell script formatting"
	@echo "  help   - Show this help message"

