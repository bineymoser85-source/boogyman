#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/ovpn-bot"
SERVICE_NAME="ovpn-bot"

print_banner() {
    echo -e "${CYAN}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║       OpenVPN → SOCKS5 Bot            ║"
    echo "  ║     Xray Outbound Manager             ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${NC}"
}

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[→]${NC} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && error "Run as root."
}

get_main_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || hostname -I | awk '{print $1}'
}

get_main_iface() {
    ip route | grep default | awk '{print $5}' | head -1
}

get_main_gateway() {
    ip route | grep default | awk '{print $3}' | head -1
}

install_deps() {
    info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq openvpn dante-server python3 python3-pip iproute2 curl
    pip3 install python-telegram-bot --break-system-packages -q
    log "Dependencies installed."
}

setup_user() {
    if ! id vpnuser &>/dev/null; then
        useradd -r -s /bin/false vpnuser
        log "Created vpnuser."
    else
        warn "vpnuser already exists."
    fi
}

setup_routing_table() {
    if ! grep -q "^200 vpn" /etc/iproute2/rt_tables; then
        echo "200 vpn" >> /etc/iproute2/rt_tables
        log "Added vpn routing table."
    else
        warn "vpn routing table already exists."
    fi
}

write_bot() {
    info "Writing bot..."
    cat > "$INSTALL_DIR/bot.py" << 'BOTEOF'
import os, re, subprocess, socket, asyncio, logging, sqlite3
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application, CommandHandler, MessageHandler,
    CallbackQueryHandler, filters, ContextTypes
)

logging.basicConfig(
    format='%(asctime)s [%(levelname)s] %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

BOT_TOKEN  = "%%BOT_TOKEN%%"
ADMIN_IDS  = [%%ADMIN_IDS%%]
SERVER_IP  = "%%SERVER_IP%%"
MAIN_IFACE = "%%MAIN_IFACE%%"
MAIN_GW    = "%%MAIN_GW%%"
INSTALL_DIR = "%%INSTALL_DIR%%"

DB_PATH = f"{INSTALL_DIR}/tunnels.db"

# ─── Database ────────────────────────────────────────────────────────────────

def db_init():
    con = sqlite3.connect(DB_PATH)
    con.execute("""
        CREATE TABLE IF NOT EXISTS tunnels (
            name        TEXT PRIMARY KEY,
            port        INTEGER,
            tun         TEXT,
            tun_ip      TEXT,
            vpn_server  TEXT,
            created_at  TEXT
        )
    """)
    con.commit()
    con.close()

def db_add(name, port, tun, tun_ip, vpn_server):
    con = sqlite3.connect(DB_PATH)
    con.execute(
        "INSERT OR REPLACE INTO tunnels VALUES (?,?,?,?,?,?)",
        (name, port, tun, tun_ip, vpn_server, datetime.now().isoformat())
    )
    con.commit()
    con.close()

def db_remove(name):
    con = sqlite3.connect(DB_PATH)
    con.execute("DELETE FROM tunnels WHERE name=?", (name,))
    con.commit()
    con.close()

def db_all():
    con = sqlite3.connect(DB_PATH)
    rows = con.execute("SELECT * FROM tunnels").fetchall()
    con.close()
    return rows

def db_get(name):
    con = sqlite3.connect(DB_PATH)
    row = con.execute("SELECT * FROM tunnels WHERE name=?", (name,)).fetchone()
    con.close()
    return row

# ─── State ───────────────────────────────────────────────────────────────────

tunnels = {}  # name → {ovpn_proc, socks_proc, port, tun, tun_ip}

# ─── Helpers ─────────────────────────────────────────────────────────────────

def is_admin(uid): return uid in ADMIN_IDS

def find_free_port(start=10800):
    for p in range(start, 10900):
        with socket.socket() as s:
            if s.connect_ex(('127.0.0.1', p)) != 0:
                return p
    return None

def find_free_tun():
    for i in range(20):
        if not os.path.exists(f'/sys/class/net/tun{i}'):
            return f'tun{i}'
    return None

def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)

