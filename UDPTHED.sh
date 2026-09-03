#!/bin/bash
set -euo pipefail

ZIVPN_VERSION="1.4.9"
BASE_DIR="/etc/zivpn"
CONF="$BASE_DIR/config.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ "$(id -u)" -ne 0 ]; then
  echo "ผิดพลาด: กรุณารันสคริปต์นี้ด้วยสิทธิ์ root"
  exit 1
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      echo "คำเตือน: สคริปต์ติดตั้งนี้ออกแบบมาสำหรับ Ubuntu/Debian"
      read -r -p "ต้องการดำเนินการต่อหรือไม่? [ใช่/ไม่]: " ans
      [[ "${ans,,}" == "ใช่" || "${ans,,}" == "y" ]] || exit 1
      ;;
  esac
fi

case "$(uname -m)" in
  x86_64|amd64)
    ARCH="amd64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ;;
  *)
    echo "ผิดพลาด: สถาปัตยกรรมไม่รองรับ: $(uname -m)"
    exit 1
    ;;
esac

echo
echo "=========================================="
echo "   ZiVPN ครบถ้วน - ปลอดภัยสำหรับเว็บไซต์"
echo "=========================================="
echo "สถาปัตยกรรม : $ARCH"
echo "พอร์ต ZiVPN  : UDP 5667"
echo "ช่วงพอร์ตสาธารณะ : UDP 6000-19999"
echo "ตัวจัดการผู้ใช้ : มี"
echo "ระบบวันหมดอายุ : มี"
echo "เมนูหลัก    : พิมพ์ menu"
echo "ไฟร์วอลล์   : iptables NAT เท่านั้น"
echo "บริการเว็บ  : ไม่มีการแก้ไข"
echo "=========================================="
echo

if [ -d "$BASE_DIR" ]; then
  BACKUP="/root/zivpn-backup-$STAMP"
  echo "[1/9] สำรองข้อมูล ZiVPN ที่มีอยู่ -> $BACKUP"
  cp -a "$BASE_DIR" "$BACKUP"
else
  echo "[1/9] ไม่พบไฟล์กำหนดค่า ZiVPN เดิม"
fi

echo "[2/9] กำลังติดตั้งแพ็กเกจที่จำเป็น..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl openssl iptables python3 conntrack ca-certificates

echo "[2b/9] สำรองกฎไฟร์วอลล์เดิม..."
iptables-save > "/root/iptables-before-zivpn-$STAMP.rules"
if command -v ip6tables-save >/dev/null 2>&1; then
  ip6tables-save > "/root/ip6tables-before-zivpn-$STAMP.rules" || true
fi

echo "[2c/9] ตรวจสอบความขัดแย้งของพอร์ต UDP..."

ZIVPN_5667_LINE="$(ss -H -ulnp 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:5667[[:space:]]' || true)"
if [ -n "$ZIVPN_5667_LINE" ] && ! printf '%s\n' "$ZIVPN_5667_LINE" | grep -qi 'zivpn'; then
  echo
  echo "ผิดพลาด: พอร์ต UDP 5667 ถูกใช้งานโดยบริการอื่นแล้ว:"
  printf '%s\n' "$ZIVPN_5667_LINE"
  echo "หยุดการติดตั้ง บริการเว็บไซต์ไม่มีการเปลี่ยนแปลงใดๆ"
  exit 1
fi

RANGE_CONFLICTS="$(
  ss -H -ulnp 2>/dev/null | while IFS= read -r line; do
    addr="$(printf '%s\n' "$line" | awk '{print $5}')"
    port="${addr##*:}"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 6000 ] && [ "$port" -le 19999 ]; then
      printf '%s\n' "$line"
    fi
  done
)"

if [ -n "$RANGE_CONFLICTS" ]; then
  echo
  echo "ผิดพลาด: มีบริการ UDP ที่ใช้พอร์ตในช่วง 6000-19999 อยู่แล้ว:"
  printf '%s\n' "$RANGE_CONFLICTS"
  echo
  echo "หยุดการติดตั้งเพื่อปกป้องบริการที่มีอยู่"
  exit 1
fi

