#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/ovpn-bot"
SERVICE_NAME="ovpn-bot"

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[→]${NC} $1"; }

SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
MAIN_GW=$(ip route | grep default | awk '{print $3}' | head -1)

[[ $EUID -ne 0 ]] && error "Run as root."

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║       OpenVPN SOCKS5 Bot v3           ║"
echo "  ║     Xray Outbound Manager             ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"
echo "  Server IP : $SERVER_IP"
echo "  Interface : $MAIN_IFACE"
echo "  Gateway   : $MAIN_GW"
echo ""

read -p "Bot Token: " BOT_TOKEN
[[ -z "$BOT_TOKEN" ]] && error "Token required."
read -p "Admin ID #1: " ADMIN1
read -p "Admin ID #2 (blank to skip): " ADMIN2
ADMIN_IDS="$ADMIN1"
[[ -n "$ADMIN2" ]] && ADMIN_IDS="$ADMIN1, $ADMIN2"

info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq openvpn dante-server python3 python3-pip iproute2 curl
pip3 install python-telegram-bot --break-system-packages -q
log "Dependencies installed."

if ! id vpnuser &>/dev/null; then
    useradd -r -s /bin/false vpnuser
    log "Created vpnuser."
fi

if ! grep -q "^200 vpn$" /etc/iproute2/rt_tables; then
    echo "200 vpn" >> /etc/iproute2/rt_tables
    log "Added vpn routing table."
fi

mkdir -p "$INSTALL_DIR"

info "Writing bot..."
python3 -c "
import sys
bot = open('/dev/stdin').read()
open('$INSTALL_DIR/bot.py', 'w').write(bot)
" << 'BOTEOF'
import os, re, subprocess, socket, asyncio, logging, sqlite3, time
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, CallbackQueryHandler, filters, ContextTypes

