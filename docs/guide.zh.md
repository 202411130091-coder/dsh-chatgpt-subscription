# 部署指南：把 ChatGPT 订阅接进 DSH

> 阅读前请先看 [README.md](../README.md) 顶部的风险声明。
> 本教程在 **Windows 11 + PowerShell 5.1/7 + Node 无需** 的环境下验证通过，日期 2026-08。

---

## 0. 你需要准备什么

| 项 | 说明 |
|---|---|
| 一台 Windows | 无需管理员权限（组件都是便携版，跑在用户态） |
| 一个代理 | Clash / v2ray 类，**本机混合端口**（默认假设 `127.0.0.1:7897`），用于回源 OpenAI |
| 一个 ChatGPT 订阅账号 | **能承受丢失的**（Plus 即可），OAuth 登录用 |
| DSH | 已装好、能跑，且 `llm-pi-ai` 适配器可用（web 配置默认已挂载） |

---

## 1. 架构一图流

```
DSH (llm-pi-ai, provider: chatgpt-sub)
        │  OpenAI 兼容 /v1/chat/completions
        ▼
Sub2API 本地网关 (127.0.0.1:8080)   ← 数据库: PostgreSQL, 缓存: Redis
        │  账号走 Codex OAuth（和 opencode 的 ChatGPT 登录同款客户端）
        ▼  （经你配的代理出口）
OpenAI 上游（订阅里「工作模式/Codex」那档 token 额度）
```

要点：DSH 只认「OpenAI 兼容」这一层，它不关心后面是官方 API 还是订阅桥。订阅桥做的
就是「OAuth 登录 + 把请求转发到 Codex 上游」，所以吃的是**订阅 token 额度**，不是网页聊天
那 80 条/3 小时。

---

## 2. 部署本地网关

### 2.1 自动（推荐先试）

```powershell
cd scripts
.\setup.ps1                      # 默认装到 ..\runtime，端口 8080
# 可选参数：
#   .\setup.ps1 -InstallDir D:\sub2api -ProxyPort 7890
#   .\setup.ps1 -DownloadProxy http://127.0.0.1:7890   # GitHub 慢/被墙时
# 同机已有服务时，三个本地服务端口必须一起避让：
#   .\setup.ps1 -InstallDir D:\sub2api-test `
#     -PostgresPort 15432 -RedisPort 16379 -ServerPort 18080
```

脚本会：下载便携 PG/Redis/Sub2API + 时区数据 → 随机生成密钥 → 起服务 → 建 代理/分组/API Key
→ 验证能生成带代理的 OAuth 授权链接。**凭据会存在 `<安装目录>\secrets.txt`，别提交 git。**
脚本拒绝覆盖非空安装目录；失败时只清理本次启动、且属于该安装目录的进程。

OAuth 的 `session_id` 与 `state` 必须连续。脚本把“成功生成授权链接”作为自动化终点；真正绑定账号时，
请进入 Web UI 的“添加 OpenAI 账号”流程，由同一个 UI 会话重新生成链接并完成登录，不要把脚本链接的
回调粘贴进一个新建的 UI 会话。

### 2.2 手动（自动失败时的对照表）

三件套，全是便携版：

| 组件 | 来源 | 说明 |
|---|---|---|
| PostgreSQL 17.x | EnterpriseDB 的 `windows-x64-binaries.zip` | 解压到 `pgsql\` |
| Redis | zkteco-home/redis-windows 的 `redis-x.y.z-windows.zip` | 解压到 `redis\` |
| Sub2API | Wei-Shaw/sub2api 的 `windows_amd64.zip` | 解压到 `app\` |
| 时区数据 | Go 仓库 `lib/time/zoneinfo.zip` | 放 `app\zoneinfo.zip` |

关键手动步骤（顺序不能乱）：

```powershell
# 1) PostgreSQL 初始化 + 启动 + 建库
initdb -D <install>\pgdata -U postgres -A scram-sha-256 --pwfile=pgpw.txt -E UTF8 --locale=C
pg_ctl -D <install>\pgdata -l <install>\pgdata\pg.log start -o "-p 5432"
$env:PGPASSWORD="<pg密码>"; createdb -h 127.0.0.1 -p 5432 -U postgres sub2api

# 2) Redis
redis-server --port 6379 --bind 127.0.0.1

# 3) Sub2API —— 两个环境变量缺一不可
$env:DATA_DIR = "<install>\app\data"      # 见坑 7.1
$env:ZONEINFO = "<install>\app\zoneinfo.zip"  # 见坑 7.2
sub2api.exe
```

首次启动会进「安装向导」，用它的 `POST /setup/install` 接口提交数据库/Redis/管理员信息，
装完手动重启，再往它生成的 `config.yaml` 里补一行 `run_mode: simple`（跳过计费/余额校验）。

---

## 3. 网关初始化（代理 / 分组 / 密钥）

登录 Web UI（`http://127.0.0.1:8080`），或直接调管理 API。需要做的四件事：

1. **建代理**：`127.0.0.1:7897`，协议 `http`（Clash 混合端口）。→ 见坑 7.3，不建会报 `unsupported_country`。
2. **建分组**：平台选 `openai`，`rate_multiplier` 填 1（必须 >0，否则 500）。
3. **建 API Key**：给 DSH 用，记下 `sk-...`。
4. **把 Key 分到分组**。

（首次用管理 API 会要求「合规确认」，POST `/api/v1/admin/compliance/accept`，
短语为英文句：`I have read, understood, and agree to the Sub2API Deployment and Operation Compliance Commitment`。）

---

## 4. 接进 DSH

