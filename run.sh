#!/bin/bash
# run.sh —— ip-ai-check 一键入口:检测本机,或经 SSH 检测远程机器;输出 JSON / 文本 / 卡片,可选发布 HTML 报告。
#
# 用法:
#   ./run.sh [目标] [选项]
#     目标          省略 = 检测本机;user@host、host 或 ~/.ssh/config 里的别名 = 经 SSH 检测远程机器
#                   (不写用户名时用 ssh 的默认用户,不会自动换成 root)
#     -y, --yes     远程检测不再询问确认(非交互环境必须加)
#     --dry-run     只显示将在目标机上做什么,不执行
#     --full        卡片和报告显示完整 IP(默认只露最后一段,如 *.*.*.56)
#     --no-xykt     不调用 xykt/IPQuality 数据源(更快,但没有各数据库的类型判定 / 风险分 / 风险因子)
#     --publish     生成 HTML 报告页到 $PUBLISH_DIR/<随机id>/,打印 $PUBLISH_URL/<id>/
#
# 远程检测怎么执行:脚本经 SSH 的标准输入流给目标机的 bash,不往目标机复制任何文件;
# 目标机上只在私有临时目录(0700)里工作,正常结束、出错、Ctrl-C、SSH 断开都会删除。
#
# 环境变量:
#   DNSBL_RESOLVER / DNSBL_LIST          查黑名单用的解析器 / 自定义黑名单列表(本机文件,内容会带到目标机)
#   XYKT_URL / XYKT_SHA256               改用别的 xykt 版本(默认固定提交 + sha256)
#   OUT_DIR                              结果目录(默认 ./reports)
#   PUBLISH_DIR / PUBLISH_URL            --publish 用,比如 /var/www/html/ipq 与 https://example.com/ipq
#
# ⚠️ 本工具的结果不要冒充 Report.Check.Place 报告:那种链接是 xykt 脚本上传结果后由 check.place 渲染的。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=""; FULL=""; XY=1; PUB=0; YES=0; DRY=0
for a in "$@"; do
  case $a in
    --full) FULL=--full;; --no-xykt) XY=0;; --publish) PUB=1;; -y|--yes) YES=1;; --dry-run) DRY=1;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    -*) echo "未知选项 $a(看帮助:./run.sh -h)"; exit 2;;
    *) [ -z "$T" ] || { echo "只能指定一个目标"; exit 2; }; T=$a;;
  esac
done
# 目标只允许 用户@主机 / 主机 / 别名 的字符,且不能以 - 开头(否则会被 ssh 当成选项)
if [ -n "$T" ] && { [[ "$T" == -* ]] || ! [[ "$T" =~ ^[A-Za-z0-9._@:%-]+$ ]]; }; then
  echo "目标格式不对:$T"; exit 2
fi

OUT_DIR=${OUT_DIR:-$HERE/reports}; mkdir -p "$OUT_DIR"
NAME=$(printf '%s' "${T:-local}" | sed 's/^.*@//; s/[^A-Za-z0-9._-]/_/g')
B="$OUT_DIR/$NAME-$(date -u +%Y%m%d-%H%M%S)"
VER=$(sed -n 's/^VERSION=//p' "$HERE/ip-ai-check.sh" | head -1)
SCRIPT_SHA=$(sha256sum "$HERE/ip-ai-check.sh" | cut -c1-16)
XYKT_DEF=$(sed -n 's/^XYKT_COMMIT_DEFAULT=//p' "$HERE/ip-ai-check.sh" | head -1)

ARGS=(-J); [ $XY = 0 ] && ARGS+=(-X)
# 只把这几个变量带到目标机
ENVS=()
for v in DNSBL_RESOLVER XYKT_URL XYKT_SHA256; do
  [ -n "${!v:-}" ] && ENVS+=("$v=${!v}")
done
# 自定义黑名单列表:本机文件的内容随命令带过去(目标机上没有这个文件)
if [ -n "${DNSBL_LIST:-}" ]; then
  [ -f "$DNSBL_LIST" ] || { echo "DNSBL_LIST 文件不存在:$DNSBL_LIST"; exit 2; }
  ENVS+=("DNSBL_ZONES=$(sed 's/#.*//' "$DNSBL_LIST" | tr -s ' \t\r\n' ' ')")
