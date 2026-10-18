# ip-ai-check

**面向 AI 服务的 IP 质量检测工具：检查 AI 服务可用性、地区识别、IP 黑名单与风险信号。**

以前，判断一个 IP 的质量，很多人首先看 Netflix 能否解锁。现在，ChatGPT、Claude、Gemini 等 AI 服务能否正常访问，Google 是否把出口识别为中国区，同样是重要的参考指标。

ip-ai-check 把这些维度整合在一起，让你看到一个 IP 在各项检测中的综合表现，而不是只依赖单一数据库的评分。

![卡片示例](docs/sample-card.png)

## 不只检测，还要避免误判

很多 IP 检测工具的问题不是缺少数据，而是**把不完整的数据直接当成确定结论**。本项目的原则是：

> **查不了就明确说查不了，绝不冒充「正常」；无意义的结果不计入统计。**

具体纠正了这些常见误判：

| 常见做法 | 会误判成什么 | ip-ai-check 的做法 |
|---|---|---|
| 用系统默认 DNS 直接查黑名单 | **被拦截的库被错误显示为「未列入」**。实测 8.8.8.8 查 Spamhaus 返回空；1.1.1.1 返回拒绝码；9.9.9.9 能查 Spamhaus，但另有 5 个库查不了 | 每个库先查一次 RFC 5782 测试点，查不了的单独标成「解析器查不了」；卡片上写实际查到的库数，如「黑名单 0 / 实查 46 库」 |
| 沿用一份几百个库的黑名单列表 | **库数虚高，凭空产生「已标记」**。一份 423 个库的公开名单里，291 个库的域名已经不存在，14 个对任何地址都回「已列入」 | 逐个实测筛选，只留 48 个真正可用的 IP 黑名单（含原名单里没有的 Spamhaus） |
| DNS 查询只要有输出就算「已标记」 | **把超时或报错文本误判为已标记**，网络一抖就多几条「标记」 | 超时单独计为「查询失败」，失败的会低并发重查一轮 |
| 把 Spamhaus PBL 当成黑名单 | **家宽 IP 被误判为黑名单**。PBL 收录的是家宽和动态地址，意思是「不应直接发邮件」，不代表有滥用 | 单列为「政策名单」，不算黑名单 |
| 看 `dig netflix.com` 返回几条地址，≤2 条就判「DNS 解锁」 | **原生 IP 被误判为 DNS 解锁**。公共 DNS 对 netflix.com 随机返回 2 条或 3 条，同一个 IP 连跑几次结果会来回变（两个 IP 各采样 12 次：3:9 和 9:3） | 直接请求自制剧和非自制剧的页面，读 Netflix 自己判定的国家，区分 完整解锁 / 仅自制剧 / 不可用 |
| 请求失败和「屏蔽」显示成同一种红色 | **网络抖一下就显示成不可用**。实测：同一个 IP 上 Disney+ 一次请求失败被显示为不可用，随后直接请求 Disney 接口 5 次全部可用 | 请求失败单独显示为灰色「查询失败」，不算不可用；每个失败请求的原因（超时、连接失败、TLS 失败等）和重试结果写进「网络诊断」 |
| 只测 ChatGPT，或只看能不能打开 | **AI 到底能不能用说不清**，被谷歌判成中国区也看不出来 | 测 ChatGPT、Claude、Gemini、Grok、Perplexity、Copilot，再加谷歌地区识别检查 |

测不到的也会写明测不到：Claude 和 Perplexity 的网页都会拒绝脚本访问（返回 Cloudflare 验证页）。Claude 改测 Anthropic API 的地区限制（支持地区返回 401、不支持地区返回 403）；Perplexity 没有可测的接口，只能确认网站可达。卡片上这类未实测的结果用虚线框标出，报告的「说明」栏写明每一项是怎么判的，不把推断包装成实测。

具体判定方法、测试依据，见下方「判定细节」。

