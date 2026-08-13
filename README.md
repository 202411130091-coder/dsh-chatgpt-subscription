# dsh-chatgpt-subscription

把 **ChatGPT 订阅**（Plus / Pro 等）接进 **DSH（DeepSeek Harness）** 本地使用的部署配方：
配置模板 + 说明文档 + Windows 一键脚本。

> 一句话架构：DSH 的 `llm-pi-ai` 适配器 → 本地 **Sub2API** 网关 → ChatGPT 订阅账号的
> **Codex OAuth** → OpenAI 上游。模型（如 gpt-5.6 系列）在 DSH 里当普通 provider 用，
> 消耗的是订阅账号里「工作模式 / Codex」那一档**按 token 计量**的额度。

---

## ⚠️ 先读这一段（很重要）

- **违反 OpenAI 服务条款。** 本方案通过非官方内部接口访问 ChatGPT 订阅，OpenAI 随时可能
  封禁账号，且通常**不退款**。**请务必只使用你能承受丢失的账号**，不要用主账号、高价值
  Pro/Team 账号。
- **仅供个人学习、技术研究与非商业性技术交流使用。** 严禁用于商业用途、批量操作、自动化
  滥用、规模化调用或任何形式的二次售卖。
- 本仓库不含任何逆向工程实现本身，底层网关是第三方项目
  [Sub2API](https://github.com/Wei-Shaw/sub2api)（其自带同样的免责声明），这里只提供
  「如何部署 + 如何接入 DSH」的文档与脚本。
- 使用本仓库即代表你已知悉并自行承担由此产生的一切风险（账号封禁、额度扣减、服务不稳定等）。

---

## 它做了什么 / 没做什么

**做了：**
- 一个本地的 OpenAI 兼容网关（Sub2API），用你 ChatGPT 订阅账号做 OAuth 登录（和 opencode
  的「ChatGPT 登录」同款 Codex OAuth 客户端）。
- 一个 DSH 的 `settings.yaml` 配置片段，把该网关注册成 DSH 里的一个 provider（含模型目录、
  上下文窗口、最大输出、推理强度档位）。
- 一键部署脚本（便携 PostgreSQL + Redis + Sub2API，免管理员权限）。

**没做 / 不保证：**
- 不含任何逆向代码、不含 Sub2API 二进制（脚本会从官方 Release 下载）。
- 不保证长期可用——OpenAI 的风控和接口随时可能变化，上游失效时本方案可能立即不可用。
- 不提供任何「绕过封号」或「规模化」能力。

---

## 快速开始

完整教程见 **[docs/guide.zh.md](docs/guide.zh.md)**。最简路径：

1. 准备：一台 Windows、一个 Clash 类代理（用于回源 OpenAI）、一个**可承受丢失**的 ChatGPT 订阅账号。
2. 运行 `scripts\setup.ps1` 部署本地网关（或按教程手动部署）。
3. 把 `dsh/settings.snippet.yaml` 的内容合并进 DSH 的 `settings.yaml`，并在凭据里写入网关的 API Key。
4. 在网关 Web UI 里给账号做一次 OAuth 登录（记得选代理）。
5. 回到 DSH 模型选择器，切到该 provider 即可。

> 脚本是「尽力而为」的自动化；教程里每一步都是人工验证过的，**以教程为准**。

Codex 主控、DSH 执行的通用桥接器与匿名盲测已拆分到独立项目
[`codex-dsh-bridge`](https://github.com/202411130091-coder/codex-dsh-bridge)，不属于本部署配方。

---

## 仓库结构

```
.
├── README.md                  # 本文件
├── LICENSE                    # MIT（第三方组件各保留原许可）
├── THIRD_PARTY_NOTICES.md     # 第三方组件许可与条款提示
├── docs/
│   └── guide.zh.md            # 完整部署教程 + 排坑清单
├── dsh/
│   └── settings.snippet.yaml  # DSH 配置片段（占位符，无密钥）
└── scripts/
    ├── setup.ps1              # 一键部署（下载 + 初始化 + 建分组/密钥/代理/OAuth 链接）
    ├── services.ps1           # 安全启停实现（只操作指定安装目录）
    ├── start-services.cmd     # 启动三件套
    └── stop-services.cmd      # 停止三件套
```

---

## 已知坑（教程里有详细解法）

- Windows 上 Go 解析不了 `Asia/Shanghai` 时区 → 需 `zoneinfo.zip` + `ZONEINFO` 环境变量。
- OAuth 兑换 token 报 `unsupported_country_region_territory` → 网关回源没走代理，需给账号绑代理。
- 模型目录与真实可用模型不一致 → 以网关 `/v1/models` 返回为准。
- 账号并发默认 1，并行任务报 `Concurrency limit exceeded` → 调高账号并发（但注意风控）。

---

## 致谢

- [Sub2API](https://github.com/Wei-Shaw/sub2api)（Apache-2.0，网关本体）
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）
- 社区里关于 ChatGPT 订阅转 API、DSH 自定义 provider 的各类公开讨论

> 本 README 与脚本均为个人整理，与上述项目官方无关。
