#!/usr/bin/env python3
"""compare.py —— 把两份或多份 ip-ai-check 结果并排对比,标出不同的项。

用法:compare.py <a.json> <b.json> [更多.json] [--full] [--md]
  可以比两个 IP,也可以比同一个 IP 在不同时间的结果。
  --full  显示完整 IP(默认只露最后一段)
  --md    输出 Markdown 表格(默认是对齐的纯文本)
不同的行在最左边标 ≠。
一键检测并对比:./run.sh user@hostA user@hostB
"""
import json, sys, unicodedata

args = sys.argv[1:]
files = [a for a in args if not a.startswith("--")]
if len(files) < 2 or "-h" in args or "--help" in args:
    sys.exit(__doc__)
full, md = "--full" in args, "--md" in args

ZH = {"ok": "可用", "blocked": "不可用", "neterr": "查询失败", "captcha": "需验证", "unknown": "未知",
      "full": "完整解锁", "originals": "仅自制剧"}
MARK = {"ok": "✓", "full": "✓", "blocked": "✕", "neterr": "?", "captcha": "!", "unknown": "!", "originals": "!"}
# xykt 流媒体状态:「失败」是请求没成功(查不了),不是「屏蔽」
XS = {"解锁": "ok", "屏蔽": "blocked", "中国": "blocked", "失败": "neterr", "待支持": "unknown", "仅自制": "originals"}
AI = [("chatgpt", "ChatGPT"), ("claude", "Claude"), ("gemini", "Gemini"), ("grok", "Grok"),
      ("perplexity", "Perplexity"), ("copilot", "Copilot")]


def st(s, region="", note=""):
    t = f'{MARK.get(s, "✕")} {ZH.get(s, s)}'
    if region:
        t += f" {region}"
    return t + note


def column(d):
    x = d.get("xykt") or {}
    info = x.get("Info") or {}
    city = info.get("City") or {}
    ip = d.get("ip", "?")
    rows = {}
    rows["IP"] = ip if full else "*.*.*." + ip.split(".")[-1]
    rows["检测时间"] = (d.get("generated") or "").replace("T", " ").replace("Z", "")
    rows["位置"] = " · ".join(v for v in [(info.get("Region") or {}).get("Name") or "", city.get("Subdivisions") or "",
                                          city.get("Name") or ""] if v) or "—"
    rows["ASN"] = f'AS{info["ASN"]} {info.get("Organization", "")}' if info.get("ASN") else "—"
    rows["IP 类型"] = info.get("Type") or "—"
    usage = (x.get("Type") or {}).get("Usage") or {}
    rows["判为家宽的库"] = f'{sum(1 for v in usage.values() if v == "家宽")}/{len(usage)}' if usage else "—"
    g = d.get("google") or {}
    rows["谷歌送中"] = {"yes": "✕ 是", "no": "✓ 否"}.get(g.get("songzhong"), "—")
    ai = d.get("ai") or {}
    for k, n in AI:
        a = ai.get(k) or {}
        det = a.get("detail", "")
        inferred = det.startswith("按地区判定") or det.startswith("仅确认可达")
        rows[n] = st(a.get("status", "neterr"), a.get("region", ""), "(推断)" if inferred else "") if a else "—"
    nf = d.get("netflix") or {}
    rows["Netflix"] = st(nf.get("status", "neterr"), nf.get("region", "")) if nf else "—"
    yt = g.get("youtube_region", "")
    rows["YouTube 地区"] = {"CN": "✕ CN(送中)", "neterr": "? 查询失败", "unknown": "! 未知", "": "—"}.get(yt, f"✓ {yt}")
    media = x.get("Media") or {}
    for k, n in [("DisneyPlus", "Disney+"), ("TikTok", "TikTok")]:
        m = media.get(k)
        rows[n] = st(XS.get(m.get("Status"), "unknown"), m.get("Region") or "") if m else "—"
    score = x.get("Score") or {}
    for k, n in [("IP2LOCATION", "IP2Location"), ("SCAMALYTICS", "Scamalytics"), ("ipapi", "ipapi"),
                 ("AbuseIPDB", "AbuseIPDB"), ("IPQS", "IPQS")]:
        v = score.get(k)
        rows[f"风险分 {n}"] = str(v) if v not in (None, "null", "") else "—"
    bl = d.get("dnsbl") or {}
    if bl:
        checked = (bl.get("total") or 0) - len(bl.get("resolver_refused", [])) - len(bl.get("query_failed", []))
        rows["黑名单"] = f'{len(bl.get("blacklisted", []))} / 实查 {checked} 库'
        rows["政策名单"] = str(len(bl.get("policy", [])))
    else:
        rows["黑名单"] = rows["政策名单"] = "—"
    xs = (d.get("tool") or {}).get("xykt") or {"called": bool(x), "ok": bool(x)}
    rows["xykt 数据源"] = "已调用" if xs.get("called") and xs.get("ok") else ("调用失败" if xs.get("called") else "未调用")
    rows["请求失败"] = str(len(d.get("diagnostics") or [])) if "diagnostics" in d else "—"
    rows["版本"] = (d.get("tool") or {}).get("version", "?")
    return rows


cols = [column(json.load(open(f))) for f in files]
keys = list(cols[0].keys())
SAME_OK = {"IP", "检测时间", "版本"}  # 这几行本来就会不同,不标 ≠


def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s, w):
    return s + " " * (w - width(s))


table = []
for k in keys:
    vals = [c.get(k, "—") for c in cols]
    known = {v for v in vals if v != "—"}  # 某份结果缺这一项(如没调用 xykt)不算不同
    diff = k not in SAME_OK and len(known) > 1
    table.append(("≠" if diff else " ", k, vals))

if md:
    print("| | 项目 | " + " | ".join(f"#{i + 1}" for i in range(len(cols))) + " |")
    print("|---|---|" + "---|" * len(cols))
    for m, k, vals in table:
        print(f"| {m.strip()} | {k} | " + " | ".join(v.replace("|", "\\|") for v in vals) + " |")
else:
    wk = max(width(k) for k in keys)
    wv = [max(width(r[2][i]) for r in table) for i in range(len(cols))]
    for m, k, vals in table:
        print(f"{m} {pad(k, wk)}  " + "  ".join(pad(v, wv[i]) for i, v in enumerate(vals)).rstrip())
    n = sum(1 for r in table if r[0] == "≠")
    print(f"\n共 {n} 项不同" + ("(≠ 标出)" if n else ""))
