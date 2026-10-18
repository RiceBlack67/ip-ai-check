#!/usr/bin/env python3
"""card.py —— 把 ip-ai-check.sh 的 JSON 渲染成一张 1200x630 的 IP 信息卡片。

用法:card.py <结果.json> <输出.png> [--full] [--brand 文字]
  默认 IP 只露最后一段(*.*.*.56);--full 显示完整 IP。
版式借鉴 cleanip.io 的分享卡(大号 IP + 地区/ASN + 标签),加了 AI 一行——现在大家关心的是 AI 不是奈飞。
"""
import html, json, os, subprocess, sys, tempfile

args = sys.argv[1:]
if len(args) < 2:
    sys.exit(__doc__)
src, out = args[0], args[1]
full = "--full" in args
brand = args[args.index("--brand") + 1] if "--brand" in args else "ip-ai-check"
d = json.load(open(src))
x = d.get("xykt") or {}
E = html.escape

ip = d.get("ip", "?")
ip_show = ip if full else "*.*.*." + ip.split(".")[-1]
info = x.get("Info") or {}
city = info.get("City") or {}
region = (info.get("Region") or {}).get("Name") or ""
loc = " · ".join(v for v in [region, city.get("Subdivisions") or "", city.get("Name") or ""] if v)
cc = ((info.get("Region") or {}).get("Code") or "").upper()
flag = "".join(chr(0x1F1E6 + ord(c) - 65) for c in cc) if len(cc) == 2 else ""
asn = f'AS{info["ASN"]} · {info.get("Organization","")}' if info.get("ASN") else ""

tags = []
if info.get("Type"):
    tags.append(info["Type"])
usage = (x.get("Type") or {}).get("Usage") or {}
if usage:
    home = sum(1 for v in usage.values() if v == "家宽")
    tags.append(f"{home}/{len(usage)} 库判家宽")
gz = d.get("google") or {}
tags.append("谷歌未送中" if gz.get("songzhong") == "no" else "谷歌送中")

AI_NAMES = [("chatgpt", "ChatGPT"), ("claude", "Claude"), ("gemini", "Gemini"),
            ("grok", "Grok"), ("perplexity", "Perplexity"), ("copilot", "Copilot")]
def badge(name, st, sub=""):
    cls = {"ok": "ok", "full": "ok", "originals": "warn", "captcha": "warn", "unknown": "warn"}.get(st, "bad")
    sym = {"ok": "✓", "warn": "!", "bad": "✕"}[cls]
    return f'<span class="b {cls}"><i>{sym}</i>{E(name)}{f"<em>{E(sub)}</em>" if sub else ""}</span>'
ai = d.get("ai") or {}
ai_html = "".join(badge(n, (ai.get(k) or {}).get("status", "neterr"), (ai.get(k) or {}).get("region", ""))
                  for k, n in AI_NAMES)

media = x.get("Media") or {}
nf = d.get("netflix") or {}
med = [badge("Netflix", nf.get("status", "neterr"), nf.get("region", ""))]
yt = gz.get("youtube_region", "")
med.append(badge("YouTube", "ok" if yt not in ("", "CN", "neterr", "unknown") else "bad", yt))
for k, n in [("DisneyPlus", "Disney+"), ("TikTok", "TikTok")]:
    m = media.get(k) or {}
    if m:
        med.append(badge(n, "ok" if m.get("Status") == "解锁" else "bad", m.get("Region", "")))
media_html = "".join(med)

score = x.get("Score") or {}
risk = []
for k, n in [("IP2LOCATION", "IP2Location"), ("SCAMALYTICS", "Scamalytics"), ("ipapi", "ipapi"),
             ("AbuseIPDB", "AbuseIPDB"), ("IPQS", "IPQS")]:
    v = score.get(k)
    if v not in (None, "null", ""):
        risk.append(f"<span><b>{E(str(v))}</b>{E(n)}</span>")
risk_html = "".join(risk) or f'<span>{E(d.get("xykt_note") or "未启用 xykt 数据源")}</span>'

bl = d.get("dnsbl") or {}
checked = (bl.get("total") or 0) - len(bl.get("resolver_refused", [])) - len(bl.get("query_failed", []))
bl_line = f'黑名单 {len(bl.get("blacklisted", []))} / 实查 {checked} 库' if bl else ""

