#!/usr/bin/env bash
# ============================================================
#  Sing-Box-Plus 管理脚本（20 节点：直连 10 + WARP 10）
#  Version: v4.8.1
#  author：Alvin9999
#  Repo: https://github.com/Alvin9999-newpac/Sing-Box-Plus
# ============================================================

set -Eeuo pipefail

# 让退格键在终端里正常工作；没有 TTY（如 curl | bash、自动化执行）时 stty 会失败，不能让它在 set -e 下直接退出
[[ -t 0 ]] && stty erase ^H 2>/dev/null || true
# ===== [BEGIN] SBP 引导模块 v2.2.0+（包管理器优先 + 二进制回退） =====
# 模式与哨兵
: "${SBP_SOFT:=0}"                               # 1=宽松模式（失败尽量继续），默认 0=严格
: "${SBP_SKIP_DEPS:=0}"                          # 1=启动跳过依赖检查（只在菜单 1) 再装）
: "${SBP_FORCE_DEPS:=0}"                         # 1=强制重新安装依赖
: "${SBP_BIN_ONLY:=0}"                           # 1=强制走二进制模式，不用包管理器
: "${SBP_ROOT:=/var/lib/sing-box-plus}"
: "${SBP_BIN_DIR:=${SBP_ROOT}/bin}"
: "${SBP_DEPS_SENTINEL:=/var/lib/sing-box-plus/.deps_ok}"

mkdir -p "$SBP_BIN_DIR" 2>/dev/null || true
export PATH="$SBP_BIN_DIR:$PATH"

# 工具：下载器 + 轻量重试
dl() { # 用法：dl <URL> <OUT_PATH>
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --connect-timeout 5 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    timeout 15 wget -qO "$out" --tries=2 "$url"
  else
    echo "[ERROR] 缺少 curl/wget：无法下载 $url"; return 1
  fi
}
with_retry() { local n=${1:-3}; shift; local i=1; until "$@"; do [ $i -ge "$n" ] && return 1; sleep $((i*2)); i=$((i+1)); done; }

# 工具：架构探测 + jq 静态兜底
detect_goarch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    i386|i686)    echo 386   ;;
    *)            echo amd64 ;;
  esac
}
ensure_jq_static() {
  command -v jq >/dev/null 2>&1 && return 0
  local arch out="$SBP_BIN_DIR/jq" url alt
  arch="$(detect_goarch)"
  url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}"
  alt="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
  dl "$url" "$out" || { [ "$arch" = amd64 ] && dl "$alt" "$out" || true; }
  chmod +x "$out" 2>/dev/null || true
  command -v jq >/dev/null 2>&1
}

# 工具：核心命令自检
sbp_core_ok() {
  local need=(curl jq tar unzip openssl)
  local b; for b in "${need[@]}"; do command -v "$b" >/dev/null 2>&1 || return 1; done
  return 0
}

# —— 包管理器路径 —— #
sbp_detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then PM=apt
  elif command -v dnf      >/dev/null 2>&1; then PM=dnf
  elif command -v yum      >/dev/null 2>&1; then PM=yum
  elif command -v pacman   >/dev/null 2>&1; then PM=pacman
  elif command -v zypper   >/dev/null 2>&1; then PM=zypper
  else PM=unknown; fi
  [ "$PM" = unknown ] && return 1 || return 0
}

# apt 允许发行信息变化（stable→oldstable / Version 变化）
apt_allow_release_change() {
  cat >/etc/apt/apt.conf.d/99allow-releaseinfo-change <<'CONF'
Acquire::AllowReleaseInfoChange::Suite "true";
Acquire::AllowReleaseInfoChange::Version "true";
CONF
}

# 刷新软件仓（含各系兜底）
sbp_pm_refresh() {
  case "$PM" in
    apt)
      apt_allow_release_change
      [[ -f /etc/apt/sources.list ]] && sed -i 's#^deb http://#deb https://#' /etc/apt/sources.list 2>/dev/null || true
      # 修正 bullseye 的 security 行：bullseye/updates → debian-security bullseye-security
      [[ -f /etc/apt/sources.list ]] && sed -i -E 's#^(deb\s+https?://security\.debian\.org)(/debian-security)?\s+bullseye/updates(.*)$#\1/debian-security bullseye-security\3#' /etc/apt/sources.list || true

      local AOPT=""
      curl -6 -fsS --connect-timeout 2 https://deb.debian.org >/dev/null 2>&1 || AOPT='-o Acquire::ForceIPv4=true'

      if ! with_retry 3 apt-get update -y $AOPT; then
        # backports 404 临时注释再试
        sed -i 's#^\([[:space:]]*deb .* bullseye-backports.*\)#\# \1#' /etc/apt/sources.list 2>/dev/null || true
        with_retry 2 apt-get update -y $AOPT -o Acquire::Check-Valid-Until=false || [ "$SBP_SOFT" = 1 ]
      fi
      ;;
    dnf)
      dnf clean metadata || true
      with_retry 3 dnf makecache || [ "$SBP_SOFT" = 1 ]
      ;;
    yum)
      yum clean all || true
      with_retry 3 yum makecache fast || true
      yum install -y epel-release || true   # EL7/老环境便于装 jq 等
      ;;
    pacman)
      pacman-key --init >/dev/null 2>&1 || true
      pacman-key --populate archlinux >/dev/null 2>&1 || true
      with_retry 3 pacman -Syy --noconfirm || [ "$SBP_SOFT" = 1 ]
      ;;
    zypper)
      zypper -n ref || zypper -n ref --force || true
      ;;
  esac
}

# 逐包安装（单个失败不拖累整体）
sbp_pm_install() {
  case "$PM" in
    apt)
      local p; apt-get update -y >/dev/null 2>&1 || true
      for p in "$@"; do apt-get install -y --no-install-recommends "$p" || true; done
      ;;
    dnf)
      local p; for p in "$@"; do dnf install -y "$p" || true; done
      ;;
    yum)
      yum install -y epel-release || true
      local p; for p in "$@"; do yum install -y "$p" || true; done
      ;;
    pacman)
      pacman -Sy --noconfirm || [ "$SBP_SOFT" = 1 ]
      local p; for p in "$@"; do pacman -S --noconfirm --needed "$p" || true; done
      ;;
    zypper)
      zypper -n ref || true
      local p; for p in "$@"; do zypper --non-interactive install "$p" || true; done
      ;;
  esac
}

# 用包管理器装一轮依赖
sbp_install_prereqs_pm() {
  sbp_detect_pm || return 1
  sbp_pm_refresh

  case "$PM" in
    apt)    CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz-utils uuid-runtime iproute2 iptables ufw) ;;
    dnf|yum)CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute iptables iptables-nft firewalld) ;;
    pacman) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables) ;;
    zypper) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables firewalld) ;;
    *) return 1 ;;
  esac

  sbp_pm_install "${CORE[@]}" "${EXTRA[@]}"

  # jq 兜底：安装失败时下载静态 jq
  if ! command -v jq >/dev/null 2>&1; then
    echo "[INFO] 通过包管理器安装 jq 失败，尝试下载静态 jq ..."
    ensure_jq_static || { echo "[ERROR] 无法获取 jq"; return 1; }
  fi

  # 严格模式：核心仍缺则失败
  if ! sbp_core_ok; then
    [ "$SBP_SOFT" = 1 ] || return 1
    echo "[WARN] 核心依赖未就绪（宽松模式继续）"
  fi
  return 0
}

# —— 二进制模式：直接获取 sing-box 可执行文件 —— #
install_singbox_binary() {
  local arch goarch pkg tmp json url fn
  goarch="$(detect_goarch)"
  tmp="$(mktemp -d)" || return 1

  ensure_jq_static || { echo "[ERROR] 无法获取 jq，二进制模式失败"; rm -rf "$tmp"; return 1; }
json="$(with_retry 3 curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.13.7)" || { rm -rf "$tmp"; return 1; }
  url="$(printf '%s' "$json" | jq -r --arg a "$goarch" '
    .assets[] | select(.name|test("linux-" + $a + "\\.(tar\\.(xz|gz)|zip)$")) | .browser_download_url
  ' | head -n1)"

  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "[ERROR] 未找到匹配架构($goarch)的 sing-box 资产"; rm -rf "$tmp"; return 1
  fi

  pkg="$tmp/pkg"
  with_retry 3 dl "$url" "$pkg" || { rm -rf "$tmp"; return 1; }

  case "$url" in
    *.tar.xz)  if command -v xz >/dev/null 2>&1; then tar -xJf "$pkg" -C "$tmp"; else echo "[ERROR] 缺少 xz；请安装 xz/xz-utils 或换 .tar.gz/.zip"; rm -rf "$tmp"; return 1; fi ;;
    *.tar.gz)  tar -xzf "$pkg" -C "$tmp" ;;
    *.zip)     unzip -q "$pkg" -d "$tmp" || { echo "[ERROR] 缺少 unzip"; rm -rf "$tmp"; return 1; } ;;
    *)         echo "[ERROR] 未知包格式：$url"; rm -rf "$tmp"; return 1 ;;
  esac

  fn="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [ -n "$fn" ] || { echo "[ERROR] 包内未找到 sing-box"; rm -rf "$tmp"; return 1; }

  install -m 0755 "$fn" "$SBP_BIN_DIR/sing-box" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "[OK] 已安装 sing-box 到 $SBP_BIN_DIR/sing-box"
}

# 证书兜底（有 openssl 就生成；没有就先跳过，由业务决定是否强制）
ensure_tls_cert() {
  local dir="$SBP_ROOT"
  mkdir -p "$dir"
  if command -v openssl >/dev/null 2>&1; then
    [[ -f "$dir/private.key" ]] || openssl ecparam -genkey -name prime256v1 -out "$dir/private.key" >/dev/null 2>&1
    [[ -f "$dir/cert.pem"    ]] || openssl req -new -x509 -days 36500 -key "$dir/private.key" -out "$dir/cert.pem" -subj "/CN=www.bing.com" >/dev/null 2>&1
  fi
}

