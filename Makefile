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

.PHONY: run-xcrypto-scan
run-xcrypto-scan:
	@echo "Running x/crypto usage scan..."
	@./scripts/xcrypto-lookup.sh

.PHONY: run-gomock-scan
run-gomock-scan:
	@echo "Running deprecated gomock usage scan..."
	@./scripts/gomock-lookup.sh

.PHONY: run-ubi-scan
run-ubi-scan:
	@echo "Running UBI7 image usage scan..."
	@./scripts/ubi-lookup.sh --version ubi7

.PHONY: run-golangci-lint-scan
run-golangci-lint-scan:
	@echo "Running golangci-lint version scan..."
	@./scripts/golangci-lint-checker.sh

.PHONY: run-ioutil-scan
run-ioutil-scan:
	@echo "Running deprecated io/ioutil usage scan..."
	@./scripts/ioutil-deprecation-checker.sh

.PHONY: run-all-scans
run-all-scans: run-xcrypto-scan run-gomock-scan run-ubi-scan run-golangci-lint-scan run-ioutil-scan
	@echo ""
	@echo "✅ All scans completed!"

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  lint                  - Check shell script formatting (same as CI)"
	@echo "  format                - Fix shell script formatting"
	@echo "  fix-lint              - Fix shell script formatting (alias for format)"
	@echo "  run-xcrypto-scan      - Scan for golang.org/x/crypto direct usage"
	@echo "  run-gomock-scan       - Scan for deprecated golang/mock usage"
	@echo "  run-ubi-scan          - Scan for UBI7 image usage"
	@echo "  run-golangci-lint-scan - Scan for outdated golangci-lint versions"
	@echo "  run-ioutil-scan       - Scan for deprecated io/ioutil usage"
	@echo "  run-all-scans         - Run all lookup scans"
	@echo "  help                  - Show this help message"