def kill_tunnel(name):
    t = tunnels.pop(name, None)
    if t:
        for p in [t.get('socks_proc'), t.get('ovpn_proc')]:
            if p:
                try: p.terminate(); p.wait(timeout=5)
                except: p.kill()
    # clean dante config
    for f in [f'/etc/danted_{name}.conf', f'{INSTALL_DIR}/{name}.log', f'{INSTALL_DIR}/{name}.auth']:
        try: os.remove(f)
        except: pass
    db_remove(name)

def setup_routing(tun, tun_ip, vpn_server_ip):
    run(['ip', 'route', 'replace', 'default', 'via', '10.8.0.1', 'dev', tun, 'table', 'vpn'])
    if vpn_server_ip:
        run(['ip', 'route', 'add', f'{vpn_server_ip}/32', 'via', MAIN_GW, 'dev', MAIN_IFACE])
    nobody_uid  = run(['id', '-u', 'nobody']).stdout.strip()
    vpnuser_uid = run(['id', '-u', 'vpnuser']).stdout.strip()
    run(['ip', 'rule', 'add', 'uidrange', f'{nobody_uid}-{nobody_uid}',   'table', 'vpn'])
    run(['ip', 'rule', 'add', 'uidrange', f'{vpnuser_uid}-{vpnuser_uid}', 'table', 'vpn'])

def write_dante_conf(name, port, tun_ip):
    conf = f"""logoutput: /var/log/danted_{name}.log
internal: 0.0.0.0 port = {port}
external: {tun_ip}
clientmethod: none
socksmethod: none
user.privileged: root
user.notprivileged: nobody

client pass {{
    from: 0.0.0.0/0 to: 0.0.0.0/0
}}

socks pass {{
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
}}
"""
    path = f'/etc/danted_{name}.conf'
    with open(path, 'w') as f:
        f.write(conf)
    return path

# ─── Keyboards ───────────────────────────────────────────────────────────────

def main_menu_kb():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("📋 Tunnels", callback_data="list"),
         InlineKeyboardButton("➕ Add Tunnel", callback_data="add")],
        [InlineKeyboardButton("🗑 Kill All", callback_data="killall_confirm")],
    ])

def tunnel_list_kb(names):
    rows = [[InlineKeyboardButton(f"🔴 Kill {n}", callback_data=f"kill_{n}")] for n in names]
    rows.append([InlineKeyboardButton("🔙 Back", callback_data="menu")])
    return InlineKeyboardMarkup(rows)

def confirm_kb(action):
    return InlineKeyboardMarkup([[
        InlineKeyboardButton("✅ Yes", callback_data=f"confirm_{action}"),
        InlineKeyboardButton("❌ No",  callback_data="menu"),
    ]])

# ─── Handlers ────────────────────────────────────────────────────────────────

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id): return
    await update.message.reply_text(
        "👋 *OpenVPN → SOCKS5 Bot*\n\nSend a `.ovpn` file to add a tunnel.",
        parse_mode='Markdown',
        reply_markup=main_menu_kb()
    )

async def cb_handler(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if not is_admin(q.from_user.id): return
    data = q.data

    if data == "menu":
        await q.edit_message_text(
            "👋 *OpenVPN → SOCKS5 Bot*\n\nSend a `.ovpn` file to add a tunnel.",
            parse_mode='Markdown', reply_markup=main_menu_kb()
        )

    elif data == "list":
        rows = db_all()
        if not rows:
            await q.edit_message_text("No active tunnels.", reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton("🔙 Back", callback_data="menu")
            ]]))
            return
        text = "📋 *Active Tunnels*\n\n"
        for r in rows:
            name, port, tun, tun_ip, vpn_server, created = r
            alive = "🟢" if name in tunnels else "🔴"
            text += f"{alive} *{name}*\n  SOCKS5: `{SERVER_IP}:{port}`\n  TUN IP: `{tun_ip}`\n  VPN: `{vpn_server}`\n  Added: {created[:16]}\n\n"
        await q.edit_message_text(text, parse_mode='Markdown',
            reply_markup=tunnel_list_kb([r[0] for r in rows]))

    elif data == "add":
        await q.edit_message_text("📤 Send your `.ovpn` file now.\n\nCaption format (optional):\n```\nusername\npassword```",
            parse_mode='Markdown')

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
        await q.edit_message_text(f"✅ Tunnel *{name}* killed.", parse_mode='Markdown',
            reply_markup=main_menu_kb())

    elif data == "confirm_killall":
        for name in list(tunnels.keys()):
            kill_tunnel(name)
        await q.edit_message_text("✅ All tunnels killed.", reply_markup=main_menu_kb())

