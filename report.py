#!/usr/bin/env python3
"""report.py —— 把 ip-ai-check.sh 的 JSON 渲染成一页静态 HTML 报告。

用法:report.py <结果.json> <输出目录> [--full] [--card card.png]
  输出 <目录>/index.html(+ 复制卡片为 card.png)。默认 IP 只露最后一段;--full 显示完整 IP。
  页面自带 noindex:报告是给人看的凭据,不是给搜索引擎的。
"""
import html, json, os, shutil, sys

a = sys.argv[1:]
if len(a) < 2:
    sys.exit(__doc__)
src, outdir = a[0], a[1]
full = "--full" in a
card = a[a.index("--card") + 1] if "--card" in a else None
d = json.load(open(src))
x = d.get("xykt") or {}
E = lambda s: html.escape(str(s))

ip = d.get("ip", "?")
ip_show = ip if full else "*.*.*." + ip.split(".")[-1]
info = x.get("Info") or {}
city = info.get("City") or {}
reg = info.get("Region") or {}

ST = {"ok": ("ok", "可用"), "full": ("ok", "完整解锁"), "originals": ("warn", "仅自制剧"),
      "captcha": ("warn", "需人机验证"), "unknown": ("warn", "未知"), "blocked": ("bad", "不可用"),
      "neterr": ("warn", "网络错误")}
# xykt 的流媒体状态:「失败」是请求没成功(查不了),不是「屏蔽」
XS = {"解锁": "ok", "屏蔽": "blocked", "中国": "blocked", "失败": "neterr", "待支持": "unknown", "仅自制": "originals"}
def pill(st, text=None):
    c, t = ST.get(st, ("warn", st))
    return f'<span class="p {c}">{E(text or t)}</span>'
def yesno(v):
    if v is None or v == "null":
        return '<span class="na">—</span>'
    return '<span class="p bad">是</span>' if v is True else '<span class="p ok">否</span>'
def table(head, rows):
    h = "".join(f"<th>{E(c)}</th>" for c in head)
    b = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f'<div class="tw"><table><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table></div>'

sec = []

# 基础信息
base = [("自治系统号", f'AS{info.get("ASN","")}'), ("组织", info.get("Organization", "")),
        ("城市", " · ".join(v for v in [city.get("Subdivisions"), city.get("Name")] if v)),
        ("使用地", reg.get("Name", "")), ("注册地", (info.get("RegisteredRegion") or {}).get("Name", "")),
        ("时区", info.get("TimeZone", "")), ("IP 类型", info.get("Type", ""))]
if info:
    sec.append(("基础信息(Maxmind)", "<dl>" + "".join(f"<dt>{E(k)}</dt><dd>{E(v)}</dd>" for k, v in base if v) + "</dl>"))

# 类型属性
t = x.get("Type") or {}
if t:
    dbs = list(dict.fromkeys(list((t.get("Usage") or {}).keys()) + list((t.get("Company") or {}).keys())))
    sec.append(("IP 类型属性", table(["", *dbs], [
        ["使用类型", *[E((t.get("Usage") or {}).get(k, "—")) for k in dbs]],
        ["公司类型", *[E((t.get("Company") or {}).get(k, "—")) for k in dbs]]])))

# 风险评分
s = x.get("Score") or {}
if s:
    sec.append(("风险评分", table(["数据库", "分数"], [[E(k), E(v)] for k, v in s.items() if v not in (None, "null")])))

# 风险因子
f = x.get("Factor") or {}
if f:
    dbs = [k for k in (f.get("Proxy") or {}).keys() if any((f.get(r) or {}).get(k) is not None for r in f)]
    names = [("CountryCode", "地区"), ("Proxy", "代理"), ("Tor", "Tor"), ("VPN", "VPN"),
             ("Server", "服务器"), ("Abuser", "滥用"), ("Robot", "机器人")]
    rows = []
    for k, n in names:
        r = f.get(k) or {}
        rows.append([n, *[(E(r.get(db)) if k == "CountryCode" and r.get(db) else yesno(r.get(db))) for db in dbs]])
    sec.append(("风险因子", table(["", *dbs], rows)))

# AI
ai = d.get("ai") or {}
AIN = [("chatgpt", "ChatGPT"), ("claude", "Claude"), ("gemini", "Gemini"), ("grok", "Grok"),
       ("perplexity", "Perplexity"), ("copilot", "Copilot")]
rows = [[E(n), pill((ai.get(k) or {}).get("status", "neterr")), E((ai.get(k) or {}).get("region", "") or "—"),
         E((ai.get(k) or {}).get("detail", ""))] for k, n in AIN if k in ai]
g = d.get("google") or {}
sz = g.get("songzhong") == "yes"
ai_html = table(["服务", "状态", "地区", "说明"], rows)
ai_html += (f'<p class="line"><b>谷歌送中</b> {pill("blocked", "是") if sz else pill("ok", "否")}'
            f'<span class="m">YouTube 地区 {E(g.get("youtube_region",""))} · 谷歌搜索 {E(g.get("search",""))}</span></p>')
sec.append(("AI 服务", ai_html))

# 流媒体
nf = d.get("netflix") or {}
med = x.get("Media") or {}
rows = [["Netflix", pill(nf.get("status", "neterr")), E(nf.get("region", "—")),
         E(f'自制剧 {nf.get("http",{}).get("original")} · 非自制剧 {nf.get("http",{}).get("nonorig1")}/{nf.get("http",{}).get("nonorig2")}(title 页实测)')]]