logging.basicConfig(format='%(asctime)s [%(levelname)s] %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

BOT_TOKEN   = "%%BOT_TOKEN%%"
ADMIN_IDS   = [%%ADMIN_IDS%%]
SERVER_IP   = "%%SERVER_IP%%"
MAIN_IFACE  = "%%MAIN_IFACE%%"
MAIN_GW     = "%%MAIN_GW%%"
INSTALL_DIR = "%%INSTALL_DIR%%"
DB_PATH     = f"{INSTALL_DIR}/tunnels.db"

def db_init():
    con = sqlite3.connect(DB_PATH)
    con.execute("""CREATE TABLE IF NOT EXISTS tunnels (
        name TEXT PRIMARY KEY, port INTEGER, tun TEXT,
        tun_ip TEXT, vpn_server TEXT, created_at TEXT,
        username TEXT, password TEXT,
        rx_bytes INTEGER DEFAULT 0, tx_bytes INTEGER DEFAULT 0)""")
    con.commit(); con.close()

def db_add(name, port, tun, tun_ip, vpn_server, username, password):
    con = sqlite3.connect(DB_PATH)
    con.execute("INSERT OR REPLACE INTO tunnels VALUES (?,?,?,?,?,?,?,?,0,0)",
        (name, port, tun, tun_ip, vpn_server, datetime.now().isoformat(), username, password))
    con.commit(); con.close()

def db_remove(name):
    con = sqlite3.connect(DB_PATH)
    con.execute("DELETE FROM tunnels WHERE name=?", (name,))
    con.commit(); con.close()

def db_all():
    con = sqlite3.connect(DB_PATH)
    rows = con.execute("SELECT * FROM tunnels").fetchall()
    con.close(); return rows

def db_get(name):
    con = sqlite3.connect(DB_PATH)
    row = con.execute("SELECT * FROM tunnels WHERE name=?", (name,)).fetchone()
    con.close(); return row

def db_update_traffic(name, rx, tx):
    con = sqlite3.connect(DB_PATH)
    con.execute("UPDATE tunnels SET rx_bytes=?, tx_bytes=? WHERE name=?", (rx, tx, name))
    con.commit(); con.close()

tunnels = {}

def is_admin(uid): return uid in ADMIN_IDS

def find_free_port(start=10800):
    for p in range(start, 10900):
        with socket.socket() as s:
            if s.connect_ex(('127.0.0.1', p)) != 0: return p
    return None

def find_free_tun():
    for i in range(20):
        if not os.path.exists(f'/sys/class/net/tun{i}'): return f'tun{i}'
    return None

def run(cmd): return subprocess.run(cmd, capture_output=True, text=True)

def get_tun_traffic(tun):
    try:
        with open('/proc/net/dev', 'r') as f:
            for line in f:
                if tun + ':' in line:
                    parts = line.split()
                    return int(parts[1]), int(parts[9])
    except: pass
    return 0, 0

def fmt_bytes(b):
    if b < 1024: return f"{b} B"
    elif b < 1024**2: return f"{b/1024:.1f} KB"
    elif b < 1024**3: return f"{b/1024**2:.1f} MB"
    else: return f"{b/1024**3:.2f} GB"

def setup_routing(tun, tun_ip, vpn_server_ip, port, tunnel_user):
    with open('/etc/iproute2/rt_tables', 'r') as f:
        rt = f.read()
    if f'vpn_{port}' not in rt:
        with open('/etc/iproute2/rt_tables', 'a') as f:
            f.write(f'{port} vpn_{port}\n')
    r = run(['ip', 'route', 'replace', 'default', 'dev', tun, 'table', f'vpn_{port}'])
    logger.info(f'route replace dev={tun} table=vpn_{port}: rc={r.returncode}')
    if vpn_server_ip:
        run(['ip', 'route', 'add', f'{vpn_server_ip}/32', 'via', MAIN_GW, 'dev', MAIN_IFACE])
    uid = run(['id', '-u', tunnel_user]).stdout.strip()
    r = run(['ip', 'rule', 'add', 'uidrange', f'{uid}-{uid}', 'table', f'vpn_{port}'])
    logger.info(f'rule add uid={uid} table=vpn_{port}: rc={r.returncode}')

def teardown_routing(port, vpn_server_ip=None):
    run(['ip', 'rule', 'del', 'table', f'vpn_{port}'])
    run(['ip', 'route', 'flush', 'table', f'vpn_{port}'])
    if vpn_server_ip:
        run(['ip', 'route', 'del', f'{vpn_server_ip}/32'])
    run(['userdel', f'tun_{port}'])

def write_dante(name, port, tun_ip, tunnel_user):
    path = f'/etc/danted_{name}.conf'
    with open(path, 'w') as f:
        f.write(f"logoutput: /var/log/danted_{name}.log\ninternal: 0.0.0.0 port = {port}\nexternal: {tun_ip}\nclientmethod: none\nsocksmethod: none\nuser.privileged: root\nuser.notprivileged: {tunnel_user}\n\nclient pass {{\n    from: 0.0.0.0/0 to: 0.0.0.0/0\n}}\nsocks pass {{\n    from: 0.0.0.0/0 to: 0.0.0.0/0\n    protocol: tcp udp\n}}\n")
    return path

def kill_tunnel(name):
    t = tunnels.pop(name, None)
    if t:
        rx, tx = get_tun_traffic(t['tun'])
        db_update_traffic(name, rx, tx)
        teardown_routing(t['port'], t.get('vpn_server_ip'))
        for p in [t.get('socks_proc'), t.get('ovpn_proc')]:
            if p:
                try: p.terminate(); p.wait(timeout=5)
                except: p.kill()
    for f in [f'/etc/danted_{name}.conf', f'{INSTALL_DIR}/{name}.log',
              f'{INSTALL_DIR}/{name}.auth', f'{INSTALL_DIR}/{name}.ovpn']:
        try: os.remove(f)
        except: pass
    db_remove(name)

def measure_real_latency(tun_ip):
    try:
        result = subprocess.run(
            ['ping', '-c', '3', '-W', '2', '-I', tun_ip, '1.1.1.1'],
            capture_output=True, text=True, timeout=10)
        m = re.search(r'rtt min/avg/max.*?=([\d.]+)/([\d.]+)', result.stdout)
        if m: return round(float(m.group(2)))
    except: pass
    return None

async def _launch_tunnel(name, ovpn_path, auth_path, username, password, tun=None, port=None):
    if tun is None: tun = find_free_tun()
    if port is None: port = find_free_port()
    if not port or not tun: return None, "No free port/tun"

    ovpn_proc = subprocess.Popen([
        'openvpn', '--config', ovpn_path, '--auth-user-pass', auth_path,
        '--route-noexec', '--dev', tun, '--dev-type', 'tun',
        '--script-security', '0', '--log', f'{INSTALL_DIR}/{name}.log',
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    tun_ip = None
    for _ in range(30):
        await asyncio.sleep(1)
        r = run(['ip', 'addr', 'show', tun])
        if 'inet ' in r.stdout:
            for line in r.stdout.split('\n'):
                if 'inet ' in line:
                    tun_ip = line.strip().split()[1].split('/')[0]; break
            break

    if not tun_ip:
        ovpn_proc.terminate()
        return None, "tun didn't come up"

    vpn_server_ip = None
    try:
        with open(f'{INSTALL_DIR}/{name}.log', 'rb') as lf:
            log_text = lf.read().decode('utf-8', errors='ignore')
            m = re.search(r'link remote.*?(\d+\.\d+\.\d+\.\d+)', log_text)
            if m: vpn_server_ip = m.group(1)
    except: pass

    tunnel_user = f'tun_{port}'
    if run(['id', '-u', tunnel_user]).returncode != 0:
        run(['useradd', '-r', '-s', '/bin/false', tunnel_user])

    setup_routing(tun, tun_ip, vpn_server_ip, port, tunnel_user)
    dante_conf = write_dante(name, port, tun_ip, tunnel_user)
    socks_proc = subprocess.Popen(['danted', '-f', dante_conf],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    await asyncio.sleep(2)

    if socks_proc.poll() is not None:
        ovpn_proc.terminate()
        teardown_routing(port, vpn_server_ip)
        return None, "danted failed"

    tunnels[name] = {
        'ovpn_proc': ovpn_proc, 'socks_proc': socks_proc,
        'port': port, 'tun': tun, 'tun_ip': tun_ip,
        'username': username, 'password': password,
        'vpn_server_ip': vpn_server_ip,
    }
    return {'port': port, 'tun': tun, 'tun_ip': tun_ip, 'vpn_server_ip': vpn_server_ip}, None

async def health_check(app):
    await asyncio.sleep(30)
    while True:
        for name, t in list(tunnels.items()):
            tun = t['tun']
            tun_alive = os.path.exists(f'/sys/class/net/{tun}')
            ovpn_alive = t.get('ovpn_proc') and t['ovpn_proc'].poll() is None
            socks_alive = t.get('socks_proc') and t['socks_proc'].poll() is None

            if not tun_alive or not ovpn_alive:
                logger.warning(f'[health] {name}: dead, restarting...')
                rx, tx = get_tun_traffic(tun)
                db_update_traffic(name, rx, tx)
                for p in [t.get('socks_proc'), t.get('ovpn_proc')]:
                    if p:
                        try: p.terminate(); p.wait(timeout=5)
                        except: p.kill()
                teardown_routing(t['port'], t.get('vpn_server_ip'))
                tunnels.pop(name, None)
                row = db_get(name)
                if row:
                    ovpn_path = f'{INSTALL_DIR}/{name}.ovpn'
                    auth_path = f'{INSTALL_DIR}/{name}.auth'
                    if os.path.exists(ovpn_path) and os.path.exists(auth_path):
                        result, err = await _launch_tunnel(name, ovpn_path, auth_path,
                            row[6], row[7], find_free_tun(), row[1])
                        if result:
                            logger.info(f'[health] {name}: restarted ok')
                        else:
                            logger.error(f'[health] {name}: restart failed: {err}')
                            db_remove(name)
                    else:
                        logger.error(f'[health] {name}: files missing')
                        db_remove(name)
            elif not socks_alive:
                logger.warning(f'[health] {name}: danted dead, restarting...')
                dante_conf = f'/etc/danted_{name}.conf'
                if os.path.exists(dante_conf):
                    tunnels[name]['socks_proc'] = subprocess.Popen(
                        ['danted', '-f', dante_conf],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                rx, tx = get_tun_traffic(tun)
                db_update_traffic(name, rx, tx)
        await asyncio.sleep(60)

async def restore_tunnels():
    rows = db_all()
    if not rows: return
    logger.info(f'[restore] Restoring {len(rows)} tunnel(s)...')
    for row in rows:
        name, port, tun, tun_ip, vpn_server, created_at, username, password, rx, tx = row
        ovpn_path = f'{INSTALL_DIR}/{name}.ovpn'
        auth_path = f'{INSTALL_DIR}/{name}.auth'
        if not os.path.exists(ovpn_path) or not os.path.exists(auth_path):
            logger.warning(f'[restore] {name}: files missing, skipping')
            db_remove(name); continue
        result, err = await _launch_tunnel(name, ovpn_path, auth_path,
            username, password, find_free_tun(), find_free_port(port))
        if result:
            db_add(name, result['port'], result['tun'], result['tun_ip'],
                   result['vpn_server_ip'] or vpn_server, username, password)
            logger.info(f'[restore] {name}: ok on port {result["port"]}')
        else:
            logger.error(f'[restore] {name}: failed: {err}')
            db_remove(name)

def main_kb():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("📋 Tunnels", callback_data="list"),
         InlineKeyboardButton("➕ Add", callback_data="add")],
        [InlineKeyboardButton("📡 Ping All", callback_data="pingall"),
         InlineKeyboardButton("📊 Stats", callback_data="stats")],
        [InlineKeyboardButton("🗑 Kill All", callback_data="killall_confirm")],
    ])

def tunnel_list_kb(names):
    rows = []
    for n in names:
        rows.append([
            InlineKeyboardButton(f"📡 {n}", callback_data=f"ping_{n}"),
            InlineKeyboardButton(f"📊", callback_data=f"stat_{n}"),
            InlineKeyboardButton(f"🔴 Kill", callback_data=f"kill_{n}"),
        ])
    rows.append([InlineKeyboardButton("🔙 Back", callback_data="menu")])
    return InlineKeyboardMarkup(rows)

def confirm_kb(action):
    return InlineKeyboardMarkup([[
        InlineKeyboardButton("✅ Yes", callback_data=f"confirm_{action}"),
        InlineKeyboardButton("❌ No",  callback_data="menu"),
    ]])

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id): return
    await update.message.reply_text(
        "👋 *OpenVPN → SOCKS5 Bot*\n\nSend a `.ovpn` file to create a tunnel.",
        parse_mode='Markdown', reply_markup=main_kb())

async def cb_handler(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_admin(q.from_user.id): return
    data = q.data

    if data == "menu":
        await q.edit_message_text(
            "👋 *OpenVPN → SOCKS5 Bot*\n\nSend a `.ovpn` file to create a tunnel.",
            parse_mode='Markdown', reply_markup=main_kb())

    elif data == "list":
        rows = db_all()
        if not rows:
            await q.edit_message_text("No active tunnels.",
                reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("🔙 Back", callback_data="menu")]])); return
        text = "📋 *Tunnels*\n\n"
        for r in rows:
            name, port, tun, tun_ip, vpn_server, created_at, username, password, rx, tx = r
            alive = "🟢" if name in tunnels else "⚪️"
            text += f"{alive} *{name}*\n  `{SERVER_IP}:{port}`\n  VPN: `{vpn_server}`\n\n"
        await q.edit_message_text(text, parse_mode='Markdown',
            reply_markup=tunnel_list_kb([r[0] for r in rows]))

    elif data == "add":
        await q.edit_message_text(
            "📤 Send your `.ovpn` file.\n\nOptional caption:\n```\nusername\npassword```",
            parse_mode='Markdown')

    elif data == "pingall":
        rows = db_all()
        if not rows:
            await q.edit_message_text("No tunnels.", reply_markup=main_kb()); return
        await q.edit_message_text("📡 Pinging all tunnels...")
        text = "📡 *Real Latency (via tun → 1.1.1.1)*\n\n"
        for r in rows:
            name = r[0]
            if name in tunnels:
                ms = measure_real_latency(tunnels[name]['tun_ip'])
                if ms:
                    emoji = "🟢" if ms < 100 else "🟡" if ms < 300 else "🔴"
                    text += f"{emoji} *{name}*: `{ms}ms`\n"
                else:
                    text += f"❌ *{name}*: timeout\n"
            else:
                text += f"⚪️ *{name}*: not running\n"
        await q.edit_message_text(text, parse_mode='Markdown', reply_markup=main_kb())

    elif data == "stats":
        rows = db_all()
        if not rows:
            await q.edit_message_text("No tunnels.", reply_markup=main_kb()); return
        for r in rows:
            name = r[0]
            if name in tunnels:
                rx, tx = get_tun_traffic(tunnels[name]['tun'])
                db_update_traffic(name, rx, tx)
        rows = db_all()
        total_rx = sum(r[8] for r in rows)
        total_tx = sum(r[9] for r in rows)
        text = "📊 *Traffic Stats*\n\n"
        for r in rows:
            name, port, tun, tun_ip, vpn_server, created_at, username, password, rx, tx = r
            alive = "🟢" if name in tunnels else "⚪️"
            text += (f"{alive} *{name}*\n"
                     f"  ⬇️ `{fmt_bytes(rx)}`  ⬆️ `{fmt_bytes(tx)}`  📦 `{fmt_bytes(rx+tx)}`\n\n")
        text += f"─────────────\n⬇️ `{fmt_bytes(total_rx)}`  ⬆️ `{fmt_bytes(total_tx)}`  📦 `{fmt_bytes(total_rx+total_tx)}`"
        await q.edit_message_text(text, parse_mode='Markdown', reply_markup=main_kb())

    elif data.startswith("stat_"):
        name = data[5:]
        row = db_get(name)
        if not row:
            await q.answer("Not found!", show_alert=True); return
        name, port, tun, tun_ip, vpn_server, created_at, username, password, rx, tx = row
        if name in tunnels:
            rx, tx = get_tun_traffic(tunnels[name]['tun'])
            db_update_traffic(name, rx, tx)
        text = (f"📊 *{name}*\n\n"
                f"⬇️ Download: `{fmt_bytes(rx)}`\n"
                f"⬆️ Upload:   `{fmt_bytes(tx)}`\n"
                f"📦 Total:    `{fmt_bytes(rx+tx)}`\n\n"
                f"🌐 SOCKS5: `{SERVER_IP}:{port}`\n"
                f"🔒 TUN: `{tun_ip}`\n"
                f"🖥 VPN: `{vpn_server}`\n"
                f"📅 Created: {created_at[:16]}")
        await q.edit_message_text(text, parse_mode='Markdown',
            reply_markup=tunnel_list_kb([r[0] for r in db_all()]))

    elif data.startswith("ping_"):
        name = data[5:]
        t = tunnels.get(name)
        if not t:
            await q.answer("Tunnel not running!", show_alert=True); return
        await q.answer("Pinging via tun...")
        ms = measure_real_latency(t['tun_ip'])
        rows = db_all()
        emoji = ("🟢" if ms < 100 else "🟡" if ms < 300 else "🔴") if ms else "❌"
        ping_txt = f"`{ms}ms`" if ms else "timeout"
        await q.edit_message_text(f"{emoji} *{name}*: {ping_txt}",
            parse_mode='Markdown', reply_markup=tunnel_list_kb([r[0] for r in rows]))

    elif data.startswith("kill_"):
        name = data[5:]
        await q.edit_message_text(f"Kill tunnel *{name}*?", parse_mode='Markdown',
            reply_markup=confirm_kb(f"kill_{name}"))

    elif data == "killall_confirm":
        await q.edit_message_text("Kill *ALL* tunnels?", parse_mode='Markdown',
            reply_markup=confirm_kb("killall"))

    elif data.startswith("confirm_kill_"):
        name = data[13:]
        kill_tunnel(name)
        await q.edit_message_text(f"✅ Tunnel *{name}* killed.",
            parse_mode='Markdown', reply_markup=main_kb())

    elif data == "confirm_killall":
        for name in list(tunnels.keys()): kill_tunnel(name)
        await q.edit_message_text("✅ All tunnels killed.", reply_markup=main_kb())

