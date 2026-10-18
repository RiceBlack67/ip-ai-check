#!/bin/bash
# run.sh —— ip-ai-check 一键入口:检测本机或经 SSH 检测远程机器,输出 JSON / 文本 / 卡片,可选发布 HTML 报告。
#
# 用法:
#   ./run.sh [目标] [选项]
#     目标        省略 = 检测本机;IP 或 ssh 别名 = 经 SSH 推过去跑(需能 ssh root@IP 免密登录)
#     --full      卡片和报告显示完整 IP(默认只露最后一段,如 *.*.*.56)
#     --no-xykt   不调用 xykt/IPQuality 数据源(更快,但没有各数据库的类型判定 / 风险分 / 风险因子)
#     --publish   生成 HTML 报告页到 $PUBLISH_DIR/<随机id>/,打印 $PUBLISH_URL/<id>/
#
# 环境变量:
#   XYKT_URL      xykt/IPQuality 脚本地址(默认其 main 分支的 ip.sh;也可写 file:///本地路径)
#   XYKT_SHA256   填了就校验 xykt 脚本的 sha256,不符拒跑(建议固定一个版本)
#   OUT_DIR       结果目录(默认 ./reports)
#   PUBLISH_DIR / PUBLISH_URL   --publish 用,比如 /var/www/html/ipq 与 https://example.com/ipq
#
# ⚠️ 底座会在目标机上用 apt 安装依赖(jq / curl / dnsutils 等)。
# ⚠️ 本工具的结果不要冒充 Report.Check.Place 报告:那种链接是 xykt 脚本上传结果后由 check.place 渲染的。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=""; FULL=""; XY=1; PUB=0
for a in "$@"; do case $a in --full) FULL=--full;; --no-xykt) XY=0;; --publish) PUB=1;; -*) echo "未知选项 $a"; exit 2;; *) T=$a;; esac; done
XYKT_URL=${XYKT_URL:-https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh}
OUT_DIR=${OUT_DIR:-$HERE/reports}; mkdir -p "$OUT_DIR"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

if [ $XY = 1 ]; then
  curl -fsSL "$XYKT_URL" -o "$WORK/xykt-ip.sh"
  if [ -n "${XYKT_SHA256:-}" ]; then
    echo "$XYKT_SHA256  $WORK/xykt-ip.sh" | sha256sum -c --quiet || { echo "xykt 脚本 sha256 不符,拒绝运行"; exit 1; }
  fi
fi

NAME=${T:-local}; NAME=${NAME#*@}
B="$OUT_DIR/$NAME-$(date -u +%Y%m%d-%H%M)"
if [ -z "$T" ]; then
  ENV=(); [ $XY = 1 ] && ENV=(XYKT="$WORK/xykt-ip.sh")
  env "${ENV[@]}" bash "$HERE/ip-ai-check.sh" -o "$B.json" | tee "$B.txt"
else
  H="$T"; [[ "$T" =~ ^[0-9.]+$ ]] && H="root@$T"
  scp -q "$HERE/ip-ai-check.sh" "$H":/tmp/ip-ai-check.sh
  E=""; [ $XY = 1 ] && { scp -q "$WORK/xykt-ip.sh" "$H":/tmp/xykt-ip.sh; E="XYKT=/tmp/xykt-ip.sh"; }
  ssh "$H" "$E bash /tmp/ip-ai-check.sh -o /tmp/ip-ai-check.json; rm -f /tmp/ip-ai-check.sh /tmp/xykt-ip.sh" | tee "$B.txt"
  scp -q "$H":/tmp/ip-ai-check.json "$B.json"
fi

python3 "$HERE/card.py" "$B.json" "$B.png" $FULL >/dev/null 2>&1 && echo "卡片: $B.png" || echo "(没有 chromium,跳过卡片)"
echo "JSON: $B.json"
if [ $PUB = 1 ]; then
  : "${PUBLISH_DIR:?--publish 需要 PUBLISH_DIR}" "${PUBLISH_URL:?--publish 需要 PUBLISH_URL}"
  ID=$(python3 -c 'import secrets,string;print("".join(secrets.choice(string.ascii_uppercase+string.digits) for _ in range(9)))')
  CARD=(); [ -f "$B.png" ] && CARD=(--card "$B.png")
  python3 "$HERE/report.py" "$B.json" "$PUBLISH_DIR/$ID" $FULL "${CARD[@]}" >/dev/null
  echo "报告链接: $PUBLISH_URL/$ID/"
fi
