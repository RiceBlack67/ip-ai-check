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
# 用法:bash ip-ai-check.sh -h
# 不需要 root:依赖(jq / dig / curl)齐全时普通用户即可运行;缺依赖时只会用 root 或【免密】sudo 补装。
# 一键(本机或经 SSH 远程):见 run.sh
set -u
VERSION=0.2.1
# 默认的 xykt/IPQuality 版本:固定提交 + sha256(2026-09-16 版)
XYKT_COMMIT_DEFAULT=2384a67c756eb35231f5982b34731e522be3653e
XYKT_SHA256_DEFAULT=b30df5a3c2204276c54e99dcc5080b46f8a627667730aee7de63b109b8ecaecf

usage(){ cat <<'U'
用法:bash ip-ai-check.sh [-o 结果.json] [-J] [-X]
  -o FILE  JSON 写到 FILE(默认 ./ip-ai-check-<时间>.json)
  -J       JSON 输出到 stdout,文本报告输出到 stderr(给 run.sh 远程用)
  -X       不调用 xykt/IPQuality 数据源
环境变量:XYKT_URL / XYKT_SHA256(改用别的 xykt 版本;XYKT_SHA256=skip 跳过校验,不建议)
        XYKT_FILE(用本地的 xykt 脚本,仍校验 sha256)/ DNSBL_LIST(文件)/ DNSBL_ZONES(空格分隔)/ DNSBL_RESOLVER
U
}

# 缺哪些命令
missing_cmds(){ local c m=""; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || m="$m $c"; done; echo "${m# }"; }

# 装缺的依赖:root 直接装;非 root 只用【免密】sudo(sudo -n,绝不弹密码);都不行返回 1
install_pkgs(){
  local who=$1; shift
  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    sudo -n true >/dev/null 2>&1 || return 1
    SUDO="sudo -n"
  fi
  local pkgs="" c
  if command -v apt-get >/dev/null 2>&1; then
    for c in "$@"; do case $c in dig) pkgs="$pkgs dnsutils";; nc) pkgs="$pkgs netcat-openbsd";; ip) pkgs="$pkgs iproute2";; *) pkgs="$pkgs $c";; esac; done
    echo "ℹ️ 为 $who 安装依赖:$pkgs" >&2
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q $pkgs </dev/null >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    local pm; pm=$(command -v dnf || command -v yum)
    for c in "$@"; do case $c in dig) pkgs="$pkgs bind-utils";; nc) pkgs="$pkgs nmap-ncat";; ip) pkgs="$pkgs iproute";; *) pkgs="$pkgs $c";; esac; done
    echo "ℹ️ 为 $who 安装依赖:$pkgs" >&2
    $SUDO "$pm" install -y $pkgs </dev/null >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    for c in "$@"; do case $c in dig) pkgs="$pkgs bind-tools";; nc) pkgs="$pkgs netcat-openbsd";; ip) pkgs="$pkgs iproute2";; *) pkgs="$pkgs $c";; esac; done
    echo "ℹ️ 为 $who 安装依赖:$pkgs" >&2
    $SUDO apk add -q $pkgs </dev/null >/dev/null 2>&1
  else
    return 1
  fi
  [ -z "$(missing_cmds "$@")" ]
}