async def handle_ovpn(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id): return
    doc = update.message.document
    if not doc or not doc.file_name.endswith('.ovpn'):
        await update.message.reply_text("Please send a `.ovpn` file."); return
    name = doc.file_name.replace('.ovpn', '').replace(' ', '_')
    if name in tunnels:
        await update.message.reply_text(f"⚠️ `{name}` already active.", parse_mode='Markdown'); return
    ovpn_path = f'{INSTALL_DIR}/{name}.ovpn'
    auth_path = f'{INSTALL_DIR}/{name}.auth'
    file = await doc.get_file()
    await file.download_to_drive(ovpn_path)
    caption = update.message.caption or ""
    creds = [l.strip() for l in caption.strip().split('\n') if l.strip()]
    if len(creds) >= 2:
        await _start_tunnel(update, ctx, name, ovpn_path, auth_path, creds[0], creds[1])
    else:
        ctx.user_data['pending'] = {'name': name, 'ovpn_path': ovpn_path, 'auth_path': auth_path}
        await update.message.reply_text("🔑 Send credentials:\n```\nusername\npassword```", parse_mode='Markdown')

async def handle_text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id): return
    pending = ctx.user_data.get('pending')
    if not pending: return
    lines = [l.strip() for l in update.message.text.strip().split('\n') if l.strip()]
    if len(lines) < 2:
        await update.message.reply_text("Two lines: username then password."); return
    ctx.user_data.pop('pending')
    await _start_tunnel(update, ctx, pending['name'], pending['ovpn_path'],
                        pending['auth_path'], lines[0], lines[1])

