#!/bin/bash
# ============================================================
# 通用版 OpenSSH 升级安装脚本（同一份脚本适配 18.04/20.04/22.04/24.04）
#
# 设计要点（通用性 & 平滑升级）：
#   1) 目标系统版本从 deb 文件名推导（~bionic/~focal/~jammy/~noble），
#      与 /etc/os-release 比对，不匹配立即退出（防止装错版本包）。
#   2) deb 智能修补（幂等）：
#      a. 若本机 dpkg 不支持 --no-rename（仅 bionic 的 dpkg 1.19.0.5），
#         且 preinst 中包含该参数 -> 删除后重打包；
#         focal/jammy/noble 的 dpkg 均支持，自动跳过。
#      b. 重打包统一使用 -Zxz（xz 格式）：所有版本都能读，
#         避免在 22.04+ 上重打时默认 zstd 导致 bionic/focal 无法读取。
#      c. 若 deb 控制信息完全无法提取（格式不兼容），报错并提示
#         在对应 Ubuntu 版本环境用 dpkg-deb -b -Zxz 重新打包。
#   3) 严禁使用 apt-get -f install 兜底：依赖冲突时它会卸载旧包
#      导致 SSH 失联；安装命令显式列出目录内全部 deb + 强制 conffile 策略。
#   4) 兼容 openssh-server 的 hold 状态（临时解除、退出时自动恢复）。
#   5) 升级完成后校验版本；从 .before 恢复原 sshd_config 后再执行 SSH 安全
#      算法清理与登录策略校正（GSSAPI/Kex/HostKey 旧行清理、PermitRootLogin
#      yes、UsePAM yes、+ssh-rsa）。
#   6) 修复 10.6p1 sshd-keygen.service 的 ExecStart 相对路径问题
#      （systemd 237 不识别裸命令，幂等修复）。
#   7) sshd -t 校验通过后才 restart，最后输出 is-active 验收。
#   8) 无外网兼容（生产环境硬约束）：全程不使用任何联网命令
#      （无 apt-get update / curl / wget）。apt 仅用于安装本地 deb：
#      依赖已在系统满足时无任何网络访问（openssh 依赖均为系统基础包），
#      本地 deb 路径也不需要 apt 源索引。已在无网络容器实测通过。
# ============================================================

# ---------- 非交互执行 ----------
export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFFOLD=1
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
export APT_LISTCHANGES_FRONTEND=none

# ---------- 0) 基础检查：从 deb 文件名推导目标版本 ----------
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE_DIR" || exit 1

SERVER_DEB=$(ls ./openssh-server_*_amd64.deb 2>/dev/null | head -1)
if [ -z "$SERVER_DEB" ]; then
    echo "ERROR: 当前目录未找到 openssh-server_*_amd64.deb" >&2
    exit 1
fi

case "$SERVER_DEB" in
    *~bionic*) EXPECT_OS="18.04" ;;
    *~focal*)  EXPECT_OS="20.04" ;;
    *~jammy*)  EXPECT_OS="22.04" ;;
    *~noble*)  EXPECT_OS="24.04" ;;
    *) echo "ERROR: 无法从 $SERVER_DEB 推导目标发行版（需含 ~bionic/~focal/~jammy/~noble）" >&2; exit 1 ;;
esac

if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "ERROR: 无法读取 /etc/os-release" >&2
    exit 1
fi

if [ "${ID}" != "ubuntu" ] || [ "${VERSION_ID}" != "$EXPECT_OS" ]; then
    echo "============================================================" >&2
    echo "ERROR: 本包集为 Ubuntu ${EXPECT_OS} 专用" >&2
    echo "       当前系统为: ${PRETTY_NAME}" >&2
    echo "============================================================" >&2
    exit 1
fi

