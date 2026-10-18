#!/bin/bash
# ip-ai-check.sh —— IP 质量检测,侧重 AI 服务可用性。在【被检测的机器】上运行。
#
# 检测内容(本工具实测):
#   - AI:ChatGPT / Claude / Gemini / Grok / Perplexity / Copilot
#   - 谷歌送中:YouTube 地区与 google.cn 跳转、谷歌搜索是否被重定向到 google.com.hk
#   - Netflix:请求自制剧与非自制剧 title 页,读 Netflix 自己判定的 requestCountry,
#     区分 完整解锁 / 仅自制剧 / 不可用
#   - 黑名单:内置一份经 RFC 5782 测试点实测筛过的 IP 黑名单(见 dnsbl_zones),
#     结果分为 黑名单 / 政策名单 / 解析器查不了 / 查询失败
# 可选数据源:xykt/IPQuality(https://github.com/xykt/IPQuality)以隐私模式 -p 运行,
#   不上传任何数据,只读取它的 JSON(各数据库的 IP 类型判定、风险评分、风险因子、流媒体)。
#
# 用法:
#   XYKT=/path/to/ip.sh bash ip-ai-check.sh [-o 结果.json]   # 带 xykt 数据源
#   bash ip-ai-check.sh [-o 结果.json]                        # 只跑本工具自己的检测
#   DNSBL_LIST=/path/to/zones.txt                            # 可选:用自己的黑名单列表(一行一个区)
#   DNSBL_RESOLVER=9.9.9.9                                   # 可选:查黑名单用指定解析器(默认用系统解析器)
# 一键(本机或经 SSH 远程):见 run.sh
set -u
OUT=/tmp/ip-ai-check.json
VERSION=0.1.0
while getopts "o:" opt; do case $opt in o) OUT=$OPTARG;; *) exit 2;; esac; done
command -v jq >/dev/null && command -v dig >/dev/null || {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q jq dnsutils curl >/dev/null 2>&1; }

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
C(){ curl -4 -s --max-time 15 -A "$UA" -H "accept-language: en-US,en;q=0.9" "$@"; }
trace_loc(){ C "https://$1/cdn-cgi/trace" 2>/dev/null | awk -F= '/^loc=/{print $2}'; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
J="$TMP/r.json"; echo '{}' > "$J"
put(){ jq --arg k "$1" --argjson v "$2" 'setpath($k|split(".");$v)' "$J" > "$J.n" && mv "$J.n" "$J"; }   # put a.b <json>

IP=$(C https://api.ipify.org); put ip "\"$IP\""
put generated "\"$(date -u +%FT%TZ)\""
put tool "{\"name\":\"ip-ai-check\",\"version\":\"$VERSION\"}"

# ---------- 1. 可选数据源:xykt/IPQuality(隐私模式,不上传) ----------
if [ -n "${XYKT:-}" ] && [ -f "$XYKT" ]; then
  bash "$XYKT" -4 -y -p -j -o "$TMP/xykt.json" </dev/null >/dev/null 2>&1
  if jq -e . "$TMP/xykt.json" >/dev/null 2>&1; then put xykt "$(cat "$TMP/xykt.json")"; else put xykt null; fi
else
  put xykt null
fi

# ---------- 2a. Netflix(title 页实测) ----------
nf_title(){  # 返回 "<http码> <国家> <status>"
  local b; b=$(C -w '\n__HTTP__%{http_code}' "https://www.netflix.com/title/$1" 2>/dev/null)
  local code=${b##*__HTTP__}
  local rc; rc=$(printf '%s' "$b" | grep -oE '"requestCountry":\{[^}]*\}' | head -1)
  local id; id=$(printf '%s' "$rc" | grep -oE '"id":"[A-Z]{2}"' | cut -d'"' -f4)
  local st; st=$(printf '%s' "$rc" | grep -oE '"status":"[A-Z_]+"' | cut -d'"' -f4)
  echo "${code:-000} ${id:--} ${st:--}"
}
read -r o_code o_cc o_st <<<"$(nf_title 80018499)"     # 自制剧(House of Cards)
read -r n1_code n1_cc _ <<<"$(nf_title 81280792)"       # 非自制剧
read -r n2_code n2_cc _ <<<"$(nf_title 70143836)"       # 非自制剧(Breaking Bad)
nf_cc=$o_cc; [ "$nf_cc" = "-" ] && nf_cc=$n1_cc
if   [ "$n1_code" = 200 ] && [ "$n2_code" = 200 ]; then nf=full
elif [ "$o_code" = 200 ]; then nf=originals
elif [ "$o_code" = 000 ]; then nf=neterr
else nf=blocked; fi
put netflix "$(jq -n --arg s "$nf" --arg cc "$nf_cc" --arg st "$o_st" --arg o "$o_code" --arg a "$n1_code" --arg b "$n2_code" \
  '{status:$s,region:$cc,request_status:$st,http:{original:$o,nonorig1:$a,nonorig2:$b}}')"

# ---------- 2b. 黑名单 ----------
# 2026-10 实测筛选:对候选库查 RFC 5782 测试点,2.0.0.127 必须列入、1.0.0.127 必须不列入;
# 剔除了已关停(域名不存在)、通配应答、白名单/信誉评分类、只收域名不收 IP 的库。
# Spamhaus ZEN 会拒绝公共 DNS(返回 127.255.255.x),用自建递归解析器才查得到,仍保留。
dnsbl_zones(){ cat <<'Z'
zen.spamhaus.org
b.barracudacentral.org
bb.barracudacentral.org
bl.spamcop.net
psbl.surriel.com
cart00ney.surriel.com
bl.mailspike.net
z.mailspike.net
dnsbl-1.uceprotect.net
dnsbl-2.uceprotect.net
dnsbl-3.uceprotect.net
dnsbl-0.uceprotect.net
dnsbl.dronebl.org
bl.blocklist.de
truncate.gbudb.net
ips.backscatterer.org
backscatter.spameatingmonkey.net
bl.spameatingmonkey.net
all.s5h.net
0spam.fusionzero.com
0spam-killlist.fusionzero.com
bl.scientificspam.net
bl.suomispam.net
black.junkemailfilter.com
blackholes.five-ten-sg.com
bsb.spamlookup.net
dev.null.dk
dnsbl.justspam.org
dnsbl.kempt.net
dnsbl.zapbl.net
dnsblchile.org
dnsrbl.swinog.ch
korea.services.net
mail-abuse.blacklist.jippg.org
rbl.abuse.ro
rbl.blockedservers.com
netscan.rbl.blockedservers.com
spam.rbl.blockedservers.com
rbl.interserver.net
rbl.schulte.org
reputation-ip.rbl.scrolloutf1.com
singular.ttk.pte.hu
spam.dnsbl.anonmails.de
spam.pedantic.org
spambot.bls.digibase.ca
spamsources.fabel.dk
tor.dan.me.uk
torexit.dan.me.uk
Z
}
LIST="$TMP/dnsbl.list"
if [ -n "${DNSBL_LIST:-}" ] && [ -f "$DNSBL_LIST" ]; then tr -d '\r' < "$DNSBL_LIST"; else dnsbl_zones; fi \
  | sed 's/#.*//; s/[[:space:]]//g' | grep -v '^$' | sort -u > "$LIST"
REV=$(echo "$IP" | awk -F. '{print $4"."$3"."$2"."$1}')
AT=""; [ -n "${DNSBL_RESOLVER:-}" ] && AT="@$DNSBL_RESOLVER"
q1(){  # 一个库查两次,两次都失败才算失败;超时报错文字不算结果
  local z=$1 r i t
  # 先查 RFC 5782 测试点 127.0.0.2:不回 127.0.x.x 说明当前解析器查不了这个库
  # (如 8.8.8.8 对 Spamhaus 返回空、1.1.1.1 返回 127.255.255.254),此时结果不可信,计为被拒而不是正常
  t=$(dig $AT +short +time=3 +tries=2 "2.0.0.127.$z" A 2>/dev/null | grep -E '^127\.0\.' | head -1)
  [ -z "$t" ] && { echo "$z|REFUSED"; return; }
  for i in 1 2; do
    r=$(dig $AT +short +time=3 +tries=1 "$REV.$z" A 2>/dev/null)
    [ $? -eq 0 ] && ! printf '%s' "$r" | grep -q '^;;' && { echo "$z|${r//$'\n'/,}"; return; }
  done
  echo "$z|ERR"
}
export -f q1; export REV AT
xargs -P 12 -I{} bash -c 'q1 "$@"' _ {} < "$LIST" > "$TMP/bl1.txt"
# 失败的再低并发重查一轮(并发高时本机解析器会丢包,不能把这个算到 IP 头上)
grep -v '|ERR$' "$TMP/bl1.txt" > "$TMP/bl.txt"
grep '|ERR$' "$TMP/bl1.txt" | cut -d'|' -f1 | xargs -r -P 3 -I{} bash -c 'q1 "$@"' _ {} >> "$TMP/bl.txt"
jq -Rn '
  [inputs | split("|") | {zone:.[0], ans:.[1]}] as $all
  | ($all | map(select(.ans=="ERR"))) as $err
  | ($all | map(select(.ans!="ERR" and .ans!="" and .ans!="REFUSED")) | map(.first=(.ans|split(",")[0]))) as $hit
  | (($hit | map(select(.first|startswith("127.255.255.")))) + ($all | map(select(.ans=="REFUSED")))) as $refused
  | ($hit | map(select(.zone=="zen.spamhaus.org" and (.first=="127.0.0.10" or .first=="127.0.0.11")))) as $policy
  | ($hit | map(select((.first|test("^127\\.0\\.[0-9]+\\.[0-9]+$")) and ((.first|startswith("127.255.255."))|not)
                       and ((.zone=="zen.spamhaus.org" and (.first=="127.0.0.10" or .first=="127.0.0.11"))|not)))) as $black
  | ($hit | map(select((.first|test("^127\\."))|not))) as $odd
  | {total:($all|length),
     clean:(($all|length)-($err|length)-($black|length)-($policy|length)-($refused|length)-($odd|length)),
     blacklisted:($black|map({zone,code:.first})),
     policy:($policy|map({zone,code:.first})),
     resolver_refused:($refused|map(.zone)),
     unexpected_answer:($odd|map({zone,answer:.first})),
     query_failed:($err|map(.zone))}' \
  < "$TMP/bl.txt" > "$TMP/bl.json"
put dnsbl "$(cat "$TMP/bl.json")"

# ---------- 2c. AI ----------
ai_put(){ put "ai.$1" "$(jq -n --arg s "$2" --arg r "$3" --arg d "$4" '{status:$s,region:$r,detail:$d}')"; }

# ChatGPT:API 的 unsupported_country + iOS 端 VPN 拦截页,地区看 trace
r1=$(C 'https://api.openai.com/compliance/cookie_requirements' -H 'authorization: Bearer null' 2>/dev/null)
r2=$(C 'https://ios.chat.openai.com/' 2>/dev/null)
loc=$(trace_loc chatgpt.com)
if   printf '%s' "$r1" | grep -qi unsupported_country; then ai_put chatgpt blocked "$loc" "api: unsupported_country"
elif printf '%s' "$r2" | grep -qi 'VPN'; then ai_put chatgpt blocked "$loc" "ios: VPN 拦截"
elif [ -z "$r1$r2" ]; then ai_put chatgpt neterr "$loc" ""
else ai_put chatgpt ok "$loc" ""; fi

# Claude:网页对 curl 一律 403(反爬),只能按 trace 地区对照官方不支持地区
loc=$(trace_loc claude.ai)
case "$loc" in
  CN|HK|MO|RU|BY|IR|KP|SY|CU|VE|AF) ai_put claude blocked "$loc" "不支持地区" ;;
  "") ai_put claude neterr "" "" ;;
  *) ai_put claude ok "$loc" "按地区判定" ;;