# 标记哨兵
sbp_mark_deps_ok() {
  if sbp_core_ok; then
    mkdir -p "$(dirname "$SBP_DEPS_SENTINEL")" && : > "$SBP_DEPS_SENTINEL" || true
  fi
}

# 入口：装依赖 / 二进制回退
sbp_bootstrap() {
  [ "$EUID" -eq 0 ] || { echo "请以 root 运行（或 sudo）"; exit 1; }

  if [ "$SBP_SKIP_DEPS" = 1 ]; then
    echo "[INFO] 已跳过启动时依赖检查（SBP_SKIP_DEPS=1）"
    return 0
  fi

  # 已就绪则跳过
  if [ "$SBP_FORCE_DEPS" != 1 ] && sbp_core_ok && [ -f "$SBP_DEPS_SENTINEL" ] && [ "$SBP_BIN_ONLY" != 1 ]; then
    echo "依赖已安装"
    return 0
  fi

  # 强制二进制模式
  if [ "$SBP_BIN_ONLY" = 1 ]; then
    echo "[INFO] 二进制模式（SBP_BIN_ONLY=1）"
    install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
    ensure_tls_cert
    return 0
  fi

  # 包管理器优先
  if sbp_install_prereqs_pm; then
    sbp_mark_deps_ok
    return 0
  fi

  # 回退到二进制模式
  echo "[WARN] 包管理器依赖安装失败，切换到二进制模式"
  install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
  ensure_tls_cert
}
# ===== [END] SBP 引导模块 v2.2.0+ =====


# ===== 提前设默认，避免 set -u 早期引用未定义变量导致脚本直接退出 =====
SYSTEMD_SERVICE=${SYSTEMD_SERVICE:-sing-box.service}
BIN_PATH=${BIN_PATH:-/usr/local/bin/sing-box}
SB_DIR=${SB_DIR:-/opt/sing-box}
CONF_JSON=${CONF_JSON:-$SB_DIR/config.json}
DATA_DIR=${DATA_DIR:-$SB_DIR/data}
CERT_DIR=${CERT_DIR:-$SB_DIR/cert}
WGCF_DIR=${WGCF_DIR:-$SB_DIR/wgcf}

# 功能开关（保持稳定默认）
ENABLE_WARP=${ENABLE_WARP:-true}
ENABLE_VLESS_REALITY=${ENABLE_VLESS_REALITY:-true}
ENABLE_VLESS_GRPCR=${ENABLE_VLESS_GRPCR:-true}
ENABLE_TROJAN_REALITY=${ENABLE_TROJAN_REALITY:-true}
ENABLE_HYSTERIA2=${ENABLE_HYSTERIA2:-true}
ENABLE_VMESS_WS=${ENABLE_VMESS_WS:-true}
ENABLE_HY2_OBFS=${ENABLE_HY2_OBFS:-true}
ENABLE_SS2022=${ENABLE_SS2022:-true}
ENABLE_SS=${ENABLE_SS:-true}
ENABLE_TUIC=${ENABLE_TUIC:-true}
ENABLE_ANYTLS=${ENABLE_ANYTLS:-true}

# 常量
SCRIPT_NAME="Sing-Box-Plus 管理脚本"
SCRIPT_VERSION="v4.8.1"
REALITY_SERVER=${REALITY_SERVER:-www.microsoft.com}
REALITY_SERVER_PORT=${REALITY_SERVER_PORT:-443}
# REALITY 偷域名池：每个 reality inbound 安装时各自随机抽一个，抽中后写入 creds.env 持久化，
# 重启/重装不会变（不会让旧客户端链接失效）。空格分隔，全部需满足 TLS1.3 + H2、不重定向、未被墙。
REALITY_SERVERS=${REALITY_SERVERS:-"swift.org yahoo.com www.yahoo.com addons.mozilla.org lovelive-anime.jp www.lovelive-anime.jp one-piece.com www.one-piece.com www.bing.com www.apple.com gateway.icloud.com"}
# 已从池里下线的域名：creds.env 里若还持久化着这些，重新部署/换端口时会自动重抽（#17：微软调整 TLS 特征后 Reality 失效）
REALITY_RETIRED=${REALITY_RETIRED:-"www.microsoft.com microsoft.com"}
GRPC_SERVICE=${GRPC_SERVICE:-grpc}
VMESS_WS_PATH=${VMESS_WS_PATH:-/vm}

# 兼容 sing-box 1.12.x 的旧 wireguard 出站
export ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=${ENABLE_DEPRECATED_WIREGUARD_OUTBOUND:-true}

# ===== 颜色 =====
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_RED="\033[31m";  C_GREEN="\033[32m"; C_YELLOW="\033[33m"
C_BLUE="\033[34m"; C_CYAN="\033[36m"; C_MAGENTA="\033[35m"
hr(){ printf "${C_DIM}=============================================================${C_RESET}\n"; }

# ===== 基础工具 =====
info(){ echo -e "[${C_CYAN}信息${C_RESET}] $*"; }
ok(){   echo -e "[${C_GREEN}成功${C_RESET}] $*"; }
warn(){ echo -e "[${C_YELLOW}警告${C_RESET}] $*"; }
err(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; }
die(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; exit 1; }

# --- 架构映射：uname -m -> 发行资产名 ---
arch_map() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l)       echo "armv7" ;;   # 上游无 armv6，回退 armv7
    i386|i686)    echo "386"  ;;
    *)            echo "amd64" ;;
  esac
}

# --- 依赖安装：兼容 apt / yum / dnf / apk / pacman / zypper ---
ensure_deps() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
  ((${#miss[@]}==0)) && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${miss[@]}" || apt-get install -y --no-install-recommends "${miss[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${miss[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${miss[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${miss[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${miss[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${miss[@]}"
  else
    err "无法自动安装依赖：${miss[*]}，请手动安装后重试"
    return 1
  fi
}

b64enc(){ base64 -w 0 2>/dev/null || base64; }
urlenc(){ # 纯 bash urlencode（不依赖 python）
  local s="$1" out="" c
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      ' ') out+="%20" ;;
      *) printf -v out "%s%%%02X" "$out" "'$c" ;;
    esac
  done
  printf "%s" "$out"
}

safe_source_env(){ # 安全 source，忽略不存在文件
  local f="$1"; [[ -f "$f" ]] || return 1
  set +u; # 避免未定义变量报错
  # shellcheck disable=SC1090
  source "$f"
  set -u
}

get_ip4(){ # 多源获取公网 IPv4（每个源最多等 5 秒，避免某个源卡住导致菜单 2 一直不动）
  local ip="" src
  for src in ipv4.icanhazip.com ifconfig.me ip.sb; do
    ip=$(curl -4 -fsSL --connect-timeout 3 --max-time 5 "$src" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
    ip=""
  done
  if [[ -z "$ip" ]]; then
    warn "获取公网 IPv4 失败，链接里的地址暂用 127.0.0.1，请手动替换为服务器 IP" >&2
    ip=127.0.0.1
  fi
  echo "$ip"
}

get_ip6(){ # 多源获取公网 IPv6（无 IPv6 则返回空）
  local ip="" src
  for src in ipv6.icanhazip.com ifconfig.me ip.sb; do
    ip=$(curl -6 -fsSL --connect-timeout 3 --max-time 5 "$src" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]] && break
    ip=""
  done
  echo "$ip"
}

# 兼容旧调用：默认返回 IPv4
get_ip(){ get_ip4; }

# URI/分享链接里：IPv6 需要用 [addr] 包起来
fmt_host_for_uri(){
  local ip="$1"
  [[ "$ip" == *:* ]] && printf '[%s]' "$ip" || printf '%s' "$ip"
}

is_uuid(){ [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]; }

ensure_dirs(){ mkdir -p "$SB_DIR" "$DATA_DIR" "$CERT_DIR" "$WGCF_DIR"; }

# ===== 端口（20 个互不重复） =====
PORT_VARS=(PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS
           PORT_VLESSR_W PORT_VLESS_GRPCR_W PORT_TROJANR_W PORT_HY2_W PORT_VMESS_WS_W PORT_HY2_OBFS_W PORT_SS2022_W PORT_SS_W PORT_TUIC_W PORT_ANYTLS_W)
PORTS=()
# 本机已在监听的端口（tcp+udp），避免和 nginx / xray 等其他程序撞端口
# 没有 ss（精简镜像）时返回空；|| true 不能省，否则 pipefail + set -e 会让脚本在这里静默退出
used_ports(){ { ss -Htuln 2>/dev/null || true; } | awk '{n=split($5,a,":"); print a[n]}' | sort -un | tr '\n' ' '; }
# 用法：gen_port <变量名>
# 直接给变量赋值，不能写成 VAR=$(gen_port)：$(...) 是子 shell，PORTS+= 回不到父进程，去重表永远是空的
gen_port() {
  local __var="$1" p
  [[ -n "${USED_PORTS+x}" ]] || USED_PORTS=" $(used_ports) "
  while :; do
    p=$(( ( (RANDOM << 15) | RANDOM ) % 55536 + 10000 ))   # 10000-65535
    [[ " ${PORTS[*]-} " == *" $p "* ]] && continue
    [[ "$USED_PORTS" == *" $p "* ]] && continue
    PORTS+=("$p")
    printf -v "$__var" '%s' "$p"
    return 0
  done
}
rand_ports_reset(){ PORTS=(); unset USED_PORTS; }

PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