# 动态收集目录内全部 deb，并断言核心包存在
mapfile -t DEBS < <(ls -1 ./*.deb 2>/dev/null)
DEB_COUNT=${#DEBS[@]}
if [ "$DEB_COUNT" -eq 0 ]; then
    echo "ERROR: 当前目录没有 deb 包" >&2
    exit 1
fi
if [ -z "$(ls ./openssh-server_*_amd64.deb 2>/dev/null | head -1)" ]; then
    echo "ERROR: 缺少 openssh-server deb" >&2
    exit 1
fi
if [ -z "$(ls ./openssh-client_*_amd64.deb 2>/dev/null | head -1)" ]; then
    echo "ERROR: 缺少 openssh-client deb" >&2
    exit 1
fi

OLD_VER=$(dpkg-query -W -f='${Version}' openssh-server 2>/dev/null || true)

PKG_DIR_NAME=$(basename "$BASE_DIR")
echo "${PKG_DIR_NAME} | ${PRETTY_NAME} | $(hostname) | $(date '+%F %T')"
echo ""
echo "[1/9] 系统与包集版本匹配"

SSHD_CONF="/etc/ssh/sshd_config"

# ---------- 1) 备份 ----------
cp /etc/pam.d/sshd /etc/pam.d/sshd.before
cp "$SSHD_CONF" "${SSHD_CONF}.before"
echo "[2/9] 配置备份完成：${SSHD_CONF}.before、/etc/pam.d/sshd.before"

# ---------- 2) deb 智能修补 ----------
TMPFIX=$(mktemp -d)
trap 'rm -rf "$TMPFIX"' EXIT

NEED_SED=0
NEED_REPACK=0

# 2a) 先验证 deb 控制信息可读（不可读=压缩格式与此 dpkg 不兼容）
if ! dpkg-deb -e "$SERVER_DEB" "$TMPFIX/ctrl" 2>/dev/null; then
    echo "ERROR: 无法读取 $SERVER_DEB 的控制信息（压缩格式与当前 dpkg 不兼容）。" >&2
    echo "       请在对应的 Ubuntu 版本环境中用: dpkg-deb -b -Zxz <解包目录> <输出.deb> 重新打包。" >&2
    exit 1
fi

# 2b) --no-rename 支持性检测
if ! dpkg-divert --help 2>&1 | grep -q -e '--no-rename'; then
    if grep -q -e '--no-rename' "$TMPFIX/ctrl/preinst" 2>/dev/null; then
        NEED_SED=1
        NEED_REPACK=1
    fi
fi

if [ "$NEED_REPACK" = "1" ]; then
    rm -rf "$TMPFIX/ctrl" "$TMPFIX/pkg"
    dpkg-deb -R "$SERVER_DEB" "$TMPFIX/pkg" || { echo "ERROR: dpkg-deb -R 提取失败" >&2; exit 1; }
    if [ "$NEED_SED" = "1" ]; then
        sed -i 's/--no-rename //; s/ --no-rename//' "$TMPFIX/pkg/DEBIAN/preinst" "$TMPFIX/pkg/DEBIAN/postinst" 2>/dev/null
        if grep -q -e '--no-rename' "$TMPFIX/pkg/DEBIAN/preinst" "$TMPFIX/pkg/DEBIAN/postinst" 2>/dev/null; then
            echo "ERROR: --no-rename 删除后校验失败" >&2
            exit 1
        fi
    fi
    sh -n "$TMPFIX/pkg/DEBIAN/preinst" 2>/dev/null || { echo "ERROR: preinst 语法校验失败" >&2; exit 1; }
    dpkg-deb -b -Zxz --root-owner-group "$TMPFIX/pkg" "$TMPFIX/fixed.deb" >/dev/null || { echo "ERROR: dpkg-deb -b 重建失败" >&2; exit 1; }
    [ -f "${SERVER_DEB}.orig" ] || cp -a "$SERVER_DEB" "${SERVER_DEB}.orig"
    mv -f "$TMPFIX/fixed.deb" "$SERVER_DEB"
    echo "[3/9] deb 已修补（删除 --no-rename，xz 重打包）"
else
    echo "[3/9] deb 无需修补"
fi

# ---------- 3) hold 状态处理（退出时自动恢复） ----------
WAS_HOLD=0
if apt-mark showhold 2>/dev/null | grep -qx 'openssh-server'; then
    WAS_HOLD=1
    apt-mark unhold openssh-server >/dev/null 2>&1
    echo "[4/9] hold 状态：已临时解除"
else
    echo "[4/9] hold 状态：无"
fi
restore_hold() {
    if [ "$WAS_HOLD" = "1" ]; then
        apt-mark hold openssh-server >/dev/null 2>&1
    fi
}
trap 'rm -rf "$TMPFIX"; restore_hold' EXIT

# ---------- 4) 清理残留半配置 & mask ----------
dpkg --configure --pending 2>&1 || true

MASK_REMOVED=0
for u in ssh.service ssh.socket; do
    if [ -L "/etc/systemd/system/$u" ] && [ "$(readlink "/etc/systemd/system/$u")" = "/dev/null" ]; then
        rm -f "/etc/systemd/system/$u"
        MASK_REMOVED=1
    fi
done
systemctl daemon-reload 2>/dev/null || true
if [ "$MASK_REMOVED" = "1" ]; then
    echo "[5/9] 残留状态：已移除 mask"
else
    echo "[5/9] 残留状态：无"
fi

# ---------- 5) 安装 ----------
# 警告：不要用 apt-get -f install 兜底（依赖冲突时会卸载旧包导致 SSH 失联）
# 无外网兼容：仅安装本地 deb，依赖已满足时 apt 纯本地操作、不访问网络
echo "[6/9] 安装 ${DEB_COUNT} 个 deb"
echo "--- apt 输出 ---"
apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-overwrite" \
    "${DEBS[@]}" \
    || echo "WARN: apt-get 返回非零（postinst 重启偶发），继续校验"
echo "--- apt 输出结束 ---"
dpkg --configure --pending 2>&1 || true
echo "[6/9] 安装完成"

# ---------- 6) 版本校验 ----------
NEW_VER=$(dpkg-query -W -f='${Version}' openssh-server 2>/dev/null || true)
if ! echo "$NEW_VER" | grep -q '1:10\.'; then
    echo "[7/9] 版本校验失败：当前 ${NEW_VER:-未知}，未升级" >&2
    echo "配置备份：${SSHD_CONF}.before" >&2
    exit 1
fi
echo "[7/9] 版本：${OLD_VER:-未安装} -> ${NEW_VER}"

# ---------- 7) 恢复备份配置 ----------
cp -a "${SSHD_CONF}.before" "$SSHD_CONF"

# ---------- 8) SSH 安全算法与登录策略校正（幂等） ----------
# 清理旧系统遗留的算法协商限制行（KexAlgorithms / GSSAPIKexAlgorithms /
# HostKeyAlgorithms）：
#  - GSSAPIKexAlgorithms 在新版 OpenSSH 中已被移除，保留会导致 sshd 拒绝
#    启动（Bad configuration option）；
#  - 旧算法清单会替换新版默认算法集（含后量子算法），清理后由新版默认
#    算法列表接管。
# 追加 HostKeyAlgorithms +ssh-rsa：兼容仍只支持 ssh-rsa 的旧客户端，
# "+" 前缀=在默认列表基础上附加，不替换、不削弱默认安全性。
# PermitRootLogin yes / UsePAM yes：维持生产环境登录策略与 PAM 集成。
sed -i '/^[[:space:]]*KexAlgorithms/d' "$SSHD_CONF"
sed -i '/^[[:space:]]*GSSAPIKexAlgorithms/d' "$SSHD_CONF"
sed -i '/^[[:space:]]*HostKeyAlgorithms/d' "$SSHD_CONF"

if ! grep -Eq '^[[:space:]]*PermitRootLogin[[:space:]]+yes\b' "$SSHD_CONF"; then
    echo "PermitRootLogin yes" >> "$SSHD_CONF"
fi

if grep -Eq '^[[:space:]]*#?[[:space:]]*UsePAM' "$SSHD_CONF"; then
    sed -i 's/^[[:space:]]*#\?[[:space:]]*UsePAM.*/UsePAM yes/' "$SSHD_CONF"
else
    echo "UsePAM yes" >> "$SSHD_CONF"
fi

/bin/cp /etc/pam.d/sshd.before /etc/pam.d/sshd

if ! grep -Eq '^[[:space:]]*HostKeyAlgorithms[[:space:]]+\+ssh-rsa\b' "$SSHD_CONF"; then
    echo "HostKeyAlgorithms +ssh-rsa" >> "$SSHD_CONF"
fi
echo "[8/9] 配置恢复，算法配置与登录策略校正完成"

# ---------- 9) unit 修复 + 校验 + 重启 ----------
if [ -f /lib/systemd/system/sshd-keygen.service ]; then
    sed -i 's|^ExecStart=ssh-keygen -A|ExecStart=/usr/bin/ssh-keygen -A|' /lib/systemd/system/sshd-keygen.service
fi

systemctl daemon-reload 2>/dev/null || true
if ! /usr/sbin/sshd -t; then
    echo "[9/9] sshd -t 失败" >&2
    echo "配置备份：${SSHD_CONF}.before" >&2
    exit 1
fi

systemctl enable ssh >/dev/null 2>&1 || true
systemctl restart ssh
sleep 1
SSH_ACTIVE=$(systemctl is-active ssh 2>/dev/null || true)
SSH_ENABLED=$(systemctl is-enabled ssh 2>/dev/null || true)
echo "[9/9] sshd -t 通过，服务 ${SSH_ACTIVE:-unknown}${SSH_ENABLED:+, $SSH_ENABLED}"
echo ""
echo "sshd: $(/usr/sbin/sshd -V 2>&1 | head -1)"
echo "ssh:  $(ssh -V 2>&1 | head -1)"
echo "升级完成"