echo "[3/9] กำลังติดตั้งไฟล์โปรแกรม ZiVPN..."
curl -fL "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_${ZIVPN_VERSION}/udp-zivpn-linux-${ARCH}" \
  -o /usr/local/bin/zivpn
chmod 755 /usr/local/bin/zivpn

mkdir -p "$BASE_DIR"
chmod 700 "$BASE_DIR"

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

if [ ! -f "$CONF" ]; then
  echo
  read -r -p "รหัสผ่านเริ่มต้น (คั่นด้วยเครื่องหมายจุลภาค) [ค่าเริ่มต้น: zi]: " INITIAL_PASSWORDS
  INITIAL_PASSWORDS="${INITIAL_PASSWORDS:-zi}"
  python3 - "$INITIAL_PASSWORDS" <<'PY'
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

cat > /usr/local/sbin/zivpn-firewall <<'EOF'
#!/bin/bash
set -e

NIC="$(ip -4 route show default | awk '{print $5; exit}')"
[ -n "$NIC" ] || {
  echo "ZiVPN: ไม่พบอินเทอร์เฟซเครือข่ายเริ่มต้น" >&2
  exit 1
}

# ปลอดภัยสำหรับเว็บไซต์: เพิ่มกฎ NAT สำหรับ UDP ของ ZiVPN เท่านั้น
# ห้ามแก้ไขนโยบาย INPUT/FORWARD, UFW, nginx, TCP 80/443, Node หรือ PostgreSQL
iptables -t nat -C PREROUTING -i "$NIC" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$NIC" -p udp --dport 6000:19999 -j DNAT --to-destination :5667
EOF
chmod 755 /usr/local/sbin/zivpn-firewall

cat > /etc/systemd/system/zivpn-firewall.service <<'EOF'
[Unit]
Description=กฎ NAT UDP ของ ZiVPN (ปลอดภัยสำหรับเว็บไซต์)
After=network-online.target
Wants=network-online.target
Before=zivpn.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zivpn-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/sysctl.d/99-zivpn.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl --system >/dev/null 2>&1 || true

echo "[6/9] กำลังติดตั้งเมนูหลัก (รวมทุกฟังก์ชัน)..."
cat > /usr/local/bin/menu <<'MAINMENU'
#!/usr/bin/env python3
import json
import os
import re
import secrets
import shutil
import string
import subprocess
import sys
import tempfile
import time
from collections import defaultdict
from datetime import datetime

CONF = "/etc/zivpn/config.json"
DB = "/etc/zivpn/users.json"
TZ = "Asia/Bangkok"

os.environ["TZ"] = TZ
try:
    time.tzset()
except AttributeError:
    pass

RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
GREEN="\033[92m"; YELLOW="\033[93m"; RED="\033[91m"
CYAN="\033[96m"; GRAY="\033[90m"

if not sys.stdout.isatty() or os.getenv("TERM", "") == "dumb":
    RESET=BOLD=DIM=GREEN=YELLOW=RED=CYAN=GRAY=""

def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def clear():
    if sys.stdout.isatty():
        print("\033[2J\033[H", end="")

def term_width():
    try:
        return max(42, min(shutil.get_terminal_size((60, 20)).columns, 72))
    except Exception:
        return 60

def rule(ch="─"):
    print(GRAY + ch * term_width() + RESET)

def title(text):
    rule("═")
    print(f"{BOLD}{CYAN}{text.center(term_width())}{RESET}")
    rule("═")

def pause():
    try:
        input(f"\n{DIM}กด Enter เพื่อกลับเมนูหลัก...{RESET}")
    except EOFError:
        pass

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
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as e:
        print(f"{RED}JSON ไม่ถูกต้อง: {path}: {e}{RESET}")
        sys.exit(1)

def load_conf():
    c = load_json(CONF, None)
    if c is None:
        print(f"{RED}ไม่พบไฟล์กำหนดค่า ZiVPN: {CONF}{RESET}")
        sys.exit(1)
    c.setdefault("auth", {}).setdefault("config", [])
    if not isinstance(c["auth"]["config"], list):
        print(f"{RED}auth.config ต้องเป็นรายการ{RESET}")
        sys.exit(1)
    c["auth"]["config"] = list(dict.fromkeys(str(x) for x in c["auth"]["config"]))
    return c