### 4.1 写 DSH 配置

把 [`dsh/settings.snippet.yaml`](../dsh/settings.snippet.yaml) 的内容合并进
`$DSH_HOME\settings.yaml`（默认 `C:\Users\<你>\.dsh\settings.yaml`）。

把网关的 API Key 写进 `$DSH_HOME\.credentials.yaml`：

```yaml
SUB2API_API_KEY: sk-xxxx   # 上一步创建的那把
```

DSH 的 settings 会热加载，刷新网页即可；不放心就重启 DSH。

### 4.2 绑账号（必须你自己登录）

1. 网关 UI → 「账号/渠道」→ 添加 OpenAI/ChatGPT 账号 → OAuth 登录。
2. **代理一定要选上**（就是上一步建的 clash）。
3. 浏览器跳 auth.openai.com，登录你的订阅账号。
4. 登录完回调到 `localhost:1455/auth/callback?code=...`；若打不开，把地址栏整条带 `code=` 的
   地址粘回 UI 的输入框即可。

### 4.3 用

DSH 模型选择器 → 选 `ChatGPT Plus (sub2api)` → 选 `gpt-5.6-sol` 等模型 → 正常发任务。
DSH 的 harness（pwsh / 文件 / 子代理 / 工作流）由该模型驱动。

---

## 5. 模型与推理强度

- 模型 id 以网关 `GET /v1/models` 返回的为准（上游目录会变，别照抄历史列表）。
- `gpt-5.6-sol` 支持显式推理强度，实测档位：**`none / low / medium / high / xhigh / max`**
  （注意：**没有 `minimal`**，它的「关闭」档叫 `none`）。snippet 里已把这些档位映射好。
- 上下文/最大输出按官方目录填：5.6 系列 272K/128K；`gpt-5.4-mini`、`gpt-5.2` 是 400K/128K。

---

## 6. 并行 & 额度

- 账号默认并发 `1`，并行任务会报 `Concurrency limit exceeded for account`。在账号里调高即可，
  但**别调太大**（见坑 7.6）。
- 额度是订阅的 token 额度，重度任务消耗快；在网关面板能看到剩余量与限流状态。

---

## 7. 排坑清单（都是真实踩过的）

### 7.1 首次安装后配置「消失」，或重启又进安装向导
Sub2API 默认把数据目录解析成 `C:\app\data`（因为代码里写的是 `/app/data`，Windows 上解析到
盘根）。**必须显式设 `DATA_DIR=<install>\app\data` 再启动**，否则配置和 `.installed` 安装锁都
会写到 `C:\app\data`，你找不到、还会被当成「首次安装」。

### 7.2 报 `invalid timezone "Asia/Shanghai": unknown time zone`
Go 在 Windows 上读不到 IANA 时区。解法：下载 `zoneinfo.zip` 并设 `ZONEINFO` 环境变量指向它。
（或者把 config 里的 `timezone` 改成 `UTC` 也能绕过，但日志/调度会按 UTC。）

### 7.3 OAuth 兑换报 `unsupported_country_region_territory`
意思是「回源 IP 所在地区不受支持」。浏览器登录走的是系统代理，但 **code→token 兑换是网关后端
直连**，没走代理。解法：先建代理、再在 OAuth 那步选上代理（或走 `generate-auth-url` 时带
`proxy_id`）。若代理节点本身也被 OpenAI 挡，就换美国/日本/新加坡节点。

### 7.4 管理员登录被 400 拒
注册时 `mail.ParseAddress` 能接受 `admin@local` 这种邮箱，但登录接口用更严的校验，会拒掉。
直接用合法邮箱（如 `admin@example.com`）当管理员即可，别用 `xxx@local`。

### 7.5 `INSUFFICIENT_BALANCE` / 计费相关报错
个人自用要在 config 里开 `run_mode: simple`（跳过计费/余额校验）。否则默认 standard 模式，
用户余额 0 时直接拒绝。

### 7.6 并行报 `Concurrency limit exceeded` / 频繁限流
账号并发默认 1。调高能并行，但单订阅账号高并发**极易触发 OpenAI 限流/风控**，甚至封号。
建议 2~4 之间，别真拉满。

### 7.7 GitHub 定价数据偶发 `TLS handshake timeout`
Sub2API 启动时会拉一份模型定价表，直连 GitHub 可能超时。它自带重试且不影响主流程，可忽略；
必要时在 config 的 `update.proxy_url` 配个代理。

### 7.8 模型能列出来但一调用就报「不支持该模型」
说明网关目录里那个 id 和上游实际能用的不一致，或该模型你的订阅档位访问不了。换一个目录里
确实能通的 id，或到分组里核对模型启用状态。

---

## 8. 日常维护

- 开机后跑 `scripts\start-services.cmd`（服务是普通进程，不注册系统服务）。若用了自定义目录/端口：
  `scripts\start-services.cmd <安装目录> <PG端口> <Redis端口> <Web端口>`；停止时用
  `scripts\stop-services.cmd <安装目录> <PG端口> <Redis端口>`。
- 代理必须常开，否则回源断。
- OAuth 带 refresh token，一般自动续期；偶发失效就重新走一遍 OAuth。
- 出问题先看 `<install>\app\data\logs\sub2api.log`。

---

## 9. 最后再说一遍

这套东西**违反 OpenAI ToS**，有封号风险，只适合个人学习/研究、用能承受丢失的账号。
别商用、别规模化、别二次售卖。OpenAI 风控一升级，随时可能不可用——它本质是「借官方客户端的
OAuth 去调内部接口」，不是稳定承诺。