esac

# Gemini:页面含 45631641 = 正常;被谷歌标异常流量会 302 /sorry,带 cookie 能自动放行算 ok
b=$(C https://gemini.google.com/ 2>/dev/null)
if   [ -z "$b" ]; then ai_put gemini neterr "" ""
elif printf '%s' "$b" | grep -qiE "not (currently )?available|unsupported"; then ai_put gemini blocked "" "地区不支持"
elif printf '%s' "$b" | grep -q 45631641; then ai_put gemini ok "" ""
elif printf '%s' "$b" | grep -q "google.com/sorry"; then
  cj="$TMP/cj"; b2=$(C -L --max-redirs 6 -c "$cj" -b "$cj" https://gemini.google.com/ 2>/dev/null)
  if printf '%s' "$b2" | grep -q 45631641; then ai_put gemini ok "" "异常流量标记,自动放行"; else ai_put gemini captcha "" "需要人机验证"; fi
else ai_put gemini blocked "" "页面异常"; fi

# Grok
loc=$(trace_loc grok.com)
code=$(C -o "$TMP/grok" -w '%{http_code}' -L https://grok.com/ 2>/dev/null)
if   [ "$code" = 451 ] || grep -qiE "not available in your|unavailable in your country" "$TMP/grok" 2>/dev/null; then ai_put grok blocked "$loc" "http $code"
elif [ "$code" = 200 ]; then ai_put grok ok "$loc" ""
elif [ "$code" = 000 ]; then ai_put grok neterr "$loc" ""
else ai_put grok unknown "$loc" "http $code"; fi

# Perplexity(站点在 CF 后面,只能看地区与可达)
loc=$(trace_loc www.perplexity.ai)
if [ -n "$loc" ]; then ai_put perplexity ok "$loc" "按地区判定"; else ai_put perplexity neterr "" ""; fi

# Copilot
code=$(C -o "$TMP/cop" -w '%{http_code}' -L https://copilot.microsoft.com/ 2>/dev/null)
if   grep -qiE "not available in your (country|region)" "$TMP/cop" 2>/dev/null; then ai_put copilot blocked "" "地区不支持"
elif [ "$code" = 200 ]; then ai_put copilot ok "" ""
elif [ "$code" = 000 ]; then ai_put copilot neterr "" ""
else ai_put copilot unknown "" "http $code"; fi

# 谷歌送中三连(送中 = 谷歌把这个 IP 当成中国用户)
y=$(C https://www.youtube.com/premium 2>/dev/null)
if   [ -z "$y" ]; then yt=neterr
elif printf '%s' "$y" | grep -q "www.google.cn"; then yt=CN
else yt=$(printf '%s' "$y" | grep -oE '"GL":"[A-Z]{2}"' | head -1 | cut -d'"' -f4); yt=${yt:-unknown}; fi
sr=$(C -o /dev/null -w "%{http_code} %{redirect_url}" "https://www.google.com/search?q=test" 2>/dev/null)
case "$sr" in 200*) se=ok;; *hkredirect*|*google.com.hk*) se=hk;; ""|000*) se=neterr;; *) se=other;; esac
sz=no; { [ "$yt" = CN ] || [ "$se" = hk ]; } && sz=yes
put google "$(jq -n --arg y "$yt" --arg s "$se" --arg z "$sz" '{youtube_region:$y,search:$s,songzhong:$z}')"

cp "$J" "$OUT"

# ---------- 文本报告 ----------
jq -r '
def mark(s): if s=="ok" or s=="full" then "✅" elif s=="originals" or s=="captcha" or s=="unknown" then "⚠️" elif s=="neterr" then "❔" else "❌" end;
def name(k): {"chatgpt":"ChatGPT","claude":"Claude","gemini":"Gemini","grok":"Grok","perplexity":"Perplexity","copilot":"Copilot"}[k] // k;
def zh(s): {"ok":"可用","blocked":"不可用","neterr":"网络错误","captcha":"需验证","unknown":"未知","full":"完整解锁","originals":"仅自制剧"}[s] // s;
"ip-ai-check \(.tool.version)   \(.ip)   \(.generated)",
"── AI ──",
(.ai | to_entries[] | "  \(mark(.value.status)) \(name(.key)) \(zh(.value.status))\(if .value.region!="" then " [\(.value.region)]" else "" end)\(if .value.detail!="" then "  \(.value.detail)" else "" end)"),
"  谷歌送中:\(if .google.songzhong=="yes" then "❌ 是" else "✅ 否" end)(YouTube 地区 \(.google.youtube_region),搜索 \(.google.search))",
"── Netflix(title 页实测)──",
"  \(mark(.netflix.status)) \(zh(.netflix.status)) [\(.netflix.region)]  自制剧 \(.netflix.http.original) / 非自制剧 \(.netflix.http.nonorig1),\(.netflix.http.nonorig2)",
"── 黑名单(\(.dnsbl.total) 个库)──",
"  正常 \(.dnsbl.clean)   黑名单 \(.dnsbl.blacklisted|length)   政策名单 \(.dnsbl.policy|length)   解析器查不了 \(.dnsbl.resolver_refused|length)   查询失败 \(.dnsbl.query_failed|length)",
(.dnsbl.blacklisted[] | "  ❌ \(.zone) \(.code)"),
(.dnsbl.policy[] | "  ℹ️ \(.zone) \(.code)(Spamhaus PBL:家宽/动态地址的政策名单,表示不应直接发邮件,不代表滥用)"),
(.dnsbl.unexpected_answer[] | "  ❔ \(.zone) 返回 \(.answer)(非标准应答,未计入)"),
(if (.dnsbl.resolver_refused|length)>0 then "  (当前解析器查不了、结果无效:\(.dnsbl.resolver_refused|join(", "));换解析器或用自建递归解析器可查)" else empty end),
(if (.dnsbl.query_failed|length)>0 then "  (查询失败:\(.dnsbl.query_failed|join(", ")))" else empty end)
' "$OUT"
