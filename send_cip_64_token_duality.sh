#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Load environment variables from .env file
if [ -f .env ]; then
  log_info "Loading environment variables from .env file"
  export $(grep -v '^#' .env | xargs)
else
  log_error ".env file not found"
  exit 1
fi

# Validate required environment variables
if [ -z "$L2_RPC_URL" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$TO_ADDRESS" ] || [ -z "$TRANSFER_VALUE" ] || [ -z "$GAS_CURRENCY" ] || [ -z "$CELO_ADDRESS" ]; then
  log_error "Missing required environment variables in .env file:"
  echo "  L2_RPC_URL: ${L2_RPC_URL:-not set}"
  echo "  PRIVATE_KEY: ${PRIVATE_KEY:-not set}"
  echo "  TO_ADDRESS: ${TO_ADDRESS:-not set}"
  echo "  TRANSFER_VALUE: ${TRANSFER_VALUE:-not set}"
  echo "  GAS_CURRENCY: ${GAS_CURRENCY:-not set}"
  echo "  CELO_ADDRESS: ${CELO_ADDRESS:-not set}"
  exit 1
fi

# Derive the from address from the private key
log_info "Deriving sender address from private key"
FROM_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")

# Command 1: send CIP-64 transaction
log_info "Executing Command 1: send CIP-64 transaction"
celocli transfer:celo -n "$L2_RPC_URL" --privateKey="$PRIVATE_KEY" --from="$FROM_ADDRESS" --to="$TO_ADDRESS" --value="$TRANSFER_VALUE" --gasCurrency "$GAS_CURRENCY"

if [ $? -eq 0 ]; then
  log_success "Command 1 completed successfully"
else
  log_error "Command 1 failed"
  exit 1
fi

echo ""

# Command 2: send token duality transaction
log_info "Executing Command 2: send token duality transaction"
cast send "$CELO_ADDRESS" "transfer(address,uint256)" "$TO_ADDRESS" "$TRANSFER_VALUE" -r "$L2_RPC_URL" --private-key "$PRIVATE_KEY"

if [ $? -eq 0 ]; then
  log_success "Command 2 completed successfully"
else
  log_error "Command 2 failed"
  exit 1
fi

echo ""
log_success "All commands completed successfully!"
