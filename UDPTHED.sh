#!/bin/bash
set -uo pipefail

ZIVPN_VERSION="1.4.9"
BASE_DIR="/etc/zivpn"
CONF="$BASE_DIR/config.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

# ========== ฟังก์ชันช่วยเหลือ ==========
to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

use_systemd() {
  has_cmd systemctl && [ -d /run/systemd/system ]
}

get_server_ip() {
  if has_cmd curl; then
    curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null && return 0
  fi
  if has_cmd hostname; then
    hostname -I 2>/dev/null | awk '{print $1}' && return 0
  fi
  if has_cmd ip; then
    ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1 && return 0
  fi
  echo "ไม่ทราบ"
}

# ========== ฟังก์ชันตรวจสอบและแก้ไข dpkg lock ==========
wait_for_dpkg_lock() {
  local max_wait=120
  local waited=0
  local lock_files="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock"

  echo "กำลังตรวจสอบ dpkg lock..."

  while [ $waited -lt $max_wait ]; do
    local locked=0
    for lf in $lock_files; do
      if [ -f "$lf" ] && fuser "$lf" >/dev/null 2>&1; then
        locked=1
        break
      fi
    done

    if [ $locked -eq 0 ]; then
      echo "✓ dpkg พร้อมใช้งาน"
      return 0
    fi

    if [ $waited -eq 0 ]; then
      echo "พบว่ามีโปรเซสอื่นกำลังใช้ dpkg (อาจเป็น auto-update)"
      echo "กำลังรอให้เสร็จสิ้น (สูงสุด ${max_wait} วินาที)..."
    fi

    sleep 5
    waited=$((waited + 5))
    echo "  รอแล้ว ${waited} วินาที..."
  done

  echo
  echo "คำเตือน: รอเกิน ${max_wait} วินาทีแล้ว dpkg ยังถูกล็อก"
  echo "กำลังพยายามแก้ไขอัตโนมัติ..."

  # หยุด unattended-upgrades
  if use_systemd; then
    systemctl stop unattended-upgrades 2>/dev/null || true
  fi

  # Kill โปรเซส apt/dpkg
  pkill -9 apt-get 2>/dev/null || true
  pkill -9 apt 2>/dev/null || true
  pkill -9 dpkg 2>/dev/null || true
  sleep 2

  # ลบไฟล์ lock
  rm -f /var/lib/dpkg/lock-frontend
  rm -f /var/lib/dpkg/lock
  rm -f /var/cache/apt/archives/lock

  # กู้คืน dpkg
  dpkg --configure -a 2>/dev/null || true

  echo "✓ พยายามแก้ไข dpkg lock แล้ว"
  sleep 2
}

# ========== ตรวจสอบสิทธิ์ root ==========
if [ "$(id -u)" -ne 0 ]; then
  echo "ผิดพลาด: กรุณารันสคริปต์นี้ด้วยสิทธิ์ root"
  exit 1
fi

# ========== ตรวจสอบระบบปฏิบัติการ ==========
OS_ID=""
OS_VERSION=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION="${VERSION_ID:-}"
elif [ -r /etc/lsb-release ]; then
  . /etc/lsb-release
  OS_ID="$(to_lower "${DISTRIB_ID:-}")"
  OS_VERSION="${DISTRIB_RELEASE:-}"
elif [ -r /etc/debian_version ]; then
  OS_ID="debian"
  OS_VERSION="$(cat /etc/debian_version)"
fi

case "$OS_ID" in
  ubuntu|debian) ;;
  *)
    echo "คำเตือน: สคริปต์ติดตั้งนี้ออกแบบมาสำหรับ Ubuntu/Debian"
    echo "ระบบปัจจุบัน: ${OS_ID:-ไม่ทราบ} ${OS_VERSION:-}"
    read -r -p "ต้องการดำเนินการต่อหรือไม่? [ใช่/ไม่]: " ans
    ans_lower="$(to_lower "$ans")"
    [ "$ans_lower" = "ใช่" ] || [ "$ans_lower" = "y" ] || exit 1
    ;;
esac

# ========== ตรวจสอบสถาปัตยกรรม ==========
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "ผิดพลาด: สถาปัตยกรรมไม่รองรับ: $(uname -m)"
    exit 1
    ;;
esac

# ========== แสดงข้อมูลเริ่มต้น ==========
echo
echo "=========================================="
echo "   ZiVPN ครบถ้วน - ปลอดภัยสำหรับเว็บไซต์"
echo "=========================================="
echo "ระบบปฏิบัติการ: ${OS_ID} ${OS_VERSION}"
echo "สถาปัตยกรรม   : $ARCH"
echo "พอร์ต ZiVPN    : UDP 5667"
echo "ช่วงพอร์ตสาธารณะ: UDP 6000-19999"
echo "ตัวจัดการผู้ใช้: มี"
echo "ระบบวันหมดอายุ: มี"
echo "เมนูหลัก      : พิมพ์ menu"
echo "ไฟร์วอลล์     : iptables/nftables NAT"
echo "บริการเว็บ    : ไม่มีการแก้ไข"
echo "=========================================="
echo

