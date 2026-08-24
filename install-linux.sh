#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

INSTALL_DIR="/opt/redwing"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

banner() {
    echo -e "${CYAN}"
    echo '  ██████╗ ███████╗██████╗ ██╗    ██╗██╗███╗   ██╗ ██████╗'
    echo '  ██╔══██╗██╔════╝██╔══██╗██║    ██║██║████╗  ██║██╔════╝'
    echo '  ██████╔╝█████╗  ██║  ██║██║ █╗ ██║██║██╔██╗ ██║██║  ███╗'
    echo '  ██╔══██╗██╔══╝  ██║  ██║██║███╗██║██║██║╚██╗██║██║   ██║'
    echo '  ██║  ██║███████╗██████╔╝╚███╔███╔╝██║██║ ╚████║╚██████╔╝'
    echo '  ╚═╝  ╚═╝╚══════╝╚═════╝  ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝ ╚═════╝'
    echo -e "${NC}"
    echo -e "  ${BOLD}LEAKED BY OMNI | t.me/omnibotnet | omni.lc${NC}"
    echo ""
}

log()  { echo -e "  ${GREEN}[+]${NC} $1 ${DIM}/ $2${NC}"; }
err()  { echo -e "  ${RED}[!]${NC} $1 ${DIM}/ $2${NC}"; }
warn() { echo -e "  ${YELLOW}[*]${NC} $1 ${DIM}/ $2${NC}"; }
ask()  { echo -en "  ${CYAN}[?]${NC} $1 ${DIM}/ $2${NC} "; }

die() { err "$1" "$2"; exit 1; }

banner

# ── Root ────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    die "Запустите от root: sudo $0" "Run as root: sudo $0"
fi

# ── Проверка source файлов / Verify source files ───────────────────
[ -f "$SCRIPT_DIR/bin/linux/server" ]   || die "Не найден bin/linux/server"   "bin/linux/server not found"
[ -d "$SCRIPT_DIR/source/decom" ]       || die "Не найдена source/decom"      "source/decom not found"
[ -d "$SCRIPT_DIR/source/web" ]         || die "Не найдена source/web"        "source/web not found"
[ -f "$SCRIPT_DIR/source/decom/debug.keystore" ] || die "Не найден debug.keystore" "debug.keystore not found"

# ── 1. Системные пакеты / System packages ──────────────────────────
log "Обновление пакетов..." "Updating packages..."
apt-get update -qq 2>/dev/null

log "Установка зависимостей..." "Installing dependencies..."
apt-get install -y -qq openjdk-17-jre-headless curl unzip > /dev/null 2>&1

if ! command -v java &>/dev/null; then
    die "Java 17 не установилась. Установите вручную: apt install openjdk-17-jre-headless" \
        "Java 17 failed to install. Install manually: apt install openjdk-17-jre-headless"
fi
log "Java: $(java -version 2>&1 | head -1)" ""

# ── 2. apktool 2.10.0 ──────────────────────────────────────────────
NEED_APKTOOL=true
if command -v apktool &>/dev/null; then
    CURRENT_VER=$(apktool --version 2>/dev/null | head -1 | tr -d '[:space:]')
    case "$CURRENT_VER" in
        2.10.*|2.1[1-9].*|3.*) NEED_APKTOOL=false ;;
    esac
fi

if $NEED_APKTOOL; then
    log "Установка apktool 2.10.0..." "Installing apktool 2.10.0..."
    rm -f /usr/local/bin/apktool /usr/local/bin/apktool.jar /usr/bin/apktool /usr/bin/apktool.jar
    apt-get remove -y -qq apktool 2>/dev/null || true

    curl -fsSL "https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool" \
        -o /usr/local/bin/apktool
    chmod +x /usr/local/bin/apktool

    curl -fSL "https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.10.0.jar" \
        -o /usr/local/bin/apktool.jar

    if ! file /usr/local/bin/apktool.jar 2>/dev/null | grep -qi "java\|zip"; then
        warn "Bitbucket отдал мусор, качаем с GitHub..." "Bitbucket returned junk, trying GitHub..."
        curl -fSL "https://github.com/iBotPeaches/Apktool/releases/download/v2.10.0/apktool_2.10.0.jar" \
            -o /usr/local/bin/apktool.jar
    fi

    if ! file /usr/local/bin/apktool.jar 2>/dev/null | grep -qi "java\|zip"; then
        die "apktool.jar не скачался. Скачайте вручную: https://apktool.org/docs/install" \
            "apktool.jar download failed. Download manually: https://apktool.org/docs/install"
    fi

    hash -r
    log "apktool $(apktool --version 2>/dev/null | head -1)" ""
