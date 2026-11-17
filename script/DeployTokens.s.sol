// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @title 在 Sepolia 造出质押币与奖励币，并把额度打给部署地址
/// @notice 只有在测试网上才需要这一步。真实项目里换成「确认两个已有代币的地址」。
///
/// @dev 为什么单独一个脚本：代币一旦造好就不再变动，而池子会反复重部署。
///      两件事写在同一份脚本里，重跑部署就把代币也重造一遍，币的地址一换，
///      之前发给用户的钱包里的余额全成了另一个币。
///
///      幂等：`deployments/sepolia.tokens.json` 存在就直接打印已有地址并退出。
contract DeployTokens is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    string internal constant RECORD = "./deployments/sepolia.tokens.json";

    /// 质押币总量：够 1000 个地址各质押 1000 枚
    uint256 internal constant STAKE_SUPPLY = 1_000_000e18;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "this script is Sepolia-only");

        address me = msg.sender;

        if (vm.exists(RECORD)) {
            // 读的是本脚本自己写的清单，不是任意路径
            // forge-lint: disable-next-line(unsafe-cheatcode)
            string memory existing = vm.readFile(RECORD);
            address stake = vm.parseJsonAddress(existing, ".stakeToken");
            address reward = vm.parseJsonAddress(existing, ".rewardToken");

            // 清单只能证明「上次脚本跑到了写文件那一步」，不能证明链上真有合约。
            // 广播中途失败时这份文件照样会被写下来（2026-11-17 实际踩到：gasLimit 差几千，
            // CREATE 回滚，清单却记了两个空地址）。所以这里必须回链上核一遍代码
            require(
                stake.code.length > 0 && reward.code.length > 0,
                "record points to addresses without code: delete deployments/sepolia.tokens.json and redeploy"
            );

            console2.log("tokens already recorded, nothing deployed");
            console2.log("  stake :", stake);
            console2.log("  reward:", reward);
            _printEnvSnippet(stake, reward);
            return;
        }

        uint256 fund = _uintOr("FUND_AMOUNT", 604_800e18);

        vm.startBroadcast();
        MockERC20 stakeToken = new MockERC20("Stake Token", "STK");
        MockERC20 rewardToken = new MockERC20("Reward Token", "RWD");
        // mint 只有 owner 能调，而 owner 就是这次广播的发送者
        stakeToken.mint(me, STAKE_SUPPLY);
        rewardToken.mint(me, fund);
        vm.stopBroadcast();

        // 先确认两个合约真的在链上，再写清单。
        // 反过来的顺序（先写清单再检查）会在广播失败时留下一份指向空地址的记录，
        // 下一次运行就会「已记录、跳过部署」，把错误固化下来
        require(
            address(stakeToken).code.length > 0 && address(rewardToken).code.length > 0,
            "deployment did not land: no code at a token address"
        );

        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("dry run: token record NOT written (add --broadcast to commit)");
            return;
        }

        vm.createDir("./deployments", true);
        string memory obj = "tokens";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "stakeToken", address(stakeToken));
        vm.serializeUint(obj, "stakeSupply", STAKE_SUPPLY);
        vm.serializeUint(obj, "rewardMinted", fund);
        vm.serializeAddress(obj, "holder", me);
        string memory json = vm.serializeAddress(obj, "rewardToken", address(rewardToken));
        vm.writeJson(json, RECORD);

        console2.log("stake token :", address(stakeToken));
        console2.log("reward token:", address(rewardToken));
        console2.log("minted to   :", me);
        _printEnvSnippet(address(stakeToken), address(rewardToken));
    }

    /// 空字符串当作「没设置」，与 set-env.ps1 里 `$env:X = ""` 的写法对齐
    function _uintOr(string memory name, uint256 defaultValue) internal view returns (uint256) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) return defaultValue;
        return vm.parseUint(raw);
    }

    function _printEnvSnippet(address stakeToken, address rewardToken) internal pure {
        console2.log("");
        console2.log("paste into set-env.ps1:");
        console2.log(string.concat('$env:STAKE_TOKEN  = "', vm.toString(stakeToken), '"'));
        console2.log(string.concat('$env:REWARD_TOKEN = "', vm.toString(rewardToken), '"'));
    }
}