# ========== [1/9] สำรองข้อมูลเดิม ==========
if [ -d "$BASE_DIR" ]; then
  BACKUP="/root/zivpn-backup-$STAMP"
  echo "[1/9] สำรองข้อมูล ZiVPN ที่มีอยู่ -> $BACKUP"
  cp -a "$BASE_DIR" "$BACKUP"
else
  echo "[1/9] ไม่พบไฟล์กำหนดค่า ZiVPN เดิม"
fi

# ========== [2/9] ติดตั้งแพ็กเกจที่จำเป็น ==========
echo "[2/9] กำลังติดตั้งแพ็กเกจที่จำเป็น..."

# ตรวจสอบและรอ dpkg lock
wait_for_dpkg_lock

# ตรวจสอบว่ามี apt หรือ apt-get
APT_CMD=""
if has_cmd apt-get; then
  APT_CMD="apt-get"
elif has_cmd apt; then
  APT_CMD="apt"
else
  echo "ผิดพลาด: ไม่พบคำสั่ง apt หรือ apt-get"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# อัปเดตรายการแพ็กเกจ
echo "กำลังอัปเดตรายการแพ็กเกจ..."
$APT_CMD update -y || {
  echo "คำเตือน: apt update มีข้อผิดพลาดบางประการ พยายามดำเนินการต่อ..."
}

# ตรวจสอบ Python
if has_cmd python3; then
  PYTHON_CMD="python3"
  PYTHON_PKG="python3"
elif has_cmd python; then
  PYTHON_CMD="python"
  PYTHON_PKG=""
else
  PYTHON_CMD="python3"
  PYTHON_PKG="python3"
fi

# ตรวจสอบแพ็กเกจอื่นๆ
EXTRA_PKGS=""
has_cmd curl || EXTRA_PKGS="$EXTRA_PKGS curl"
has_cmd openssl || EXTRA_PKGS="$EXTRA_PKGS openssl"
has_cmd iptables || EXTRA_PKGS="$EXTRA_PKGS iptables"
has_cmd conntrack || EXTRA_PKGS="$EXTRA_PKGS conntrack"
has_cmd ca-certificates || EXTRA_PKGS="$EXTRA_PKGS ca-certificates"
has_cmd ss || has_cmd netstat || EXTRA_PKGS="$EXTRA_PKGS iproute2 net-tools"

ALL_PKGS="$PYTHON_PKG $EXTRA_PKGS"
if [ -n "$(echo "$ALL_PKGS" | xargs)" ]; then
  echo "กำลังติดตั้ง: $(echo "$ALL_PKGS" | xargs)"
  $APT_CMD install -y $ALL_PKGS || {
    echo "คำเตือน: ติดตั้งบางแพ็กเกจไม่สำเร็จ พยายามต่อ..."
  }
else
  echo "แพ็กเกจที่จำเป็นติดตั้งอยู่แล้วทั้งหมด"
fi

# ยืนยันว่ามี Python
if ! has_cmd python3 && ! has_cmd python; then
  echo "ผิดพลาด: ไม่สามารถติดตั้ง Python ได้"
  exit 1
fi
has_cmd python3 && PYTHON_CMD="python3" || PYTHON_CMD="python"

# ========== [2b/9] สำรองกฎไฟร์วอลล์เดิม ==========
echo "[2b/9] สำรองกฎไฟร์วอลล์เดิม..."
has_cmd iptables-save && iptables-save > "/root/iptables-before-zivpn-$STAMP.rules" 2>/dev/null || true
has_cmd ip6tables-save && ip6tables-save > "/root/ip6tables-before-zivpn-$STAMP.rules" 2>/dev/null || true
has_cmd nft && nft list ruleset > "/root/nftables-before-zivpn-$STAMP.rules" 2>/dev/null || true

# ========== [2c/9] ตรวจสอบความขัดแย้งของพอร์ต UDP ==========
echo "[2c/9] ตรวจสอบความขัดแย้งของพอร์ต UDP..."

check_udp_port() {
  local port="$1"
  if has_cmd ss; then
    ss -H -ulnp 2>/dev/null | grep -E "(^|[[:space:]])[^[:space:]]*:${port}[[:space:]]" || true
  elif has_cmd netstat; then
    netstat -ulnp 2>/dev/null | grep -E ":${port}[[:space:]]" || true
  fi
}

check_udp_port_range() {
  local min_port="$1" max_port="$2"
  if has_cmd ss; then
    ss -H -ulnp 2>/dev/null | while IFS= read -r line; do
      addr="$(echo "$line" | awk '{print $5}')"
      port="${addr##*:}"
      if echo "$port" | grep -qE '^[0-9]+$' && [ "$port" -ge "$min_port" ] && [ "$port" -le "$max_port" ]; then
        echo "$line"
      fi
    done
  elif has_cmd netstat; then
    netstat -ulnp 2>/dev/null | while IFS= read -r line; do
      addr="$(echo "$line" | awk '{print $4}')"
      port="${addr##*:}"
      if echo "$port" | grep -qE '^[0-9]+$' && [ "$port" -ge "$min_port" ] && [ "$port" -le "$max_port" ]; then
        echo "$line"
      fi
    done
  fi
}

