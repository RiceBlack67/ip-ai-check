#!/bin/bash
# dnsbl-screen.sh —— 按 RFC 5782 测试点重新实测 DNS 黑名单库,筛出真正可用的 IP 黑名单。
#
# 用法:bash tools/dnsbl-screen.sh [-r 解析器] [-P 并发] < 候选列表 > 可用列表
#   候选列表一行一个库,# 后面是注释。结果(可用的库)输出到 stdout,每个库的判定输出到 stderr。
#   重测内置列表:bash ip-ai-check.sh -L | bash tools/dnsbl-screen.sh -r 127.0.0.1 > zones.txt
#   然后用 DNSBL_LIST=zones.txt ./run.sh … 试用,或替换 ip-ai-check.sh 里 dnsbl_zones 的内容并更新 DNSBL_TESTED。
#
# 判定(对每个库):
#   域名不存在            测试点 NXDOMAIN 且库没有域名服务器,库已关停   → 剔除
#   不应答                测试点 SERVFAIL,库的域名服务器坏了(多半已关停) → 剔除
#   解析器查不了          测试点 127.0.0.2 返回空或 127.255.255.x 拒绝码 → 剔除(换解析器重测)
#   通配应答              测试点 127.0.0.1 也返回「已列入」,查什么都命中 → 剔除
#   可用                  127.0.0.2 返回 127.x.x.x,127.0.0.1 不返回       → 保留
#
# ⚠️ 脚本只能筛掉「查不通 / 通配」的库。白名单(如 dnswl)、信誉评分类、只收录域名不收录 IP 的库(如 SURBL)
#    同样能通过测试点,但列入不代表 IP 有问题,要看各库官网说明后人工剔除。
# ⚠️ 用公共 DNS 筛会把拒绝公共 DNS 的库(如 Spamhaus)误判成「解析器查不了」。用自建递归解析器(unbound)筛最准。
set -u
AT=""; P=8
while getopts "r:P:h" o; do
  case $o in r) AT="@$OPTARG";; P) P=$OPTARG;; *) sed -n '2,20p' "$0"; exit 0;; esac
done
command -v dig >/dev/null || { echo "需要 dig(Debian/Ubuntu: dnsutils;RHEL: bind-utils;Alpine: bind-tools;Arch: bind)" >&2; exit 3; }

one(){
  local z=$1 st a b
  a=$(dig $AT +short +time=3 +tries=2 "2.0.0.127.$z" A 2>/dev/null | grep -E '^127\.' | head -1)
  if [ -z "$a" ] || [[ $a == 127.255.255.* ]]; then
    # 测试点查不通时才判断库是否还在:很多黑名单服务器(rbldnsd)对库名本身就回 NXDOMAIN,
    # 所以看【测试点】的状态码,NXDOMAIN 且没有拒绝码 = 库已关停
    st=$(dig $AT +time=3 +tries=2 "2.0.0.127.$z" A 2>/dev/null | grep -o 'status: [A-Z]*' | head -1 | cut -d' ' -f2)
    if [ -z "$a" ] && [ "$st" = NXDOMAIN ] && [ -z "$(dig $AT +short +time=3 +tries=2 NS "$z" 2>/dev/null; dig $AT +short +time=3 +tries=2 NS "${z#*.}" 2>/dev/null)" ]; then
      echo "DEAD|$z|域名不存在"
    elif [ -z "$a" ] && [ "$st" = SERVFAIL ]; then
      echo "BROKEN|$z|测试点 SERVFAIL"
    else
      echo "REFUSED|$z|测试点 127.0.0.2 返回 ${a:-空}(${st:-无应答})"
    fi
    return
  fi
  b=$(dig $AT +short +time=3 +tries=2 "1.0.0.127.$z" A 2>/dev/null | grep -E '^127\.' | head -1)
  [ -n "$b" ] && { echo "WILDCARD|$z|127.0.0.1 也返回 $b"; return; }
  echo "OK|$z|127.0.0.2 → $a"
}
export -f one; export AT

R=$(mktemp) || exit 1
trap 'rm -f "$R"' EXIT
sed 's/#.*//; s/[[:space:]]//g' | grep -E '^[A-Za-z0-9.-]+$' | sort -u \
  | xargs -P "$P" -I{} bash -c 'one "$@"' _ {} | sort > "$R"
while IFS='|' read -r k z why; do
  case $k in OK) echo "✓ $z  $why" >&2; echo "$z";; DEAD) echo "✗ $z  $why" >&2;;
             REFUSED) echo "? $z  $why(解析器查不了,换解析器重测)" >&2;; WILDCARD) echo "✗ $z  $why(通配应答)" >&2;;
             BROKEN) echo "✗ $z  $why(库的域名服务器不应答,多半已关停;换解析器仍如此就剔除)" >&2;; esac
done < "$R"
res=${AT#@}
echo "可用 $(grep -c '^OK|' "$R")  域名不存在 $(grep -c '^DEAD|' "$R")  不应答 $(grep -c '^BROKEN|' "$R")  通配 $(grep -c '^WILDCARD|' "$R")  解析器查不了 $(grep -c '^REFUSED|' "$R")  解析器:${res:-系统默认}" >&2