def load_db():
    d = load_json(DB, {"version": 2, "users": {}})
    d.setdefault("version", 2)
    d.setdefault("users", {})
    return d

def sync_imported():
    c = load_conf()
    d = load_db()
    now = int(time.time())
    changed = False
    for pw in c["auth"]["config"]:
        if pw not in d["users"]:
            d["users"][pw] = {
                "name": "นำเข้า",
                "created_at": now,
                "expires_at": None,
                "source": "existing-config"
            }
            changed = True
    if changed:
        atomic_write(DB, d)
    return c, d

def service_active():
    return run(["systemctl", "is-active", "--quiet", "zivpn"]).returncode == 0

def restart_zivpn():
    p = run(["systemctl", "restart", "zivpn"])
    if p.returncode != 0:
        print(f"{RED}รีสตาร์ท ZiVPN ไม่สำเร็จ{RESET}")
        if p.stderr.strip():
            print(p.stderr.strip())
        return False
    return True

def start_zivpn():
    p = run(["systemctl", "start", "zivpn"])
    return p.returncode == 0

def stop_zivpn():
    p = run(["systemctl", "stop", "zivpn"])
    return p.returncode == 0

def fmt_ts(ts):
    if ts is None:
        return "ไม่มีวันหมด"
    return datetime.fromtimestamp(int(ts)).strftime("%d/%m/%y %H:%M")

def left(ts):
    if ts is None:
        return "ไม่จำกัด"
    sec = int(ts) - int(time.time())
    if sec <= 0:
        return "หมดอายุแล้ว"
    d, rem = divmod(sec, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d: return f"{d}วัน {h}ชม."
    if h: return f"{h}ชม. {m}นาที"
    return f"{m}นาที"

def state(pw, meta, configured, server_up):
    exp = meta.get("expires_at")
    if exp is not None and int(exp) <= int(time.time()):
        return "หมดอายุ", False
    if pw not in configured:
        return "ปิดใช้งาน", False
    if not server_up:
        return "เซิร์ฟเวอร์ดาวน์", False
    return "ใช้งานได้", True

def state_color(s):
    if s == "ใช้งานได้": return GREEN
    if s in ("หมดอายุ", "เซิร์ฟเวอร์ดาวน์"): return RED
    return YELLOW

def ask_days(prompt="จำนวนวันที่ใช้งาน (0 = ไม่มีวันหมด): "):
    while True:
        try:
            n = int(input(prompt).strip())
            if 0 <= n <= 3650:
                return n
        except ValueError:
            pass
        print(f"{YELLOW}กรุณากรอกตัวเลข 0-3650{RESET}")

def random_password(n=12):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))

# ========== ฟังก์ชันจัดการผู้ใช้ ==========

def add_user():
    clear(); title("เพิ่มผู้ใช้")
    c, d = sync_imported()
    name = input("ชื่อลูกค้า : ").strip() or "ลูกค้า"
    pw = input("รหัสผ่าน (กด Enter = สุ่มอัตโนมัติ): ").strip() or random_password()
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
    print(f"ชื่อ       : {name}")
    print(f"รหัสผ่าน  : {BOLD}{pw}{RESET}")
    print(f"วันหมดอายุ: {fmt_ts(exp)} ({left(exp)})")
    print(f"สถานะ    : {GREEN if ok else RED}{'เปิดใช้งาน' if ok else 'เซิร์ฟเวอร์ผิดพลาด'}{RESET}")
    rule(); pause()