ZIVPN_5667_LINE="$(check_udp_port 5667)"
if [ -n "$ZIVPN_5667_LINE" ] && ! echo "$ZIVPN_5667_LINE" | grep -qi 'zivpn'; then
  echo
  echo "ผิดพลาด: พอร์ต UDP 5667 ถูกใช้งานโดยบริการอื่นแล้ว:"
  echo "$ZIVPN_5667_LINE"
  echo "หยุดการติดตั้ง บริการเว็บไซต์ไม่มีการเปลี่ยนแปลงใดๆ"
  exit 1
fi

RANGE_CONFLICTS="$(check_udp_port_range 6000 19999)"
if [ -n "$RANGE_CONFLICTS" ]; then
  echo
  echo "ผิดพลาด: มีบริการ UDP ที่ใช้พอร์ตในช่วง 6000-19999 อยู่แล้ว:"
  echo "$RANGE_CONFLICTS"
  echo "หยุดการติดตั้งเพื่อปกป้องบริการที่มีอยู่"
  exit 1
fi

# ========== [3/9] ติดตั้งไฟล์โปรแกรม ZiVPN ==========
echo "[3/9] กำลังติดตั้งไฟล์โปรแกรม ZiVPN..."

DOWNLOAD_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_${ZIVPN_VERSION}/udp-zivpn-linux-${ARCH}"

if has_cmd curl; then
  curl -fL --retry 3 --retry-delay 5 "$DOWNLOAD_URL" -o /usr/local/bin/zivpn || {
    echo "ผิดพลาด: ดาวน์โหลดไฟล์ ZiVPN ไม่สำเร็จ"
    echo "URL: $DOWNLOAD_URL"
    exit 1
  }
elif has_cmd wget; then
  wget -q --tries=3 --waitretry=5 "$DOWNLOAD_URL" -O /usr/local/bin/zivpn || {
    echo "ผิดพลาด: ดาวน์โหลดไฟล์ ZiVPN ไม่สำเร็จ"
    exit 1
  }
else
  echo "ผิดพลาด: ไม่พบ curl หรือ wget"
  exit 1
fi

chmod 755 /usr/local/bin/zivpn
mkdir -p "$BASE_DIR"
chmod 700 "$BASE_DIR"

# ========== [4/9] สร้างใบรับรอง ==========
if [ ! -f "$BASE_DIR/zivpn.key" ] || [ ! -f "$BASE_DIR/zivpn.crt" ]; then
  echo "[4/9] กำลังสร้างใบรับรอง..."
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/C=TH/O=ZiVPN/CN=zivpn" \
    -keyout "$BASE_DIR/zivpn.key" \
    -out "$BASE_DIR/zivpn.crt" >/dev/null 2>&1
  chmod 600 "$BASE_DIR/zivpn.key"
else
  echo "[4/9] ใช้ใบรับรองเดิมที่มีอยู่แล้ว"
fi

# ========== [5/9] สร้างไฟล์กำหนดค่า ==========
if [ ! -f "$CONF" ]; then
  echo
  read -r -p "รหัสผ่านเริ่มต้น (คั่นด้วยจุลภาค) [ค่าเริ่มต้น: zi]: " INITIAL_PASSWORDS
  INITIAL_PASSWORDS="${INITIAL_PASSWORDS:-zi}"
  $PYTHON_CMD - "$INITIAL_PASSWORDS" <<PY
import json, sys
raw = sys.argv[1]
passwords = [x.strip() for x in raw.split(",") if x.strip()]
if not passwords:
    passwords = ["zi"]
conf = {
    "listen": ":5667",
    "cert": "/etc/zivpn/zivpn.crt",
    "key": "/etc/zivpn/zivpn.key",
    "obfs": "zivpn",
    "auth": {"mode": "passwords", "config": passwords},
}
with open("/etc/zivpn/config.json", "w") as f:
    json.dump(conf, f, indent=2)
    f.write("\n")
PY
  chmod 600 "$CONF"
  echo "[5/9] สร้างไฟล์กำหนดค่า ZiVPN ใหม่แล้ว"
else
  echo "[5/9] ใช้ไฟล์กำหนดค่า/ผู้ใช้เดิมที่มีอยู่แล้ว"
fi

# ========== [6/9] ติดตั้งบริการระบบ ==========
echo "[6/9] กำลังติดตั้งบริการระบบ..."

if use_systemd; then
  echo "พบ systemd - ใช้บริการแบบ systemd"

  cat > /etc/systemd/system/zivpn.service <<'EOF'
[Unit]
Description=เซิร์ฟเวอร์ ZiVPN VPN
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/zimanager-expire.service <<'EOF'
[Unit]
Description=ทำความสะอาดผู้ใช้ที่หมดอายุของ ZiVPN
After=zivpn.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/menu --expire
EOF

  cat > /etc/systemd/system/zimanager-expire.timer <<'EOF'
[Unit]
Description=ตรวจสอบวันหมดอายุผู้ใช้ ZiVPN ทุกนาที

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=20s
Persistent=true

[Install]
WantedBy=timers.target
EOF

else
  echo "ไม่พบ systemd - ใช้บริการแบบ SysVinit"

  cat > /etc/init.d/zivpn <<'INITEOF'
