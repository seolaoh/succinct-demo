#!/bin/bash

# OP Succinct malicious challenger

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ENV_FILE=".env"

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
  local missing_deps=()

  if ! command_exists jq; then
    missing_deps+=("jq")
  fi

  if ! command_exists curl; then
    missing_deps+=("curl")
  fi

  if ! command_exists cast; then
    missing_deps+=("cast (from foundry)")
  fi

  if [ ${#missing_deps[@]} -ne 0 ]; then
    log_error "Missing required dependencies: ${missing_deps[*]}"
    exit 1
  fi
}

load_env() {
  if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
  else
    log_warn "Environment file $ENV_FILE not found, using system environment variables"
  fi

  local required_vars=("L1_RPC" "FACTORY_ADDRESS" "GAME_TYPE" "PRIVATE_KEY")
  local missing_vars=()

  for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      missing_vars+=("$var")
    fi
  done

  if [ ${#missing_vars[@]} -ne 0 ]; then
    log_error "Missing required environment variables: ${missing_vars[*]}"
    exit 1
  fi

  # Set optional variables with defaults
  FETCH_INTERVAL=${FETCH_INTERVAL:-30}
  MAX_GAMES_TO_CHECK_FOR_CHALLENGE=${MAX_GAMES_TO_CHECK_FOR_CHALLENGE:-100}
  BLOCKSCOUT_ADDRESS=${BLOCKSCOUT_ADDRESS:-""}
}

get_challenger_address() {
  local private_key="$1"
  local address=$(cast wallet address --private-key "$private_key")
  echo "$address"
}

json_rpc_call() {
  local rpc_url="$1"
  local method="$2"
  local params="$3"

  local response=$(curl -s -X POST "$rpc_url" \
    -H "Content-Type: application/json" \
    -d "{
            \"jsonrpc\": \"2.0\",
            \"method\": \"$method\",
            \"params\": $params,
            \"id\": 1
        }")

  echo "$response"
}

get_game_count() {
  local rpc_url="$1"
  local factory_address="$2"

  local count=$(cast call --rpc-url "$rpc_url" "$factory_address" "gameCount()")
  if [ "$count" = "0" ] || [ -z "$count" ]; then
    echo "0"
  else
    echo "$count"
  fi
}

get_game_at_index() {
  local rpc_url="$1"
  local factory_address="$2"
  local game_index="$3"

  local result=$(cast call --rpc-url "$rpc_url" "$factory_address" "gameAtIndex(uint256)" "$game_index")
  if [ -z "$result" ] || [ "$result" = "0x0000000000000000000000000000000000000000" ]; then
    echo ""
  else
    # Extract the 20-byte address from the last part of the struct result
    local address_part=${result#0x}
    local game_address="0x${address_part: -40}"
    echo "$game_address"
  fi
}

get_challenger_bond() {
  local rpc_url="$1"
  local factory_address="$2"
  local game_type="$3"

  # First get the game implementation address
  local game_impl_result=$(cast call --rpc-url "$rpc_url" "$factory_address" "gameImpls(uint32)" "$game_type")

  # Extract the 20-byte address from the 32-byte result
  local impl_address_part=${game_impl_result#0x}
  local game_impl_address="0x${impl_address_part:24:40}"

  if [ -z "$game_impl_address" ] || [ "$game_impl_address" = "0x0000000000000000000000000000000000000000" ]; then
    log_error "No game implementation found for game type $game_type"
    return 1
  fi

  # Now get the challenger bond from the game implementation
  local challenger_bond=$(cast call --rpc-url "$rpc_url" "$game_impl_address" "challengerBond()")

  if [ -z "$challenger_bond" ] || [ "$challenger_bond" = "0" ]; then
    log_error "Failed to get challenger bond"
    return 1
  fi

  echo "$challenger_bond"
}

get_game_claim_data() {
  local rpc_url="$1"
  local game_address="$2"

  local result=$(cast call --rpc-url "$rpc_url" "$game_address" "claimData()")

  if [ -z "$result" ]; then
    echo ""
  else
    echo "$result"
  fi
}

is_game_challengeable() {
  local rpc_url="$1"
  local game_address="$2"

  # Get claim data
  local claim_data=$(get_game_claim_data "$rpc_url" "$game_address")
  if [ -z "$claim_data" ]; then
    log_error "Failed to get claim data"
    return 1
  fi

  # Parse the claim data to get status and deadline
  # The claim data structure is: (parentIndex, counteredBy, prover, claim, status, deadline)
  # We need to decode this to get the status and deadline

  # Get current L1 block timestamp
  local l1_response=$(json_rpc_call "$rpc_url" "eth_getBlockByNumber" "[\"latest\", false]")
  local current_timestamp_hex=$(echo "$l1_response" | jq -r '.result.timestamp')
  local current_timestamp=$(cast --to-dec "$current_timestamp_hex")

  # Extract deadline from claim data
  # The deadline is the last 32 bytes (64 hex characters) in the ClaimData struct
  local deadline_hex=${claim_data: -64} # Get last 64 characters
  local deadline=$(cast --to-dec "0x$deadline_hex")

  # Get the second last 64 characters
  local status_hex=${claim_data: -128:64} # Get 64 chars starting 128 chars from the end
  local status=$(cast --to-dec "0x$status_hex")

  # Check game status before attempting to challenge
  local game_status=$(cast call --rpc-url "$rpc_url" "$game_address" "status()")
  local game_status_decimal=$(cast --to-dec "$game_status")

  # Check if status is Unchallenged (0), deadline hasn't passed, and game status is IN_PROGRESS (0)
  if [ "$status" -eq 0 ] && [ "$current_timestamp" -lt "$deadline" ] && [ "$game_status_decimal" -eq 0 ]; then
    return 0 # Challengeable
  else
    return 1 # Not challengeable
  fi
}

# Function to wait for transactions to be submitted to a game by the proposer
wait_for_game_transactions() {
  local rpc_url="$1"
  local game_address="$2"
  local blockscout_address="$3"
  local required_tx_num="$4"
  local challenge_tx_hash="$5"

  log_info "Waiting for proposer to prove and resolve the game..."

  local tx_count=0
  local last_block=$(cast block-number --rpc-url "$rpc_url")
  local start_block=$last_block

  while [ "$tx_count" -lt "$required_tx_num" ]; do
    sleep 5

    local current_block=$(cast block-number --rpc-url "$rpc_url")

    # Check for new transactions to the game address in the recent blocks
    for ((block = start_block; block <= current_block; block++)); do
      local block_txs=$(cast block --rpc-url "$rpc_url" "$block" --json)

      # Convert game address to lowercase for case-insensitive comparison
      local game_address_lower=$(echo "$game_address" | tr '[:upper:]' '[:lower:]')

      local tx_hashes_in_block=$(echo "$block_txs" | jq -r '.transactions[]?' 2>/dev/null)

      while IFS= read -r tx_hash; do
        if [ -n "$tx_hash" ] && [ "$tx_hash" != "null" ]; then
          local tx_details=$(cast tx --rpc-url "$rpc_url" "$tx_hash" --json 2>/dev/null)

          # Check if this transaction is to our game address and not the challenge tx
          local tx_to=$(echo "$tx_details" | jq -r '.to' 2>/dev/null)
          if [ "$tx_to" = "$game_address_lower" ] && [ "$tx_hash" != "$challenge_tx_hash" ]; then
            tx_count=$((tx_count + 1))

            if [ "$tx_count" -eq 1 ]; then
              log_success "Proof generated via SP1: https://explorer.succinct.xyz/requester/0xfb968b52d25549ec2dd26a9f650a0a0f135a4358"
            fi

            if [ "$tx_count" -eq 1 ]; then
              local msg="proved"
            elif [ "$tx_count" -eq 2 ]; then
              local msg="resolved"
            else
              local msg="rewarded from"
            fi
            log_success "Proposer $msg the game: $blockscout_address/tx/$tx_hash"

            if [ "$tx_count" -ge "$required_tx_num" ]; then
              log_success "Game $game_address has been resolved as DEFENDER_WINS and the proposer has been rewarded!"
              return 0
            fi
          fi
        fi
      done <<<"$tx_hashes_in_block"
    done

    start_block=$((current_block + 1))
  done
}

challenge_game() {
  local rpc_url="$1"
  local game_address="$2"
  local challenger_bond="$3"
  local private_key="$4"
  local blockscout_address="$5"

  log_info "Challenging game at address: $game_address"

  local challenger_bond_decimal=$(cast --to-dec "$challenger_bond")
  local tx_receipt=$(cast send --private-key "$private_key" --rpc-url "$rpc_url" --value "$challenger_bond_decimal" "$game_address" "challenge()")

  if [ $? -eq 0 ]; then
    # Extract transaction hash from the receipt (handle multi-line output)
    local tx_hash=$(echo "$tx_receipt" | tail -n 1 | jq -r '.transactionHash' 2>/dev/null || echo "$tx_receipt" | grep "transactionHash" | tail -n 1 | sed 's/.*transactionHash[[:space:]]*//')
    log_success "Successfully challenged game: $blockscout_address/tx/$tx_hash"

    # Wait for 3 more transactions to be submitted to this game (excluding the challenge tx)
    wait_for_game_transactions "$rpc_url" "$game_address" "$blockscout_address" 3 "$tx_hash"

    return 0
  else
    log_error "Failed to challenge game $game_address"
    return 1
  fi
}

handle_game_challenging() {
  local l1_rpc="$1"
  local factory_address="$2"
  local max_games_to_check="$3"
  local challenger_bond="$4"
  local private_key="$5"
  local blockscout_address="$6"

  log_info "Checking for challengeable games..."

  local game_count=$(get_game_count "$l1_rpc" "$factory_address")
  game_count=$(cast --to-dec "$game_count")
  if [ "$game_count" -eq 0 ]; then
    log_info "No games exist yet"
    return 1
  fi

  # Calculate the range of games to check
  local latest_game_index=$((game_count - 1))
  local start_index=$((latest_game_index - max_games_to_check + 1))
  if [ "$start_index" -lt 0 ]; then
    start_index=0
  fi

  # Check games from newest to oldest
  for ((i = latest_game_index; i >= start_index; i--)); do
    local game_address=$(get_game_at_index "$l1_rpc" "$factory_address" "$i")
    if [ -n "$game_address" ] && [ "$game_address" != "0x0000000000000000000000000000000000000000" ]; then
      if is_game_challengeable "$l1_rpc" "$game_address"; then
        log_info "Found challengeable game at index $i"
        challenge_game "$l1_rpc" "$game_address" "$challenger_bond" "$private_key" "$blockscout_address"
        return 0 # Successfully challenged a game
      fi
    fi
  done

  log_info "No challengeable games found"
  return 1
}

run_challenger() {
  local l1_rpc="$1"
  local factory_address="$2"
  local game_type="$3"
  local fetch_interval="$4"
  local max_games_to_check="$5"
  local private_key="$6"
  local blockscout_address="$7"

  local challenger_bond=$(get_challenger_bond "$l1_rpc" "$factory_address" "$game_type")
  if [ -z "$challenger_bond" ]; then
    log_error "Failed to get challenger bond"
    exit 1
  fi

  local challenger_bond_eth=$(cast --from-wei "$challenger_bond" eth)
  log_info "Challenger bond: $challenger_bond_eth ETH"

  while true; do
    if handle_game_challenging "$l1_rpc" "$factory_address" "$max_games_to_check" "$challenger_bond" "$private_key" "$blockscout_address"; then
      break
    else
      log_info "No games challenged, waiting ${fetch_interval} seconds..."
      sleep "$fetch_interval"
    fi
  done
}

main() {
  log_info "Starting malicious challenger..."

  check_dependencies

  load_env

  local challenger_address=$(get_challenger_address "$PRIVATE_KEY")
  log_info "Challenger address: $challenger_address"

  run_challenger "$L1_RPC" "$FACTORY_ADDRESS" "$GAME_TYPE" "$FETCH_INTERVAL" "$MAX_GAMES_TO_CHECK_FOR_CHALLENGE" "$PRIVATE_KEY" "$BLOCKSCOUT_ADDRESS"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
  --env-file)
    ENV_FILE="$2"
    shift 2
    ;;
  --help | -h)
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --env-file FILE    Environment file to load (default: .env)"
    echo "  --help, -h         Show this help message"
    echo ""
    echo "Required environment variables:"
    echo "  L1_RPC             L1 RPC endpoint URL"
    echo "  FACTORY_ADDRESS    Address of the DisputeGameFactory contract"
    echo "  GAME_TYPE          Type identifier for the dispute game"
    echo "  PRIVATE_KEY        Private key for transaction signing"
    echo ""
    echo "Optional environment variables:"
    echo "  FETCH_INTERVAL                    Polling interval in seconds (default: 30)"
    echo "  MAX_GAMES_TO_CHECK_FOR_CHALLENGE  Maximum games to check (default: 100)"
    echo "  BLOCKSCOUT_ADDRESS                Blockscout explorer URL for transaction links"
    exit 0
    ;;
  *)
    log_error "Unknown option: $1"
    echo "Use --help for usage information"
    exit 1
    ;;
  esac
done

main "$@"