def delete_user():
    clear(); title("ลบผู้ใช้")
    c, d = sync_imported()
    pw = input("รหัสผ่าน : ").strip()
    if pw not in d["users"] and pw not in c["auth"]["config"]:
        print(f"\n{RED}ไม่พบผู้ใช้{RESET}"); pause(); return
    meta = d["users"].get(pw, {})
    print(f"ชื่อ       : {meta.get('name','-')}")
    print(f"รหัสผ่าน  : {pw}")
    if input(f"\n{RED}ยืนยันการลบถาวร? [ใช่/ไม่]: {RESET}").strip().lower() not in ("ใช่", "y"):
        return
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
    print(f"ชื่อ              : {meta.get('name','-')}")
    print(f"วันหมดอายุปัจจุบัน: {fmt_ts(meta.get('expires_at'))} ({left(meta.get('expires_at'))})")
    days = ask_days("เพิ่มจำนวนวัน (0 = ไม่มีวันหมด): ")
    now = int(time.time())
    if days == 0:
        meta["expires_at"] = None
    else:
        old = meta.get("expires_at")
        base = max(now, int(old)) if old is not None else now
        meta["expires_at"] = base + days * 86400
    if pw not in c["auth"]["config"]:
        c["auth"]["config"].append(pw)
    atomic_write(DB, d); atomic_write(CONF, c)
    restart_zivpn()
    print(f"\n{GREEN}✓ อัปเดตสำเร็จ{RESET}")
    print(f"วันหมดอายุใหม่: {fmt_ts(meta.get('expires_at'))} ({left(meta.get('expires_at'))})")
    pause()

def list_users():
    clear(); title("รายการผู้ใช้ปัจจุบัน")
    c, d = sync_imported()
    configured = set(c["auth"]["config"])
    up = service_active()
    print(f"เซิร์ฟเวอร์ : {GREEN if up else RED}{'ออนไลน์' if up else 'ออฟไลน์'}{RESET}")
    print(f"จำนวนผู้ใช้ : {len(d['users'])}")
    print(f"เขตเวลา     : {TZ}")
    rule()
    if not d["users"]:
        print("ยังไม่มีผู้ใช้"); pause(); return
    items = sorted(d["users"].items(), key=lambda x: (x[1].get("name","").lower(), x[0].lower()))
    for i, (pw, meta) in enumerate(items, 1):
        st, allowed = state(pw, meta, configured, up)
        print(f"{BOLD}{CYAN}[{i}] {meta.get('name','-')}{RESET}")
        print(f"    รหัสผ่าน  : {BOLD}{pw}{RESET}")
        print(f"    วันหมดอายุ: {fmt_ts(meta.get('expires_at'))} ({left(meta.get('expires_at'))})")
        print(f"    สถานะ    : {state_color(st)}{st}{RESET} | เข้าใช้: {GREEN if allowed else RED}{'ได้' if allowed else 'ไม่ได้'}{RESET}")
        if i != len(items):
            print(GRAY + "·" * term_width() + RESET)
    rule(); pause()

def check_user():
    clear(); title("ตรวจสอบสิทธิ์ผู้ใช้")
    c, d = sync_imported()
    pw = input("รหัสผ่าน : ").strip()
    meta = d["users"].get(pw)
    if not meta:
        print(f"\n{RED}ไม่พบผู้ใช้{RESET}"); pause(); return
    st, allowed = state(pw, meta, set(c["auth"]["config"]), service_active())
    print(); rule()
    print(f"ชื่อ          : {meta.get('name','-')}")
    print(f"รหัสผ่าน      : {pw}")
    print(f"วันหมดอายุ    : {fmt_ts(meta.get('expires_at'))}")
    print(f"เวลาที่เหลือ   : {left(meta.get('expires_at'))}")
    print(f"สถานะ        : {state_color(st)}{st}{RESET}")
    print(f"สามารถใช้งาน : {GREEN if allowed else RED}{'ได้' if allowed else 'ไม่ได้'}{RESET}")
    rule(); pause()

def cleanup(silent=False):
    c, d = sync_imported()
    now = int(time.time())
    expired = []
    for pw, meta in d["users"].items():
        exp = meta.get("expires_at")
        if exp is not None and int(exp) <= now and pw in c["auth"]["config"]:
            expired.append(pw)
    if expired:
        c["auth"]["config"] = [x for x in c["auth"]["config"] if x not in expired]
        atomic_write(CONF, c)
        restart_zivpn()
    if not silent:
        clear(); title("ทำความสะอาดผู้ใช้ที่หมดอายุ")
        if expired:
            print(f"{GREEN}ปิดใช้งานผู้ใช้ที่หมดอายุ {len(expired)} คน:{RESET}")
            for x in expired: print(f"  • {x}")
        else:
            print(f"{GREEN}✓ ไม่มีผู้ใช้ที่หมดอายุ{RESET}")
        pause()
    return len(expired)