#!/bin/bash
### BEGIN INIT INFO
# Provides:          zivpn
# Required-Start:    $network $remote_fs $syslog
# Required-Stop:     $network $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ZiVPN VPN Server
### END INIT INFO

NAME="zivpn"
DAEMON="/usr/local/bin/zivpn"
PIDFILE="/var/run/zivpn.pid"
LOGFILE="/var/log/zivpn.log"
WORKDIR="/etc/zivpn"

case "$1" in
  start)
    echo "เริ่ม $NAME..."
    cd "$WORKDIR"
    ZIVPN_LOG_LEVEL=info start-stop-daemon --start --background --make-pidfile \
      --pidfile "$PIDFILE" --exec "$DAEMON" -- server -c /etc/zivpn/config.json \
      >> "$LOGFILE" 2>&1
    ;;
  stop)
    echo "หยุด $NAME..."
    start-stop-daemon --stop --pidfile "$PIDFILE" --retry 5
    rm -f "$PIDFILE"
    ;;
  restart)
    $0 stop; sleep 1; $0 start
    ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "$NAME กำลังทำงาน"; exit 0
    else
      echo "$NAME หยุดทำงาน"; exit 1
    fi
    ;;
  *)
    echo "ใช้งาน: $0 {start|stop|restart|status}"; exit 1
    ;;
esac
exit 0
INITEOF
  chmod 755 /etc/init.d/zivpn

  cat > /etc/cron.d/zivpn-expire <<'CRONEOF'
* * * * * root /usr/local/bin/menu --expire >/dev/null 2>&1
CRONEOF
  chmod 644 /etc/cron.d/zivpn-expire
fi

# ========== สคริปต์ไฟร์วอลล์ ==========
cat > /usr/local/sbin/zivpn-firewall <<'FWEOF'
#!/bin/bash
set -e

NIC=""
if command -v ip >/dev/null 2>&1; then
  NIC="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
fi
if [ -z "$NIC" ] && command -v route >/dev/null 2>&1; then
  NIC="$(route -n 2>/dev/null | awk '$1=="0.0.0.0" {print $8; exit}')"
fi

[ -n "$NIC" ] || { echo "ZiVPN: ไม่พบอินเทอร์เฟซ" >&2; exit 1; }

if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -C PREROUTING -i "$NIC" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$NIC" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
elif command -v nft >/dev/null 2>&1; then
  nft add table ip nat 2>/dev/null || true
  nft add chain ip nat PREROUTING '{ type nat hook prerouting priority -100; }' 2>/dev/null || true
  nft add rule ip nat PREROUTING iif "$NIC" udp dport 6000-19999 dnat to :5667 2>/dev/null || true
fi
FWEOF
chmod 755 /usr/local/sbin/zivpn-firewall
/usr/local/sbin/zivpn-firewall || echo "คำเตือน: ตั้งค่าไฟร์วอลล์ไม่สำเร็จ"

# ========== ตั้งค่า sysctl ==========
cat > /etc/sysctl.d/99-zivpn.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
has_cmd sysctl && sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-zivpn.conf >/dev/null 2>&1 || true

# ========== [7/9] ติดตั้งเมนูหลัก ==========
echo "[7/9] กำลังติดตั้งเมนูหลัก..."

PYTHON_PATH="$(which $PYTHON_CMD)"
cat > /usr/local/bin/menu <<MAINMENU
#!${PYTHON_PATH}
import json, os, re, secrets, shutil, string, subprocess, sys, tempfile, time
from collections import defaultdict
from datetime import datetime

CONF = "/etc/zivpn/config.json"
DB = "/etc/zivpn/users.json"
TZ = "Asia/Bangkok"

os.environ["TZ"] = TZ
try: time.tzset()
except AttributeError: pass

RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
GREEN="\033[92m"; YELLOW="\033[93m"; RED="\033[91m"
CYAN="\033[96m"; GRAY="\033[90m"

if not sys.stdout.isatty() or os.getenv("TERM", "") == "dumb":
    RESET=BOLD=DIM=GREEN=YELLOW=RED=CYAN=GRAY=""

def has_cmd(cmd): return shutil.which(cmd) is not None
def use_systemd(): return has_cmd("systemctl") and os.path.isdir("/run/systemd/system")
def run(cmd): return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
def clear():
    if sys.stdout.isatty(): print("\033[2J\033[H", end="")
def term_width():
    try: return max(42, min(shutil.get_terminal_size((60, 20)).columns, 72))
    except Exception: return 60
def rule(ch="─"): print(GRAY + ch * term_width() + RESET)
def title(text):
    rule("═")
    print(f"{BOLD}{CYAN}{text.center(term_width())}{RESET}")
    rule("═")
def pause():
    try: input(f"\n{DIM}กด Enter เพื่อกลับเมนูหลัก...{RESET}")
    except EOFError: pass

def atomic_write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".zimgr-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise

def load_json(path, default):
    try:
        with open(path) as f: return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as e:
        print(f"{RED}JSON ไม่ถูกต้อง: {path}: {e}{RESET}"); sys.exit(1)