async def _start_tunnel(update, ctx, name, ovpn_path, auth_path, username, password):
    port = find_free_port()
    tun  = find_free_tun()
    if not port:
        await update.message.reply_text("❌ No free port."); return
    with open(auth_path, 'w') as f: f.write(f"{username}\n{password}\n")
    os.chmod(auth_path, 0o600)
    msg = await update.message.reply_text("⚙️ Starting OpenVPN tunnel...")
    result, err = await _launch_tunnel(name, ovpn_path, auth_path, username, password, tun, port)
    if not result:
        log_tail = ""
        try:
            with open(f'{INSTALL_DIR}/{name}.log', 'rb') as lf:
                log_tail = lf.read().decode('utf-8', errors='ignore')[-600:]
        except: pass
        # cleanup any partial routing
        teardown_routing(port)
        await msg.edit_text(f"❌ Failed: {err}\n\n<pre>{log_tail}</pre>", parse_mode='HTML'); return

    db_add(name, result['port'], result['tun'], result['tun_ip'],
           result['vpn_server_ip'] or 'unknown', username, password)

    await msg.edit_text("📡 Measuring real latency...")
    ms = measure_real_latency(result['tun_ip'])
    ping_str = f"📡 Latency: `{ms}ms`" if ms else "📡 Latency: N/A"

    await msg.edit_text(
        f"✅ *Tunnel `{name}` is live!*\n\n"
        f"🌐 SOCKS5: `{SERVER_IP}:{result['port']}`\n"
        f"🔒 TUN: `{result['tun_ip']}`\n"
        f"🖥 VPN: `{result['vpn_server_ip'] or 'unknown'}`\n"
        f"{ping_str}\n\n"
        f"*Xray Outbound:*\n"
        f"Protocol: `socks`\n"
        f"Address: `{SERVER_IP}`\n"
        f"Port: `{result['port']}`",
        parse_mode='Markdown', reply_markup=main_kb())

