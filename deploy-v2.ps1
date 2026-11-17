# Deploy the StakingRewardsV2 implementation to Sepolia.
#
# This only deploys CODE. It does not touch the proxy, does not initialize,
# and does not need any role. The actual switch (upgradeToAndCall) is a separate
# transaction signed by the UPGRADER wallet -- see UPGRADE-V2.md.
#
# Run it from your own terminal (it must ask for the keystore password):
#     powershell -ExecutionPolicy Bypass -File .\deploy-v2.ps1
#
# Keep this file ASCII-only. PowerShell 5.1 decodes BOM-less scripts with the
# system ANSI code page; non-ASCII comments turn into garbage that can swallow
# the following line (that is how STAKE_TOKEN once became empty).

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

. .\set-env.ps1

# The default local proxy (127.0.0.1:64318) answers 502 for api.etherscan.io.
# 7897 is the Clash mixed port and it does work for both RPC and Etherscan.
$env:HTTPS_PROXY = "http://127.0.0.1:7897"
$env:HTTP_PROXY = "http://127.0.0.1:7897"

# EIP-7825 caps one transaction at 16,777,216 gas. On Sepolia (EIP-8037 is live
# there) the V2 runtime is 10,332 bytes at 1,530 gas/byte deposit, so the real
# cost is ~16,356,000. The usual shortcut `-g 1000` cannot be used here:
# 16.36M * 1.3 way exceeds the cap and the node rejects the whole transaction.
# So pass an absolute limit that sits under the cap but above the estimate.
$GAS_LIMIT = 16700000

Write-Host ""
Write-Host "deploying StakingRewardsV2 implementation, gas limit $GAS_LIMIT"
Write-Host ""

forge create src/StakingRewardsV2.sol:StakingRewardsV2 `
    --account deployer `
    --rpc-url $env:SEPOLIA_RPC_URL `
    --gas-limit $GAS_LIMIT `
    --broadcast

Write-Host ""
Write-Host "Next:"
Write-Host "  1. copy the 'Deployed to:' address above"
Write-Host "  2. verify its source (no constructor args):"
Write-Host "     forge verify-contract <NEW_IMPL> src/StakingRewardsV2.sol:StakingRewardsV2 --chain sepolia --etherscan-api-key \$env:ETHERSCAN_API_KEY"
Write-Host "  3. send a little Sepolia ETH to the UPGRADER wallet, it holds no gas right now"