def load_conf():
    c = load_json(CONF, None)
    if c is None: print(f"{RED}ไม่พบไฟล์กำหนดค่า ZiVPN{RESET}"); sys.exit(1)
    c.setdefault("auth", {}).setdefault("config", [])
    if not isinstance(c["auth"]["config"], list): print(f"{RED}auth.config ต้องเป็นรายการ{RESET}"); sys.exit(1)
    c["auth"]["config"] = list(dict.fromkeys(str(x) for x in c["auth"]["config"]))
    return c

def load_db():
    d = load_json(DB, {"version": 2, "users": {}})
    d.setdefault("version", 2); d.setdefault("users", {})
    return d

def sync_imported():
    c, d = load_conf(), load_db()
    now = int(time.time()); changed = False
    for pw in c["auth"]["config"]:
        if pw not in d["users"]:
            d["users"][pw] = {"name": "นำเข้า", "created_at": now, "expires_at": None, "source": "existing-config"}
            changed = True
    if changed: atomic_write(DB, d)
    return c, d

def service_active():
    if use_systemd():
        return run(["systemctl", "is-active", "--quiet", "zivpn"]).returncode == 0
    pidfile = "/var/run/zivpn.pid"
    if os.path.isfile(pidfile):
        try: os.kill(int(open(pidfile).read().strip()), 0); return True
        except (OSError, ValueError): return False
    return False

def service_action(action):
    if use_systemd():
        return run(["systemctl", action, "zivpn"]).returncode == 0
    return run(["/etc/init.d/zivpn", action]).returncode == 0

def restart_zivpn():
    ok = service_action("restart")
    if not ok: print(f"{RED}รีสตาร์ท ZiVPN ไม่สำเร็จ{RESET}")
    return ok

def fmt_ts(ts):
    if ts is None: return "ไม่มีวันหมด"
    return datetime.fromtimestamp(int(ts)).strftime("%d/%m/%y %H:%M")

def left(ts):
    if ts is None: return "ไม่จำกัด"
    sec = int(ts) - int(time.time())
    if sec <= 0: return "หมดอายุแล้ว"
    d, rem = divmod(sec, 86400); h, rem = divmod(rem, 3600); m = rem // 60
    if d: return f"{d}วัน {h}ชม."
    if h: return f"{h}ชม. {m}นาที"
    return f"{m}นาที"

def state(pw, meta, configured, server_up):
    exp = meta.get("expires_at")
    if exp is not None and int(exp) <= int(time.time()): return "หมดอายุ", False
    if pw not in configured: return "ปิดใช้งาน", False
    if not server_up: return "เซิร์ฟเวอร์ดาวน์", False
    return "ใช้งานได้", True

def state_color(s):
    if s == "ใช้งานได้": return GREEN
    if s in ("หมดอายุ", "เซิร์ฟเวอร์ดาวน์"): return RED
    return YELLOW

def ask_days(prompt="จำนวนวันที่ใช้งาน (0 = ไม่มีวันหมด): "):
    while True:
        try:
            n = int(input(prompt).strip())
            if 0 <= n <= 3650: return n
        except ValueError: pass
        print(f"{YELLOW}กรุณากรอกตัวเลข 0-3650{RESET}")

def random_password(n=12):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))

# ===== ฟังก์ชันจัดการผู้ใช้ =====
def add_user():
    clear(); title("เพิ่มผู้ใช้")
    c, d = sync_imported()
    name = input("ชื่อลูกค้า : ").strip() or "ลูกค้า"
    pw = input("รหัสผ่าน (กด Enter = สุ่ม): ").strip() or random_password()
    if pw in d["users"] or pw in c["auth"]["config"]:
        print(f"\n{RED}รหัสผ่านนี้มีอยู่แล้ว{RESET}"); pause(); return
    days = ask_days()
    now = int(time.time())
    exp = None if days == 0 else now + days * 86400
    d["users"][pw] = {"name": name, "created_at": now, "expires_at": exp, "source": "manager"}
    c["auth"]["config"].append(pw)
    atomic_write(DB, d); atomic_write(CONF, c)
    ok = restart_zivpn()
    print(); rule()
    print(f"{GREEN}{BOLD}✓ เพิ่มผู้ใช้สำเร็จ{RESET}")
    print(f"ชื่อ: {name} | รหัสผ่าน: {BOLD}{pw}{RESET}")
    print(f"วันหมดอายุ: {fmt_ts(exp)} ({left(exp)})")
    rule(); pause()

def delete_user():
    clear(); title("ลบผู้ใช้")
    c, d = sync_imported()
    pw = input("รหัสผ่าน : ").strip()
    if pw not in d["users"] and pw not in c["auth"]["config"]:
        print(f"\n{RED}ไม่พบผู้ใช้{RESET}"); pause(); return
    meta = d["users"].get(pw, {})
    print(f"ชื่อ: {meta.get('name','-')} | รหัสผ่าน: {pw}")
    ans = input(f"\n{RED}ยืนยันการลบ? [ใช่/ไม่]: {RESET}").strip().lower()
    if ans not in ("ใช่", "y"): return
    c["auth"]["config"] = [x for x in c["auth"]["config"] if x != pw]
    d["users"].pop(pw, None)
    atomic_write(DB, d); atomic_write(CONF, c)
    restart_zivpn()
    print(f"\n{GREEN}✓ ลบสำเร็จ{RESET}"); pause()