async def handle_ovpn(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id): return
    doc = update.message.document
    if not doc or not doc.file_name.endswith('.ovpn'):
        await update.message.reply_text("Please send a `.ovpn` file.")
        return

    name = doc.file_name.replace('.ovpn', '').replace(' ', '_')
    if name in tunnels:
        await update.message.reply_text(f"⚠️ Tunnel `{name}` already active. Kill it first.",
            parse_mode='Markdown')
        return

    ovpn_path = f'{INSTALL_DIR}/{name}.ovpn'
    auth_path = f'{INSTALL_DIR}/{name}.auth'
    file = await doc.get_file()
    await file.download_to_drive(ovpn_path)

    caption = update.message.caption or ""
    creds = [l.strip() for l in caption.strip().split('\n') if l.strip()]

    if len(creds) >= 2:
        username, password = creds[0], creds[1]
        await _start_tunnel(update, ctx, name, ovpn_path, auth_path, username, password)
    else:
        ctx.user_data['pending'] = {'name': name, 'ovpn_path': ovpn_path, 'auth_path': auth_path}
        await update.message.reply_text(
            "🔑 Send credentials (one per line):\n```\nusername\npassword```",
            parse_mode='Markdown'
        )

async def handle_text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user.id): return
    pending = ctx.user_data.get('pending')
    if not pending: return
    lines = [l.strip() for l in update.message.text.strip().split('\n') if l.strip()]
    if len(lines) < 2:
        await update.message.reply_text("Send two lines: username then password.")
        return
    ctx.user_data.pop('pending')
    await _start_tunnel(update, ctx, pending['name'], pending['ovpn_path'],
                        pending['auth_path'], lines[0], lines[1])

async def _start_tunnel(update, ctx, name, ovpn_path, auth_path, username, password):
    port = find_free_port()
    tun  = find_free_tun()
    if not port:
        await update.message.reply_text("❌ No free port available.")
        return

    with open(auth_path, 'w') as f:
        f.write(f"{username}\n{password}\n")
    os.chmod(auth_path, 0o600)

    msg = await update.message.reply_text("⚙️ Starting OpenVPN tunnel...")

    ovpn_proc = subprocess.Popen([
        'openvpn',
        '--config', ovpn_path,
        '--auth-user-pass', auth_path,
        '--route-noexec',
        '--dev', tun,
        '--dev-type', 'tun',
        '--script-security', '0',
        '--log', f'{INSTALL_DIR}/{name}.log',
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # wait for tun interface
    tun_ip = None
    for _ in range(30):
        await asyncio.sleep(1)
        r = run(['ip', 'addr', 'show', tun])
        if 'inet ' in r.stdout:
            for line in r.stdout.split('\n'):
                if 'inet ' in line:
                    tun_ip = line.strip().split()[1].split('/')[0]
                    break
            break

    if not tun_ip:
        ovpn_proc.terminate()
        log_tail = ""
        try:
            with open(f'{INSTALL_DIR}/{name}.log', 'rb') as lf:
                log_tail = lf.read().decode('utf-8', errors='ignore')[-600:]
        except: pass
        await msg.edit_text(f"❌ Tunnel failed to come up.\n\n<pre>{log_tail}</pre>", parse_mode='HTML')
        return

    # get vpn server ip from log
    vpn_server_ip = None
    try:
        with open(f'{INSTALL_DIR}/{name}.log', 'rb') as lf:
            log_text = lf.read().decode('utf-8', errors='ignore')
            m = re.search(r'link remote.*?(\d+\.\d+\.\d+\.\d+)', log_text)
            if m: vpn_server_ip = m.group(1)
    except: pass

    await msg.edit_text(f"⚙️ Tunnel up (`{tun_ip}`). Setting up routing...")

    setup_routing(tun, tun_ip, vpn_server_ip)

    dante_conf = write_dante_conf(name, port, tun_ip)
    socks_proc = subprocess.Popen(
        ['danted', '-f', dante_conf],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    await asyncio.sleep(2)

    if socks_proc.poll() is not None:
        ovpn_proc.terminate()
        await msg.edit_text("❌ SOCKS5 server failed to start.")
        return

    tunnels[name] = {
        'ovpn_proc': ovpn_proc,
        'socks_proc': socks_proc,
        'port': port,
        'tun': tun,
        'tun_ip': tun_ip,
    }
    db_add(name, port, tun, tun_ip, vpn_server_ip or 'unknown')

    await msg.edit_text(
        f"✅ *Tunnel `{name}` is live!*\n\n"
        f"🌐 SOCKS5: `{SERVER_IP}:{port}`\n"
        f"🔒 TUN IP: `{tun_ip}`\n"
        f"🖥 VPN Server: `{vpn_server_ip or 'unknown'}`\n\n"
        f"*Add to Xray outbound:*\n"
        f"Protocol: `socks`\n"
        f"Address: `{SERVER_IP}`\n"
        f"Port: `{port}`",
        parse_mode='Markdown',
        reply_markup=main_menu_kb()
    )

def main():
    db_init()
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CallbackQueryHandler(cb_handler))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_ovpn))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    logger.info("Bot started!")
    app.run_polling()

