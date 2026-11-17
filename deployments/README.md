# deployments/

部署脚本写的清单，也是脚本判断「这一步做过没有」的唯一依据。**不要手改**，
改错了脚本会把 A 池当成 B 池（`_assertReusable` 会拦下不一致的配置，但拦不住你把它删掉）。

| 文件 | 谁写 | 内容 |
|---|---|---|
| `sepolia.tokens.json` | `script/DeployTokens.s.sol` | 两个 Mock 代币地址、铸造量、持有人 |
| `sepolia.json` | `script/Deploy.s.sol` | 实现合约、代理、四个角色地址、周期参数 |

两条规则：

1. **干跑不写盘。** 只有带 `--broadcast` 时才落盘（`vm.isContext(ScriptBroadcast)`），
   所以 `forge script` 试跑一百次也不会让脚本以为链上已经有池子。
2. **清单与链上不一致时，以链上为准重新部署，不要手工修补。** 如果清单里的代理地址上
   没有代码（上一轮广播中断），脚本会打印 `record exists but proxy has no code`
   并当成全新部署；这种情况删掉清单文件即可，不需要别的操作。

想从头再来（例如换了代币）：删掉这里的 json，重跑脚本。**删之前先确认链上那个池子
里没有用户资金**——脚本不会替你检查这一点。