for k, n in [("Youtube", "YouTube"), ("DisneyPlus", "Disney+"), ("TikTok", "TikTok"),
             ("AmazonPrimeVideo", "Prime Video"), ("Reddit", "Reddit")]:
    m = med.get(k)
    if m:
        st = XS.get(m.get("Status"), "unknown")
        rows.append([n, pill(st, "查询失败(不计入)" if st == "neterr" else m.get("Status")),
                     E(m.get("Region") or "—"), E(m.get("Type") or "")])
sec.append(("流媒体", table(["服务", "状态", "地区", "说明"], rows)))

# 黑名单
bl = d.get("dnsbl") or {}
mail = x.get("Mail") or {}
bh = (f'<p class="line">共 {E(bl.get("total"))} 个库 · 正常 <b>{E(bl.get("clean"))}</b> · '
      f'黑名单 <b class="r">{len(bl.get("blacklisted", []))}</b> · 政策名单 <b class="y">{len(bl.get("policy", []))}</b> · '
      f'解析器查不了 {len(bl.get("resolver_refused", []))} · 查询失败 {len(bl.get("query_failed", []))}</p>')
lst = [f'<li><span class="p bad">黑名单</span> {E(z["zone"])} <code>{E(z["code"])}</code></li>' for z in bl.get("blacklisted", [])]
lst += [f'<li><span class="p warn">政策名单</span> {E(z["zone"])} <code>{E(z["code"])}</code> Spamhaus PBL:家宽/动态地址,不应直接发邮件,不代表滥用</li>' for z in bl.get("policy", [])]
lst += [f'<li><span class="p warn">非标准应答</span> {E(z["zone"])} <code>{E(z["answer"])}</code> 未计入</li>' for z in bl.get("unexpected_answer", [])]
if lst:
    bh += "<ul>" + "".join(lst) + "</ul>"
for k, n in [("resolver_refused", "当前解析器查不了这些库、结果无效(换解析器或用自建递归解析器可查)"), ("query_failed", "查询失败(超时,不计入)")]:
    if bl.get(k):
        bh += f'<p class="m">{n}:{E(", ".join(bl[k]))}</p>'
if "Port25" in mail:
    bh += f'<p class="line"><b>本机 25 端口出站</b> {"开放" if mail["Port25"] else "阻断"}</p>'
sec.append(("黑名单与邮件", bh))

when = (d.get("generated") or "").replace("T", " ").replace("Z", " UTC")
body = "".join(f"<section><h2>{E(h)}</h2>{c}</section>" for h, c in sec)
img = '<img class="card" src="card.png" alt="IP 检测卡片">' if card else ""
page = f"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:">
<title>IP 检测报告 {E(ip_show)}</title><style>
:root{{--bg:#f7f5f1;--card:#fffdfa;--ink:#2f2a26;--m:#8a8078;--line:#e6e0d8;--ok:#2e7d32;--okb:#e4f1dc;--w:#7a5a00;--wb:#f6ebc9;--b:#8a2a20;--bb:#f6dcd8}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1a1816;--card:#232020;--ink:#ece7e0;--m:#9a9089;--line:#332e2b;--okb:#24382a;--ok:#8fd19e;--wb:#3b331d;--w:#e8c66a;--bb:#3e2422;--b:#f0a39a}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.7 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;padding:0 14px}}
.w{{max-width:760px;margin:0 auto;padding:36px 0 50px}}h1{{font-size:24px;margin:0 0 4px}}.sub{{color:var(--m);font-size:13px;margin:0 0 18px}}
.card{{width:100%;border:1px solid var(--line);border-radius:12px;margin:0 0 18px}}
section{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin:0 0 14px}}
h2{{font-size:16px;margin:0 0 10px}}dl{{display:grid;grid-template-columns:7em 1fr;gap:4px 10px;margin:0}}dt{{color:var(--m)}}dd{{margin:0}}
.tw{{overflow-x:auto}}table{{border-collapse:collapse;width:100%;font-size:14px}}th,td{{padding:6px 8px;border-bottom:1px dashed var(--line);text-align:left;white-space:nowrap}}th{{color:var(--m);font-weight:500}}
.p{{display:inline-block;padding:1px 9px;border-radius:999px;font-size:13px;font-weight:600}}.ok{{background:var(--okb);color:var(--ok)}}.warn{{background:var(--wb);color:var(--w)}}.bad{{background:var(--bb);color:var(--b)}}
.na{{color:var(--m)}}.m{{color:var(--m);font-size:13px;margin-left:8px}}p.m{{margin:6px 0 0}}.line{{margin:8px 0 0}}b.r{{color:var(--b)}}b.y{{color:var(--w)}}
ul{{margin:8px 0 0;padding-left:18px}}code{{font-size:12.5px;color:var(--m)}}.foot{{color:var(--m);font-size:12.5px;margin-top:20px}}
</style></head><body><div class="w">
<h1>IP 检测报告:{E(ip_show)}</h1><p class="sub">{E(when)} · ip-ai-check {E((d.get("tool") or {}).get("version",""))}</p>
{img}{body}
<p class="foot">由 ip-ai-check 生成。各数据库的类型判定、风险评分与风险因子来自 <a href="https://github.com/xykt/IPQuality">xykt/IPQuality</a>(隐私模式运行,不上传);
Netflix、黑名单、AI 与谷歌送中为本工具实测。AI「可用」= 所在地区未被服务拦截;Claude / Perplexity 网站拒绝脚本访问,只能按地区判定。</p>
</div></body></html>"""
os.makedirs(outdir, exist_ok=True)
open(os.path.join(outdir, "index.html"), "w").write(page)
if card:
    shutil.copy(card, os.path.join(outdir, "card.png"))
print(os.path.join(outdir, "index.html"))