save_ports(){ cat > "$SB_DIR/ports.env" <<EOF
PORT_VLESSR=$PORT_VLESSR
PORT_VLESS_GRPCR=$PORT_VLESS_GRPCR
PORT_TROJANR=$PORT_TROJANR
PORT_HY2=$PORT_HY2
PORT_VMESS_WS=$PORT_VMESS_WS
PORT_HY2_OBFS=$PORT_HY2_OBFS
PORT_SS2022=$PORT_SS2022
PORT_SS=$PORT_SS
PORT_TUIC=$PORT_TUIC
PORT_ANYTLS=$PORT_ANYTLS
PORT_VLESSR_W=$PORT_VLESSR_W
PORT_VLESS_GRPCR_W=$PORT_VLESS_GRPCR_W
PORT_TROJANR_W=$PORT_TROJANR_W
PORT_HY2_W=$PORT_HY2_W
PORT_VMESS_WS_W=$PORT_VMESS_WS_W
PORT_HY2_OBFS_W=$PORT_HY2_OBFS_W
PORT_SS2022_W=$PORT_SS2022_W
PORT_SS_W=$PORT_SS_W
PORT_TUIC_W=$PORT_TUIC_W
PORT_ANYTLS_W=$PORT_ANYTLS_W
EOF
}
load_ports(){ safe_source_env "$SB_DIR/ports.env" || return 1; }

save_all_ports(){
  rand_ports_reset
  local v
  # 先登记已有端口；旧版本 bug 可能留下重复端口（会导致 sing-box bind 失败），重复的那个清空重新分配
  for v in "${PORT_VARS[@]}"; do
    [[ -n "${!v:-}" ]] || continue
    if [[ " ${PORTS[*]-} " == *" ${!v} "* ]]; then
      warn "端口 ${!v} 重复（${v}），重新分配"
      printf -v "$v" '%s' ""
    else
      PORTS+=("${!v}")
    fi
  done
  # 订阅端口也要避开（没有 ss 时只能靠这里去重）
  local sp; sp=$(sed -n 's/^SUB_PORT=//p' "$SB_DIR/sub.env" 2>/dev/null || true)
  [[ -n "$sp" ]] && PORTS+=("$sp")
  for v in "${PORT_VARS[@]}"; do
    [[ -n "${!v:-}" ]] || gen_port "$v"
  done
  save_ports
}

# ===== env / creds / warp =====
save_env(){ cat > "$SB_DIR/env.conf" <<EOF
BIN_PATH=$BIN_PATH
ENABLE_VLESS_REALITY=$ENABLE_VLESS_REALITY
ENABLE_VLESS_GRPCR=$ENABLE_VLESS_GRPCR
ENABLE_TROJAN_REALITY=$ENABLE_TROJAN_REALITY
ENABLE_HYSTERIA2=$ENABLE_HYSTERIA2
ENABLE_VMESS_WS=$ENABLE_VMESS_WS
ENABLE_HY2_OBFS=$ENABLE_HY2_OBFS
ENABLE_SS2022=$ENABLE_SS2022
ENABLE_SS=$ENABLE_SS
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_WARP=$ENABLE_WARP
REALITY_SERVER=$REALITY_SERVER
REALITY_SERVER_PORT=$REALITY_SERVER_PORT
GRPC_SERVICE=$GRPC_SERVICE
VMESS_WS_PATH=$VMESS_WS_PATH
EOF
}
load_env(){ safe_source_env "$SB_DIR/env.conf" || true; }

save_creds(){ cat > "$SB_DIR/creds.env" <<EOF
UUID=$UUID
HY2_PWD=$HY2_PWD
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SID=$REALITY_SID
HY2_PWD2=$HY2_PWD2
HY2_OBFS_PWD=$HY2_OBFS_PWD
SS2022_KEY=$SS2022_KEY
SS_PWD=$SS_PWD
TUIC_UUID=$TUIC_UUID
TUIC_PWD=$TUIC_PWD
ANYTLS_PWD=$ANYTLS_PWD
RS_VR=$RS_VR
RS_GR=$RS_GR
RS_TR=$RS_TR
RS_VRW=$RS_VRW
RS_GRW=$RS_GRW
RS_TRW=$RS_TRW
EOF
}
load_creds(){ safe_source_env "$SB_DIR/creds.env" || return 1; }

save_warp(){ cat > "$SB_DIR/warp.env" <<EOF
WARP_PRIVATE_KEY=$WARP_PRIVATE_KEY
WARP_PEER_PUBLIC_KEY=$WARP_PEER_PUBLIC_KEY
WARP_ENDPOINT_HOST=$WARP_ENDPOINT_HOST
WARP_ENDPOINT_PORT=$WARP_ENDPOINT_PORT
WARP_ADDRESS_V4=$WARP_ADDRESS_V4
WARP_ADDRESS_V6=$WARP_ADDRESS_V6
WARP_RESERVED_1=$WARP_RESERVED_1
WARP_RESERVED_2=$WARP_RESERVED_2
WARP_RESERVED_3=$WARP_RESERVED_3
EOF
}
load_warp(){ safe_source_env "$SB_DIR/warp.env" || return 1; }

# 生成 8 字节十六进制（16 个 hex 字符）
rand_hex8(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8 | tr -d "\n"
  else
    # 兜底：没有 openssl 时用 hexdump
    hexdump -v -n 8 -e '1/1 "%02x"' /dev/urandom
  fi
}
rand_b64_32(){ openssl rand -base64 32 | tr -d "\n"; }   # 只用于 SS2022 密钥（协议要求 base64 的 32 字节）
# 普通密码只用 0-9a-f：分享链接里不用 urlencode，手动填客户端也不会被 %3D 之类坑到（#16 / #5）
rand_pwd(){ openssl rand -hex 16 | tr -d "\n"; }

# 在服务器本机检查一个域名能不能当 Reality 目标：TLS1.3 + X25519 + ALPN h2
# （Reality 握手时就是服务器去连这个域名，所以要从服务器这边测）。REALITY_CHECK=false 可跳过检测
declare -A REALITY_CHECKED=()
reality_target_ok(){
  local d="$1" out
  [[ "${REALITY_CHECK:-true}" == "true" ]] || return 0
  if [[ -z "${REALITY_CHECKED[$d]+x}" ]]; then
    out=$(timeout 6 openssl s_client -connect "${d}:${REALITY_SERVER_PORT:-443}" -servername "$d" \
            -tls1_3 -groups X25519 -alpn h2 </dev/null 2>/dev/null || true)
    if grep -q 'ALPN protocol: h2' <<<"$out" && grep -q 'TLSv1\.3' <<<"$out"; then
      REALITY_CHECKED[$d]=0
    else
      REALITY_CHECKED[$d]=1
    fi
  fi
  return "${REALITY_CHECKED[$d]}"
}