async def post_init(app):
    asyncio.create_task(restore_tunnels())
    asyncio.create_task(health_check(app))

def main():
    db_init()
    app = Application.builder().token(BOT_TOKEN).post_init(post_init).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CallbackQueryHandler(cb_handler))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_ovpn))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    logger.info("Bot started!")
    app.run_polling()

if __name__ == '__main__':
    main()
BOTEOF

sed -i "s|%%BOT_TOKEN%%|$BOT_TOKEN|g"     "$INSTALL_DIR/bot.py"
sed -i "s|%%ADMIN_IDS%%|$ADMIN_IDS|g"     "$INSTALL_DIR/bot.py"
sed -i "s|%%SERVER_IP%%|$SERVER_IP|g"     "$INSTALL_DIR/bot.py"
sed -i "s|%%MAIN_IFACE%%|$MAIN_IFACE|g"   "$INSTALL_DIR/bot.py"
sed -i "s|%%MAIN_GW%%|$MAIN_GW|g"         "$INSTALL_DIR/bot.py"
sed -i "s|%%INSTALL_DIR%%|$INSTALL_DIR|g" "$INSTALL_DIR/bot.py"

cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=OpenVPN SOCKS5 Bot v3
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/bot.py
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo ""
log "Installation complete!"
echo ""
echo -e "${CYAN}Commands:${NC}"
echo "  Logs : journalctl -u $SERVICE_NAME -f"
echo "  Stop : systemctl stop $SERVICE_NAME"
echo "  Start: systemctl start $SERVICE_NAME"
echo ""
echo -e "${GREEN}Send /start to your bot on Telegram!${NC}"