when = (d.get("generated") or "").replace("T", " ").replace("Z", " UTC")

page = f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{width:1200px;height:630px;background:#FBF6EA;color:#2f2a26;
 font-family:"Noto Sans CJK SC","Noto Sans SC",sans-serif;padding:46px 60px 0;position:relative;overflow:hidden}}
.top{{display:flex;justify-content:space-between;align-items:center}}
.brand{{font-size:22px;font-weight:700;color:#7a6a56;letter-spacing:.06em}}
.brand i{{display:inline-block;width:14px;height:14px;border:4px solid #3f8f5a;border-radius:50%;margin-right:10px;vertical-align:-1px}}
.when{{font-size:16px;color:#9a8f84}}
.ip{{font-size:96px;font-weight:800;letter-spacing:-.01em;line-height:1.05;margin:26px 0 10px;font-family:"Noto Sans Mono CJK SC",monospace}}
.loc{{font-size:26px;color:#4a423b}} .asn{{font-size:22px;color:#6b6158;margin-top:6px}}
.tags{{margin:18px 0 0}} .tags span{{display:inline-block;border:2px solid #3f8f5a;color:#2e7d32;background:#eaf4e4;
 font-size:19px;font-weight:700;padding:4px 14px;border-radius:8px;margin-right:10px}}
.row{{position:absolute;left:60px;right:60px;display:flex;align-items:center;gap:10px;flex-wrap:nowrap}}
.row .h{{font-size:17px;color:#9a8f84;width:70px;flex:none;font-weight:700;letter-spacing:.1em}}
.r1{{top:420px}} .r2{{top:474px}} .r3{{top:528px}}
.b{{display:inline-flex;align-items:center;font-size:18px;font-weight:700;padding:5px 12px 5px 8px;border-radius:999px;white-space:nowrap}}
.b i{{font-style:normal;display:inline-block;width:22px;height:22px;line-height:22px;text-align:center;border-radius:50%;
 color:#fff;font-size:14px;margin-right:7px}}
.b em{{font-style:normal;font-weight:500;color:#8a8078;margin-left:6px;font-size:15px}}
.ok{{background:#e4f1dc;color:#24572f}} .ok i{{background:#3f8f5a}}
.warn{{background:#f6ebc9;color:#7a5a00}} .warn i{{background:#c99a1c}}
.bad{{background:#f6dcd8;color:#8a2a20}} .bad i{{background:#b03a2e}}
.risk span{{font-size:17px;color:#6b6158;margin-right:20px}} .risk b{{color:#2e7d32;font-size:20px;margin-right:6px}}
.bl{{margin-left:auto;font-size:17px;color:#6b6158;white-space:nowrap}}
.foot{{position:absolute;left:60px;right:60px;bottom:18px;font-size:13px;color:#b0a597;display:flex;justify-content:space-between}}
</style></head><body>
<div class="top"><div class="brand"><i></i>{E(brand)}</div><div class="when">{E(when)}</div></div>
<div class="ip">{E(ip_show)}</div>
<div class="loc">{flag} {E(loc)}</div>
<div class="asn">{E(asn)}</div>
<div class="tags">{"".join(f"<span>{E(t)}</span>" for t in tags)}</div>
<div class="row r1"><span class="h">AI</span>{ai_html}</div>
<div class="row r2"><span class="h">流媒体</span>{media_html}</div>
<div class="row r3 risk"><span class="h">风险分</span>{risk_html}<span class="bl">{E(bl_line)}</span></div>
<div class="foot"><span>ip-ai-check · 数据库判定与风险分来自 xykt/IPQuality</span><span>AI 可用 = 地区未被拦截;Claude/Perplexity 只能按地区判定</span></div>
</body></html>"""

with tempfile.TemporaryDirectory() as t:
    h = os.path.join(t, "card.html")
    open(h, "w").write(page)
    chrome = next((p for p in ("chromium", "chromium-browser", "google-chrome")
                   if subprocess.call(["which", p], stdout=subprocess.DEVNULL) == 0), None)
    if not chrome:
        sys.exit("没有 chromium,HTML 留在:" + h)
    subprocess.run([chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", "--window-size=1200,630",
                    f"--screenshot={os.path.abspath(out)}", "file://" + h],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
if not (os.path.exists(out) and os.path.getsize(out) > 0):
    sys.exit("截图失败:" + out)
print(out)