def online_data():
    if run(["sh", "-c", "command -v conntrack >/dev/null 2>&1"]).returncode != 0:
        return None
    p = run(["conntrack", "-L", "-p", "udp"])
    data = defaultdict(lambda: {"flows": 0, "src_ports": set(), "dst_ports": set()})
    for line in p.stdout.splitlines():
        sm = re.search(r"\bsrc=([0-9a-fA-F:.]+)", line)
        sp = re.search(r"\bsport=(\d+)", line)
        dp = re.search(r"\bdport=(\d+)", line)
        if not (sm and sp and dp):
            continue
        src = sm.group(1); sport = int(sp.group(1)); dport = int(dp.group(1))
        if dport != 5667 and not (6000 <= dport <= 19999):
            continue
        if src in ("127.0.0.1", "::1"):
            continue
        data[src]["flows"] += 1
        data[src]["src_ports"].add(sport)
        data[src]["dst_ports"].add(dport)
    return data

def summarize_ports(ports):
    p = sorted(ports)
    if not p: return "-"
    if len(p) <= 4: return ",".join(map(str,p))
    return f"{p[0]}-{p[-1]} ({len(p)})"

def online_clients():
    clear(); title("ผู้ใช้ที่ออนไลน์อยู่")
    data = online_data()
    if data is None:
        print(f"{YELLOW}ยังไม่ได้ติดตั้ง conntrack{RESET}"); pause(); return
    if not data:
        print(f"{YELLOW}ไม่พบผู้ใช้ ZiVPN ที่กำลังเชื่อมต่อ{RESET}"); pause(); return
    print(f"จำนวน IP ที่ออนไลน์ : {BOLD}{GREEN}{len(data)}{RESET}")
    print(f"จำนวนการเชื่อมต่อ UDP : {sum(v['flows'] for v in data.values())}")
    rule()
    for i, (ip, info) in enumerate(sorted(data.items(), key=lambda x: (-x[1]["flows"], x[0])), 1):
        dports = sorted(info["dst_ports"])
        target = str(dports[0]) if len(dports) == 1 else f"{dports[0]}-{dports[-1]}"
        print(f"{GREEN}{BOLD}● [{i}] {ip}{RESET}")
        print(f"    จำนวนการเชื่อมต่อ : {info['flows']}")
        print(f"    พอร์ตต้นทาง     : {summarize_ports(info['src_ports'])}")
        print(f"    พอร์ตปลายทาง   : {target}")
        if i != len(data): print(GRAY + "·" * term_width() + RESET)
    rule()
    print(f"{DIM}แสดงแต่ละ IP เพียงครั้งเดียว ไม่สามารถระบุรหัสผ่านที่ตรงกับ IP ได้แม่นยำ{RESET}")
    pause()

# ========== ฟังก์ชันจัดการเซิร์ฟเวอร์ ==========

def server_status_full():
    clear(); title("สถานะเซิร์ฟเวอร์")
    up = service_active()
    enabled = run(["systemctl","is-enabled","zivpn"]).stdout.strip() or "ไม่ทราบ"
    ss = run(["ss","-ulnp"]).stdout
    listen = any(":5667" in x for x in ss.splitlines())
    timer = run(["systemctl","is-active","--quiet","zimanager-expire.timer"]).returncode == 0
    data = online_data()
    print(f"ZiVPN          : {GREEN if up else RED}{'ทำงาน' if up else 'หยุด'}{RESET}")
    print(f"เปิดอัตโนมัติ : {enabled}")
    print(f"UDP 5667       : {GREEN if listen else RED}{'กำลังรับฟัง' if listen else 'ไม่พบ'}{RESET}")
    print(f"ตัวจับเวลาวันหมดอายุ: {GREEN if timer else RED}{'ทำงาน' if timer else 'หยุด'}{RESET}")
    if data is not None: print(f"จำนวน IP ที่ออนไลน์: {len(data)}")
    print()
    print("รายละเอียด systemctl status:")
    rule()
    p = run(["systemctl", "status", "zivpn", "--no-pager"])
    print(p.stdout)
    if p.stderr.strip():
        print(p.stderr)
    rule()
    print("พอร์ต UDP ที่กำลังรับฟัง:")
    p2 = run(["sh", "-c", "ss -ulnp | grep ':5667' || echo 'ไม่พบ'"])
    print(p2.stdout.strip())
    rule()
    print("กฎ NAT iptables:")
    p3 = run(["sh", "-c", "iptables -t nat -L PREROUTING -n -v | grep '5667' || echo 'ไม่พบกฎ NAT'"])
    print(p3.stdout.strip())
    pause()