# 用法：pick_reality <变量名>
# 从 REALITY_SERVERS 池里随机抽一个：跳过 REALITY_RETIRED 里已下线的，跳过本机检测不通过的；
# 池为空则回退到 REALITY_SERVER。直接赋值、不走 $(...)，检测结果缓存才能在 6 次抽取之间共用
pick_reality(){
  local __var="$1" d i j t pool=() cand=()
  read -ra pool <<<"$REALITY_SERVERS"
  for d in "${pool[@]}"; do [[ " $REALITY_RETIRED " == *" $d "* ]] || cand+=("$d"); done
  if (( ${#cand[@]} == 0 )); then printf -v "$__var" '%s' "$REALITY_SERVER"; return 0; fi
  for ((i=${#cand[@]}-1; i>0; i--)); do   # 打乱顺序，取第一个检测通过的
    j=$((RANDOM % (i+1))); t=${cand[i]}; cand[i]=${cand[j]}; cand[j]=$t
  done
  for d in "${cand[@]}"; do
    if reality_target_ok "$d"; then printf -v "$__var" '%s' "$d"; return 0; fi
  done
  warn "REALITY 域名池在本机全部检测未通过（openssl 太旧或出网受限？），${__var} 暂用未检测的 ${cand[0]}"
  printf -v "$__var" '%s' "${cand[0]}"
}

gen_uuid(){
  local u=""
  if [[ -x "$BIN_PATH" ]]; then u=$("$BIN_PATH" generate uuid 2>/dev/null | head -n1); fi
  if [[ -z "$u" ]] && command -v uuidgen >/dev/null 2>&1; then u=$(uuidgen | head -n1); fi
  if [[ -z "$u" ]]; then u=$(cat /proc/sys/kernel/random/uuid | head -n1); fi
  printf '%s' "$u" | tr -d '\r\n'
}
gen_reality(){ "$BIN_PATH" generate reality-keypair; }

mk_cert(){
  local crt="$CERT_DIR/fullchain.pem" key="$CERT_DIR/key.pem"
  if [[ ! -s "$crt" || ! -s "$key" ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
      -keyout "$key" -out "$crt" -subj "/CN=$REALITY_SERVER" \
      -addext "subjectAltName=DNS:$REALITY_SERVER" >/dev/null 2>&1
  fi
CRT_SHA256=$(openssl x509 -in "$crt" -fingerprint -sha256 -noout \
  | sed 's/.*Fingerprint=//;s/://g' | tr 'A-F' 'a-f')
}

ensure_creds(){
  [[ -z "${UUID:-}" ]] && UUID=$(gen_uuid)
  is_uuid "$UUID" || UUID=$(gen_uuid)
  # 密码只在为空时生成：已安装用户的旧密码不动，旧链接继续可用；新装的才是纯十六进制
  [[ -z "${HY2_PWD:-}" ]] && HY2_PWD=$(rand_pwd)
  if [[ -z "${REALITY_PRIV:-}" || -z "${REALITY_PUB:-}" || -z "${REALITY_SID:-}" ]]; then
    readarray -t RKP < <(gen_reality)
    REALITY_PRIV=$(printf "%s\n" "${RKP[@]}" | awk '/PrivateKey/{print $2}')
    REALITY_PUB=$(printf "%s\n" "${RKP[@]}" | awk '/PublicKey/{print $2}')
    REALITY_SID=$(rand_hex8)
  fi
  [[ -z "${HY2_PWD2:-}" ]] && HY2_PWD2=$(rand_pwd)
  [[ -z "${HY2_OBFS_PWD:-}" ]] && HY2_OBFS_PWD=$(rand_pwd)
  [[ -z "${SS2022_KEY:-}" ]] && SS2022_KEY=$(rand_b64_32)
  [[ -z "${SS_PWD:-}" ]] && SS_PWD=$(openssl rand -base64 24 | tr -d "=\n" | tr "+/" "-_")
  TUIC_UUID="$UUID"; TUIC_PWD="$UUID"
  [[ -z "${ANYTLS_PWD:-}" ]] && ANYTLS_PWD=$(rand_pwd)
  # 每个 reality inbound 独立随机偷一个域名（首次安装抽取后持久化）
  # RS_VR=vless-reality  RS_GR=vless-grpc-reality  RS_TR=trojan-reality  （带 W 的是对应 -warp 节点）
  local rv
  for rv in RS_VR RS_GR RS_TR RS_VRW RS_GRW RS_TRW; do
    if [[ -n "${!rv:-}" && " $REALITY_RETIRED " == *" ${!rv} "* ]]; then
      warn "${rv} 持久化的偷域名 ${!rv} 已下线，重新抽取（该节点分享链接的 sni 会变，需重新导入）"
      printf -v "$rv" '%s' ""
    fi
    [[ -n "${!rv:-}" ]] || pick_reality "$rv"
  done
  save_creds
}

# ===== WARP（wgcf） =====
WGCF_BIN=/usr/local/bin/wgcf
install_wgcf_disabled(){
  [[ -x "$WGCF_BIN" ]] && return 0
  local GOA url tmp
  case "$(arch_map)" in
    amd64) GOA=amd64;; arm64) GOA=arm64;; armv7) GOA=armv7;; 386) GOA=386;; *) GOA=amd64;;
  esac
  url=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        | jq -r ".assets[] | select(.name|test(\"linux_${GOA}$\")) | .browser_download_url" | head -n1)
  [[ -n "$url" ]] || { warn "获取 wgcf 下载地址失败"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/wgcf"
  install -m0755 "$tmp/wgcf" "$WGCF_BIN"
  rm -rf "$tmp"
}

# —— Base64 清理 + 补齐：去掉引号/空白，长度 %4==2 补“==”，%4==3 补“=” ——
pad_b64(){
  local s="${1:-}"
  # 去引号/空格/回车
  s="$(printf '%s' "$s" | tr -d '\r\n\" ')"
  # 去掉已有尾随 =，按需重加
  s="${s%%=*}"
  local rem=$(( ${#s} % 4 ))
  if   (( rem == 2 )); then s="${s}=="
  elif (( rem == 3 )); then s="${s}="
  fi
  printf '%s' "$s"
}


# ===== WARP（官方 warp-cli，proxy 模式）一键安装/修复 =====
# 说明：
# - 本脚本强制使用官方 cloudflare-warp (warp-cli) 提供本地 SOCKS5 (默认 127.0.0.1:40000)
# - sing-box 的 tag=warp 出站固定走该 SOCKS5
WARP_SOCKS_HOST="${WARP_SOCKS_HOST:-127.0.0.1}"
WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"

install_warpcli(){
  command -v warp-cli >/dev/null 2>&1 && return 0

  if command -v apt-get >/dev/null 2>&1; then
    info "安装 cloudflare-warp (Debian/Ubuntu)..."
    apt-get update -y
    apt-get install -y curl gpg lsb-release ca-certificates >/dev/null 2>&1 || true
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main"       > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
    apt-get install -y cloudflare-warp
  elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    info "安装 cloudflare-warp (CentOS/RHEL)..."
    curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y cloudflare-warp
    else
      yum install -y cloudflare-warp
    fi
  else
    err "未识别的包管理器，无法自动安装 cloudflare-warp"
    return 1
  fi

  command -v warp-cli >/dev/null 2>&1
}

ensure_warpcli_proxy(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  install_warpcli || return 1

  systemctl enable --now warp-svc >/dev/null 2>&1 || true

  # 已注册则跳过；未注册则自动同意条款
  if ! warp-cli registration show >/dev/null 2>&1; then
    info "正在初始化 Cloudflare WARP"

    # warp-cli 强制检测 TTY，非 TTY 拒绝输入，需模拟真实终端注入 y
    # 优先级：python3 pty（最可靠）→ expect → 安装 python3 兜底
    _warp_reg_ok=0

    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'PYEOF' 2>/dev/null && _warp_reg_ok=1 || true
import pty, os, time, select, sys

def run():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("warp-cli", ["warp-cli", "registration", "new"])
    else:
        answered = False
        for _ in range(30):
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    data = os.read(fd, 4096).decode(errors="ignore")
                except OSError:
                    break
                if not answered and ("y/N" in data or "y/n" in data):
                    time.sleep(0.2)
                    os.write(fd, b"y\n")
                    answered = True
                if "Success" in data:
                    sys.exit(0)
            try:
                ret = os.waitpid(pid, os.WNOHANG)
                if ret[0] != 0:
                    break
            except ChildProcessError:
                break
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass
        sys.exit(1)

run()
PYEOF

    elif command -v expect >/dev/null 2>&1; then
      expect -c '
        spawn warp-cli registration new
        expect -re {[yY]/[nN]}
        send "y\r"
        expect eof
      ' >/dev/null 2>&1 && _warp_reg_ok=1 || true

    else
      # 尝试安装 python3（兜底）
      warn "未找到 python3/expect，尝试安装 python3..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y python3 >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 >/dev/null 2>&1 || true
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 >/dev/null 2>&1 || true
      elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm python >/dev/null 2>&1 || true
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install python3 >/dev/null 2>&1 || true
      fi

      if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PYEOF' 2>/dev/null && _warp_reg_ok=1 || true
import pty, os, time, select, sys

def run():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("warp-cli", ["warp-cli", "registration", "new"])
    else:
        answered = False
        for _ in range(30):
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    data = os.read(fd, 4096).decode(errors="ignore")
                except OSError:
                    break
                if not answered and ("y/N" in data or "y/n" in data):
                    time.sleep(0.2)
                    os.write(fd, b"y\n")
                    answered = True
                if "Success" in data:
                    sys.exit(0)
            try:
                ret = os.waitpid(pid, os.WNOHANG)
                if ret[0] != 0:
                    break
            except ChildProcessError:
                break
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass
        sys.exit(1)

run()
PYEOF
      else
        err "无法自动完成 WARP 注册（缺少 python3/expect），请手动运行：warp-cli registration new"
        return 1
      fi
    fi

    sleep 2
    if ! warp-cli registration show >/dev/null 2>&1; then
      err "WARP 注册失败，请手动运行：warp-cli registration new"; return 1
    fi
  fi

  # proxy 模式：不改系统默认路由
  warp-cli mode proxy >/dev/null 2>&1 || true

  # 连接
  warp-cli connect >/dev/null 2>&1 || return 1

  # 等待 socks 端口监听
  for i in {1..12}; do
    if ss -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b" || netstat -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b"; then
      break
    fi
    sleep 1
  done

  if ! { ss -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b" || netstat -lntp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT}\b"; }; then
    err "WARP SOCKS5 端口 ${WARP_SOCKS_PORT} 未监听（warp-svc/warp-cli 可能未正常工作）"
    systemctl status warp-svc --no-pager | head -80 || true
    journalctl -u warp-svc -n 120 --no-pager || true
    return 1
  fi

  # 真正测试 warp=on
  if ! curl -fsSL --connect-timeout 5 --max-time 15 --proxy "socks5://${WARP_SOCKS_HOST}:${WARP_SOCKS_PORT}" https://cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    err "WARP 代理测试失败：未检测到 warp=on"
    warp-cli status || true
    return 1
  fi

  ok "WARP proxy 已就绪：socks5://${WARP_SOCKS_HOST}:${WARP_SOCKS_PORT}"
  return 0
}

# ===== WARP（wgcf）配置生成/修复（已废弃/不再默认使用，保留旧代码以兼容历史） =====

ensure_wgcf_profile(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  # 先尝试读取旧 env，并做一次规范化补齐
  if load_warp 2>/dev/null; then
    WARP_PRIVATE_KEY="$(pad_b64 "${WARP_PRIVATE_KEY:-}")"
    WARP_PEER_PUBLIC_KEY="$(pad_b64 "${WARP_PEER_PUBLIC_KEY:-}")"
    # 允许之前没写 reserved，给默认 0
    : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"
    save_warp
    # 如果关键字段都在，就直接用旧的（已经补齐），无需重建
    if [[ -n "$WARP_PRIVATE_KEY" && -n "$WARP_PEER_PUBLIC_KEY" && -n "${WARP_ENDPOINT_HOST:-}" && -n "${WARP_ENDPOINT_PORT:-}" ]]; then
      return 0
    fi
  fi

  # 走到这里说明旧 env 不完整；开始用 wgcf 重建
  install_wgcf_disabled || { warn "wgcf 安装失败，禁用 WARP 节点"; ENABLE_WARP=false; save_env; return 0; }

  local wd="$SB_DIR/wgcf"; mkdir -p "$wd"
  if [[ ! -f "$wd/wgcf-account.toml" ]]; then
    "$WGCF_BIN" register --accept-tos --config "$wd/wgcf-account.toml" >/dev/null
  fi
  "$WGCF_BIN" generate --config "$wd/wgcf-account.toml" --profile "$wd/wgcf-profile.conf" >/dev/null

  local prof="$wd/wgcf-profile.conf"
  # 提取并规范化
  WARP_PRIVATE_KEY="$(pad_b64 "$(awk -F'= *' '/^PrivateKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"
  WARP_PEER_PUBLIC_KEY="$(pad_b64 "$(awk -F'= *' '/^PublicKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"

  # Endpoint 可能是域名或 [IPv6]:port
  local ep host port
  ep="$(awk -F'= *' '/^Endpoint/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  if [[ "$ep" =~ ^\[(.+)\]:(.+)$ ]]; then host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"; else host="${ep%:*}"; port="${ep##*:}"; fi
  WARP_ENDPOINT_HOST="$host"
  WARP_ENDPOINT_PORT="$port"

  # 内网地址与 reserved
  local ad rs
  ad="$(awk -F'= *' '/^Address/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_ADDRESS_V4="${ad%%,*}"
  WARP_ADDRESS_V6="${ad##*,}"
  rs="$(awk -F'= *' '/^Reserved/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_RESERVED_1="${rs%%,*}"; rs="${rs#*,}"
  WARP_RESERVED_2="${rs%%,*}"; WARP_RESERVED_3="${rs##*,}"
  : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"

  save_warp
}

# ===== 依赖与安装 =====
install_deps(){
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y ca-certificates curl wget jq tar iproute2 openssl coreutils uuid-runtime >/dev/null 2>&1 || true
}

# ===== 安装 / 更新 sing-box（GitHub Releases）=====
install_singbox() {

  # 已安装则直接返回
  if command -v "$BIN_PATH" >/dev/null 2>&1; then
    info "检测到 sing-box: $("$BIN_PATH" version | head -n1)"
    return 0
  fi

  # 依赖
  ensure_deps curl jq tar || return 1
  command -v xz >/dev/null 2>&1 || ensure_deps xz-utils >/dev/null 2>&1 || true
  command -v unzip >/dev/null 2>&1 || ensure_deps unzip   >/dev/null 2>&1 || true

  local repo="SagerNet/sing-box"
  local tag="${SINGBOX_TAG:-v1.13.7}"   # 允许用环境变量固定版本，如 v1.13.7
  local arch; arch="$(arch_map)"
  local api url tmp pkg re rel_url

  info "下载 sing-box (${arch}) ..."

  # 取 release JSON
  if [[ "$tag" = "latest" ]]; then
    rel_url="https://api.github.com/repos/${repo}/releases/latest"
  else
    rel_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  fi

  # 资产名匹配：兼容 tar.gz / tar.xz / zip
  # 典型名称：sing-box-1.12.7-linux-amd64.tar.gz
  re="^sing-box-.*-linux-${arch}\\.(tar\\.(gz|xz)|zip)$"

  # 先在目标 release 里找；找不到再从所有 releases 里兜底
  url="$(curl -fsSL "$rel_url" | jq -r --arg re "$re" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)"
  if [[ -z "$url" ]]; then
    url="$(curl -fsSL "https://api.github.com/repos/${repo}/releases" \
           | jq -r --arg re "$re" '[ .[] | .assets[] | select(.name | test($re)) | .browser_download_url ][0]')"
  fi
  [[ -n "$url" ]] || { err "下载 sing-box 失败：未匹配到发行包（arch=${arch} tag=${tag})"; return 1; }


  tmp="$(mktemp -d)"; pkg="${tmp}/pkg"
  if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 15 -o "$pkg" "$url"; then
    rm -rf "$tmp"; err "下载 sing-box 失败"; return 1
  fi

  # 解压
  if echo "$url" | grep -qE '\.tar\.gz$|\.tgz$'; then
    tar -xzf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.tar\.xz$'; then
    tar -xJf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.zip$'; then
    unzip -q "$pkg" -d "$tmp"
  else
    rm -rf "$tmp"; err "未知包格式：$url"; return 1
  fi

  # 找到二进制并安装
  local bin
  bin="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [[ -n "$bin" ]] || { rm -rf "$tmp"; err "解压失败：未找到 sing-box 可执行文件"; return 1; }

  install -m 0755 "$bin" "$BIN_PATH"
  rm -rf "$tmp"
  info "安装完成：$("$BIN_PATH" version | head -n1)"
}

# ===== systemd =====
write_systemd(){ cat > "/etc/systemd/system/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Sing-Box (Native 20 nodes)
After=network-online.target warp-svc.service
Wants=network-online.target warp-svc.service
Requires=network-online.target

[Service]
Type=simple
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
ExecStart=${BIN_PATH} run -c ${CONF_JSON} -D ${DATA_DIR}
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
}

# ===== 写 config.json（使用你提供的稳定配置逻辑） =====
write_config(){
  ensure_dirs; load_env || true; load_creds || true; load_ports || true
  ensure_creds; save_all_ports; mk_cert
  # WARP 失败不能中断：换端口时 ports.env 已经写入新端口，这里一退出 config.json 还是旧端口，两边就对不上了
  if [[ "$ENABLE_WARP" == "true" ]]; then
    ensure_warpcli_proxy || warn "WARP 代理未就绪，-warp 节点暂时不可用；直连节点不受影响（之后可重新执行 1) 修复）"
  fi

  local CRT="$CERT_DIR/fullchain.pem" KEY="$CERT_DIR/key.pem"
  local NEW_CONF="${CONF_JSON}.new"
  jq -n \
  --arg RS "$REALITY_SERVER" --argjson RSP "${REALITY_SERVER_PORT:-443}" --arg UID "$UUID" \
  --arg WSHOST "$WARP_SOCKS_HOST" --argjson WSPORT "$WARP_SOCKS_PORT" \
  --arg RPR "$REALITY_PRIV" --arg RPB "$REALITY_PUB" --arg SID "$REALITY_SID" \
  --arg RS_VR "$RS_VR" --arg RS_GR "$RS_GR" --arg RS_TR "$RS_TR" \
  --arg RS_VRW "$RS_VRW" --arg RS_GRW "$RS_GRW" --arg RS_TRW "$RS_TRW" \
  --arg HY2 "$HY2_PWD" --arg HY22 "$HY2_PWD2" --arg HY2O "$HY2_OBFS_PWD" \
  --arg GRPC "$GRPC_SERVICE" --arg VMWS "$VMESS_WS_PATH" --arg CRT "$CRT" --arg KEY "$KEY" \
  --arg SS2022 "$SS2022_KEY" --arg SSPWD "$SS_PWD" --arg TUICUUID "$TUIC_UUID" --arg TUICPWD "$TUIC_PWD" --arg ANYTLSPWD "$ANYTLS_PWD" \
  --argjson P1 "$PORT_VLESSR" --argjson P2 "$PORT_VLESS_GRPCR" --argjson P3 "$PORT_TROJANR" \
  --argjson P4 "$PORT_HY2" --argjson P5 "$PORT_VMESS_WS" --argjson P6 "$PORT_HY2_OBFS" \
  --argjson P7 "$PORT_SS2022" --argjson P8 "$PORT_SS" --argjson P9 "$PORT_TUIC" --argjson P10 "$PORT_ANYTLS" \
  --argjson PW1 "$PORT_VLESSR_W" --argjson PW2 "$PORT_VLESS_GRPCR_W" --argjson PW3 "$PORT_TROJANR_W" \
  --argjson PW4 "$PORT_HY2_W" --argjson PW5 "$PORT_VMESS_WS_W" --argjson PW6 "$PORT_HY2_OBFS_W" \
  --argjson PW7 "$PORT_SS2022_W" --argjson PW8 "$PORT_SS_W" --argjson PW9 "$PORT_TUIC_W" --argjson PW10 "$PORT_ANYTLS_W" \
  --arg ENABLE_WARP "$ENABLE_WARP" \
  --arg WPRIV "${WARP_PRIVATE_KEY:-}" --arg WPPUB "${WARP_PEER_PUBLIC_KEY:-}" \
  --arg WHOST "${WARP_ENDPOINT_HOST:-}" --argjson WPORT "${WARP_ENDPOINT_PORT:-0}" \
  --arg W4 "${WARP_ADDRESS_V4:-}" --arg W6 "${WARP_ADDRESS_V6:-}" \
  --argjson WR1 "${WARP_RESERVED_1:-0}" --argjson WR2 "${WARP_RESERVED_2:-0}" --argjson WR3 "${WARP_RESERVED_3:-0}" \
  '
  def inbound_vless($port; $rs): {type:"vless", listen:"::", listen_port:$port, users:[{uuid:$UID}], tls:{enabled:true, server_name:$rs, reality:{enabled:true, handshake:{server:$rs, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_vless_flow($port; $rs): {type:"vless", listen:"::", listen_port:$port, users:[{uuid:$UID, flow:"xtls-rprx-vision"}], tls:{enabled:true, server_name:$rs, reality:{enabled:true, handshake:{server:$rs, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_trojan($port; $rs): {type:"trojan", listen:"::", listen_port:$port, users:[{password:$UID}], tls:{enabled:true, server_name:$rs, reality:{enabled:true, handshake:{server:$rs, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_hy2($port): {type:"hysteria2", listen:"::", listen_port:$port, users:[{name:"hy2", password:$HY2}], tls:{enabled:true, certificate_path:$CRT, key_path:$KEY}};
  def inbound_vmess_ws($port): {type:"vmess", listen:"::", listen_port:$port, users:[{uuid:$UID}], transport:{type:"ws", path:$VMWS}};
  def inbound_hy2_obfs($port): {type:"hysteria2", listen:"::", listen_port:$port, users:[{name:"hy2", password:$HY22}], obfs:{type:"salamander", password:$HY2O}, tls:{enabled:true, certificate_path:$CRT, key_path:$KEY, alpn:["h3"]}};
  def inbound_ss2022($port): {type:"shadowsocks", listen:"::", listen_port:$port, method:"2022-blake3-aes-256-gcm", password:$SS2022};
  def inbound_ss($port): {type:"shadowsocks", listen:"::", listen_port:$port, method:"aes-256-gcm", password:$SSPWD};
  def inbound_tuic($port): {type:"tuic", listen:"::", listen_port:$port, users:[{uuid:$TUICUUID, password:$TUICPWD}], congestion_control:"bbr", tls:{enabled:true, certificate_path:$CRT, key_path:$KEY, alpn:["h3"]}};
  def inbound_anytls($port): {type:"anytls", listen:"::", listen_port:$port, users:[{name:"anytls", password:$ANYTLSPWD}], tls:{enabled:true, certificate_path:$CRT, key_path:$KEY}};

  def warp_outbound:
    {type:"socks", tag:"warp", server:$WSHOST, server_port:$WSPORT};


  {
    log:{level:"info", timestamp:true},
  dns:{ servers:[ {type:"https", tag:"dns-remote", server:"1.1.1.1", server_port:443, path:"/dns-query"}, {type:"udp", tag:"dns-local", server:"8.8.8.8"} ], strategy:"prefer_ipv4" },
  inbounds:[
      (inbound_vless_flow($P1; $RS_VR) + {tag:"vless-reality"}),
      (inbound_vless($P2; $RS_GR) + {tag:"vless-grpcr", transport:{type:"grpc", service_name:$GRPC}}),
      (inbound_trojan($P3; $RS_TR) + {tag:"trojan-reality"}),
      (inbound_hy2($P4) + {tag:"hy2"}),
      (inbound_vmess_ws($P5) + {tag:"vmess-ws"}),
      (inbound_hy2_obfs($P6) + {tag:"hy2-obfs"}),
      (inbound_ss2022($P7) + {tag:"ss2022"}),
      (inbound_ss($P8) + {tag:"ss"}),
      (inbound_tuic($P9) + {tag:"tuic-v5"}),
      (inbound_anytls($P10) + {tag:"anytls"}),

      (inbound_vless_flow($PW1; $RS_VRW) + {tag:"vless-reality-warp"}),
      (inbound_vless($PW2; $RS_GRW) + {tag:"vless-grpcr-warp", transport:{type:"grpc", service_name:$GRPC}}),
      (inbound_trojan($PW3; $RS_TRW) + {tag:"trojan-reality-warp"}),
      (inbound_hy2($PW4) + {tag:"hy2-warp"}),
      (inbound_vmess_ws($PW5) + {tag:"vmess-ws-warp"}),
      (inbound_hy2_obfs($PW6) + {tag:"hy2-obfs-warp"}),
      (inbound_ss2022($PW7) + {tag:"ss2022-warp"}),
      (inbound_ss($PW8) + {tag:"ss-warp"}),
      (inbound_tuic($PW9) + {tag:"tuic-v5-warp"}),
      (inbound_anytls($PW10) + {tag:"anytls-warp"})
    ],
    outbounds: (
      if $ENABLE_WARP=="true" then
        [{type:"direct", tag:"direct"}, {type:"block", tag:"block"}, warp_outbound]
      else
        [{type:"direct", tag:"direct"}, {type:"block", tag:"block"}]
      end
    ),
    route: (
      if $ENABLE_WARP=="true" then
        { default_domain_resolver:"dns-remote", rules:[
            { inbound: ["vless-reality-warp","vless-grpcr-warp","trojan-reality-warp","hy2-warp","vmess-ws-warp","hy2-obfs-warp","ss2022-warp","ss-warp","tuic-v5-warp","anytls-warp"], outbound:"warp" }
          ],
          final:"direct"
        }
      else
        # sing-box 1.13 起缺 default_domain_resolver 直接 FATAL 拒绝启动（ENABLE_WARP=false 时原来就会起不来）
        { default_domain_resolver:"dns-remote", final:"direct" }
      end
    )
  }' > "$NEW_CONF" || { rm -f "$NEW_CONF"; err "生成配置失败（jq），保留原 config.json"; return 1; }

  # 先 check 再替换：新配置有问题时不覆盖正在用的 config.json，服务不会被一个坏配置弄挂
  if [[ -x "$BIN_PATH" ]] && ! ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true "$BIN_PATH" check -c "$NEW_CONF"; then
    err "新配置未通过 sing-box check，保留原 config.json（问题配置留在 ${NEW_CONF} 供排查）"
    return 1
  fi
  mv -f "$NEW_CONF" "$CONF_JSON"
  save_env
}

# ===== 防火墙 =====
open_firewall(){
  local rules=() all=() r
  all+=("${PORT_VLESSR:-}/tcp" "${PORT_VLESS_GRPCR:-}/tcp" "${PORT_TROJANR:-}/tcp" "${PORT_VMESS_WS:-}/tcp")
  all+=("${PORT_HY2:-}/udp" "${PORT_HY2_OBFS:-}/udp" "${PORT_TUIC:-}/udp")
  all+=("${PORT_SS2022:-}/tcp" "${PORT_SS2022:-}/udp" "${PORT_SS:-}/tcp" "${PORT_SS:-}/udp")
  all+=("${PORT_ANYTLS:-}/tcp")
  all+=("${PORT_VLESSR_W:-}/tcp" "${PORT_VLESS_GRPCR_W:-}/tcp" "${PORT_TROJANR_W:-}/tcp" "${PORT_VMESS_WS_W:-}/tcp")
  all+=("${PORT_HY2_W:-}/udp" "${PORT_HY2_OBFS_W:-}/udp" "${PORT_TUIC_W:-}/udp")
  all+=("${PORT_SS2022_W:-}/tcp" "${PORT_SS2022_W:-}/udp" "${PORT_SS_W:-}/tcp" "${PORT_SS_W:-}/udp")
  all+=("${PORT_ANYTLS_W:-}/tcp")
  sub_enabled && load_sub && all+=("${SUB_PORT:-}/tcp")
  # 老版本升级上来可能缺某些端口（如 AnyTLS），空的跳过，避免 set -u 退出或写出 "/tcp" 这种坏规则
  for r in "${all[@]}"; do [[ "$r" == /* ]] || rules+=("$r"); done

  # 注意：原来 grep "active" 会把 "Status: inactive" 也当成启用，于是只往没启用的 ufw 里加规则、iptables 一条没放
  # （Oracle 等自带 iptables REJECT 规则、ufw 装了没开的镜像上端口就不通）。LC_ALL=C 固定英文输出再精确匹配
  if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
    for r in "${rules[@]}"; do ufw allow "$r" >/dev/null 2>&1 || true; done
    ufw reload >/dev/null 2>&1 || true

  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    for r in "${rules[@]}"; do firewall-cmd --permanent --add-port="$r" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true

  else
    local p proto
    for r in "${rules[@]}"; do
      p="${r%/*}"; proto="${r#*/}"

      # IPv4
      if [[ "$proto" == tcp ]]; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
      fi
      if [[ "$proto" == udp ]]; then
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
      fi

      # IPv6（关键补全）
      if command -v ip6tables >/dev/null 2>&1; then
        if [[ "$proto" == tcp ]]; then
          ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT
        fi
        if [[ "$proto" == udp ]]; then
          ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT
        fi
      fi
    done

    # 保存（netfilter-persistent 通常会把 v4/v6 一起保存）
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

# ===== 分享链接（分组输出 + 提示） =====
conf_has_inbound(){ jq -e --arg t "$1" '.inbounds[]|select(.tag==$t)' "$CONF_JSON" >/dev/null 2>&1; }

# 老版本升级上来，creds.env 里可能缺字段：RS_*（v4.7.0 前没有）、AnyTLS（v4.6.0 前没有）。
# 查看链接时不改任何文件：缺的 RS_* 直接读正在运行的 config.json，保证链接里的 sni 和服务端一致（#15）
backfill_from_config(){
  local pair v tag val
  for pair in RS_VR:vless-reality RS_GR:vless-grpcr RS_TR:trojan-reality \
              RS_VRW:vless-reality-warp RS_GRW:vless-grpcr-warp RS_TRW:trojan-reality-warp; do
    v=${pair%%:*}; tag=${pair#*:}
    [[ -n "${!v:-}" ]] && continue
    val=$(jq -r --arg t "$tag" '.inbounds[]|select(.tag==$t)|.tls.server_name // empty' "$CONF_JSON" 2>/dev/null || true)
    printf -v "$v" '%s' "${val:-$REALITY_SERVER}"
  done
}

# 生成全部分享链接，放进全局数组 LINKS_DIRECT / LINKS_WARP / LINKS_PCS（查看链接和订阅共用这一份）
# 同时设置 LINK_IP、LINK_MODE（IPv6 取不到时回退成 4）、HAS_ANYTLS
build_links(){
  load_env; load_creds; load_ports
  ensure_dirs
  backfill_from_config
  mk_cert    # 确保 CRT_SHA256 已赋值（pinnedPeerCertSha256 节点需要）
  HAS_ANYTLS=false
  [[ -n "${ANYTLS_PWD:-}" ]] && conf_has_inbound anytls && HAS_ANYTLS=true
  local mode="${1:-4}" ip host
  if [[ "$mode" == "6" ]]; then
    ip="$(get_ip6)"
    if [[ -z "$ip" ]]; then
      warn "未检测到公网 IPv6，自动回退到 IPv4"
      ip="$(get_ip4)"
      mode="4"
    fi
  else
    ip="$(get_ip4)"
  fi
  LINK_IP="$ip"; LINK_MODE="$mode"
  host="$(fmt_host_for_uri "$ip")"
  local has_anytls=$HAS_ANYTLS
  local links_direct=() links_warp=()
  # 直连 10
  links_direct+=("vless://${UUID}@${host}:${PORT_VLESSR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RS_VR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#vless-reality")
  links_direct+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR}?encryption=none&security=reality&sni=${RS_GR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#vless-grpc-reality")
  links_direct+=("trojan://${UUID}@${host}:${PORT_TROJANR}?security=reality&sni=${RS_TR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#trojan-reality")
  links_direct+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#hysteria2")
  local VMESS_JSON; VMESS_JSON=$(cat <<JSON
{"v":"2","ps":"vmess-ws","add":"${ip}","port":"${PORT_VMESS_WS}","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"","path":"${VMESS_WS_PATH}","tls":""}
JSON
  )
  links_direct+=("vmess://$(printf "%s" "$VMESS_JSON" | b64enc)")
  links_direct+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#hysteria2-obfs")
  links_direct+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022}#ss2022")
  links_direct+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS}#ss")
  # allow_insecure=1 是 v2rayN 的 TUIC 解析唯一认的写法（它不读 insecure / allowInsecure，#17）；另外两个留给其他客户端
  links_direct+=("tuic://${UUID}:$(urlenc "${UUID}")@${host}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&insecure=1&allow_insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#tuic-v5")
  $has_anytls && links_direct+=("anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS}?insecure=1&sni=${REALITY_SERVER}#anytls")

  # WARP 10
  links_warp+=("vless://${UUID}@${host}:${PORT_VLESSR_W}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RS_VRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#vless-reality-warp")
  links_warp+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR_W}?encryption=none&security=reality&sni=${RS_GRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#vless-grpc-reality-warp")
  links_warp+=("trojan://${UUID}@${host}:${PORT_TROJANR_W}?security=reality&sni=${RS_TRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#trojan-reality-warp")
  links_warp+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2_W}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#hysteria2-warp")
  local VMESS_JSON_W; VMESS_JSON_W=$(cat <<JSON
{"v":"2","ps":"vmess-ws-warp","add":"${ip}","port":"${PORT_VMESS_WS_W}","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"","path":"${VMESS_WS_PATH}","tls":""}
JSON
  )
  links_warp+=("vmess://$(printf "%s" "$VMESS_JSON_W" | b64enc)")
  links_warp+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS_W}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#hysteria2-obfs-warp")
  links_warp+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022_W}#ss2022-warp")
  links_warp+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS_W}#ss-warp")
  links_warp+=("tuic://${UUID}:$(urlenc "${UUID}")@${host}:${PORT_TUIC_W}?congestion_control=bbr&alpn=h3&insecure=1&allow_insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#tuic-v5-warp")
  $has_anytls && links_warp+=("anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS_W}?insecure=1&sni=${REALITY_SERVER}#anytls-warp")

  # Xray-core v26.2.6+ 移除了 allowInsecure，hysteria2 用证书指纹 pcs 的版本
  local links_pcs=()
  links_pcs+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2}?sni=${REALITY_SERVER}&pcs=${CRT_SHA256}#hysteria2-pinnedPeerCertSha256")
  links_pcs+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS}?sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")&pcs=${CRT_SHA256}#hysteria2-obfs-pinnedPeerCertSha256")
  links_pcs+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2_W}?sni=${REALITY_SERVER}&pcs=${CRT_SHA256}#hysteria2-warp-pinnedPeerCertSha256")
  links_pcs+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS_W}?sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")&pcs=${CRT_SHA256}#hysteria2-obfs-warp-pinnedPeerCertSha256")

  LINKS_DIRECT=("${links_direct[@]}"); LINKS_WARP=("${links_warp[@]}"); LINKS_PCS=("${links_pcs[@]}")
}

print_links_grouped(){
  build_links "${1:-4}"
  local links_direct=("${LINKS_DIRECT[@]}") links_warp=("${LINKS_WARP[@]}") has_anytls=$HAS_ANYTLS l
  local nd=${#links_direct[@]} nw=${#links_warp[@]}
  echo -e "${C_BLUE}${C_BOLD}分享链接（$((nd + nw)) 个）${C_RESET}"
  hr
  echo -e "${C_CYAN}${C_BOLD}【直连节点（${nd}）】${C_RESET}（vless-reality / vless-grpc-reality / trojan-reality / vmess-ws / hy2 / hy2-obfs / ss2022 / ss / tuic / anytls）"
  for l in "${links_direct[@]}"; do echo "  $l"; done
  hr
  echo -e "${C_CYAN}${C_BOLD}【WARP 节点（${nw}）】${C_RESET}（同上 ${nw} 种，带 -warp）"
  echo -e "${C_DIM}说明：带 -warp 的节点走 Cloudflare WARP 出口，流媒体解锁更友好${C_RESET}"
  for l in "${links_warp[@]}"; do echo "  $l"; done
  if ! $has_anytls; then
    echo -e "${C_YELLOW}  当前配置是旧版本生成的，还没有 AnyTLS 节点；执行 1) 安装/部署 即可补上${C_RESET}"
  fi
  local rv retired=()
  for rv in RS_VR RS_GR RS_TR RS_VRW RS_GRW RS_TRW; do
    [[ " $REALITY_RETIRED " == *" ${!rv} "* ]] && retired+=("${!rv}")
  done
  if (( ${#retired[@]} )); then
    echo -e "${C_YELLOW}  ⚠ 有 ${#retired[@]} 个 Reality 节点还在用已失效的偷域名 ${retired[0]}，可能连不上。${C_RESET}"
    echo -e "${C_YELLOW}    执行 1) 安装/部署 会自动换成可用域名（端口、密码不变，只有这些节点的 sni 变），之后重新导入这几个节点${C_RESET}"
  fi
  hr
  echo -e "${C_YELLOW}📌 如果你使用 v2rayN/Xray-core v26.2.6+，hysteria2 节点的 allowInsecure 已被移除，${C_RESET}"
  echo -e "${C_YELLOW}   请改用以下 pinnedPeerCertSha256 节点（含混淆版）：${C_RESET}"
  for l in "${LINKS_PCS[@]}"; do echo "  $l"; done
  hr
  # 开了订阅的话顺手刷新订阅内容（只用 IPv4 那一份，查看 IPv6 链接时不动订阅）
  if sub_enabled; then
    [[ "$LINK_MODE" == "4" ]] && sub_write_file
    echo -e "${C_CYAN}${C_BOLD}订阅链接：${C_RESET}$(sub_url)"
    hr
  fi
}

# ===== 本机 HTTP 订阅（#14）=====
# 做法同 sing-box-yg：busybox httpd 托管 /<随机口令>/sub.txt；没有 busybox 时用 python3 http.server。
# 用 systemd 托管（开机自启），口令 32 位随机串，不复用节点 UUID；每层目录放空 index.html，访问目录拿不到列表。
# 注意：HTTP 明文，拉订阅时节点信息会明文经过网络
SUB_ENV="$SB_DIR/sub.env"
SUB_WWW="$SB_DIR/sub/www"
SUB_SERVICE="sing-box-plus-sub.service"

sub_enabled(){ [[ -f "$SUB_ENV" ]]; }
load_sub(){ safe_source_env "$SUB_ENV"; }
sub_url(){ load_sub; printf 'http://%s:%s/%s/sub.txt' "$(fmt_host_for_uri "${LINK_IP:-$(get_ip4)}")" "$SUB_PORT" "$SUB_TOKEN"; }

# 把 build_links 生成的链接写成 base64 订阅（v2rayN / Shadowrocket / NekoBox / Hiddify 通用格式）
sub_write_file(){
  sub_enabled && load_sub || return 0
  local dir="$SUB_WWW/$SUB_TOKEN"
  mkdir -p "$dir"
  : > "$SUB_WWW/index.html"; : > "$dir/index.html"
  printf '%s\n' "${LINKS_DIRECT[@]}" "${LINKS_WARP[@]}" "${LINKS_PCS[@]}" | b64enc > "$dir/sub.txt.tmp"
  chmod 644 "$dir/sub.txt.tmp"
  mv -f "$dir/sub.txt.tmp" "$dir/sub.txt"
}

# 换端口 / 重新部署后调用：重新生成链接并刷新订阅内容
sub_refresh(){
  sub_enabled || return 0
  build_links 4 >/dev/null 2>&1 && sub_write_file || warn "订阅内容刷新失败，可在 7) 订阅链接 里重试"
}

sub_server_cmd(){
  if command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx httpd; then
    printf '%s httpd -f -p %s -h %s' "$(command -v busybox)" "$SUB_PORT" "$SUB_WWW"
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s -m http.server %s' "$(command -v python3)" "$SUB_PORT"   # 目录由 WorkingDirectory 指定，兼容 python3.6
  else
    return 1
  fi
}

sub_write_unit(){
  local cmd
  cmd=$(sub_server_cmd) || { err "没有可用的 HTTP 服务程序（busybox 或 python3），无法开启订阅"; return 1; }
  cat > "/etc/systemd/system/${SUB_SERVICE}" <<EOF
[Unit]
Description=Sing-Box-Plus subscription (HTTP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
NoNewPrivileges=yes
WorkingDirectory=${SUB_WWW}
ExecStart=${cmd}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SUB_SERVICE}" >/dev/null 2>&1 || true
  systemctl restart "${SUB_SERVICE}"
}

# 用法：sub_enable [reset]   reset = 换一个新口令（旧订阅地址立即失效）
sub_enable(){
  local mode="${1:-}" v
  load_sub 2>/dev/null || true
  load_ports || true
  if [[ -z "${SUB_PORT:-}" ]]; then
    rand_ports_reset
    for v in "${PORT_VARS[@]}"; do [[ -n "${!v:-}" ]] && PORTS+=("${!v}"); done
    gen_port SUB_PORT
  fi
  if [[ -z "${SUB_TOKEN:-}" || "$mode" == "reset" ]]; then
    [[ -n "${SUB_TOKEN:-}" ]] && rm -rf "${SUB_WWW:?}/${SUB_TOKEN}"
    SUB_TOKEN=$(openssl rand -hex 16)
  fi
  printf 'SUB_PORT=%s\nSUB_TOKEN=%s\n' "$SUB_PORT" "$SUB_TOKEN" > "$SUB_ENV"
  command -v busybox >/dev/null 2>&1 || ensure_deps busybox >/dev/null 2>&1 || true
  build_links 4 >/dev/null
  sub_write_file
  sub_write_unit || { rm -f "$SUB_ENV"; return 1; }
  open_firewall
  sleep 1
  if systemctl is-active --quiet "${SUB_SERVICE}"; then
    ok "订阅已开启（端口 ${SUB_PORT}/tcp，云厂商有安全组的话记得放行）"
  else
    err "订阅服务未能启动："; journalctl -u "${SUB_SERVICE}" -n 20 --no-pager 2>/dev/null || true
    return 1
  fi
  echo -e "${C_CYAN}${C_BOLD}订阅链接：${C_RESET}$(sub_url)"
  echo -e "${C_DIM}v2rayN：订阅分组 → 添加，粘贴上面的地址；Shadowrocket / NekoBox / Hiddify 直接添加订阅即可${C_RESET}"
}

sub_disable(){
  systemctl disable --now "${SUB_SERVICE}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SUB_SERVICE}"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "${SB_DIR:?}/sub" "$SUB_ENV"
}

sub_menu(){
  local c="" yn=""
  if sub_enabled && load_sub; then
    build_links 4 >/dev/null; sub_write_file
    echo -e "${C_CYAN}${C_BOLD}订阅链接：${C_RESET}$(sub_url)"
    echo -e "服务状态：$(systemctl is-active --quiet "${SUB_SERVICE}" && echo -e "${C_GREEN}运行中${C_RESET}" || echo -e "${C_RED}未运行${C_RESET}")"
    hr
    echo "  1) 更换订阅地址（旧地址立即失效，导入过的客户端要重新添加）"
    echo "  2) 关闭订阅"
    echo "  0) 返回"
    read -erp "选择: " c || c=0
    case "$c" in
      1) sub_enable reset || true ;;
      2) sub_disable; ok "订阅已关闭，原订阅地址已失效" ;;
    esac
  else
    warn "订阅走 HTTP 明文：客户端拉订阅时，全部节点的地址和密钥会明文经过网络。"
    warn "建议导入完就回来关掉，或定期用 1) 更换订阅地址。"
    read -erp "开启本机订阅？[y/N]: " yn || true
    [[ "$yn" =~ ^[Yy]$ ]] && { sub_enable || true; }
  fi
  return 0   # 用户选"不开启"时上一行是 false，不显式 return 0 的话 set -e 会让脚本直接退出
}

# ===== BBR =====
enable_bbr(){
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "BBR 已启用"
  else
    echo "net.core.default_qdisc=fq" >/etc/sysctl.d/99-bbr.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1 || true
    info "已尝试开启 BBR（如内核不支持需自行升级）"
  fi
}

# ===== 显示状态与 banner =====
sb_service_state(){
  systemctl is-active --quiet "${SYSTEMD_SERVICE:-sing-box.service}" && echo -e "${C_GREEN}运行中${C_RESET}" || echo -e "${C_RED}未运行/未安装${C_RESET}"
}
bbr_state(){
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && echo -e "${C_GREEN}已启用 BBR${C_RESET}" || echo -e "${C_RED}未启用 BBR${C_RESET}"
}

banner(){
  clear >/dev/null 2>&1 || true
  hr
  echo -e " ${C_CYAN}🚀 ${SCRIPT_NAME} ${SCRIPT_VERSION} 🚀${C_RESET}"
  echo -e "${C_CYAN} 脚本更新地址: https://github.com/Alvin9999-newpac/Sing-Box-Plus${C_RESET}"

  hr
  echo -e "系统加速状态：$(bbr_state)"
  echo -e "Sing-Box 启动状态：$(sb_service_state)"
  hr
  echo -e "  ${C_BLUE}1)${C_RESET} 安装/部署（20 节点）"
  echo -e "  ${C_GREEN}2)${C_RESET} 查看分享链接（IPv4）"
  echo -e "  ${C_GREEN}6)${C_RESET} 查看分享链接（IPv6）"
  echo -e "  ${C_GREEN}7)${C_RESET} 订阅链接（本机 HTTP，开启/查看/关闭）"
  echo -e "  ${C_GREEN}3)${C_RESET} 重启服务"
  echo -e "  ${C_GREEN}4)${C_RESET} 一键更换所有端口"
  echo -e "  ${C_GREEN}5)${C_RESET} 一键开启 BBR"
  echo -e "  ${C_RED}8)${C_RESET} 卸载"
  echo -e "  ${C_RED}0)${C_RESET} 退出"
  hr
}

# ===== 业务流程 =====
restart_service(){
  systemctl restart "${SYSTEMD_SERVICE}" || die "重启失败"
  systemctl --no-pager status "${SYSTEMD_SERVICE}" | sed -n '1,6p' || true
}

rotate_ports(){
  ensure_installed_or_hint || return 0
  load_ports || true
  rand_ports_reset

  # 清空 20 项端口变量，触发重新分配不重复端口
  PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
  PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
  PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
  PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

  cp -f "$SB_DIR/ports.env" "$SB_DIR/ports.env.bak" 2>/dev/null || true
  save_all_ports          # 重新生成并保存 20 个不重复端口
  # 用新端口重写 config.json；失败就把 ports.env 换回去，否则查看链接显示的是新端口、服务跑的是旧端口
  if ! write_config; then
    mv -f "$SB_DIR/ports.env.bak" "$SB_DIR/ports.env" 2>/dev/null || true
    err "更换端口失败，已恢复原端口，服务未改动"
    read -erp "回车返回..." _ || true
    return 0
  fi
  rm -f "$SB_DIR/ports.env.bak"
  open_firewall           # ★ 新增：把“当前配置中的端口”全部放行
  systemctl restart "${SYSTEMD_SERVICE}"
  sub_refresh             # 开了订阅的话，订阅内容换成新端口（订阅地址本身不变）

  info "已更换端口并重启。"
  read -erp "回车返回..." _ || true
}


uninstall_all(){
  local yn=""
  read -erp "确认卸载？将删除 ${SB_DIR}（全部节点密钥、端口、证书），所有已导入的节点都会失效 [y/N]: " yn || true
  [[ "$yn" =~ ^[Yy]$ ]] || { info "已取消卸载"; exit 0; }
  sub_disable
  systemctl stop "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SYSTEMD_SERVICE}"
  systemctl daemon-reload
  rm -rf "$SB_DIR"
  echo -e "${C_GREEN}已卸载并清理完成。${C_RESET}"
  exit 0
}

deploy_native(){
  install_deps
  install_singbox
  write_config
  info "检查配置 ..."
  "$BIN_PATH" check -c "$CONF_JSON"
  info "写入并启用 systemd 服务 ..."
  write_systemd
  systemctl restart "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  open_firewall
  echo; echo -e "${C_BOLD}${C_GREEN}★ 部署完成（20 节点）${C_RESET}"; echo
  # 打印链接并直接退出
  print_links_grouped 4
  exit 0
}

ensure_installed_or_hint(){
  if [[ ! -f "$CONF_JSON" ]]; then
    warn "尚未安装，请先选择 1) 安装/部署（20 节点）"
    return 1
  fi
  return 0
}

# ===== 菜单 =====
menu(){
  banner
  # -e 用 readline 读输入：Backspace 发 ^H 还是 ^? 都能正常删除；读到 EOF（没有终端）直接退出，避免 menu 无限递归
  read -erp "选择: " op || exit 0
  case "${op:-}" in
  1)
  sbp_bootstrap                                     # 依赖/二进制回退
  set +e                                            # ← 关闭严格退出，避免中途被杀掉
  echo -e "${C_BLUE}[信息] 正在检查 sing-box 安装状态...${C_RESET}"
  install_singbox            || true
  # WARP 由 write_config 内部初始化（原来这里先调一次、write_config 里再调一次，重复跑 WARP 检测）
  if ! write_config; then
    set -e
    die "生成配置失败，未重启服务。请把上面的报错发到 issues"
  fi
  write_systemd              || true
  open_firewall              || true
  systemctl restart "${SYSTEMD_SERVICE}" || true
  sleep 1
  if ! systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
    err "sing-box 未能启动，最近日志："
    journalctl -u "${SYSTEMD_SERVICE}" -n 30 --no-pager 2>/dev/null || true
  fi
  set -e                                            # ← 恢复严格模式
  print_links_grouped
  exit 0                                          # ← 打印后直接退出
  ;;
  2) if ensure_installed_or_hint; then print_links_grouped 4; exit 0; fi ;;

  6) if ensure_installed_or_hint; then print_links_grouped 6; exit 0; fi ;;
  7) if ensure_installed_or_hint; then sub_menu; fi; read -erp "回车返回..." _ || true; menu ;;
    3) if ensure_installed_or_hint; then restart_service; fi; read -erp "回车返回..." _ || true; menu ;;
   4) if ensure_installed_or_hint; then rotate_ports; fi; menu ;;
    5) enable_bbr; read -erp "回车返回..." _ || true; menu ;;
    8) uninstall_all ;; # 直接退出
    0) exit 0 ;;
    *) menu ;;
  esac
}

# ===== 入口 =====
menu