else
    log "apktool уже установлен: $CURRENT_VER" "apktool already installed: $CURRENT_VER"
fi

# ── 3. apksigner + zipalign ────────────────────────────────────────
if ! command -v apksigner &>/dev/null; then
    log "Установка apksigner..." "Installing apksigner..."
    apt-get install -y -qq apksigner 2>/dev/null || true
fi
if ! command -v zipalign &>/dev/null; then
    apt-get install -y -qq zipalign 2>/dev/null || true
fi

if ! command -v apksigner &>/dev/null; then
    warn "apt не помог, качаем Android build-tools..." "apt failed, downloading Android build-tools..."
    BT_ZIP="/tmp/redwing-bt.zip"
    curl -fSL "https://dl.google.com/android/repository/build-tools_r35-linux.zip" -o "$BT_ZIP"

    if file "$BT_ZIP" 2>/dev/null | grep -qi "zip"; then
        BT_TMP="/tmp/redwing-bt-extract"
        rm -rf "$BT_TMP"
        unzip -qo "$BT_ZIP" -d "$BT_TMP"

        BT_DIR=$(ls -d "$BT_TMP"/*/ 2>/dev/null | head -1)
        if [ -n "$BT_DIR" ]; then
            [ -f "$BT_DIR/zipalign" ] && cp "$BT_DIR/zipalign" /usr/local/bin/ && chmod +x /usr/local/bin/zipalign

            mkdir -p /usr/local/lib/android-sdk
            [ -f "$BT_DIR/apksigner.jar" ] && cp "$BT_DIR/apksigner.jar" /usr/local/lib/android-sdk/
            [ -d "$BT_DIR/lib" ] && cp -r "$BT_DIR/lib" /usr/local/lib/android-sdk/

            if [ -f /usr/local/lib/android-sdk/apksigner.jar ]; then
                printf '#!/bin/bash\nexec java -jar /usr/local/lib/android-sdk/apksigner.jar "$@"\n' \
                    > /usr/local/bin/apksigner
                chmod +x /usr/local/bin/apksigner
            elif [ -d /usr/local/lib/android-sdk/lib ] && ls /usr/local/lib/android-sdk/lib/apksigner.jar &>/dev/null; then
                printf '#!/bin/bash\nexec java -jar /usr/local/lib/android-sdk/lib/apksigner.jar "$@"\n' \
                    > /usr/local/bin/apksigner
                chmod +x /usr/local/bin/apksigner
            fi
        fi
        rm -rf "$BT_TMP"
    fi
    rm -f "$BT_ZIP"
fi

hash -r

if ! command -v apksigner &>/dev/null; then
    die "apksigner не установлен. Установите: apt install apksigner" \
        "apksigner not installed. Install: apt install apksigner"
fi
log "apksigner: $(which apksigner)" ""

if command -v zipalign &>/dev/null; then
    log "zipalign: $(which zipalign)" ""
else
    warn "zipalign не найден (не критично, встроен в сервер)" "zipalign not found (not critical, built into server)"
fi

# ── 4. Развёртывание файлов / Deploying files ─────────────────────
log "Развёртывание в ${INSTALL_DIR}..." "Deploying to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR/data"

cp "$SCRIPT_DIR/bin/linux/server" "$INSTALL_DIR/server"
chmod +x "$INSTALL_DIR/server"

rm -rf "$INSTALL_DIR/decom" "$INSTALL_DIR/web"
cp -r "$SCRIPT_DIR/source/decom" "$INSTALL_DIR/decom"
cp -r "$SCRIPT_DIR/source/web"   "$INSTALL_DIR/web"

log "Файлы развёрнуты." "Files deployed."

# ── 5. Настройка / Configuration ──────────────────────────────────
echo ""
echo -e "  ${BOLD}── Настройка / Configuration ──${NC}"
echo ""

EXTERNAL_IP=$(curl -fs --max-time 5 ifconfig.me 2>/dev/null) || true
if [ -z "$EXTERNAL_IP" ]; then
    EXTERNAL_IP=$(curl -fs --max-time 5 icanhazip.com 2>/dev/null) || true
fi
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
DEFAULT_IP="${EXTERNAL_IP:-$LOCAL_IP}"

if [ -n "$EXTERNAL_IP" ] && [ -n "$LOCAL_IP" ] && [ "$EXTERNAL_IP" != "$LOCAL_IP" ]; then
    warn "Внешний IP / External IP: ${BOLD}${EXTERNAL_IP}${NC}" ""
    warn "Локальный IP / Local IP:  ${BOLD}${LOCAL_IP}${NC}" ""
fi

ask "IP для APK-билдов (Enter = ${DEFAULT_IP}):" "IP for APK builds (Enter = ${DEFAULT_IP}):"
read -r SERVER_IP
SERVER_IP="${SERVER_IP:-$DEFAULT_IP}"

ask "Порт (Enter = 8080):" "Port (Enter = 8080):"
read -r PORT
PORT="${PORT:-8080}"

ask "Регистрация — open / closed (Enter = closed):" "Registration — open / closed (Enter = closed):"
read -r REG_MODE
REG_MODE="${REG_MODE:-closed}"

# ── 6. Инициализация БД и создание админа / DB init + admin ───────
ADMIN_LOGIN=""
ADMIN_PASS=""
INIT_LOG=$(mktemp /tmp/redwing-init.XXXXXX)

if [ "$REG_MODE" = "closed" ]; then
    echo ""
    ask "Логин админа (Enter = admin):" "Admin login (Enter = admin):"
    read -r ADMIN_LOGIN
    ADMIN_LOGIN="${ADMIN_LOGIN:-admin}"

    ask "Пароль админа (Enter = авто):" "Admin password (Enter = auto):"
    read -r ADMIN_PASS

    log "Первый запуск для инициализации БД..." "First run to initialize the DB..."

    cd "$INSTALL_DIR"
    printf '%s\n%s\n' "$ADMIN_LOGIN" "$ADMIN_PASS" | \
        SERVER_IP="$SERVER_IP" PORT="$PORT" REGISTRATION="$REG_MODE" \
        timeout --signal=KILL 10 "$INSTALL_DIR/server" > "$INIT_LOG" 2>&1 || true

    echo ""
    if [ -s "$INIT_LOG" ]; then
        sed 's/^/    /' "$INIT_LOG"
    fi
    echo ""
    log "БД инициализирована, админ создан." "DB initialized, admin created."
else
    log "Первый запуск для инициализации БД..." "First run to initialize the DB..."

    cd "$INSTALL_DIR"
    SERVER_IP="$SERVER_IP" PORT="$PORT" REGISTRATION="$REG_MODE" \
        timeout --signal=KILL 8 "$INSTALL_DIR/server" > "$INIT_LOG" 2>&1 || true

    log "БД инициализирована." "DB initialized."
fi

rm -f "$INIT_LOG"

sleep 1
if ss -tlnp 2>/dev/null | grep -q ":${PORT} " || netstat -tlnp 2>/dev/null | grep -q ":${PORT} "; then
    warn "Порт ${PORT} занят после init — убиваем..." "Port ${PORT} busy after init — killing..."
    fuser -k "${PORT}/tcp" 2>/dev/null || true
    sleep 1
fi

# ── 7. Systemd ─────────────────────────────────────────────────────
log "Создание systemd-сервиса..." "Creating systemd service..."

systemctl stop redwing 2>/dev/null || true

cat > /etc/systemd/system/redwing.service << EOF
[Unit]
Description=RedWing Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/server
Restart=always
RestartSec=5
Environment=PORT=${PORT}
Environment=SERVER_IP=${SERVER_IP}
Environment=REGISTRATION=${REG_MODE}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now redwing

# ── 8. Проверка запуска / Verifying startup ───────────────────────
log "Ожидание запуска..." "Waiting for startup..."
sleep 3

if systemctl is-active --quiet redwing; then
    STATUS="${GREEN}работает / running${NC}"
else
    STATUS="${RED}не запустился / failed${NC}"
    warn "Проверьте логи: journalctl -u redwing -e" "Check logs: journalctl -u redwing -e"
fi

# ── 9. Итог / Summary ────────────────────────────────────────────
echo ""
echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}RedWing запущен! / RedWing is running!${NC}"
echo ""
echo -e "  ${CYAN}Панель / Panel:${NC}        ${BOLD}http://${SERVER_IP}:${PORT}${NC}"
echo -e "  ${CYAN}Статус / Status:${NC}       ${STATUS}"
echo -e "  ${CYAN}Директория / Dir:${NC}      ${INSTALL_DIR}"
echo -e "  ${CYAN}Логи / Logs:${NC}           journalctl -u redwing -f"
echo -e "  ${CYAN}Перезапуск / Restart:${NC}  systemctl restart redwing"
echo -e "  ${CYAN}Остановка / Stop:${NC}      systemctl stop redwing"
echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
