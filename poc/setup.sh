#!/bin/bash
set -e

echo "Anti-Stampede + DLQ + Idempotency POC Setup"
echo "=========================================="
echo "Setting up local emulation environment for distributed systems patterns"

# Check if pipenv is installed
if ! command -v pipenv &> /dev/null; then
    echo "Installing pipenv for Python environment management..."
    pip install pipenv
fi

# Set pipenv to create venv in project directory
export PIPENV_VENV_IN_PROJECT=1

# Install dependencies and create venv in .venv/
echo "Installing Python dependencies..."
pipenv install

# Create .env file for local configuration
echo "Creating local emulator configuration..."
cat > .env << EOF
# Local Emulator Configuration - No AWS Account Required
# These URLs point to in-memory emulators that replicate AWS behavior

# Main SQS Queue - Handles message processing with anti-stampede batching
MAIN_QUEUE_URL=local://sqs/anti-stampede-poc

# Dead Letter Queue - Processes failed messages with recovery strategies  
DLQ_URL=local://sqs/anti-stampede-poc-dlq

# DynamoDB Table - Stores idempotency keys to prevent duplicate processing
DYNAMODB_TABLE=poc-idempotency
EOF

echo "Setup completed successfully!"
echo ""
echo "WHAT WAS CONFIGURED:"
echo "- Python virtual environment with required dependencies"
echo "- Local emulator configuration (no external services needed)"
echo "- Environment variables for queue and table references"
echo ""
echo "NEXT STEP: Run 'make run' to execute the comprehensive demonstration"