# 整个脚本包在 main 里:经 `ssh host bash -s` 从标准输入流过去执行时,
# bash 先读完整个函数再运行,中途任何命令都不会误读到脚本本身。
main(){
  exec </dev/null
  local OUT="" JSON_STDOUT=0 USE_XYKT=1 opt
  while getopts "o:JXh" opt; do
    case $opt in o) OUT=$OPTARG;; J) JSON_STDOUT=1;; X) USE_XYKT=0;; h) usage; return 0;; *) usage >&2; return 2;; esac
  done
  XYKT_URL=${XYKT_URL:-https://raw.githubusercontent.com/xykt/IPQuality/$XYKT_COMMIT_DEFAULT/ip.sh}
  XYKT_SHA256=${XYKT_SHA256:-$XYKT_SHA256_DEFAULT}

  # 只在私有临时目录(0700)里工作;正常结束、出错、Ctrl-C、SSH 断开(HUP/PIPE)都会清理
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/ip-ai-check.XXXXXXXX") || { echo "建临时目录失败" >&2; return 1; }
  chmod 700 "$TMP"
  WATCH=""; XPID=""
  cleanup(){
    [ -n "$WATCH" ] && kill "$WATCH" 2>/dev/null
    [ -n "$XPID" ] && kill -TERM -- "-$XPID" 2>/dev/null   # xykt 在独立进程组里,连同它的子进程一起结束
    rm -rf -- "$TMP"
  }
  trap cleanup EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP; trap 'exit 141' PIPE
  # -J(run.sh 远程/本机调用)时结果要交回调用方:调用方进程(远程时是 SSH 会话)一消失就立刻停下并清理,
  # 不在后台继续跑、继续访问外部服务。
  if [ "$JSON_STDOUT" = 1 ]; then
    local parent=$PPID
    # 查 /proc 判断进程是否还在:kill -0 对别的用户的进程会因权限被拒而误判成「已退出」
    alive(){ if [ -d /proc ]; then [ -d "/proc/$1" ]; else ps -p "$1" >/dev/null 2>&1; fi; }
    ( trap - EXIT; while alive "$parent"; do sleep 2; done; kill -TERM $$ 2>/dev/null ) &
    WATCH=$!
  fi

  local miss; miss=$(missing_cmds jq dig curl)
  if [ -n "$miss" ]; then
    install_pkgs ip-ai-check $miss || {
      echo "❌ 缺少依赖:$miss。请先安装(Debian/Ubuntu:apt-get install jq dnsutils curl),或用 root / 免密 sudo 运行。" >&2
      return 3; }
  fi
  local RFD=1; [ "$JSON_STDOUT" = 1 ] && RFD=2

  UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
  C(){ curl -4 -s --max-time 15 -A "$UA" -H "accept-language: en-US,en;q=0.9" "$@"; }
  trace_loc(){ C "https://$1/cdn-cgi/trace" 2>/dev/null | awk -F= '/^loc=/{print $2}'; }
  J="$TMP/r.json"; echo '{}' > "$J"
  put(){ jq --arg k "$1" --argjson v "$2" 'setpath($k|split(".");$v)' "$J" > "$J.n" && mv "$J.n" "$J"; }   # put a.b <json>

  IP=$(C https://api.ipify.org); put ip "\"$IP\""
  put generated "\"$(date -u +%FT%TZ)\""
  put tool "{\"name\":\"ip-ai-check\",\"version\":\"$VERSION\"}"

  # ---------- 1. 可选数据源:xykt/IPQuality(隐私模式,不上传报告) ----------
  # 默认按【固定提交 + sha256】下载,哈希不符拒绝运行;不再拉 main 分支的最新版。
  if [ "$USE_XYKT" = 1 ]; then
    xy="$TMP/xykt-ip.sh"; xy_err=""
    if [ -n "${XYKT_FILE:-}" ]; then cp -- "$XYKT_FILE" "$xy" 2>/dev/null || xy_err="读不到 XYKT_FILE"
    else C -fL -o "$xy" "$XYKT_URL" 2>/dev/null || xy_err="下载失败:$XYKT_URL"; fi
    if [ -z "$xy_err" ] && [ "$XYKT_SHA256" != skip ]; then
      echo "$XYKT_SHA256  $xy" | sha256sum -c --quiet >/dev/null 2>&1 || xy_err="sha256 不符,拒绝运行"
    fi
    # xykt 自己还要 bc / nc / ip;齐了就 -n 跳过它的依赖安装,缺了且能 root/免密 sudo 才补装,否则跳过它
    xy_missing=$(missing_cmds jq curl bc nc dig ip)
    if [ -z "$xy_err" ] && [ -n "$xy_missing" ]; then
      install_pkgs xykt $xy_missing || xy_err="缺依赖($xy_missing),且没有 root 或免密 sudo,跳过"
    fi
    if [ -z "$xy_err" ]; then
      # setsid:放进独立进程组,中断时能整组结束;wait 期间收到信号会立刻转去清理
    ( cd "$TMP" && exec setsid bash "$xy" -4 -n -p -j -o "$TMP/xykt.json" </dev/null >/dev/null 2>&1 ) &
    XPID=$!; wait "$XPID" 2>/dev/null; XPID=""
      if jq -e . "$TMP/xykt.json" >/dev/null 2>&1; then put xykt "$(cat "$TMP/xykt.json")"
      else xy_err="xykt 运行失败"; fi
    fi
    [ -n "$xy_err" ] && { put xykt null; put xykt_note "$(jq -n --arg e "$xy_err" '$e')"; echo "⚠️ xykt 数据源:$xy_err" >&2; }
  else
    put xykt null
  fi

  # ---------- 2a. Netflix(title 页实测) ----------
  nf_title(){  # 返回 "<http码> <国家> <status>"
    # Netflix 会按地区 301 到带语言前缀的地址(如日本 /jp-en/title/…),必须跟随跳转,
    # 否则非美国 IP 一律被误判成不可用;只认最终仍停在 netflix.com 的 title 页
    local b; b=$(C -L --max-redirs 3 -w '\n__HTTP__%{http_code}__URL__%{url_effective}' "https://www.netflix.com/title/$1" 2>/dev/null)
    local tail=${b##*__HTTP__} url=${b##*__URL__}
    local code=${tail%%__URL__*}
    case "$url" in https://www.netflix.com/*title/"$1"*) ;; *) [ "$code" = 200 ] && code=302 ;; esac
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
  if [ -n "${DNSBL_ZONES:-}" ]; then printf '%s\n' $DNSBL_ZONES
  elif [ -n "${DNSBL_LIST:-}" ] && [ -f "$DNSBL_LIST" ]; then tr -d '\r' < "$DNSBL_LIST"; else dnsbl_zones; fi \
    | sed 's/#.*//; s/[[:space:]]//g' | grep -E '^[A-Za-z0-9.-]+$' | sort -u > "$LIST"
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
  ' "$J" >&"$RFD"

  if [ "$JSON_STDOUT" = 1 ]; then cat "$J"
  else
    [ -n "$OUT" ] || OUT="./ip-ai-check-$(date -u +%Y%m%d-%H%M%S).json"
    cp -- "$J" "$OUT" && echo "JSON: $OUT" >&2
  fi
}

main "$@"