def server_start():
    clear(); title("เริ่มเซิร์ฟเวอร์ ZiVPN")
    if service_active():
        print(f"{YELLOW}ZiVPN กำลังทำงานอยู่แล้ว{RESET}")
    else:
        if start_zivpn():
            print(f"{GREEN}✓ เริ่ม ZiVPN สำเร็จ{RESET}")
        else:
            print(f"{RED}เริ่ม ZiVPN ไม่สำเร็จ{RESET}")
    pause()

def server_stop():
    clear(); title("หยุดเซิร์ฟเวอร์ ZiVPN")
    if not service_active():
        print(f"{YELLOW}ZiVPN หยุดทำงานอยู่แล้ว{RESET}")
    else:
        if stop_zivpn():
            print(f"{GREEN}✓ หยุด ZiVPN สำเร็จ{RESET}")
        else:
            print(f"{RED}หยุด ZiVPN ไม่สำเร็จ{RESET}")
    pause()

def server_restart():
    clear(); title("รีสตาร์ทเซิร์ฟเวอร์ ZiVPN")
    if restart_zivpn():
        print(f"{GREEN}✓ รีสตาร์ท ZiVPN สำเร็จ{RESET}")
    else:
        print(f"{RED}รีสตาร์ท ZiVPN ไม่สำเร็จ{RESET}")
    pause()

def server_logs():
    clear(); title("บันทึกการทำงานล่าสุด")
    p = run(["journalctl", "-u", "zivpn", "-n", "40", "--no-pager"])
    print(p.stdout)
    if p.stderr.strip():
        print(p.stderr)
    pause()

def server_config():
    clear(); title("ไฟล์กำหนดค่า ZiVPN")
    try:
        with open(CONF) as f:
            print(f.read())
    except FileNotFoundError:
        print(f"{RED}ไม่พบไฟล์กำหนดค่า{RESET}")
    pause()

# ========== เมนูหลัก ==========

def menu_header():
    c, d = sync_imported()
    configured = set(c["auth"]["config"])
    now = int(time.time())
    active_users = sum(
        1 for pw, meta in d["users"].items()
        if pw in configured and (meta.get("expires_at") is None or int(meta["expires_at"]) > now)
    )
    expired = sum(
        1 for meta in d["users"].values()
        if meta.get("expires_at") is not None and int(meta["expires_at"]) <= now
    )
    clear(); title("เมนูหลัก ZiVPN")
    up = service_active()
    print(f"เซิร์ฟเวอร์ {GREEN if up else RED}{'● ออนไลน์' if up else '● ออฟไลน์'}{RESET}   ผู้ใช้ใช้งานได้ {BOLD}{active_users}{RESET}   หมดอายุ {expired}")
    rule()