if __name__ == '__main__':
    main()
BOTEOF
    log "Bot written."
}

write_service() {
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=OpenVPN SOCKS5 Bot
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
    log "Systemd service created."
}

main() {
    print_banner
    check_root

    SERVER_IP=$(get_main_ip)
    MAIN_IFACE=$(get_main_iface)
    MAIN_GW=$(get_main_gateway)

    echo -e "${CYAN}Detected:${NC}"
    echo "  Server IP : $SERVER_IP"
    echo "  Interface : $MAIN_IFACE"
    echo "  Gateway   : $MAIN_GW"
    echo ""

    read -p "Bot Token: " BOT_TOKEN
    [[ -z "$BOT_TOKEN" ]] && error "Token required."

    read -p "Admin Telegram ID #1: " ADMIN1
    read -p "Admin Telegram ID #2 (leave blank to skip): " ADMIN2

    ADMIN_IDS="$ADMIN1"
    [[ -n "$ADMIN2" ]] && ADMIN_IDS="$ADMIN1, $ADMIN2"

    mkdir -p "$INSTALL_DIR"

    install_deps
    setup_user
    setup_routing_table
    write_bot

    # inject config
    sed -i "s|%%BOT_TOKEN%%|$BOT_TOKEN|g"   "$INSTALL_DIR/bot.py"
    sed -i "s|%%ADMIN_IDS%%|$ADMIN_IDS|g"   "$INSTALL_DIR/bot.py"
    sed -i "s|%%SERVER_IP%%|$SERVER_IP|g"   "$INSTALL_DIR/bot.py"
    sed -i "s|%%MAIN_IFACE%%|$MAIN_IFACE|g" "$INSTALL_DIR/bot.py"
    sed -i "s|%%MAIN_GW%%|$MAIN_GW|g"       "$INSTALL_DIR/bot.py"
    sed -i "s|%%INSTALL_DIR%%|$INSTALL_DIR|g" "$INSTALL_DIR/bot.py"

    write_service

    echo ""
    log "Installation complete!"
    echo ""
    echo -e "${CYAN}Commands:${NC}"
    echo "  Start : systemctl start $SERVICE_NAME"
    echo "  Stop  : systemctl stop $SERVICE_NAME"
    echo "  Logs  : journalctl -u $SERVICE_NAME -f"
    echo ""
    read -p "Start bot now? [Y/n]: " START
    if [[ "$START" != "n" && "$START" != "N" ]]; then
        systemctl enable --now "$SERVICE_NAME"
        log "Bot is running!"
        echo ""
        echo -e "${GREEN}Send /start to your bot on Telegram.${NC}"
    fi
}

main
