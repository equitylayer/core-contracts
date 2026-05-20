#!/bin/bash
set -e
set -a
source .env
set +a

RPC_URL=${RPC_URL:-http://127.0.0.1:8545}

# Get chain ID from RPC
CHAIN_ID=$(cast chain-id --rpc-url $RPC_URL 2>/dev/null || echo "unknown")
echo "Deploying to chain ID: $CHAIN_ID"

# For non-mainnet, deploy mock external dependencies (Chainalysis, optionally EAS)
if [ "$CHAIN_ID" != "1" ]; then
    echo ""
    echo "=== Deploying Mock Dependencies ==="
    forge script script/DeployDevelopment.s.sol:DeployDevelopment \
        --rpc-url $RPC_URL \
        --private-key $PRIVATE_KEY \
        --broadcast
fi

# Deploy production contracts
echo ""
echo "=== Deploying Production Contracts ==="
forge script script/DeployFactories.s.sol:DeployFactories \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast
