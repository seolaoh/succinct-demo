# OP Succinct Malicious Challenger

It monitors the DisputeGameFactory contract for challengeable games and automatically challenges them when found.

## Prerequisites

Before running the script, ensure you have the following dependencies installed:

### Required Dependencies

1. **jq** - JSON processor for parsing RPC responses

   ```bash
   # macOS
   brew install jq
   
   # Ubuntu/Debian
   sudo apt-get install jq
   
   # CentOS/RHEL
   sudo yum install jq
   ```

2. **curl** - HTTP client for RPC calls

   ```bash
   # Usually pre-installed, but if not:
   # macOS
   brew install curl
   
   # Ubuntu/Debian
   sudo apt-get install curl
   ```

3. **cast** - Foundry's command-line tool for Ethereum interactions

   ```bash
   # Install Foundry (includes cast)
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

## Configuration

### Environment Variables

Copy `.env.example` to `.env` file in the same directory as the script:

```bash
cp .env.example .env
```

```env
# Required Configuration
L1_RPC=https://your-l1-rpc-endpoint
FACTORY_ADDRESS=0x...  # Address of the DisputeGameFactory contract
PRIVATE_KEY=0x...      # Private key for transaction signing
BLOCKSCOUT_ADDRESS=https://your-blockscout-address  # Blockscout explorer URL for transaction links
GAME_TYPE=42           # Type identifier for the dispute game

# Optional Configuration
FETCH_INTERVAL=30                     # Polling interval in seconds (default: 30)
MAX_GAMES_TO_CHECK_FOR_CHALLENGE=100  # Maximum games to check (default: 100)
```

## Usage

### Basic Usage

1. Run the script:

   ```bash
   ./challenger.sh
   ```

## How It Works

The script runs in an infinite loop that scans recent games and challenges the first challengeable game. It then waits for
some transactions from proposer submitted to conclude the game, and exits.

### Example Output

```log
[INFO] Starting malicious challenger...
[INFO] Challenger address: 0xE25583099BA105D9ec0A67f5Ae86D90e50036425
[INFO] Challenger bond: 1.000000000000000000 ETH
[INFO] Checking for challengeable games...
[INFO] Found challengeable game at index 101
[INFO] Challenging game at address: 0x5fa1bd32a97cc2fcbd2d1315d5d2f98196cce3b0
[SUCCESS] Successfully challenged game: https://celo-baklava.blockscout.com/tx/0x234708a9ba9cbc473f83d7bff5e04a4efec1673dd6c0522ce5797b87e7c773f5
[INFO] Waiting for proposer to prove and resolve the game...
[SUCCESS] Proof generated via SP1: https://explorer.succinct.xyz/requester/0xfb968b52d25549ec2dd26a9f650a0a0f135a4358
[SUCCESS] Proposer proved the game: https://celo-baklava.blockscout.com/tx/0xbd3a75cfa319519916c638773201064e20b78d5f0c48d004f9fdbc7ea02e80ae
[SUCCESS] Proposer resolved the game: https://celo-baklava.blockscout.com/tx/0x6c97c3db0ea9f8877461554882a7c06a795d59f289479c2fbdf8cafe44521611
[SUCCESS] Proposer rewarded from the game: https://celo-baklava.blockscout.com/tx/0x03f4d8314c8f1eb222bbe89788b2093960c06f34b5f96f8b06cb611ef4d7becc
[SUCCESS] Game 0x5fa1bd32a97cc2fcbd2d1315d5d2f98196cce3b0 has been resolved as DEFENDER_WINS and the proposer has been rewarded!
```