fi

if [ -z "$T" ]; then
  [ $DRY = 1 ] && { echo "本机检测:bash ip-ai-check.sh ${ARGS[*]}"; exit 0; }
  env "${ENVS[@]}" bash "$HERE/ip-ai-check.sh" "${ARGS[@]}" > "$B.json.part" 2> >(tee "$B.txt" >&2)
else
  SSH_USER=$(ssh -G -- "$T" 2>/dev/null | awk '$1=="user"{print $2; exit}')
  SSH_HOST=$(ssh -G -- "$T" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')
  cat >&2 <<EOF
── 远程检测预览 ──
目标:${SSH_USER:-?}@${SSH_HOST:-$T}
将在目标机上:
  · 经标准输入运行 ip-ai-check.sh $VER(sha256 前 16 位 $SCRIPT_SHA),不复制任何文件到目标机
  · 只在私有临时目录(0700)里工作,结束、出错、中断、断线都会删除
  · 访问:AI 服务、Netflix、YouTube、Google、api.ipify.org、DNS 黑名单
EOF
  if [ $XY = 1 ]; then
    cat >&2 <<EOF
  · 下载并运行第三方脚本 xykt/IPQuality(固定提交 ${XYKT_URL:+自定义 URL}${XYKT_URL:-${XYKT_DEF:0:7}},sha256 不符拒绝运行)
    它会把被检测的 IP 发给它自己的服务器 ipinfo.check.place 查询各数据库;不想要就加 --no-xykt
EOF
  fi
  cat >&2 <<EOF
  · 缺依赖(jq / dig / curl$( [ $XY = 1 ] && echo ' / bc / nc / ip'))时:root 或免密 sudo 才会用包管理器安装,
    否则 ip-ai-check 报错退出、xykt 部分跳过;不会弹出 sudo 密码
EOF
  if [ "${SSH_USER:-}" = root ]; then
    echo "  ⚠️ 以 root 登录:脚本会以 root 运行。依赖装好后用普通用户即可(ssh 目标写成 user@host)。" >&2
  fi
  [ $DRY = 1 ] && exit 0
  if [ $YES = 0 ]; then
    if [ -t 0 ]; then
      read -r -p "继续?[y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消"; exit 1; }
    else
      echo "非交互环境,未加 -y,已取消" >&2; exit 1
    fi
  fi
  REMOTE="bash -s --"
  for a in "${ARGS[@]}"; do REMOTE+=" $(printf '%q' "$a")"; done
  [ ${#ENVS[@]} -gt 0 ] && REMOTE="env $(printf '%q ' "${ENVS[@]}")$REMOTE"
  ssh -T -o BatchMode=yes -- "$T" "$REMOTE" < "$HERE/ip-ai-check.sh" > "$B.json.part" 2> >(tee "$B.txt" >&2)
fi

# 校验结果是合法 JSON 再落盘
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$B.json.part" 2>/dev/null \
  || { echo "❌ 没拿到有效结果(见上面的输出)"; rm -f "$B.json.part"; exit 1; }
mv "$B.json.part" "$B.json"

python3 "$HERE/card.py" "$B.json" "$B.png" $FULL >/dev/null 2>&1 && echo "卡片: $B.png" || echo "(没有 chromium,跳过卡片)"
echo "JSON: $B.json"
if [ $PUB = 1 ]; then
  : "${PUBLISH_DIR:?--publish 需要 PUBLISH_DIR}" "${PUBLISH_URL:?--publish 需要 PUBLISH_URL}"
  ID=$(python3 -c 'import secrets,string;print("".join(secrets.choice(string.ascii_uppercase+string.digits) for _ in range(9)))')
  CARD=(); [ -f "$B.png" ] && CARD=(--card "$B.png")
  python3 "$HERE/report.py" "$B.json" "$PUBLISH_DIR/$ID" $FULL "${CARD[@]}" >/dev/null
  echo "报告链接: $PUBLISH_URL/$ID/"
fi