## 检测项目

| 检测维度 | 检测内容 |
|---|---|
| AI 服务可用性 | ChatGPT、Claude（API）、Gemini、Grok、Perplexity（仅可达）、Copilot 是否限制当前地区访问 |
| Google 地区识别 | YouTube 是否判为中国区（跳转 google.cn）、Google 搜索是否被重定向到 google.com.hk |
| Netflix 解锁状态 | 通过 Netflix 片源页面判断 完整解锁 / 仅自制剧 / 不可用，以及地区 |
| IP 黑名单 | 48 个经实测筛选的 DNS 黑名单，区分 命中 / 政策名单 / 解析器查不了 / 查询失败 |
| IP 类型与风险评分（可选） | 调用 [xykt/IPQuality](https://github.com/xykt/IPQuality)，获取 IPinfo、ipregistry、ipapi、IP2Location、AbuseIPDB 等数据源的类型判定、风险评分和风险因子 |

## 适用场景

- 购买 VPS 或更换出口 IP 后，快速确认 AI 服务与流媒体是否可用。
- 对比不同 IP 在地区识别、黑名单与风险评分上的差异。
- 排查因公共 DNS 导致的黑名单检测异常。
- 生成报告，记录不同出口 IP 的检测结果。

## 用法

```bash
git clone https://github.com/RiceBlack67/ip-ai-check && cd ip-ai-check

./run.sh                          # 检测本机
./run.sh user@203.0.113.10        # 经 SSH 检测远程机器（先显示要做什么，确认后才执行）
./run.sh user@203.0.113.10 --dry-run   # 只看将在目标机上做什么，不执行
./run.sh user@203.0.113.10 -y     # 不再询问确认（脚本、定时任务里用）
./run.sh myserver --full          # ~/.ssh/config 里的别名也可以；--full 显示完整 IP（默认只露最后一段）
./run.sh --no-xykt                # 不调用 xykt 数据源，几十秒出结果
./run.sh user@hostA user@hostB    # 逐个检测，再并排对比两个 IP，不同的项标 ≠

# 对比已有的结果（两个 IP，或同一个 IP 的不同时间）
./compare.py reports/a.json reports/b.json      # --md 输出 Markdown 表格

# 生成可分享的 HTML 报告页
PUBLISH_DIR=/var/www/html/ipq PUBLISH_URL=https://example.com/ipq ./run.sh user@203.0.113.10 --publish
```

**不需要 root。** 目标机上装好 `jq`、`dig`（dnsutils）、`curl` 后，普通用户就能跑；开 xykt 数据源还要 `bc`、`nc`、`ip`。缺依赖时，只有在 root 或【免密】sudo 下才会自动安装，否则直接告诉你缺什么并退出，不会弹出 sudo 密码。不写用户名时用 ssh 的默认用户，不会自动换成 root。

只想在本机跑检测、不要卡片：`bash ip-ai-check.sh -o result.json`

可选环境变量：

| 变量 | 作用 |
|---|---|
| `DNSBL_RESOLVER=9.9.9.9` | 查黑名单用指定的 DNS 解析器（默认用系统解析器）；用自建递归解析器（如 unbound）查得最全 |
| `DNSBL_LIST=zones.txt` | 换成自己的黑名单列表，一行一个库（本机文件，远程检测时内容会带过去） |
| `XYKT_URL` / `XYKT_SHA256` | 改用别的 xykt 版本（默认已固定到一个提交并校验 sha256） |
| `OUT_DIR` / `PUBLISH_DIR` / `PUBLISH_URL` | 结果目录 / 报告页发布目录与网址 |

### 依赖

被检测的机器需要 bash、curl、jq、dig；开启 xykt 数据源还需要 bc、nc、ip。用 root 或免密 sudo 运行时会自动安装（支持 apt、dnf/yum、apk、pacman），否则请先手动安装：

| 系统 | 安装命令（xykt 需要的放在括号里） |
|---|---|
| Debian / Ubuntu | `apt-get install jq dnsutils curl`（`bc netcat-openbsd iproute2`） |
| RHEL / Fedora / Alma / Rocky | `dnf install jq bind-utils curl`（`bc nmap-ncat iproute`） |
| Alpine | `apk add bash jq bind-tools curl`（`bc netcat-openbsd iproute2`） |
| Arch | `pacman -S jq bind curl`（`bc openbsd-netcat iproute2`） |

运行 `run.sh` 的机器需要 ssh、python3；生成卡片还需要 chromium。

## 报告格式

结果保存在 `reports/`：

- **JSON**：完整检测数据，便于后续处理。
- **文本报告**：快速查看结果。第二行写明数据源：是否调用了 xykt（调用过就意味着被检测的 IP 已发给 xykt 的服务器）。有请求失败时，末尾的「网络诊断」列出每个失败请求的原因和重试结果。
- **PNG 卡片**：方便分享和对比。
- **HTML 报告页**：适合自己部署展示，默认隐藏 IP 前三段。样例：[docs/sample-report.png](docs/sample-report.png)

## 安全

远程检测会在你的服务器上执行命令，所以这部分按「不留隐患」设计：

- **不默认要求 root**：见上面「用法」。用 root 登录时，执行前的预览里会提示你改用普通用户。
- **执行前先预览**：列出将以哪个用户运行、会访问哪些服务、会不会安装软件包、是否下载第三方脚本，确认后才执行；`--dry-run` 只看不跑；非交互环境不加 `-y` 会直接取消。
- **不往目标机复制文件**：脚本经 SSH 的标准输入交给目标机的 bash 运行。目标机上只在私有临时目录（权限 0700）里工作，避免了同机其他用户预先放置同名文件、借机替换脚本的风险。
- **任何方式退出都会清理**：正常结束、出错、Ctrl-C 都会删除临时目录；SSH 中途断开时，目标机上的检测会在几秒内自行停止并清理，不会在后台继续运行。
- **第三方脚本固定版本**：xykt/IPQuality 按固定提交下载，并校验 sha256，不符就拒绝运行；不会拉取它的最新版。
- **输入校验**：SSH 目标只接受 主机名 / 用户@主机 / 别名 的格式，以 `-` 开头的会被拒绝，防止被当成 ssh 的选项。
- **远端数据不可信**：生成卡片和报告页时，目标机返回的所有内容都会转义；页面还带了禁止一切脚本的 CSP，作为第二道防线。

## 隐私

本工具不会把检测结果上传到任何地方，也不生成公开链接；HTML 报告页只会发布到你自己用 `--publish` 指定的目录。

但检测本身需要联网，以下服务都能看到被检测的 IP：

- 本工具自己的检测：各 AI 服务、Netflix、YouTube、Google，查询出口 IP 的 api.ipify.org，以及查黑名单用的 DNS 解析器。
- 开启 xykt 数据源时（默认开启，`--no-xykt` 关闭）：xykt 的大部分数据库查询经由它自己的服务器 `ipinfo.check.place` 转发，还会访问它的使用量计数器。隐私模式只是不上传报告、不生成链接，**被检测的 IP 仍会发给 xykt 的服务器**。介意的话用 `--no-xykt`。

## 结果如何解读

本工具提供的是多个维度的检测结果，不是对 IP 质量的绝对保证。

AI 网站能访问，不代表账号一定能正常使用；没有命中黑名单，不代表 IP 没有风险；数据库把 IP 标成住宅类型，也不代表目标平台一定会把它当作普通家庭用户。

建议结合检测方法、数据来源和实际使用场景综合判断。

## 判定细节

- **AI「可用」= 所在地区没有被该服务拦截。** 账号层面的风控检测不到。
  - ChatGPT：看官方接口是否返回「不支持的地区」、iOS 端是否出现 VPN 拦截页。
  - Claude：不带密钥请求 Anthropic API，支持地区返回 401（缺少密钥），不支持地区返回 403「Request not allowed」（2026-10 实测：日本、美国 401，香港 403）。API 没给出这两种结果时，才退回按 Cloudflare 返回的地区对照不支持地区判断，并标注「按地区判定」。
  - Perplexity：只确认网站可达（能拿到 Cloudflare 的地区信息），标注「仅确认可达」。
- **网络请求的重试**：超时、域名解析失败、连接失败、TLS 失败这类网络错误会隔 2 秒重试一次；结果 JSON 的 `diagnostics` 记录每个失败过的请求。
- **Gemini**：页面里出现正常加载的标记即为可用；被谷歌标记「异常流量」时会尝试带 cookie 自动放行，需要人机验证则标为「需验证」。
- **Google 地区识别（送中）**：YouTube 判为中国区或 Google 搜索被重定向到 google.com.hk，任一出现即视为被识别为中国区。
- **Netflix**：两部非自制剧页面都能打开 = 完整解锁；只有自制剧能打开 = 仅自制剧。
- **Disney+、TikTok 等（来自 xykt）**：xykt 的「失败」表示请求没有成功，显示为「查询失败」，不算不可用；只有「屏蔽」才显示为不可用。
- **黑名单分类**：返回 `127.x.x.x`（RFC 5782 规定的范围，有的库用 `127.2.x.x` 之类）为命中，`127.255.255.x` 是拒绝码不算（Spamhaus 的 `127.0.0.10/11` 单列为政策名单）；测试点查不通、或返回 `127.255.255.x` 拒绝码，计为「解析器查不了」；超时计为「查询失败」。后两类都不计入「正常」。

### 黑名单列表是怎么筛出来的（2026-10-17 实测）

从一份公开的 423 个库的名单出发，按 [RFC 5782](https://www.rfc-editor.org/rfc/rfc5782) 的测试点逐个检查：查 `127.0.0.2` 必须返回「已列入」，查 `127.0.0.1` 必须返回「未列入」。

- 291 个库的域名已经不存在（早已关停）
- 14 个对任何地址都返回同一个结果（通配应答），查了没有意义
- 另有白名单、信誉评分类、只收录域名不收录 IP 的库：被列入不代表 IP 有问题

剔除后剩下 48 个，内置在 `ip-ai-check.sh` 的 `dnsbl_zones` 里，实测日期记在脚本的 `DNSBL_TESTED`，也会写进每份结果（`dnsbl.list_tested`）。

### 更新黑名单列表

黑名单库会继续关停或变化，建议每隔几个月重测一次：

```bash
# 1. 重测内置列表（-r 指定解析器；用自建递归解析器最准，公共 DNS 会把 Spamhaus 误判成「解析器查不了」）
bash ip-ai-check.sh -L | bash tools/dnsbl-screen.sh -r 127.0.0.1 > zones.txt

# 2. 也可以拿别的候选名单来筛（一行一个库）
bash tools/dnsbl-screen.sh -r 127.0.0.1 < candidates.txt > zones.txt

# 3. 用新列表试跑
DNSBL_LIST=zones.txt ./run.sh user@203.0.113.10
```

`dnsbl-screen.sh` 自动剔除：域名不存在、库的域名服务器不应答、通配应答（查什么都命中）的库。白名单、信誉评分类、只收录域名的库同样能通过测试点，要看各库官网说明后人工剔除。确认无误后，把 `zones.txt` 的内容换进 `dnsbl_zones`，并更新 `DNSBL_TESTED`。

## 致谢

IP 类型判定、风险评分和风险因子来自 [@xykt](https://github.com/xykt) 的 [IPQuality](https://github.com/xykt/IPQuality)（AGPL-3.0）。本工具在运行时下载并以隐私模式调用它，不包含、也不修改它的代码。

## 许可

MIT