def renew_user():
    clear(); title("ต่ออายุผู้ใช้")
    c, d = sync_imported()
    pw = input("รหัสผ่าน : ").strip()
    if pw not in d["users"]:
        print(f"\n{RED}ไม่พบผู้ใช้{RESET}"); pause(); return
    meta = d["users"][pw]
    print(f"ชื่อ: {meta.get('name','-')} | วันหมดอายุปัจจุบัน: {fmt_ts(meta.get('expires_at'))}")
    days = ask_days("เพิ่มจำนวนวัน (0 = ไม่มีวันหมด): ")
    now = int(time.time())
    if days == 0: meta["expires_at"] = None
    else:
        old = meta.get("expires_at")
        base = max(now, int(old)) if old is not None else now
        meta["expires_at"] = base + days * 86400
    if pw not in c["auth"]["config"]: c["auth"]["config"].append(pw)
    atomic_write(DB, d); atomic_write(CONF, c)
    restart_zivpn()
    print(f"\n{GREEN}✓ อัปเดตสำเร็จ | วันหมดอายุใหม่: {fmt_ts(meta.get('expires_at'))}{RESET}")
    pause()

def list_users():
    clear(); title("รายการผู้ใช้ปัจจุบัน")
    c, d = sync_imported()
    configured = set(c["auth"]["config"])
    up = service_active()
    print(f"เซิร์ฟเวอร์: {GREEN if up else RED}{'ออนไลน์' if up else 'ออฟไลน์'}{RESET} | ผู้ใช้: {len(d['users'])}")
    rule()
    if not d["users"]: print("ยังไม่มีผู้ใช้"); pause(); return
    items = sorted(d["users"].items(), key=lambda x: (x[1].get("name","").lower(), x[0].lower()))
    for i, (pw, meta) in enumerate(items, 1):
        st, allowed = state(pw, meta, configured, up)
        print(f"{BOLD}{CYAN}[{i}] {meta.get('name','-')}{RESET}")
        print(f"    รหัสผ่าน: {BOLD}{pw}{RESET} | วันหมดอายุ: {fmt_ts(meta.get('expires_at'))}")
        print(f"    สถานะ: {state_color(st)}{st}{RESET} | เข้าใช้: {GREEN if allowed else RED}{'ได้' if allowed else 'ไม่ได้'}{RESET}")
        if i != len(items): print(GRAY + "·" * term_width() + RESET)
    rule(); pause()

def check_user():
    clear(); title("ตรวจสอบสิทธิ์ผู้ใช้")
    c, d = sync_imported()
    pw = input("รหัสผ่าน : ").strip()
    meta = d["users"].get(pw)
    if not meta: print(f"\n{RED}ไม่พบผู้ใช้{RESET}"); pause(); return
    st, allowed = state(pw, meta, set(c["auth"]["config"]), service_active())
    print(); rule()
    print(f"ชื่อ: {meta.get('name','-')} | รหัสผ่าน: {pw}")
    print(f"วันหมดอายุ: {fmt_ts(meta.get('expires_at'))} | เหลือ: {left(meta.get('expires_at'))}")
    print(f"สถานะ: {state_color(st)}{st}{RESET} | ใช้งาน: {GREEN if allowed else RED}{'ได้' if allowed else 'ไม่ได้'}{RESET}")
    rule(); pause()

def cleanup(silent=False):
    c, d = sync_imported()
    now = int(time.time()); expired = []
    for pw, meta in d["users"].items():
        exp = meta.get("expires_at")
        if exp is not None and int(exp) <= now and pw in c["auth"]["config"]: expired.append(pw)
    if expired:
        c["auth"]["config"] = [x for x in c["auth"]["config"] if x not in expired]
        atomic_write(CONF, c); restart_zivpn()
    if not silent:
        clear(); title("ทำความสะอาดผู้ใช้ที่หมดอายุ")
        if expired:
            print(f"{GREEN}ปิดใช้งาน {len(expired)} คน:{RESET}")
            for x in expired: print(f"  • {x}")
        else: print(f"{GREEN}✓ ไม่มีผู้ใช้ที่หมดอายุ{RESET}")
        pause()
    return len(expired)

def online_data():
    if not has_cmd("conntrack"): return None
    p = run(["conntrack", "-L", "-p", "udp"])
    data = defaultdict(lambda: {"flows": 0, "src_ports": set(), "dst_ports": set()})
    for line in p.stdout.splitlines():
        sm = re.search(r"\bsrc=([0-9a-fA-F:.]+)", line)
        sp = re.search(r"\bsport=(\d+)", line)
        dp = re.search(r"\bdport=(\d+)", line)
        if not (sm and sp and dp): continue
        src, sport, dport = sm.group(1), int(sp.group(1)), int(dp.group(1))
        if dport != 5667 and not (6000 <= dport <= 19999): continue
        if src in ("127.0.0.1", "::1"): continue
        data[src]["flows"] += 1
        data[src]["src_ports"].add(sport)
        data[src]["dst_ports"].add(dport)
    return data

