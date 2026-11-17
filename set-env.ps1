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

$env:SEPOLIA_RPC_URL   = "https://ethereum-sepolia-rpc.publicnode.com"

# ---- 本轮部署的目标地址：全部留空，等新合约自己产生 ----
# 2026-11-17：旧实例整体作废，三个地址不再复用
#   ERC20 池（不可升级版） 0xB39a4222BCc65656FDFCF7d14622a7cE42F4e681
#   旧 pSTK                0x354C959d4e6Ad44eDA2cE68285ADC3C197e8F8Bf
#   旧 pRWD                0x416a8c972630e5b6A74f348f851881B24072d90A
# 旧币不用它的真实理由：那两个 Mock 的 mint 是公开的（连 owner() 都不存在），
# 任何人都能凭空铸 pSTK 再质押进来分奖励；而且 pRWD 只剩 395,200 枚，不够一期 604,800。
#
# 留空是有意的，不是漏填：Deploy.s.sol 把空值当成「缺失」，在广播前一次性列出所有
# 缺失变量并退出，绝不会拿一个作废地址悄悄部署。填法见下面两段注释。
$env:STAKING           = ""     # 部署后填：代理地址（用户唯一该用的地址）
$env:STAKE_TOKEN       = ""     # 由 DeployTokens.s.sol 打印后填
$env:REWARD_TOKEN      = ""     # 由 DeployTokens.s.sol 打印后填

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
$env:IMPLEMENTATION    = ""

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
