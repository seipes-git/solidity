# StakingRewards - Sepolia environment
#
# Usage (note the dot and space at the front - it makes the variables
# stay in YOUR current window instead of dying with a child process):
#
#     . .\set-env.ps1
#
# Then verify:
#     $env:STAKING
#
# No private key is stored here. Only public addresses. Signing is done by
# `--account deployer`, which reads the encrypted keystore and asks for a
# password each run.

$env:SEPOLIA_RPC_URL   = "https://sepolia.gateway.tenderly.co"

# 备用 RPC：主站偶发抽风就换一行（都已在这台机器上实测返回 chainId 11155111）
#   https://sepolia.gateway.tenderly.co
#   https://1rpc.io/sepolia
# 换完先验一下，能打印 11155111 再往下走：
#   cast chain-id --rpc-url $env:SEPOLIA_RPC_URL
#
# 注意本机的 HTTP_PROXY / HTTPS_PROXY 指向一个本地代理（127.0.0.1 的随机端口）。
# 那个代理重启或换端口时，forge 会报 `tls handshake eof` / `Connect`，与合约无关。
# 应急：本窗口内 $env:HTTP_PROXY=""; $env:HTTPS_PROXY="" 后重跑（直连同样通）。

# ============================================================================
# 本文件必须保存为「UTF-8 with BOM」。
#
# 原因：Windows 上的旧版 shell 读「无 BOM」文件时按系统 ANSI 代码页解码，
# 中文注释会变成乱码；乱码里若出现续行符，会把下一行整行吞进注释。
# 2026-11-17 就因此让 STAKE_TOKEN 静默变成空值，而报错却是
# "missing env (...): STAKE_TOKEN"，看上去像根本没填。
#
# 编辑器另存时若把 BOM 去掉了，用「UTF-8 with BOM」重新保存即可。
# 验证方法：载入本文件后，下面三个地址都应能正确打印出来。
# ============================================================================

# ---- 本轮部署的目标地址：全部留空，等新合约自己产生 ----
$env:STAKING           = "0xa10313F431f506028b7AB1b06be33556EA21015D"   # 代理，2026-11-17 部署
$env:STAKE_TOKEN       = "0x3F0211345ce621f3845455E6937670f1F4acBf29"   # STK，2026-11-17 部署
$env:REWARD_TOKEN      = "0xC3F080d818D8433cB6ffc5c31E1283Da705545B0"   # RWD，2026-11-17 部署

# Deployer EOA. Keep it identical to `--account deployer`; the deploy script
# refuses to broadcast when the two disagree.
$env:DEPLOYER          = "0x42F3F79D6bA98aaE7D82ee48eB191fdcd4B8870e"

# Demo amount: 1000 tokens, 18 decimals
$env:DEMO_AMOUNT       = "1000000000000000000000"

# ---- UUPS: implementation vs proxy ----
# STAKING is the PROXY: that is the address users interact with, the one that
# holds all state, and the one you upgrade. IMPLEMENTATION is just the code
# container - it has no state and cannot be initialized.
# Deploy in two steps: `forge create ... --gas-limit 16000000` for the
# implementation, then Deploy.s.sol with IMPLEMENTATION set, which creates the
# proxy and initializes it atomically.
$env:IMPLEMENTATION    = "0xAa02E88c49097ac27fb77BAbF11F0df8E525d99D"   # 实现合约，仅供升级时用

# ---- Role identifiers: 32-byte hashes baked into the contract ----
# These are NOT addresses. They are the first argument to grantRole / hasRole.
# admin = 0x00...00 because DEFAULT_ADMIN_ROLE is literally the zero hash.
$env:ROLE_ADMIN       = "0x0000000000000000000000000000000000000000000000000000000000000000"
$env:ROLE_GUARDIAN    = "0x55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a5041"
$env:ROLE_MANAGER     = "0x51785d261c3b3e8c2cfe2d0e108b9ab2b1fb703ff9e9e49aba4ebdc85c36152b"
$env:ROLE_UPGRADER    = "0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3"

# ---- Role holders: wallet addresses, one per role ----
# Empty string means "not set". An empty variable disappears when expanded,
# which turns `grantRole(role, )` into a one-argument call and fails with
# "encode length mismatch". Always print them before broadcasting.
$env:ADDR_GUARDIAN    = "0xcCFf66A6FAE89EB8BeFff9E15805ea0eFdA68f2a"
$env:ADDR_MANAGER     = "0x87674f36257142159fEb83fb58641cd70a5D1a07"
$env:ADDR_ADMIN       = "0x48C4586acc06b9fcdE09a1abFcF1F696fA4C118C"
$env:ADDR_UPGRADER    = "0x06aB17f11A98C536149193cCfCF7bC2B8511511B"

# Clear the old misleading names if a previous session defined them.
# (They used to hold either role hashes or addresses, which made grantRole fail silently.)
foreach ($old in "GUARDIAN_ROLE","REWARDS_MANAGER_ROLE","ADMIN_ROLE","NEW_ACCOUNT") {
    if (Test-Path "env:$old") { Remove-Item "env:$old" }
}

# Deployment parameters (only needed when re-deploying)
$env:REWARDS_DURATION  = "604800"
$env:FUND_AMOUNT       = "604800000000000000000000"
$env:UNSTAKE_COOLDOWN  = "86400"

# Foundry needs this when talking to a local anvil through a proxy
$env:NO_PROXY          = "127.0.0.1,localhost"

Write-Host "env loaded: STAKING=$env:STAKING"
Write-Host "            IMPLEMENTATION=$env:IMPLEMENTATION"
Write-Host "            DEPLOYER=$env:DEPLOYER"
Write-Host "            DEMO_AMOUNT=$env:DEMO_AMOUNT"
Write-Host "role holders:"
Write-Host "            GUARDIAN=$env:ADDR_GUARDIAN"
Write-Host "            MANAGER =$env:ADDR_MANAGER"
Write-Host "            ADMIN   =$env:ADDR_ADMIN"
Write-Host "            UPGRADER=$env:ADDR_UPGRADER"