def online_clients():
    clear(); title("ผู้ใช้ที่ออนไลน์อยู่")
    data = online_data()
    if data is None: print(f"{YELLOW}ยังไม่ได้ติดตั้ง conntrack{RESET}"); pause(); return
    if not data: print(f"{YELLOW}ไม่พบผู้ใช้ที่กำลังเชื่อมต่อ{RESET}"); pause(); return
    print(f"จำนวน IP: {BOLD}{GREEN}{len(data)}{RESET} | การเชื่อมต่อ: {sum(v['flows'] for v in data.values())}")
    rule()
    for i, (ip, info) in enumerate(sorted(data.items(), key=lambda x: (-x[1]["flows"], x[0])), 1):
        print(f"{GREEN}{BOLD}● [{i}] {ip}{RESET} | Flows: {info['flows']}")
    rule(); pause()

# ===== ฟังก์ชันจัดการเซิร์ฟเวอร์ =====
def server_status_full():
    clear(); title("สถานะเซิร์ฟเวอร์")
    up = service_active()
    listen = False
    if has_cmd("ss"): listen = ":5667" in run(["ss","-ulnp"]).stdout
    elif has_cmd("netstat"): listen = ":5667" in run(["netstat","-ulnp"]).stdout
    data = online_data()
    print(f"ZiVPN: {GREEN if up else RED}{'ทำงาน' if up else 'หยุด'}{RESET}")
    print(f"ระบบบริการ: {'systemd' if use_systemd() else 'SysVinit'}")
    print(f"UDP 5667: {GREEN if listen else RED}{'กำลังรับฟัง' if listen else 'ไม่พบ'}{RESET}")
    if data is not None: print(f"IP ออนไลน์: {len(data)}")
    rule()
    if use_systemd(): print(run(["systemctl", "status", "zivpn", "--no-pager"]).stdout)
    else: print(run(["/etc/init.d/zivpn", "status"]).stdout)
    pause()

def server_start():
    clear(); title("เริ่มเซิร์ฟเวอร์")
    if service_active(): print(f"{YELLOW}กำลังทำงานอยู่แล้ว{RESET}")
    elif service_action("start"): print(f"{GREEN}✓ เริ่มสำเร็จ{RESET}")
    else: print(f"{RED}เริ่มไม่สำเร็จ{RESET}")
    pause()

def server_stop():
    clear(); title("หยุดเซิร์ฟเวอร์")
    if not service_active(): print(f"{YELLOW}หยุดทำงานอยู่แล้ว{RESET}")
    elif service_action("stop"): print(f"{GREEN}✓ หยุดสำเร็จ{RESET}")
    else: print(f"{RED}หยุดไม่สำเร็จ{RESET}")
    pause()

def server_restart():
    clear(); title("รีสตาร์ทเซิร์ฟเวอร์")
    if restart_zivpn(): print(f"{GREEN}✓ รีสตาร์ทสำเร็จ{RESET}")
    else: print(f"{RED}รีสตาร์ทไม่สำเร็จ{RESET}")
    pause()

def server_logs():
    clear(); title("บันทึกการทำงานล่าสุด")
    if use_systemd(): print(run(["journalctl", "-u", "zivpn", "-n", "40", "--no-pager"]).stdout)
    elif os.path.isfile("/var/log/zivpn.log"): print(run(["tail", "-n", "40", "/var/log/zivpn.log"]).stdout)
    else: print(f"{YELLOW}ไม่พบไฟล์บันทึก{RESET}")
    pause()

def server_config():
    clear(); title("ไฟล์กำหนดค่า")
    try: print(open(CONF).read())
    except FileNotFoundError: print(f"{RED}ไม่พบไฟล์กำหนดค่า{RESET}")
    pause()

# ===== เมนูหลัก =====
def menu_header():
    c, d = sync_imported()
    configured = set(c["auth"]["config"])
    now = int(time.time())
    active = sum(1 for pw, m in d["users"].items() if pw in configured and (m.get("expires_at") is None or int(m["expires_at"]) > now))
    expired = sum(1 for m in d["users"].values() if m.get("expires_at") is not None and int(m["expires_at"]) <= now)
    clear(); title("เมนูหลัก ZiVPN")
    up = service_active()
    print(f"เซิร์ฟเวอร์ {GREEN if up else RED}{'● ออนไลน์' if up else '● ออฟไลน์'}{RESET} | ผู้ใช้ใช้งานได้ {BOLD}{active}{RESET} | หมดอายุ {expired}")
    rule()

