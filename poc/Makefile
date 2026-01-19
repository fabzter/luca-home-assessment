.PHONY: setup run clean test help

help: ## Show available commands
	@echo "Anti-Stampede + DLQ + Idempotency POC Commands"
	@echo "=============================================="
	@echo "setup  - Initialize Python environment and local emulator configuration"
	@echo "run    - Execute comprehensive demonstration of all three patterns"
	@echo "test   - Verify local emulators are functioning correctly"
	@echo "clean  - Clean up environment and generated files"

setup: ## Set up Python virtual environment and local configuration
	@./setup.sh

test: ## Quick test of local emulators functionality
	@echo "Testing local AWS emulators..."
	@pipenv run python -c "from robust_emulators import setup_local_infrastructure; setup_local_infrastructure(); print('Local emulators verified successfully')"

run: ## Run the comprehensive POC demonstration
	@./run.sh

clean: ## Clean up environment and generated files
	@echo "Cleaning up POC environment..."
	@rm -rf .venv/ Pipfile.lock
	@rm -f .env
	@echo "Cleanup completed successfully"
