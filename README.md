# ip-ai-check

**一个专门减少误判的 IP 质量检测工具，侧重 AI 服务可用性。**

常见的 IP 检测脚本会给出「看起来很确定、其实是错的」结论：被 DNS 挡掉的黑名单显示成「干净」，早已关停的黑名单库被算进总数，原生 IP 被说成「DNS 解锁」。ip-ai-check 的原则只有一条：

> **查不了就说查不了，不冒充「正常」；没意义的结果不计入。**

![卡片示例](docs/sample-card.png)

## 它纠正了哪些常见误判

| 常见做法 | 会误判成什么 | ip-ai-check 的做法 |
|---|---|---|
| 用系统默认 DNS 直接查黑名单 | **被挡掉的库显示成「没列入」**。实测 8.8.8.8 查 Spamhaus 返回空；1.1.1.1 返回拒绝码；9.9.9.9 能查 Spamhaus，但另有 5 个库查不了 | 每个库先查一次 RFC 5782 测试点，查不了的单独标成「解析器查不了」；卡片上写实际查到的库数，如「黑名单 0 / 实查 46 库」 |
| 沿用一份几百个库的黑名单列表 | **库数虚高、凭空多出「已标记」**。一份 423 个库的公开名单里，291 个库的域名已经不存在，14 个对任何地址都回「已列入」 | 逐个实测筛选，只留 48 个真正可用的 IP 黑名单（含原名单里没有的 Spamhaus） |
| DNS 查询只要有输出就算「已标记」 | **把超时报错文字当成被标记**，网络一抖就多几条「标记」 | 超时单独计为「查询失败」，失败的会低并发重查一轮 |
| 把 Spamhaus PBL 当成黑名单 | **家宽 IP 被冤枉**。PBL 收录的是家宽和动态地址，意思是「不应直接发邮件」，不代表有滥用 | 单列为「政策名单」，不算黑名单 |
| 看 `dig netflix.com` 返回几条地址，≤2 条就判「DNS 解锁」 | **原生 IP 被说成 DNS 解锁**。公共 DNS 对 netflix.com 随机返回 2 条或 3 条，同一个 IP 连跑几次结果会来回变（两个 IP 各采样 12 次：3:9 和 9:3） | 直接请求自制剧和非自制剧的页面，读 Netflix 自己判定的国家，区分 完整解锁 / 仅自制剧 / 不可用 |
| 只测 ChatGPT，或只看能不能打开 | **AI 到底能不能用说不清**，被谷歌判成中国（送中）也看不出来 | 测 ChatGPT、Claude、Gemini、Grok、Perplexity、Copilot，再加谷歌送中三项检查 |

另外，测不到的东西会写明测不到：Claude 和 Perplexity 的网站会拒绝脚本访问，本工具只能按地区判断它们是否被拦截，卡片和报告上都标注了这一点，不把「按地区推断」包装成「实测可用」。

## 检测项目一览

| 项目 | 内容 |
|---|---|
| AI 服务 | ChatGPT、Claude、Gemini、Grok、Perplexity、Copilot |
| 谷歌送中 | YouTube 是否判为中国区（跳转 google.cn）、谷歌搜索是否被重定向到 google.com.hk |
| Netflix | 完整解锁 / 仅自制剧 / 不可用，以及地区 |
| IP 黑名单 | 48 个实测可用的库：黑名单 / 政策名单 / 解析器查不了 / 查询失败 |
| 数据库判定与风险分（可选） | 调用 [xykt/IPQuality](https://github.com/xykt/IPQuality) 获取 IPinfo、ipregistry、ipapi、IP2Location、AbuseIPDB 等的 IP 类型判定、风险评分和风险因子 |

输出：JSON、文本报告、分享卡片（PNG）、可自托管的 HTML 报告页。**不上传任何数据。**

## 用法

```bash
git clone https://github.com/RiceBlack67/ip-ai-check && cd ip-ai-check

./run.sh                     # 检测本机
./run.sh 203.0.113.10        # 经 SSH 检测远程机器（需能 ssh root@IP 免密登录）
./run.sh 203.0.113.10 --full # 卡片和报告显示完整 IP（默认只露最后一段，如 *.*.*.56）
./run.sh --no-xykt           # 不调用 xykt 数据源，几十秒出结果

# 生成可分享的 HTML 报告页
PUBLISH_DIR=/var/www/html/ipq PUBLISH_URL=https://example.com/ipq ./run.sh 203.0.113.10 --publish
```

结果在 `reports/`：`*.json`（完整数据）、`*.txt`（文本报告）、`*.png`（卡片）。

HTML 报告页长这样（IP 默认打码）：[docs/sample-report.png](docs/sample-report.png)

只想在本机跑检测、不要卡片：`bash ip-ai-check.sh -o result.json`

可选环境变量：

| 变量 | 作用 |
|---|---|
| `DNSBL_RESOLVER=9.9.9.9` | 查黑名单用指定的 DNS 解析器（默认用系统解析器）；用自建递归解析器（如 unbound）查得最全 |
| `DNSBL_LIST=zones.txt` | 换成自己的黑名单列表，一行一个库 |
| `XYKT_SHA256=<sha256>` | 固定 xykt 脚本版本，不符就拒绝运行 |
| `OUT_DIR` / `PUBLISH_DIR` / `PUBLISH_URL` | 结果目录 / 报告页发布目录与网址 |

依赖：被检测机器上有 bash、curl、jq、dig（缺了会用 apt 安装）；生成卡片需要 python3 和 chromium。

## 判定细节

- **AI「可用」= 所在地区没有被该服务拦截。** ChatGPT 看官方接口是否返回「不支持的地区」和 iOS 端是否出现 VPN 拦截页；Claude 和 Perplexity 按 Cloudflare 返回的地区对照官方支持地区判断。账号层面的风控检测不到。
- **Gemini**：页面里出现正常加载的标记即为可用；被谷歌标记「异常流量」时会尝试带 cookie 自动放行，需要人机验证则标为「需验证」。
- **谷歌送中**：YouTube 判为中国区或谷歌搜索被重定向到 google.com.hk，任一出现即视为送中。
- **Netflix**：两部非自制剧页面都能打开 = 完整解锁；只有自制剧能打开 = 仅自制剧。
- **黑名单分类**：返回 `127.0.x.x` 为列入（Spamhaus 的 `127.0.0.10/11` 单列为政策名单）；测试点查不通、或返回 `127.255.255.x` 拒绝码，计为「解析器查不了」；超时计为「查询失败」。后两类都不计入「正常」。

### 黑名单列表是怎么筛出来的（2026-10 实测）

从一份公开的 423 个库的名单出发，按 [RFC 5782](https://www.rfc-editor.org/rfc/rfc5782) 的测试点逐个检查：查 `127.0.0.2` 必须返回「已列入」，查 `127.0.0.1` 必须返回「未列入」。

- 291 个库的域名已经不存在（早已关停）
- 14 个对任何地址都返回同一个结果（通配应答），查了没有意义
- 另有白名单、信誉评分类、只收录域名不收录 IP 的库：被列入不代表 IP 有问题

剔除后剩下 48 个，内置在 `ip-ai-check.sh` 的 `dnsbl_zones` 里。黑名单库会继续关停或变化，这份列表需要定期重新实测。

## 致谢

各数据库的类型判定、风险评分和风险因子来自 [@xykt](https://github.com/xykt) 的 [IPQuality](https://github.com/xykt/IPQuality)（AGPL-3.0）。本工具在运行时下载并以隐私模式调用它，不包含、也不修改它的代码。

## 许可

MIT
