#!/bin/bash
set -e

echo "Anti-Stampede + DLQ + Idempotency POC Execution"
echo "=============================================="
echo "Running comprehensive demonstration of distributed systems patterns"

# Check if .env exists
if [ ! -f .env ]; then
    echo "ERROR: Configuration file (.env) not found."
    echo "Please run 'make setup' first to initialize the environment."
    exit 1
fi

echo ""
echo "EXECUTING COMPREHENSIVE POC DEMONSTRATION:"
echo "This will showcase three critical distributed systems patterns:"
echo ""
echo "1. ANTI-STAMPEDE PATTERN"
echo "   - Batch processing prevents overwhelming downstream systems"
echo "   - Controlled message throughput during traffic spikes"
echo ""
echo "2. IDEMPOTENCY PATTERN" 
echo "   - Prevents duplicate processing using unique keys"
echo "   - Ensures exactly-once semantics for critical operations"
echo ""
echo "3. DLQ RECOVERY PATTERN"
echo "   - Smart recovery strategies for different failure types"
echo "   - Prevents message loss and implements fault tolerance"
echo ""
echo "Starting demonstration..."

pipenv run python comprehensive_demo.py

echo ""
echo "DEMONSTRATION COMPLETE"
echo "======================"
echo "All three distributed systems patterns have been successfully demonstrated:"
echo "- Message batching and anti-stampede processing"
echo "- Duplicate detection and prevention via idempotency"  
echo "- Failed message recovery using DLQ strategies"
echo ""
echo "The system processed messages using local emulators that replicate"
echo "production AWS behavior without requiring external accounts or services."
