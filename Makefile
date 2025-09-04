.PHONY: install run pdf help

TITLE ?=

help:
	@echo "Targets:"
	@echo "  install  - Install dependencies via Homebrew (Brewfile)"
	@echo "  run      - Capture until final page is detected (requires TITLE)"
	@echo "  pdf      - Rebuild PDF from existing images (requires TITLE)"

install:
	brew bundle

run:
	@if [ -z "$(TITLE)" ]; then \
		echo "Usage: make run TITLE=\"<book title>\""; \
		exit 2; \
	fi
	./scripts/kindle_capture.sh "$(TITLE)"

pdf:
	@if [ -z "$(TITLE)" ]; then \
		echo "Usage: make pdf TITLE=\"<book title>\""; \
		exit 2; \
	fi
	@./scripts/kindle_capture.sh --pdf-only "$(TITLE)"