def main_menu():
    cleanup(silent=True)
    while True:
        menu_header()
        print(f"{BOLD}{CYAN}═══ จัดการผู้ใช้ ═══{RESET}")
        print(f"{CYAN}[1]{RESET} เพิ่มผู้ใช้  {CYAN}[2]{RESET} ลบผู้ใช้  {CYAN}[3]{RESET} รายการผู้ใช้")
        print(f"{CYAN}[4]{RESET} ต่ออายุ  {CYAN}[5]{RESET} ตรวจสอบสิทธิ์  {CYAN}[6]{RESET} ผู้ใช้ออนไลน์  {CYAN}[7]{RESET} ทำความสะอาด")
        print()
        print(f"{BOLD}{CYAN}═══ จัดการเซิร์ฟเวอร์ ═══{RESET}")
        print(f"{CYAN}[8]{RESET} สถานะ  {CYAN}[9]{RESET} เริ่ม  {CYAN}[10]{RESET} หยุด  {CYAN}[11]{RESET} รีสตาร์ท")
        print(f"{CYAN}[12]{RESET} บันทึกการทำงาน  {CYAN}[13]{RESET} แสดงไฟล์กำหนดค่า")
        print()
        print(f"{GRAY}[0] ออกจากเมนู{RESET}")
        rule()
        ch = input(f"{BOLD}เลือกเมนู › {RESET}").strip()
        if ch=="1": add_user()
        elif ch=="2": delete_user()
        elif ch=="3": list_users()
        elif ch=="4": renew_user()
        elif ch=="5": check_user()
        elif ch=="6": online_clients()
        elif ch=="7": cleanup()
        elif ch=="8": server_status_full()
        elif ch=="9": server_start()
        elif ch=="10": server_stop()
        elif ch=="11": server_restart()
        elif ch=="12": server_logs()
        elif ch=="13": server_config()
        elif ch=="0": clear(); print(f"{GREEN}ออกจากเมนู ZiVPN แล้ว{RESET}"); return
        else: time.sleep(.3)

def main():
    if os.geteuid() != 0: print("กรุณารันด้วยสิทธิ์ root"); sys.exit(1)
    if len(sys.argv) > 1 and sys.argv[1] == "--expire": cleanup(silent=True); return
    sync_imported(); main_menu()

if __name__ == "__main__": main()
MAINMENU
chmod 700 /usr/local/bin/menu

# ลบไฟล์เมนูแยกเดิม
rm -f /usr/local/bin/zimenu /usr/local/bin/zivpnmenu

# ========== [8/9] เปิดใช้งานบริการ ==========
echo "[8/9] เปิดใช้งานบริการ..."

if use_systemd; then
  systemctl daemon-reload
  systemctl enable zivpn.service 2>/dev/null || true
  systemctl restart zivpn.service 2>/dev/null || true
  systemctl enable --now zimanager-expire.timer 2>/dev/null || true
else
  if has_cmd update-rc.d; then
    update-rc.d zivpn defaults 2>/dev/null || true
  elif has_cmd chkconfig; then
    chkconfig --add zivpn 2>/dev/null; chkconfig zivpn on 2>/dev/null || true
  fi
  /etc/init.d/zivpn restart 2>/dev/null || true
  has_cmd service && (service cron restart 2>/dev/null || service crond restart 2>/dev/null || true)
fi

/usr/local/bin/menu --expire 2>/dev/null || true

# ========== [9/9] ตรวจสอบขั้นสุดท้าย ==========
echo "[9/9] ตรวจสอบขั้นสุดท้าย..."
sleep 2

if service_active; then
  SERVER_STATUS="ออนไลน์"
else
  SERVER_STATUS="ไม่สำเร็จ"
fi

PORT_STATUS="ไม่พบ"
if has_cmd ss; then
  ss -ulnp 2>/dev/null | grep -q ':5667' && PORT_STATUS="กำลังรับฟัง"
elif has_cmd netstat; then
  netstat -ulnp 2>/dev/null | grep -q ':5667' && PORT_STATUS="กำลังรับฟัง"
fi

IP="$(get_server_ip)"

WEB80_STATUS="ไม่พบ"
if has_cmd ss; then
  ss -H -ltnp 2>/dev/null | grep -qE '(^|[[:space:]])[^[:space:]]*:80[[:space:]]' && WEB80_STATUS="ยังทำงานปกติ"
elif has_cmd netstat; then
  netstat -ltnp 2>/dev/null | grep -qE ':80[[:space:]]' && WEB80_STATUS="ยังทำงานปกติ"
fi

echo
echo "=========================================="
echo "        ติดตั้งเสร็จสมบูรณ์"
echo "=========================================="
echo "ระบบปฏิบัติการ: ${OS_ID} ${OS_VERSION}"
echo "ระบบบริการ    : $(use_systemd && echo 'systemd' || echo 'SysVinit')"
echo "IP เซิร์ฟเวอร์ : ${IP}"
echo "ZiVPN         : $SERVER_STATUS"
echo "UDP 5667      : $PORT_STATUS"
echo "ช่วงพอร์ต UDP : 6000-19999"
echo "TCP 80        : $WEB80_STATUS"
echo
echo "คำสั่งใช้งาน: menu"
echo
echo "สำคัญ: หากมี Cloud Firewall ให้อนุญาต UDP 5667 และ UDP 6000-19999"
echo
echo "พิมพ์: menu"
echo "=========================================="

if [ "$SERVER_STATUS" != "ออนไลน์" ]; then
  echo
  echo "ZiVPN ไม่สามารถเริ่มทำงานได้ ตรวจสอบด้วย:"
  if use_systemd; then
    echo "journalctl -u zivpn -n 80 --no-pager"
  else
    echo "tail -n 80 /var/log/zivpn.log"
  fi
  exit 1
fi