def main_menu():
    cleanup(silent=True)
    while True:
        menu_header()
        print(f"{BOLD}{CYAN}═══ จัดการผู้ใช้ ═══{RESET}")
        print(f"{CYAN}[1]{RESET} เพิ่มผู้ใช้")
        print(f"{CYAN}[2]{RESET} ลบผู้ใช้")
        print(f"{CYAN}[3]{RESET} รายการผู้ใช้ทั้งหมด")
        print(f"{CYAN}[4]{RESET} ต่ออายุ / เปลี่ยนวันหมดอายุ")
        print(f"{CYAN}[5]{RESET} ตรวจสอบสิทธิ์ผู้ใช้")
        print(f"{CYAN}[6]{RESET} ผู้ใช้ที่ออนไลน์อยู่")
        print(f"{CYAN}[7]{RESET} ทำความสะอาดผู้ใช้ที่หมดอายุ")
        print()
        print(f"{BOLD}{CYAN}═══ จัดการเซิร์ฟเวอร์ ═══{RESET}")
        print(f"{CYAN}[8]{RESET} ดูสถานะเซิร์ฟเวอร์")
        print(f"{CYAN}[9]{RESET} เริ่มเซิร์ฟเวอร์")
        print(f"{CYAN}[10]{RESET} หยุดเซิร์ฟเวอร์")
        print(f"{CYAN}[11]{RESET} รีสตาร์ทเซิร์ฟเวอร์")
        print(f"{CYAN}[12]{RESET} บันทึกการทำงานล่าสุด")
        print(f"{CYAN}[13]{RESET} แสดงไฟล์กำหนดค่า")
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
    if os.geteuid() != 0:
        print("กรุณารันด้วยสิทธิ์ root"); sys.exit(1)
    if len(sys.argv) > 1 and sys.argv[1] == "--expire":
        cleanup(silent=True); return
    sync_imported(); main_menu()

if __name__ == "__main__":
    main()
MAINMENU
chmod 700 /usr/local/bin/menu

# ลบไฟล์เมนูแยกเดิมถ้ามี (อัปเกรดจากเวอร์ชันเก่า)
rm -f /usr/local/bin/zimenu /usr/local/bin/zivpnmenu

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

echo "[7/9] เปิดใช้งานบริการ..."
systemctl daemon-reload
systemctl enable --now zivpn-firewall.service
systemctl enable zivpn.service
systemctl restart zivpn.service
systemctl enable --now zimanager-expire.timer
/usr/local/bin/menu --expire || true

echo "[8/9] ตรวจสอบขั้นสุดท้าย..."
sleep 1

if systemctl is-active --quiet zivpn; then
  SERVER_STATUS="ออนไลน์"
else
  SERVER_STATUS="ไม่สำเร็จ"
fi

if ss -ulnp | grep -q ':5667'; then
  PORT_STATUS="กำลังรับฟัง"
else
  PORT_STATUS="ไม่พบ"
fi

IP="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

NGINX80="$(ss -H -ltnp 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:80[[:space:]]' | head -n1 || true)"
WEB80_STATUS="ไม่พบ"
if [ -n "$NGINX80" ]; then WEB80_STATUS="ยังทำงานปกติ"; fi

echo
echo "=========================================="
echo "        ติดตั้งเสร็จสมบูรณ์"
echo "=========================================="
echo "IP เซิร์ฟเวอร์ : ${IP:-ไม่ทราบ}"
echo "ZiVPN       : $SERVER_STATUS"
echo "UDP 5667    : $PORT_STATUS"
echo "ช่วงพอร์ต UDP : 6000-19999"
echo "TCP 80      : $WEB80_STATUS"
echo "ไฟร์วอลล์   : เพียงกฎ NAT เท่านั้น; UFW ไม่มีการเปลี่ยนแปลง"
echo
echo "คำสั่งใช้งาน:"
echo "  menu       เปิดเมนูหลัก (รวมทุกฟังก์ชัน)"
echo
echo "รหัสผ่านเดิมจะถูกนำเข้าอัตโนมัติ"
echo "ไฟล์สำรอง iptables: /root/iptables-before-zivpn-$STAMP.rules"
echo
echo "สำคัญ: หากผู้ให้บริการ VPS มี Cloud Firewall/Security Group"
echo "กรุณาอนุญาตพอร์ต UDP 5667 และ UDP 6000-19999 ด้วย"
echo
echo "พิมพ์คำสั่ง: menu"
echo "=========================================="

if [ "$SERVER_STATUS" != "ออนไลน์" ]; then
  echo
  echo "ZiVPN ไม่สามารถเริ่มทำงานได้ ตรวจสอบด้วยคำสั่ง:"
  echo "journalctl -u zivpn -n 80 --no-pager"
  exit 1
fi
