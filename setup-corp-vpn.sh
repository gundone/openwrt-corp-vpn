#!/bin/sh
#
# setup-corp-vpn.sh — Интерактивная настройка OpenConnect + Podkop на OpenWrt
#
# Использование:
#   Установка:
#     1. scp setup-corp-vpn.sh root@ROUTER:/tmp/
#     2. ssh root@ROUTER
#     3. sh /tmp/setup-corp-vpn.sh
#
#   Откат всех изменений:
#     sh /tmp/setup-corp-vpn.sh uninstall
#
# Если скрипт скопирован с Windows, исправьте переводы строк:
#   sed -i 's/\r$//' /tmp/setup-corp-vpn.sh
#

# ============================================================
# Константы
# ============================================================
IFACE_NAME="corp_vpn"
PODKOP_SECTION="corp"
PODKOP_PROXY_SECTION="corp_proxy"
VPNC_SCRIPT="/lib/netifd/vpnc-script"
AUTH_LOG="/tmp/oc_auth_result.log"
DAILY_SCRIPT="/usr/bin/corpvpn"
CORPVPN_UCI="corpvpn"
CORPVPN_UCI_SECTION="main"
RPCD_SCRIPT="/usr/libexec/rpcd/luci.corpvpn"
LUCI_VIEW="/www/luci-static/resources/view/corpvpn.js"
LUCI_MENU="/usr/share/luci/menu.d/luci-app-corpvpn.json"
LUCI_ACL="/usr/share/rpcd/acl.d/luci-app-corpvpn.json"
CORPVPN_VERSION="1.1.2"
CORPVPN_REPO="gundone/corpvpn-for-podkop"

# Собранные данные (заполняются в процессе)
VPN_SERVER=""
VPN_SERVERS_EXTRA=""
VPN_USER=""
VPN_PASS=""
VPN_PASS2=""
VPN_GROUP=""
CORP_DNS=""
CORP_DOMAINS=""
PROXY_SERVER=""
PROXY_PORT=""
PROXY_DOMAINS=""
AUTO_DISCONNECT_TIME=""

# ============================================================
# Цвета
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# Вспомогательные функции
# ============================================================
info()  { printf "${BLUE}[i]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
err()   { printf "${RED}[-]${NC} %s\n" "$1"; }

step() {
    printf "\n${BOLD}${CYAN}══════════════════════════════════════${NC}\n"
    printf "${BOLD}${CYAN}  Шаг %s: %s${NC}\n" "$1" "$2"
    printf "${BOLD}${CYAN}══════════════════════════════════════${NC}\n\n"
}

ask() {
    local prompt="$1" default="$2" answer
    if [ -n "$default" ]; then
        printf "${BOLD}%s${NC} [%s]: " "$prompt" "$default" >&2
    else
        printf "${BOLD}%s${NC}: " "$prompt" >&2
    fi
    read -r answer
    if [ -z "$answer" ] && [ -n "$default" ]; then
        echo "$default"
    else
        echo "$answer"
    fi
}

ask_password() {
    local prompt="$1" answer
    printf "${BOLD}%s${NC}: " "$prompt" >&2
    read -s -r answer
    printf "\n" >&2
    echo "$answer"
}

ask_yesno() {
    local prompt="$1" default="$2" answer
    if [ "$default" = "y" ]; then
        printf "${BOLD}%s${NC} [Y/n]: " "$prompt"
    else
        printf "${BOLD}%s${NC} [y/N]: " "$prompt"
    fi
    read -r answer
    case "$answer" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        "") [ "$default" = "y" ] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

cleanup() {
    rm -f "$AUTH_LOG"
    stty echo 2>/dev/null
}
trap cleanup EXIT

# ============================================================
# Шаг 0: Проверка предусловий
# ============================================================
check_prerequisites() {
    step "0" "Проверка системы"

    if [ ! -f /etc/openwrt_release ]; then
        err "Скрипт предназначен для OpenWrt. Запустите на роутере."
        exit 1
    fi

    . /etc/openwrt_release
    ok "OpenWrt: $DISTRIB_DESCRIPTION"

    if ! opkg list-installed 2>/dev/null | grep -q "^podkop "; then
        err "Podkop не установлен. Сначала установите Podkop."
        exit 1
    fi
    ok "Podkop установлен"

    if opkg list-installed 2>/dev/null | grep -q "^sing-box"; then
        ok "sing-box установлен"
    fi

    local mem_avail
    mem_avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    info "Свободная RAM: ${mem_avail}MB"

    if [ "$mem_avail" -lt 30 ]; then
        warn "Мало свободной памяти. OpenConnect может работать нестабильно."
    fi
}

# ============================================================
# Шаг 1: Установка пакетов
# ============================================================
install_packages() {
    step "1" "Установка пакетов"

    local oc_installed=0
    local luci_installed=0

    opkg list-installed 2>/dev/null | grep -q "^openconnect " && oc_installed=1
    opkg list-installed 2>/dev/null | grep -q "^luci-proto-openconnect " && luci_installed=1

    if [ "$oc_installed" -eq 1 ] && [ "$luci_installed" -eq 1 ]; then
        ok "Все пакеты уже установлены"
        return 0
    fi

    info "Обновление списка пакетов..."
    if ! opkg update > /dev/null 2>&1; then
        warn "opkg update завершился с ошибкой (может быть нормально)"
    fi

    if [ "$oc_installed" -eq 0 ]; then
        info "Установка openconnect..."
        if ! opkg install openconnect; then
            err "Не удалось установить openconnect"
            exit 1
        fi
    fi

    if [ "$luci_installed" -eq 0 ]; then
        info "Установка luci-proto-openconnect..."
        if ! opkg install luci-proto-openconnect; then
            warn "Не удалось установить luci-proto-openconnect (LuCI может быть недоступен)"
        fi
    fi

    # Перезапуск netifd для регистрации proto handler openconnect
    # Без этого ifup corp_vpn будет показывать proto=none
    info "Перезапуск сетевой подсистемы (SSH может на секунду оборваться)..."
    service network restart 2>/dev/null
    sleep 3
    service rpcd restart 2>/dev/null
    ok "Пакеты установлены"
}

# ============================================================
# Шаг 2: Сбор параметров VPN
# ============================================================
gather_vpn_info() {
    step "2" "Параметры корпоративного VPN"

    info "Все данные можно взять из AnyConnect/OpenConnect клиента на ПК."
    info "Откройте клиент и посмотрите, какие параметры используются при подключении."
    echo ""

    # --- VPN Server ---
    info "Адрес сервера — строка подключения в AnyConnect клиенте."
    info "Примеры: vpn.company.com, https://vpn.company.com/corp"
    VPN_SERVER=$(ask "URL VPN-сервера")

    # Добавить https:// если не указан протокол
    case "$VPN_SERVER" in
        https://*|http://*) ;;
        *) VPN_SERVER="https://$VPN_SERVER" ;;
    esac

    # --- Extra servers ---
    echo ""
    info "Можно добавить дополнительные серверы (те же учётные данные)."
    info "Первый сервер будет использоваться по умолчанию."
    if ask_yesno "Добавить дополнительные серверы?" "n"; then
        info "Введите адреса через пробел. Пример: vpn2.company.com vpn-eu.company.com"
        VPN_SERVERS_EXTRA=$(ask "Дополнительные серверы")
    fi

    # --- Username ---
    echo ""
    info "Логин — тот же, что вводите в AnyConnect при подключении."
    VPN_USER=$(ask "Имя пользователя")

    # --- Password ---
    echo ""
    info "Пароль — корпоративный пароль. Ввод скрыт, символы не отображаются."
    VPN_PASS=$(ask_password "Пароль")

    # --- Group ---
    echo ""
    info "GROUP — некоторые серверы показывают выпадающий список перед подключением."
    info "Если в AnyConnect нет выбора группы — ответьте 'n'."
    if ask_yesno "Сервер спрашивает GROUP при подключении?" "n"; then
        VPN_GROUP=$(ask "Название группы")
    fi

    # --- 2FA ---
    echo ""
    printf "${BOLD}Тип двухфакторной аутентификации:${NC}\n"
    info "Выберите способ, которым вы обычно подтверждаете вход в VPN."
    printf "  1) Push на телефон (Duo, MS Authenticator, Okta Verify)\n"
    printf "  2) TOTP-код из приложения (Google Authenticator и т.д.)\n"
    printf "  3) SMS-код\n"
    printf "  4) Нет 2FA / не уверен\n"
    local tfa_choice
    tfa_choice=$(ask "Выберите" "1")

    case "$tfa_choice" in
        1) VPN_PASS2="push" ;;
        2)
            VPN_PASS2="push"
            warn "TOTP-коды меняются каждые 30 сек."
            warn "Для тестирования будет предложен интерактивный режим."
            ;;
        3) VPN_PASS2="sms" ;;
        4) VPN_PASS2="" ;;
    esac

    echo ""
    ok "Параметры сохранены."
}

# ============================================================
# Шаг 3: Тестовое подключение
# ============================================================
test_connection() {
    step "3" "Тестовое подключение"

    if ! ask_yesno "Выполнить тест аутентификации?" "y"; then
        warn "Тест пропущен. Корп. DNS нужно будет ввести вручную."
        return 0
    fi

    info "Запускаю openconnect --authenticate..."
    info "Следуйте инструкциям на экране:"
    info "  - Примите сертификат (введите 'yes' если спросит)"
    info "  - Введите пароль"
    info "  - Подтвердите 2FA (push на телефон / введите код)"
    echo ""
    warn "Вывод openconnect ↓↓↓"
    echo "-----------------------------------------------------------"

    # stdout (COOKIE, FINGERPRINT) → файл
    # stderr (промпты, статус) → терминал
    openconnect --authenticate \
        --user="$VPN_USER" \
        --useragent="AnyConnect" \
        ${VPN_GROUP:+--authgroup="$VPN_GROUP"} \
        "$VPN_SERVER" > "$AUTH_LOG"

    local rc=$?
    echo "-----------------------------------------------------------"

    if [ $rc -eq 0 ] && grep -q "^COOKIE=" "$AUTH_LOG" 2>/dev/null; then
        ok "Аутентификация успешна!"
    else
        err "Аутентификация не удалась (код: $rc)"

        if [ -f "$AUTH_LOG" ] && [ -s "$AUTH_LOG" ]; then
            warn "Содержимое ответа:"
            cat "$AUTH_LOG"
        fi

        echo ""
        warn "Возможные причины:"
        warn "  - Неверный пароль или логин"
        warn "  - 2FA не подтверждена вовремя"
        warn "  - Сервер использует Duo HTML-форму (не поддерживается)"
        warn "  - Проблемы с сертификатом"
        echo ""

        if ! ask_yesno "Продолжить настройку (можно исправить позже)?" "y"; then
            exit 1
        fi
    fi

    rm -f "$AUTH_LOG"
}

# ============================================================
# Шаг 4: Патч vpnc-script (защита DNS)
# ============================================================
patch_vpnc_script() {
    step "4" "Защита DNS от перезаписи"

    if [ ! -f "$VPNC_SCRIPT" ]; then
        warn "Файл $VPNC_SCRIPT не найден. Пропускаю."
        return 0
    fi

    # Проверить, нужен ли патч
    if ! grep -q '/tmp/dnsmasq.d/openconnect' "$VPNC_SCRIPT"; then
        ok "vpnc-script уже пропатчен или не содержит DNS-записи"
        return 0
    fi

    info "Проблема: vpnc-script пишет DNS-конфиг VPN в /tmp/dnsmasq.d/"
    info "Это ломает Podkop, подменяя DNS-резолвер."
    info "Патч перенаправит файл в /tmp/ (вне dnsmasq)."
    echo ""

    if ! ask_yesno "Применить патч?" "y"; then
        warn "Патч пропущен. DNS может конфликтовать!"
        return 0
    fi

    # Бэкап
    if [ ! -f "${VPNC_SCRIPT}.bak.podkop" ]; then
        cp "$VPNC_SCRIPT" "${VPNC_SCRIPT}.bak.podkop"
        info "Бэкап: ${VPNC_SCRIPT}.bak.podkop"
    fi

    # Патч: перенаправить DNS-файл из /tmp/dnsmasq.d/ в /tmp/
    sed -i 's|/tmp/dnsmasq\.d/openconnect\.|/tmp/openconnect-dns.|g' "$VPNC_SCRIPT"

    # Проверка
    if grep -q '/tmp/dnsmasq.d/openconnect' "$VPNC_SCRIPT"; then
        err "Патч не применился! Отредактируйте $VPNC_SCRIPT вручную:"
        err "Замените /tmp/dnsmasq.d/openconnect. на /tmp/openconnect-dns."
    else
        ok "vpnc-script пропатчен"
    fi
}

# ============================================================
# Шаг 5: Настройка сетевого интерфейса
# ============================================================
setup_interface() {
    step "5" "Настройка интерфейса OpenConnect"

    # Проверить, существует ли интерфейс
    if uci -q get "network.$IFACE_NAME" > /dev/null 2>&1; then
        warn "Интерфейс '$IFACE_NAME' уже существует."
        if ask_yesno "Перезаписать конфигурацию?" "y"; then
            uci delete "network.$IFACE_NAME"
        else
            ok "Используем существующий интерфейс"
            return 0
        fi
    fi

    info "Создаю интерфейс $IFACE_NAME..."

    uci set "network.$IFACE_NAME=interface"
    uci set "network.$IFACE_NAME.proto=openconnect"
    uci set "network.$IFACE_NAME.uri=$VPN_SERVER"
    uci set "network.$IFACE_NAME.username=$VPN_USER"
    uci set "network.$IFACE_NAME.password=$VPN_PASS"

    if [ -n "$VPN_PASS2" ]; then
        uci set "network.$IFACE_NAME.password2=$VPN_PASS2"
    fi

    if [ -n "$VPN_GROUP" ]; then
        uci set "network.$IFACE_NAME.authgroup=$VPN_GROUP"
    fi

    # Критично: не трогать маршрут по умолчанию и DNS
    uci set "network.$IFACE_NAME.defaultroute=0"
    uci set "network.$IFACE_NAME.peerdns=0"

    # Не запускать при загрузке (2FA не пройдёт без пользователя)
    uci set "network.$IFACE_NAME.auto=0"

    uci commit network

    ok "Интерфейс создан"

    echo ""
    info "Конфигурация:"
    uci show "network.$IFACE_NAME" | sed 's/\.password=.*/.password=***HIDDEN***/'
}

# ============================================================
# Шаг 6: Настройка Podkop
# ============================================================
gather_podkop_info() {
    echo ""
    info "Введите корпоративные домены (через пробел)."
    info "Пример: gitlab.corp.com jira.corp.com wiki.corp.com"
    CORP_DOMAINS=$(ask "Домены")

    echo ""
    if [ -z "$CORP_DNS" ]; then
        info "Корпоративный DNS-сервер нужен для резолва внутренних доменов."
        info "Узнайте у сисадминов или из настроек AnyConnect клиента."
        info "Типичные значения: 10.x.x.x, 172.x.x.x"
        info "Оставьте пустым, если не знаете (настроите позже в LuCI)."
        CORP_DNS=$(ask "IP корпоративного DNS" "")
    else
        info "Корпоративный DNS (из теста): $CORP_DNS"
        if ! ask_yesno "Использовать этот DNS?" "y"; then
            CORP_DNS=$(ask "IP корпоративного DNS" "$CORP_DNS")
        fi
    fi
}

setup_podkop() {
    step "6" "Настройка секции Podkop"

    gather_podkop_info

    if [ -z "$CORP_DOMAINS" ]; then
        warn "Домены не указаны. Настройте позже в LuCI → Services → Podkop."
        return 0
    fi

    # Показать текущую конфигурацию Podkop
    info "Текущие секции Podkop:"
    uci show podkop 2>/dev/null | grep "=section" | sed 's/podkop\.\(.*\)=section/  - \1/'
    echo ""

    # Проверить, существует ли секция
    if uci -q get "podkop.$PODKOP_SECTION" > /dev/null 2>&1; then
        warn "Секция '$PODKOP_SECTION' уже существует в Podkop."
        if ask_yesno "Перезаписать?" "y"; then
            uci delete "podkop.$PODKOP_SECTION"
        else
            ok "Используем существующую секцию"
            return 0
        fi
    fi

    info "Создаю секцию '$PODKOP_SECTION'..."

    uci set "podkop.$PODKOP_SECTION=section"
    uci set "podkop.$PODKOP_SECTION.connection_type=vpn"
    # sing-box bind_interface требует имя устройства (vpn-X), а не UCI-интерфейса (X)
    uci set "podkop.$PODKOP_SECTION.interface=vpn-$IFACE_NAME"

    # Domain Resolver (Split DNS через VPN-туннель)
    if [ -n "$CORP_DNS" ]; then
        uci set "podkop.$PODKOP_SECTION.domain_resolver_enabled=1"
        uci set "podkop.$PODKOP_SECTION.domain_resolver_dns_type=udp"
        uci set "podkop.$PODKOP_SECTION.domain_resolver_dns_server=$CORP_DNS"
        info "Domain Resolver → $CORP_DNS (UDP)"
    fi

    # Пользовательские домены
    uci set "podkop.$PODKOP_SECTION.user_domain_list_type=text"
    uci set "podkop.$PODKOP_SECTION.user_domains_text=$CORP_DOMAINS"

    uci commit podkop

    ok "Секция Podkop создана"

    echo ""
    info "Конфигурация секции:"
    uci show "podkop.$PODKOP_SECTION" 2>/dev/null

    echo ""
    warn "Проверьте секцию в LuCI → Services → Podkop"
    warn "Если опции не отображаются корректно, настройте вручную:"
    warn "  Connection Type: VPN"
    warn "  Interface: $IFACE_NAME"
    warn "  Domain Resolver: UDP, $CORP_DNS"
    warn "  User Domain List: $CORP_DOMAINS"
}

# ============================================================
# Шаг 6b: HTTP-прокси для части корп. ресурсов
# ============================================================
gather_proxy_info() {
    echo ""
    info "Некоторые корп. ресурсы (Jira, Confluence и т.д.) могут быть доступны"
    info "только через HTTP-прокси внутри VPN. Обычно это настраивается"
    info "расширением ProxyOmega или PAC-файлом в браузере."
    echo ""

    if ! ask_yesno "Нужен ли HTTP-прокси для части корп. ресурсов?" "n"; then
        return 0
    fi

    echo ""
    info "Параметры прокси — из расширения ProxyOmega / настроек браузера."
    PROXY_SERVER=$(ask "IP-адрес прокси-сервера" "198.18.4.1")
    PROXY_PORT=$(ask "Порт прокси" "3129")

    echo ""
    info "Введите домены, которым нужен прокси (через пробел)."
    info "Пример: jira.company.com confluence.company.com"
    PROXY_DOMAINS=$(ask "Домены для прокси")
}

setup_podkop_proxy() {
    if [ -z "$PROXY_DOMAINS" ] || [ -z "$PROXY_SERVER" ]; then
        return 0
    fi

    info "Настройка прокси-секции Podkop..."

    if uci -q get "podkop.$PODKOP_PROXY_SECTION" > /dev/null 2>&1; then
        warn "Секция '$PODKOP_PROXY_SECTION' уже существует в Podkop."
        if ask_yesno "Перезаписать?" "y"; then
            uci delete "podkop.$PODKOP_PROXY_SECTION"
        else
            ok "Используем существующую секцию"
            return 0
        fi
    fi

    local outbound_json
    outbound_json="{\"type\":\"http\",\"server\":\"$PROXY_SERVER\",\"server_port\":$PROXY_PORT,\"bind_interface\":\"vpn-$IFACE_NAME\"}"

    uci set "podkop.$PODKOP_PROXY_SECTION=section"
    uci set "podkop.$PODKOP_PROXY_SECTION.connection_type=proxy"
    uci set "podkop.$PODKOP_PROXY_SECTION.proxy_config_type=outbound"
    uci set "podkop.$PODKOP_PROXY_SECTION.outbound_json=$outbound_json"

    # Domain Resolver (тот же корп. DNS)
    if [ -n "$CORP_DNS" ]; then
        uci set "podkop.$PODKOP_PROXY_SECTION.domain_resolver_enabled=1"
        uci set "podkop.$PODKOP_PROXY_SECTION.domain_resolver_dns_type=udp"
        uci set "podkop.$PODKOP_PROXY_SECTION.domain_resolver_dns_server=$CORP_DNS"
    fi

    # Домены для прокси
    uci set "podkop.$PODKOP_PROXY_SECTION.user_domain_list_type=text"
    uci set "podkop.$PODKOP_PROXY_SECTION.user_domains_text=$PROXY_DOMAINS"

    uci commit podkop

    ok "Прокси-секция Podkop создана"

    echo ""
    info "Конфигурация прокси-секции:"
    uci show "podkop.$PODKOP_PROXY_SECTION" 2>/dev/null

    echo ""
    info "Домены из этой секции пойдут через HTTP-прокси $PROXY_SERVER:$PROXY_PORT"
    info "внутри VPN-тоннеля (bind_interface=vpn-$IFACE_NAME)"
}

# ============================================================
# Шаг 6d: Приоритет секций Podkop
# ============================================================
reorder_podkop_sections() {
    info "Настройка приоритета секций Podkop..."

    # Позиция 0 — settings, начинаем с 1
    local pos=1

    # 1. Exclusion-секции первыми
    for s in $(uci -q show podkop 2>/dev/null | grep "\.connection_type='exclusion'" | \
               sed "s/podkop\.//;s/\.connection_type.*//"); do
        uci reorder "podkop.$s=$pos"
        pos=$((pos + 1))
    done

    # 2. corp_proxy
    if uci -q get "podkop.$PODKOP_PROXY_SECTION" > /dev/null 2>&1; then
        uci reorder "podkop.$PODKOP_PROXY_SECTION=$pos"
        pos=$((pos + 1))
    fi

    # 3. corp
    if uci -q get "podkop.$PODKOP_SECTION" > /dev/null 2>&1; then
        uci reorder "podkop.$PODKOP_SECTION=$pos"
        pos=$((pos + 1))
    fi

    # 4. main и остальные секции остаются после
    uci commit podkop
    ok "Приоритет: exclusion → corp_proxy → corp → main"
}

# ============================================================
# Шаг 6c: UCI-конфиг corpvpn (список серверов и настройки)
# ============================================================
create_uci_config() {
    info "Создаю UCI-конфиг /etc/config/$CORPVPN_UCI..."

    [ -f "/etc/config/$CORPVPN_UCI" ] || touch "/etc/config/$CORPVPN_UCI"

    if uci -q get "$CORPVPN_UCI.$CORPVPN_UCI_SECTION" > /dev/null 2>&1; then
        uci delete "$CORPVPN_UCI.$CORPVPN_UCI_SECTION"
    fi

    uci set "$CORPVPN_UCI.$CORPVPN_UCI_SECTION=$CORPVPN_UCI"

    # Добавить серверы
    uci add_list "$CORPVPN_UCI.$CORPVPN_UCI_SECTION.servers=$VPN_SERVER"
    for s in $VPN_SERVERS_EXTRA; do
        case "$s" in
            https://*|http://*) ;;
            *) s="https://$s" ;;
        esac
        uci add_list "$CORPVPN_UCI.$CORPVPN_UCI_SECTION.servers=$s"
    done

    uci set "$CORPVPN_UCI.$CORPVPN_UCI_SECTION.version=$CORPVPN_VERSION"
    uci commit "$CORPVPN_UCI"
    ok "UCI-конфиг создан (v$CORPVPN_VERSION)"
}

# ============================================================
# Шаг 7: Создание скрипта для ежедневного использования
# ============================================================
create_daily_script() {
    step "7" "Скрипт для ежедневного использования"

    info "Создаю $DAILY_SCRIPT..."

    cat > "$DAILY_SCRIPT" << 'SCRIPT_EOF'
#!/bin/sh
#
# corpvpn — управление корпоративным VPN
# Использование: corpvpn [connect|disconnect|status|servers|addhost|delhost|schedule|unschedule]
#

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

IFACE="corp_vpn"
UCI_CONFIG="corpvpn"
UCI_SECTION="main"
CRON_TAG="corpvpn-auto-disconnect"
CONNECT_TIMEOUT=120

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

get_servers() {
    local line
    line=$(uci -q show "$UCI_CONFIG.$UCI_SECTION.servers" 2>/dev/null) || return
    echo "$line" | sed "s/^${UCI_CONFIG}\.${UCI_SECTION}\.servers=//;s/'//g"
}

server_count() {
    local count=0
    for s in $(get_servers); do
        count=$((count + 1))
    done
    echo "$count"
}

get_status() {
    ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null
}

show_status() {
    local up
    up=$(get_status)
    if [ "$up" = "true" ]; then
        local ip uri route_count
        ip=$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
        uri=$(uci -q get "network.$IFACE.uri")
        route_count=$(ip route | grep -c "dev vpn-$IFACE" 2>/dev/null)
        printf "${GREEN}[VPN]${NC} Подключен (IP: %s, сервер: %s)\n" "${ip:-N/A}" "${uri:-N/A}"
        if [ "$route_count" -gt 0 ]; then
            printf "${BLUE}[i]${NC} Split-include маршрутов: %s\n" "$route_count"
        fi
    else
        printf "${RED}[VPN]${NC} Отключен\n"
    fi
    local sched_time
    sched_time=$(uci -q get "$UCI_CONFIG.$UCI_SECTION.disconnect_time")
    if [ -n "$sched_time" ]; then
        printf "${BLUE}[i]${NC} Автоотключение: %s\n" "$sched_time"
    fi
}

do_routes() {
    local up
    up=$(get_status)
    if [ "$up" != "true" ]; then
        printf "${RED}[VPN]${NC} Отключен — маршрутов нет\n"
        return 1
    fi
    printf "${BOLD}Split-include маршруты через VPN:${NC}\n"
    ip route | grep "dev vpn-$IFACE" | while IFS= read -r line; do
        printf "  %s\n" "$line"
    done
    local count
    count=$(ip route | grep -c "dev vpn-$IFACE" 2>/dev/null)
    printf "${BLUE}[i]${NC} Всего: %s\n" "${count:-0}"
}

show_servers() {
    local current_uri i s
    current_uri=$(uci -q get "network.$IFACE.uri")
    i=1
    for s in $(get_servers); do
        if [ "$s" = "$current_uri" ]; then
            printf "  ${GREEN}%d) %s (текущий)${NC}\n" "$i" "$s"
        else
            printf "  %d) %s\n" "$i" "$s"
        fi
        i=$((i + 1))
    done
}

resolve_server() {
    local requested="$1"
    if [ -z "$requested" ]; then
        return
    fi
    case "$requested" in
        [0-9]|[0-9][0-9])
            local i=1
            for s in $(get_servers); do
                if [ "$i" = "$requested" ]; then
                    echo "$s"
                    return
                fi
                i=$((i + 1))
            done
            ;;
        *)
            case "$requested" in
                https://*|http://*) echo "$requested" ;;
                *) echo "https://$requested" ;;
            esac
            ;;
    esac
}

switch_server() {
    local target="$1"
    local current_uri
    current_uri=$(uci -q get "network.$IFACE.uri")
    if [ "$target" != "$current_uri" ]; then
        uci set "network.$IFACE.uri=$target"
        uci commit network
        printf "${BLUE}[i]${NC} Сервер: %s\n" "$target"
    fi
}

sync_routes_to_podkop() {
    local routes=""
    local route
    for route in $(ip route 2>/dev/null | grep "dev vpn-$IFACE" | awk '{print $1}'); do
        routes="${routes:+$routes }$route"
    done
    if [ -n "$routes" ]; then
        uci set "podkop.corp.user_subnet_list_type=text"
        uci set "podkop.corp.user_subnets_text=$routes"
        uci commit podkop
        local count
        count=$(echo "$routes" | wc -w)
        printf "${BLUE}[i]${NC} Split-include → Podkop: %s подсетей\n" "$count"
    fi
}

do_connect() {
    local requested="$1"

    # Если сервер не указан и их несколько — показать меню
    if [ -z "$requested" ] && [ "$(server_count)" -gt 1 ]; then
        printf "${BOLD}Выберите сервер:${NC}\n"
        show_servers
        printf "${BOLD}Номер${NC} [1]: "
        read -r requested
        requested="${requested:-1}"
    fi

    # Переключение сервера, если указан
    if [ -n "$requested" ]; then
        local target
        target=$(resolve_server "$requested")
        if [ -z "$target" ]; then
            printf "${RED}[-]${NC} Сервер #%s не найден\n" "$requested"
            show_servers
            return 1
        fi
        switch_server "$target"
    fi

    local up
    up=$(get_status)
    if [ "$up" = "true" ]; then
        printf "${YELLOW}[!]${NC} VPN уже подключен\n"
        show_status
        return 0
    fi

    printf "${BLUE}[i]${NC} Подключение к корпоративному VPN...\n"
    printf "${YELLOW}[!]${NC} Подтвердите 2FA на телефоне!\n"
    ifup "$IFACE"

    # Ждём подключения (макс. CONNECT_TIMEOUT сек ≈ 2 попытки 2FA)
    local i=0
    printf "${BLUE}[i]${NC} Ожидание (макс. %s сек) " "$CONNECT_TIMEOUT"
    while [ $i -lt $CONNECT_TIMEOUT ]; do
        up=$(get_status)
        if [ "$up" = "true" ]; then
            printf "\n"
            printf "${GREEN}[+]${NC} Подключен!\n"
            show_status
            sync_routes_to_podkop
            printf "${BLUE}[i]${NC} Перезапуск Podkop...\n"
            service podkop restart > /dev/null 2>&1
            sleep 2
            printf "${GREEN}[+]${NC} Podkop перезапущен\n"
            return 0
        fi
        printf "."
        sleep 2
        i=$((i + 2))
    done

    printf "\n"
    printf "${RED}[-]${NC} Не удалось подключиться за %s сек.\n" "$CONNECT_TIMEOUT"
    printf "${YELLOW}[!]${NC} Отменяю попытку подключения...\n"
    ifdown "$IFACE"
    printf "${BLUE}[i]${NC} Проверьте: logread | grep openconnect\n"
    return 1
}

do_disconnect() {
    printf "${BLUE}[i]${NC} Отключение VPN...\n"
    ifdown "$IFACE"
    sleep 1
    printf "${GREEN}[+]${NC} VPN отключен\n"
}

do_restart() {
    local requested="$1"
    do_disconnect
    sleep 2
    # Без аргумента — переподключиться к текущему серверу (без меню)
    if [ -z "$requested" ]; then
        requested=$(uci -q get "network.$IFACE.uri")
    fi
    do_connect "$requested"
}

do_addhost() {
    local host="$1"
    if [ -z "$host" ]; then
        printf "${BOLD}Адрес сервера:${NC} "
        read -r host
    fi
    if [ -z "$host" ]; then
        printf "${RED}[-]${NC} Адрес не указан\n"
        return 1
    fi
    case "$host" in
        https://*|http://*) ;;
        *) host="https://$host" ;;
    esac
    # Проверка дубликатов
    for s in $(get_servers); do
        if [ "$s" = "$host" ]; then
            printf "${YELLOW}[!]${NC} Сервер %s уже в списке\n" "$host"
            return 0
        fi
    done
    uci add_list "$UCI_CONFIG.$UCI_SECTION.servers=$host"
    uci commit "$UCI_CONFIG"
    printf "${GREEN}[+]${NC} Добавлен: %s\n" "$host"
    show_servers
}

do_delhost() {
    local requested="$1"
    if [ -z "$requested" ]; then
        show_servers
        printf "${BOLD}Номер сервера для удаления:${NC} "
        read -r requested
    fi
    if [ -z "$requested" ]; then
        printf "${RED}[-]${NC} Номер не указан\n"
        return 1
    fi
    if [ "$(server_count)" -le 1 ]; then
        printf "${RED}[-]${NC} Нельзя удалить единственный сервер\n"
        return 1
    fi
    local target
    target=$(resolve_server "$requested")
    if [ -z "$target" ]; then
        printf "${RED}[-]${NC} Сервер #%s не найден\n" "$requested"
        return 1
    fi
    uci del_list "$UCI_CONFIG.$UCI_SECTION.servers=$target"
    uci commit "$UCI_CONFIG"
    printf "${GREEN}[+]${NC} Удалён: %s\n" "$target"
    show_servers
}

do_schedule() {
    local time="${1:-21:00}"
    case "$time" in
        [0-1][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
        *)
            printf "${RED}[-]${NC} Неверный формат: %s (ожидается HH:MM, 00:00–23:59)\n" "$time"
            return 1
            ;;
    esac
    local hour="${time%%:*}"
    local minute="${time##*:}"
    uci set "$UCI_CONFIG.$UCI_SECTION.disconnect_time=$time"
    uci commit "$UCI_CONFIG"
    if [ -f /etc/crontabs/root ]; then
        sed -i "/$CRON_TAG/d" /etc/crontabs/root
    fi
    echo "$minute $hour * * * /usr/bin/corpvpn disconnect  # $CRON_TAG" >> /etc/crontabs/root
    /etc/init.d/cron restart 2>/dev/null
    printf "${GREEN}[+]${NC} Автоотключение: каждый день в %s\n" "$time"
}

do_unschedule() {
    uci -q delete "$UCI_CONFIG.$UCI_SECTION.disconnect_time"
    uci commit "$UCI_CONFIG"
    if [ -f /etc/crontabs/root ] && grep -q "$CRON_TAG" /etc/crontabs/root; then
        sed -i "/$CRON_TAG/d" /etc/crontabs/root
        /etc/init.d/cron restart 2>/dev/null
    fi
    printf "${GREEN}[+]${NC} Автоотключение отменено\n"
}

show_help() {
    printf "${BOLD}Использование:${NC} corpvpn [команда]\n\n"
    printf "  ${BOLD}connect${NC} [N|host]    Подключиться (нужно подтвердить 2FA)\n"
    printf "  ${BOLD}disconnect${NC}          Отключиться\n"
    printf "  ${BOLD}status${NC}              Показать статус\n"
    printf "  ${BOLD}restart${NC} [N|host]    Переподключиться\n"
    printf "  ${BOLD}servers${NC}             Показать список серверов\n"
    printf "  ${BOLD}addhost${NC} [host]      Добавить сервер\n"
    printf "  ${BOLD}delhost${NC} [N]         Удалить сервер\n"
    printf "  ${BOLD}routes${NC}              Split-include маршруты через VPN\n"
    printf "  ${BOLD}schedule${NC} [HH:MM]   Автоотключение по расписанию (по умолч. 21:00)\n"
    printf "  ${BOLD}unschedule${NC}          Отменить автоотключение\n"
    printf "  ${BOLD}logs${NC}                Показать логи OpenConnect\n"
    printf "  ${BOLD}help${NC}                Эта справка\n"
}

case "${1:-status}" in
    connect|up|on)       do_connect "$2" ;;
    disconnect|down|off) do_disconnect ;;
    status|st)           show_status ;;
    restart|re)          do_restart "$2" ;;
    servers|srv)         show_servers ;;
    addhost)             do_addhost "$2" ;;
    delhost|rmhost)      do_delhost "$2" ;;
    routes|rt)           do_routes ;;
    schedule|sched)      do_schedule "$2" ;;
    unschedule|unsched)  do_unschedule ;;
    logs|log)            logread | grep -i openconnect | tail -30 ;;
    help|--help|-h)      show_help ;;
    *)
        printf "${RED}[-]${NC} Неизвестная команда: %s\n" "$1"
        show_help
        exit 1
        ;;
esac
SCRIPT_EOF

    chmod +x "$DAILY_SCRIPT"
    ok "Скрипт создан: $DAILY_SCRIPT"

    echo ""
    info "Команды:"
    info "  corpvpn connect          — подключиться (выбор сервера)"
    info "  corpvpn disconnect       — отключиться"
    info "  corpvpn status           — статус"
    info "  corpvpn servers          — список серверов"
    info "  corpvpn addhost <host>   — добавить сервер"
    info "  corpvpn delhost <N>      — удалить сервер"
    info "  corpvpn restart          — переподключиться"
    info "  corpvpn schedule [HH:MM] — автоотключение (по умолч. 21:00)"
    info "  corpvpn unschedule       — отменить автоотключение"
    info "  corpvpn logs             — логи"
}

# ============================================================
# Шаг 7b: Автоотключение по расписанию
# ============================================================
setup_auto_disconnect() {
    echo ""
    info "Можно настроить автоматическое отключение VPN по расписанию."
    info "Например, каждый день в 21:00 — чтобы VPN не оставался на ночь."
    echo ""

    if ! ask_yesno "Настроить автоотключение VPN?" "y"; then
        return 0
    fi

    AUTO_DISCONNECT_TIME=$(ask "Время отключения (HH:MM)" "21:00")

    case "$AUTO_DISCONNECT_TIME" in
        [0-1][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
        *)
            warn "Неверный формат времени. Автоотключение не настроено."
            warn "Можно настроить позже: corpvpn schedule 21:00"
            AUTO_DISCONNECT_TIME=""
            return 0
            ;;
    esac

    local hour="${AUTO_DISCONNECT_TIME%%:*}"
    local minute="${AUTO_DISCONNECT_TIME##*:}"

    # Сохранить в UCI
    uci set "$CORPVPN_UCI.$CORPVPN_UCI_SECTION.disconnect_time=$AUTO_DISCONNECT_TIME"
    uci commit "$CORPVPN_UCI"

    # Обновить cron
    if [ -f /etc/crontabs/root ]; then
        sed -i "/corpvpn-auto-disconnect/d" /etc/crontabs/root
    fi

    echo "$minute $hour * * * /usr/bin/corpvpn disconnect  # corpvpn-auto-disconnect" >> /etc/crontabs/root
    /etc/init.d/cron restart 2>/dev/null

    ok "Автоотключение: каждый день в $AUTO_DISCONNECT_TIME"
}

# ============================================================
# Шаг 7c: LuCI-приложение (веб-интерфейс управления)
# ============================================================
deploy_luci_app() {
    step "7c" "Установка LuCI-приложения"

    info "Создаю страницу управления в LuCI (Services → Corp VPN)..."

    # --- Меню ---
    mkdir -p "$(dirname "$LUCI_MENU")"
    cat > "$LUCI_MENU" << 'MENU_EOF'
{
    "admin/services/corpvpn": {
        "title": "Corp VPN",
        "order": 90,
        "action": {
            "type": "view",
            "path": "corpvpn"
        },
        "depends": {
            "acl": ["luci-app-corpvpn"],
            "uci": { "corpvpn": true }
        }
    }
}
MENU_EOF
    ok "Меню создано"

    # --- ACL ---
    mkdir -p "$(dirname "$LUCI_ACL")"
    cat > "$LUCI_ACL" << 'ACL_EOF'
{
    "luci-app-corpvpn": {
        "description": "Grant access to Corp VPN management",
        "read": {
            "ubus": {
                "luci.corpvpn": ["getStatus", "getRoutes", "checkVersion", "getLogs"],
                "uci": ["corpvpn", "network"]
            },
            "uci": ["corpvpn", "network"]
        },
        "write": {
            "ubus": {
                "luci.corpvpn": ["connect", "disconnect", "restartPodkop", "setSchedule", "removeSchedule", "doUpgrade"],
                "uci": ["corpvpn", "network"]
            },
            "uci": ["corpvpn", "network"]
        }
    }
}
ACL_EOF
    ok "ACL создан"

    # --- rpcd-плагин (бэкенд) ---
    mkdir -p "$(dirname "$RPCD_SCRIPT")"
    cat > "$RPCD_SCRIPT" << 'RPCD_EOF'
#!/bin/sh

. /usr/share/libubox/jshn.sh

case "$1" in
    list)
        echo '{"getStatus":{},"getRoutes":{},"checkVersion":{},"getLogs":{},"doUpgrade":{},"connect":{"server":"str"},"disconnect":{},"restartPodkop":{},"setSchedule":{"time":"str"},"removeSchedule":{}}'
        ;;
    call)
        case "$2" in
            getStatus)
                _json=$(ifstatus corp_vpn 2>/dev/null)
                _up=$(echo "$_json" | jsonfilter -e '@.up' 2>/dev/null)
                _pending=$(echo "$_json" | jsonfilter -e '@.pending' 2>/dev/null)
                _ip=$(echo "$_json" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
                _uri=$(uci -q get network.corp_vpn.uri)
                _oc_running=$(pgrep -x openconnect > /dev/null 2>&1 && echo 1 || echo 0)
                json_init
                if [ "$_up" = "true" ]; then
                    json_add_boolean "up" 1
                    json_add_boolean "pending" 0
                elif [ "$_pending" = "true" ] || [ "$_oc_running" = "1" ]; then
                    json_add_boolean "up" 0
                    json_add_boolean "pending" 1
                else
                    json_add_boolean "up" 0
                    json_add_boolean "pending" 0
                fi
                json_add_string "ip" "${_ip:-}"
                json_add_string "server" "${_uri:-}"
                _rc=$(ip route 2>/dev/null | grep -c "dev vpn-corp_vpn")
                json_add_int "route_count" "${_rc:-0}"
                json_dump
                ;;
            getRoutes)
                _tmpfile="/tmp/.corpvpn_routes"
                ip route 2>/dev/null | grep "dev vpn-corp_vpn" | awk '{print $1}' > "$_tmpfile"
                json_init
                json_add_array "routes"
                while IFS= read -r _r; do
                    json_add_string "" "$_r"
                done < "$_tmpfile"
                json_close_array
                rm -f "$_tmpfile"
                json_dump
                ;;
            checkVersion)
                _current=$(uci -q get corpvpn.main.version)
                _latest=$(wget -qO- "https://raw.githubusercontent.com/gundone/corpvpn-for-podkop/main/VERSION?t=$(date +%s)" 2>/dev/null | head -1 | tr -d '[:space:]')
                json_init
                json_add_string "current" "${_current:-unknown}"
                json_add_string "latest" "${_latest:-unknown}"
                json_dump
                ;;
            getLogs)
                _tmpfile="/tmp/.corpvpn_logs"
                logread 2>/dev/null | grep -i openconnect | tail -50 > "$_tmpfile"
                json_init
                json_add_array "lines"
                while IFS= read -r _line; do
                    json_add_string "" "$_line"
                done < "$_tmpfile"
                json_close_array
                rm -f "$_tmpfile"
                json_dump
                ;;
            doUpgrade)
                (wget -qO /tmp/setup-corp-vpn.sh "https://raw.githubusercontent.com/gundone/corpvpn-for-podkop/main/setup-corp-vpn.sh" 2>/dev/null && sh /tmp/setup-corp-vpn.sh upgrade > /tmp/corpvpn-upgrade.log 2>&1; rm -f /tmp/setup-corp-vpn.sh) &
                json_init
                json_add_boolean "ok" 1
                json_dump
                ;;
            connect)
                read -r input
                json_load "$input"
                json_get_var server server
                if [ -n "$server" ]; then
                    uci set "network.corp_vpn.uri=$server"
                    uci commit network
                fi
                ifup corp_vpn 2>/dev/null
                json_init
                json_add_boolean "ok" 1
                json_dump
                ;;
            disconnect)
                ifdown corp_vpn 2>/dev/null
                json_init
                json_add_boolean "ok" 1
                json_dump
                ;;
            restartPodkop)
                # Sync split-include routes to Podkop before restart
                _routes=""
                for _r in $(ip route 2>/dev/null | grep "dev vpn-corp_vpn" | awk '{print $1}'); do
                    _routes="${_routes:+$_routes }$_r"
                done
                if [ -n "$_routes" ]; then
                    uci set "podkop.corp.user_subnet_list_type=text"
                    uci set "podkop.corp.user_subnets_text=$_routes"
                    uci commit podkop
                fi
                service podkop restart > /dev/null 2>&1
                json_init
                json_add_boolean "ok" 1
                json_dump
                ;;
            setSchedule)
                read -r input
                json_load "$input"
                json_get_var time time
                if [ -n "$time" ]; then
                    /usr/bin/corpvpn schedule "$time" > /dev/null 2>&1
                fi
                json_init
                json_add_boolean "ok" 1
                json_dump
                ;;
            removeSchedule)
                /usr/bin/corpvpn unschedule > /dev/null 2>&1
                json_init
                json_add_boolean "ok" 1
                json_dump
                ;;
        esac
        ;;
esac
RPCD_EOF
    chmod +x "$RPCD_SCRIPT"
    ok "rpcd-плагин создан"

    # --- LuCI View (JS) ---
    mkdir -p "$(dirname "$LUCI_VIEW")"
    cat > "$LUCI_VIEW" << 'VIEW_EOF'
'use strict';
'require view';
'require dom';
'require ui';
'require uci';
'require rpc';
'require poll';

var callGetStatus = rpc.declare({
    object: 'luci.corpvpn',
    method: 'getStatus'
});

var callGetRoutes = rpc.declare({
    object: 'luci.corpvpn',
    method: 'getRoutes'
});

var callConnect = rpc.declare({
    object: 'luci.corpvpn',
    method: 'connect',
    params: ['server']
});

var callDisconnect = rpc.declare({
    object: 'luci.corpvpn',
    method: 'disconnect'
});

var callRestartPodkop = rpc.declare({
    object: 'luci.corpvpn',
    method: 'restartPodkop'
});

var callSetSchedule = rpc.declare({
    object: 'luci.corpvpn',
    method: 'setSchedule',
    params: ['time']
});

var callRemoveSchedule = rpc.declare({
    object: 'luci.corpvpn',
    method: 'removeSchedule'
});

var callCheckVersion = rpc.declare({
    object: 'luci.corpvpn',
    method: 'checkVersion'
});

var callGetLogs = rpc.declare({
    object: 'luci.corpvpn',
    method: 'getLogs'
});

var callDoUpgrade = rpc.declare({
    object: 'luci.corpvpn',
    method: 'doUpgrade'
});

function statusColor(s) {
    if (s && s.up) return '#4caf50';
    if (s && s.pending) return '#ff9800';
    return '#f44336';
}

function statusText(s) {
    if (s && s.up) return 'Подключен';
    if (s && s.pending) return 'Подключение...';
    return 'Отключен';
}

return view.extend({
    load: function() {
        return Promise.all([
            uci.load('corpvpn'),
            uci.load('network'),
            callGetStatus()
        ]);
    },

    pollStatus: function() {
        return callGetStatus().then(function(s) {
            var dot = document.getElementById('vpn-dot');
            var txt = document.getElementById('vpn-status-text');
            var ipEl = document.getElementById('vpn-ip');
            var srvEl = document.getElementById('vpn-srv');
            var rtEl = document.getElementById('vpn-routes');
            if (!dot) return;
            dot.style.background = statusColor(s);
            txt.textContent = statusText(s);
            ipEl.textContent = (s && s.up) ? 'IP: ' + (s.ip || 'N/A') : '';
            srvEl.textContent = 'Сервер: ' + ((s && s.server) || 'N/A');
            if (rtEl) {
                rtEl.textContent = (s && s.up && s.route_count) ? 'Маршрутов: ' + s.route_count : '';
            }
        });
    },

    render: function(data) {
        var status = data[2] || {};
        var servers = uci.get('corpvpn', 'main', 'servers') || [];
        var disconnectTime = uci.get('corpvpn', 'main', 'disconnect_time') || '';
        var currentUri = uci.get('network', 'corp_vpn', 'uri') || '';
        var self = this;

        if (typeof servers === 'string') servers = [servers];

        /* ── Статус ── */
        var statusBox = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, 'Статус'),
            E('div', { style: 'padding:8px 0' }, [
                E('div', { style: 'display:flex;align-items:center;margin-bottom:4px' }, [
                    E('span', { id: 'vpn-dot', style: 'display:inline-block;width:12px;height:12px;border-radius:50%;margin-right:8px;background:' + statusColor(status) }),
                    E('strong', { id: 'vpn-status-text' }, statusText(status))
                ]),
                E('div', { id: 'vpn-ip' }, status.up ? 'IP: ' + (status.ip || 'N/A') : ''),
                E('div', { id: 'vpn-srv' }, 'Сервер: ' + (status.server || 'N/A')),
                E('div', { id: 'vpn-routes' }, (status.up && status.route_count) ? 'Маршрутов: ' + status.route_count : '')
            ])
        ]);

        /* ── Подключение ── */
        var select = E('select', { id: 'vpn-server-select', 'class': 'cbi-input-select', style: 'min-width:300px' });
        servers.forEach(function(srv) {
            select.appendChild(E('option', { value: srv, selected: srv === currentUri ? '' : null }, srv));
        });

        var connBox = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, 'Подключение'),
            E('div', { style: 'margin-bottom:10px' }, [
                E('label', { style: 'display:block;margin-bottom:4px;font-weight:bold' }, 'Сервер:'),
                select
            ]),
            E('div', { style: 'display:flex;gap:6px;flex-wrap:wrap' }, [
                E('button', {
                    'class': 'cbi-button cbi-button-apply',
                    click: ui.createHandlerFn(this, function() {
                        var srv = document.getElementById('vpn-server-select').value;
                        return callConnect(srv).then(function() {
                            ui.addNotification(null, E('p', 'Подключение... Подтвердите 2FA на телефоне!'), 'info');
                        });
                    })
                }, 'Подключиться'),
                E('button', {
                    'class': 'cbi-button cbi-button-reset',
                    click: ui.createHandlerFn(this, function() {
                        return callDisconnect().then(function() {
                            ui.addNotification(null, E('p', 'VPN отключен'), 'success');
                        });
                    })
                }, 'Отключиться'),
                E('button', {
                    'class': 'cbi-button cbi-button-action',
                    click: ui.createHandlerFn(this, function() {
                        return callRestartPodkop().then(function() {
                            ui.addNotification(null, E('p', 'Podkop перезапущен'), 'success');
                        });
                    })
                }, 'Перезапустить Podkop')
            ])
        ]);

        /* ── Серверы ── */
        var serverList = E('div', {});
        servers.forEach(function(srv) {
            serverList.appendChild(E('div', { style: 'display:flex;align-items:center;padding:4px 0;gap:8px' }, [
                E('span', { style: 'flex:1' }, srv),
                E('button', {
                    'class': 'cbi-button cbi-button-remove',
                    'data-server': srv,
                    click: ui.createHandlerFn(self, function(ev) {
                        var target = ev.currentTarget.getAttribute('data-server');
                        var cur = uci.get('corpvpn', 'main', 'servers') || [];
                        if (typeof cur === 'string') cur = [cur];
                        if (cur.length <= 1) {
                            ui.addNotification(null, E('p', 'Нельзя удалить единственный сервер'), 'warning');
                            return;
                        }
                        uci.set('corpvpn', 'main', 'servers', cur.filter(function(s) { return s !== target; }));
                        return uci.save().then(function() { return uci.apply(true); }).then(function() { location.reload(); });
                    })
                }, 'Удалить')
            ]));
        });

        var serversBox = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, 'Серверы'),
            serverList,
            E('div', { style: 'display:flex;gap:8px;margin-top:8px;align-items:center' }, [
                E('input', { id: 'new-server-input', type: 'text', 'class': 'cbi-input-text', placeholder: 'vpn.company.com', style: 'flex:1' }),
                E('button', {
                    'class': 'cbi-button cbi-button-add',
                    click: ui.createHandlerFn(this, function() {
                        var val = document.getElementById('new-server-input').value.trim();
                        if (!val) return;
                        if (!/^https?:\/\//.test(val)) val = 'https://' + val;
                        var cur = uci.get('corpvpn', 'main', 'servers') || [];
                        if (typeof cur === 'string') cur = [cur];
                        if (cur.indexOf(val) !== -1) {
                            ui.addNotification(null, E('p', 'Сервер уже в списке'), 'warning');
                            return;
                        }
                        cur.push(val);
                        uci.set('corpvpn', 'main', 'servers', cur);
                        return uci.save().then(function() { return uci.apply(true); }).then(function() { location.reload(); });
                    })
                }, 'Добавить')
            ])
        ]);

        /* ── Маршруты ── */
        var routesContent = E('div', { id: 'routes-list' }, [
            E('p', { style: 'color:#999' }, status.up ? 'Загрузка...' : 'VPN отключен')
        ]);

        var routesBox = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, 'Split-include маршруты'),
            E('p', { style: 'color:#666;margin-bottom:8px;font-size:90%' },
                'Маршруты, которые VPN-сервер передаёт клиенту. Трафик к этим адресам идёт через VPN-туннель.'),
            routesContent
        ]);

        if (status.up) {
            callGetRoutes().then(function(data) {
                var el = document.getElementById('routes-list');
                if (!el || !data) return;
                var routes = data.routes || [];
                if (routes.length === 0) {
                    dom.content(el, E('p', { style: 'color:#999' }, 'Нет маршрутов (full tunnel или сервер не передаёт split-include)'));
                    return;
                }
                var items = routes.map(function(r) {
                    return E('div', { style: 'font-family:monospace;padding:1px 0' }, r);
                });
                items.push(E('div', { style: 'margin-top:6px;color:#666' }, 'Всего: ' + routes.length));
                dom.content(el, items);
            });
        }

        /* ── Автоотключение ── */
        var scheduleBox = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, 'Автоотключение'),
            E('div', { style: 'display:flex;gap:8px;align-items:center;flex-wrap:wrap' }, [
                E('label', {}, 'Время:'),
                E('input', { id: 'disconnect-time', type: 'time', 'class': 'cbi-input-text', value: disconnectTime, style: 'width:130px' }),
                E('button', {
                    'class': 'cbi-button cbi-button-apply',
                    click: ui.createHandlerFn(this, function() {
                        var t = document.getElementById('disconnect-time').value;
                        if (!t) return;
                        return callSetSchedule(t).then(function() {
                            uci.set('corpvpn', 'main', 'disconnect_time', t);
                            ui.addNotification(null, E('p', 'Автоотключение: каждый день в ' + t), 'success');
                        });
                    })
                }, 'Сохранить'),
                E('button', {
                    'class': 'cbi-button cbi-button-remove',
                    click: ui.createHandlerFn(this, function() {
                        return callRemoveSchedule().then(function() {
                            uci.unset('corpvpn', 'main', 'disconnect_time');
                            document.getElementById('disconnect-time').value = '';
                            ui.addNotification(null, E('p', 'Автоотключение отменено'), 'success');
                        });
                    })
                }, 'Отключить')
            ]),
            disconnectTime
                ? E('p', { style: 'color:#4caf50;margin-top:6px' }, 'Активно: отключение каждый день в ' + disconnectTime)
                : E('p', { style: 'color:#999;margin-top:6px' }, 'Не настроено')
        ]);

        /* ── Автообновление статуса ── */
        poll.add(L.bind(this.pollStatus, this), 5);

        /* ══════════ Вкладка: Диагностика ══════════ */

        /* ── Версия ── */
        var versionInfo = E('div', { id: 'version-info' }, [
            E('p', { style: 'color:#999' }, 'Загрузка...')
        ]);

        var versionBox = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, 'Версия'),
            versionInfo
        ]);

        callCheckVersion().then(function(v) {
            var el = document.getElementById('version-info');
            if (!el || !v) return;
            var cur = v.current || 'unknown';
            var lat = v.latest || 'unknown';
            var needsUpdate = (cur !== lat && lat !== 'unknown' && cur !== 'unknown');
            var items = [
                E('div', { style: 'margin:4px 0' }, [
                    E('strong', {}, 'Установлена: '), E('span', {}, cur)
                ]),
                E('div', { style: 'margin:4px 0' }, [
                    E('strong', {}, 'Доступна: '),
                    E('span', { style: needsUpdate ? 'color:#ff9800;font-weight:bold' : '' }, lat)
                ])
            ];
            if (needsUpdate) {
                items.push(E('button', {
                    'class': 'cbi-button cbi-button-apply',
                    style: 'margin-top:8px',
                    click: ui.createHandlerFn(self, function() {
                        if (!confirm('Обновить corpvpn до версии ' + lat + '?')) return;
                        return callDoUpgrade().then(function() {
                            ui.addNotification(null, E('p', 'Обновление запущено в фоне. Страница обновится через 30 секунд...'), 'info');
                            setTimeout(function() { location.reload(); }, 30000);
                        });
                    })
                }, 'Обновить до ' + lat));
            } else if (cur !== 'unknown') {
                items.push(E('p', { style: 'color:#4caf50;margin-top:4px' }, 'Актуальная версия'));
            }
            dom.content(el, items);
        });

        /* ── Логи ── */
        var logsBox = E('div', { 'class': 'cbi-section' }, [
            E('h3', {}, 'Логи OpenConnect'),
            E('button', {
                'class': 'cbi-button cbi-button-action',
                click: ui.createHandlerFn(this, function() {
                    return callGetLogs().then(function(data) {
                        var el = document.getElementById('log-output');
                        if (!el || !data) return;
                        var lines = data.lines || [];
                        if (lines.length === 0) {
                            dom.content(el, E('p', { style: 'color:#999' }, 'Логи пусты'));
                        } else {
                            dom.content(el, E('pre', {
                                style: 'max-height:400px;overflow:auto;background:#1a1a2e;color:#e0e0e0;padding:10px;border-radius:4px;font-size:12px;line-height:1.4;white-space:pre-wrap;word-break:break-all'
                            }, lines.join('\n')));
                        }
                    });
                })
            }, 'Загрузить логи'),
            E('div', { id: 'log-output', style: 'margin-top:8px' })
        ]);

        /* ══════════ Вкладки ══════════ */
        var contentMain = E('div', {}, [statusBox, connBox, serversBox, routesBox, scheduleBox]);
        var contentDiag = E('div', { style: 'display:none' }, [versionBox, logsBox]);

        var tabMainBtn = E('li', { 'class': 'cbi-tab' }, E('a', { href: '#' }, 'Управление'));
        var tabDiagBtn = E('li', { 'class': 'cbi-tab-disabled' }, E('a', { href: '#' }, 'Диагностика'));

        tabMainBtn.addEventListener('click', function(e) {
            e.preventDefault();
            contentMain.style.display = '';
            contentDiag.style.display = 'none';
            tabMainBtn.className = 'cbi-tab';
            tabDiagBtn.className = 'cbi-tab-disabled';
        });

        tabDiagBtn.addEventListener('click', function(e) {
            e.preventDefault();
            contentMain.style.display = 'none';
            contentDiag.style.display = '';
            tabMainBtn.className = 'cbi-tab-disabled';
            tabDiagBtn.className = 'cbi-tab';
        });

        return E('div', {}, [
            E('h2', {}, 'Corp VPN'),
            E('ul', { 'class': 'cbi-tabmenu' }, [tabMainBtn, tabDiagBtn]),
            contentMain,
            contentDiag
        ]);
    }
});
VIEW_EOF
    ok "LuCI View создан"

    # Перезапуск rpcd для загрузки нового плагина
    info "Перезапуск rpcd..."
    service rpcd restart 2>/dev/null
    sleep 1
    ok "LuCI-приложение установлено: Services → Corp VPN"
}

# ============================================================
# Шаг 8: Первое подключение и проверка
# ============================================================
first_connect() {
    step "8" "Первое подключение"

    if ! ask_yesno "Подключиться к корп. VPN сейчас?" "y"; then
        info "Пропущено. Для подключения: corpvpn connect"
        return 0
    fi

    info "Подключение к $VPN_SERVER..."
    warn "Подтвердите 2FA на телефоне!"
    echo ""
    ifup "$IFACE_NAME"

    # Ожидание подключения (макс. 120 сек ≈ 2 попытки 2FA)
    local i=0
    local max_wait=120
    printf "Ожидание (макс. %sс) " "$max_wait"
    while [ $i -lt $max_wait ]; do
        local up
        up=$(ifstatus "$IFACE_NAME" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)
        if [ "$up" = "true" ]; then
            printf "\n"
            ok "VPN подключен!"

            local vpn_ip
            vpn_ip=$(ifstatus "$IFACE_NAME" 2>/dev/null | \
                jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
            info "VPN IP: ${vpn_ip:-N/A}"

            # Перезапуск Podkop ПОСЛЕ подключения VPN,
            # чтобы sing-box увидел интерфейс vpn-corp_vpn
            info "Перезапуск Podkop (чтобы увидел VPN-интерфейс)..."
            service podkop restart
            sleep 3
            ok "Podkop перезапущен"
            return 0
        fi
        printf "."
        sleep 2
        i=$((i + 2))
    done

    printf "\n"
    err "Не удалось подключиться за ${max_wait}с."
    warn "Отменяю попытку подключения..."
    ifdown "$IFACE_NAME" 2>/dev/null
    warn "Проверьте логи: logread | grep openconnect"
}

# ============================================================
# Шаг 9: Проверка
# ============================================================
verify() {
    step "9" "Проверка"

    local all_ok=1

    # Проверка sing-box
    if netstat -tlnp 2>/dev/null | grep -q "127.0.0.42:53"; then
        ok "sing-box слушает на 127.0.0.42:53"
    else
        warn "sing-box не найден на 127.0.0.42:53"
        all_ok=0
    fi

    # Проверка dnsmasq
    if ! grep -q '/tmp/dnsmasq.d/openconnect' /tmp/dnsmasq.d/* 2>/dev/null; then
        ok "DNS не перезаписан OpenConnect"
    else
        err "Найден DNS-конфиг OpenConnect в /tmp/dnsmasq.d/"
        err "Патч vpnc-script не работает!"
        all_ok=0
    fi

    # Проверка интерфейса VPN
    local up
    up=$(ifstatus "$IFACE_NAME" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)
    if [ "$up" = "true" ]; then
        ok "Интерфейс $IFACE_NAME поднят"

        # Проверка маршрутов
        local routes
        routes=$(ip route | grep -c "$IFACE_NAME" 2>/dev/null)
        if [ "$routes" -gt 0 ]; then
            ok "Маршруты через VPN: $routes шт."
        else
            warn "Маршрутов через $IFACE_NAME не найдено"
        fi
    else
        warn "Интерфейс $IFACE_NAME не поднят (ожидаемо, если пропустили подключение)"
    fi

    # Проверка Podkop секции
    if uci -q get "podkop.$PODKOP_SECTION.connection_type" > /dev/null 2>&1; then
        ok "Секция Podkop '$PODKOP_SECTION' существует"
    else
        warn "Секция Podkop '$PODKOP_SECTION' не найдена"
        all_ok=0
    fi

    # Проверка прокси-секции (если создавалась)
    if uci -q get "podkop.$PODKOP_PROXY_SECTION.connection_type" > /dev/null 2>&1; then
        ok "Прокси-секция Podkop '$PODKOP_PROXY_SECTION' существует"
    fi

    # Проверка LuCI-приложения
    if [ -f "$LUCI_VIEW" ] && [ -f "$RPCD_SCRIPT" ]; then
        ok "LuCI-приложение установлено"
    else
        warn "LuCI-приложение не найдено"
        all_ok=0
    fi

    # Проверка Podkop работает
    if pgrep -f sing-box > /dev/null 2>&1; then
        ok "Podkop (sing-box) работает"
    else
        warn "sing-box не запущен"
        all_ok=0
    fi

    echo ""
    if [ "$all_ok" -eq 1 ]; then
        ok "Все проверки пройдены!"
    else
        warn "Есть предупреждения — проверьте их выше."
    fi
}

# ============================================================
# Откат всех изменений
# ============================================================
uninstall() {
    printf "${BOLD}${RED}"
    printf "╔══════════════════════════════════════════╗\n"
    printf "║  OpenConnect + Podkop — ОТКАТ            ║\n"
    printf "╚══════════════════════════════════════════╝\n"
    printf "${NC}\n"

    warn "Будут отменены ВСЕ изменения, сделанные скриптом установки:"
    echo ""
    printf "  1. Отключение VPN-интерфейса %s\n" "$IFACE_NAME"
    printf "  2. Удаление интерфейса из /etc/config/network\n"
    printf "  3. Удаление секций '%s' и '%s' из /etc/config/podkop\n" "$PODKOP_SECTION" "$PODKOP_PROXY_SECTION"
    printf "  4. Восстановление vpnc-script из бэкапа\n"
    printf "  5. Удаление скрипта %s\n" "$DAILY_SCRIPT"
    printf "  6. Удаление автоотключения из cron\n"
    printf "  7. Удаление LuCI-приложения и UCI-конфига\n"
    printf "  8. (опционально) Удаление пакетов openconnect\n"
    echo ""

    if ! ask_yesno "Продолжить откат?" "n"; then
        info "Откат отменён."
        exit 0
    fi

    echo ""
    uninstall_disconnect
    uninstall_interface
    uninstall_podkop
    uninstall_vpnc_patch
    uninstall_daily_script
    uninstall_cron
    uninstall_luci_app
    uninstall_uci_config
    uninstall_packages
    uninstall_restart_services
    uninstall_summary
}

uninstall_disconnect() {
    info "Отключение VPN..."
    local up
    up=$(ifstatus "$IFACE_NAME" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)
    if [ "$up" = "true" ]; then
        ifdown "$IFACE_NAME" 2>/dev/null
        sleep 1
        ok "VPN отключен"
    else
        ok "VPN уже отключен"
    fi
}

uninstall_interface() {
    info "Удаление интерфейса $IFACE_NAME..."
    if uci -q get "network.$IFACE_NAME" > /dev/null 2>&1; then
        uci delete "network.$IFACE_NAME"
        uci commit network
        ok "Интерфейс удалён из /etc/config/network"
    else
        ok "Интерфейс $IFACE_NAME не найден (уже удалён)"
    fi
}

uninstall_podkop() {
    info "Удаление секции Podkop '$PODKOP_SECTION'..."
    if uci -q get "podkop.$PODKOP_SECTION" > /dev/null 2>&1; then
        uci delete "podkop.$PODKOP_SECTION"
        ok "Секция '$PODKOP_SECTION' удалена из /etc/config/podkop"
    else
        ok "Секция '$PODKOP_SECTION' не найдена (уже удалена)"
    fi

    info "Удаление прокси-секции '$PODKOP_PROXY_SECTION'..."
    if uci -q get "podkop.$PODKOP_PROXY_SECTION" > /dev/null 2>&1; then
        uci delete "podkop.$PODKOP_PROXY_SECTION"
        ok "Секция '$PODKOP_PROXY_SECTION' удалена из /etc/config/podkop"
    else
        ok "Секция '$PODKOP_PROXY_SECTION' не найдена (уже удалена)"
    fi

    uci commit podkop
}

uninstall_vpnc_patch() {
    info "Восстановление vpnc-script..."
    local backup="${VPNC_SCRIPT}.bak.podkop"

    if [ -f "$backup" ]; then
        cp "$backup" "$VPNC_SCRIPT"
        rm -f "$backup"
        ok "vpnc-script восстановлен из бэкапа"
    elif [ -f "$VPNC_SCRIPT" ]; then
        # Бэкапа нет — проверить, пропатчен ли файл
        if grep -q '/tmp/openconnect-dns\.' "$VPNC_SCRIPT"; then
            warn "Бэкап не найден, но vpnc-script пропатчен."
            warn "Пытаюсь откатить патч..."
            sed -i 's|/tmp/openconnect-dns\.|/tmp/dnsmasq.d/openconnect.|g' "$VPNC_SCRIPT"
            if grep -q '/tmp/dnsmasq.d/openconnect' "$VPNC_SCRIPT"; then
                ok "Патч откачен (обратная замена)"
            else
                err "Не удалось откатить патч. Проверьте $VPNC_SCRIPT вручную."
            fi
        else
            ok "vpnc-script не пропатчен (откат не нужен)"
        fi
    else
        ok "vpnc-script не найден (откат не нужен)"
    fi
}

uninstall_daily_script() {
    info "Удаление скрипта $DAILY_SCRIPT..."
    if [ -f "$DAILY_SCRIPT" ]; then
        rm -f "$DAILY_SCRIPT"
        ok "Скрипт удалён"
    else
        ok "Скрипт не найден (уже удалён)"
    fi
}

uninstall_cron() {
    info "Удаление автоотключения из cron..."
    if [ -f /etc/crontabs/root ] && grep -q "corpvpn-auto-disconnect" /etc/crontabs/root; then
        sed -i "/corpvpn-auto-disconnect/d" /etc/crontabs/root
        /etc/init.d/cron restart 2>/dev/null
        ok "Автоотключение удалено из cron"
    else
        ok "Автоотключение не было настроено"
    fi
}

uninstall_luci_app() {
    info "Удаление LuCI-приложения..."
    rm -f "$LUCI_VIEW" "$LUCI_MENU" "$LUCI_ACL" "$RPCD_SCRIPT"
    ok "LuCI-приложение удалено"
}

uninstall_uci_config() {
    info "Удаление UCI-конфига /etc/config/$CORPVPN_UCI..."
    if [ -f "/etc/config/$CORPVPN_UCI" ]; then
        rm -f "/etc/config/$CORPVPN_UCI"
        ok "UCI-конфиг удалён"
    else
        ok "UCI-конфиг не найден (уже удалён)"
    fi
}

uninstall_packages() {
    echo ""
    if ! ask_yesno "Удалить пакеты openconnect и luci-proto-openconnect?" "n"; then
        info "Пакеты оставлены."
        return 0
    fi

    if opkg list-installed 2>/dev/null | grep -q "^luci-proto-openconnect "; then
        info "Удаление luci-proto-openconnect..."
        opkg remove luci-proto-openconnect 2>/dev/null
    fi

    if opkg list-installed 2>/dev/null | grep -q "^openconnect "; then
        info "Удаление openconnect..."
        opkg remove openconnect 2>/dev/null
    fi

    ok "Пакеты удалены"
}

uninstall_restart_services() {
    info "Перезапуск сервисов..."
    service network reload 2>/dev/null
    service podkop restart 2>/dev/null
    service rpcd restart 2>/dev/null
    sleep 2
    ok "Сервисы перезапущены"
}

uninstall_summary() {
    printf "\n${BOLD}${GREEN}══════════════════════════════════════${NC}\n"
    printf "${BOLD}${GREEN}  Откат завершён!${NC}\n"
    printf "${BOLD}${GREEN}══════════════════════════════════════${NC}\n\n"

    info "Все изменения, сделанные скриптом установки, отменены."
    info "Podkop должен работать как до установки OpenConnect."
    echo ""

    info "Проверьте:"
    printf "  service podkop status        Podkop работает\n"
    printf "  nslookup fakeip.podkop.fyi   FakeIP работает (с клиента)\n"
    printf "  uci show network             Нет интерфейса %s\n" "$IFACE_NAME"
    printf "  uci show podkop              Нет секций %s, %s\n" "$PODKOP_SECTION" "$PODKOP_PROXY_SECTION"
    echo ""
}

# ============================================================
# Финальная сводка
# ============================================================
show_summary() {
    printf "\n${BOLD}${GREEN}══════════════════════════════════════${NC}\n"
    printf "${BOLD}${GREEN}  Настройка завершена!${NC}\n"
    printf "${BOLD}${GREEN}══════════════════════════════════════${NC}\n\n"

    printf "${BOLD}Ежедневное использование:${NC}\n"
    printf "  corpvpn connect        Подключиться (+ 2FA)\n"
    printf "  corpvpn disconnect     Отключиться\n"
    printf "  corpvpn status         Проверить статус\n"
    printf "  corpvpn servers        Список серверов\n"
    printf "  corpvpn addhost        Добавить сервер\n"
    printf "  corpvpn delhost        Удалить сервер\n"
    printf "  corpvpn schedule       Автоотключение (по умолч. 21:00)\n"
    printf "  corpvpn unschedule     Отменить автоотключение\n"
    printf "  corpvpn logs           Посмотреть логи\n"
    echo ""

    if [ -n "$AUTO_DISCONNECT_TIME" ]; then
        printf "${BOLD}Автоотключение:${NC} каждый день в %s\n" "$AUTO_DISCONNECT_TIME"
        printf "  Изменить:  corpvpn schedule 22:00\n"
        printf "  Отменить:  corpvpn unschedule\n"
    fi
    echo ""

    printf "${BOLD}Веб-интерфейс (LuCI):${NC}\n"
    printf "  Services → Corp VPN          Управление VPN из браузера\n"
    printf "  Network → Interfaces → %s\n" "$IFACE_NAME"
    printf "  Services → Podkop → секция '%s'\n" "$PODKOP_SECTION"
    if [ -n "$PROXY_DOMAINS" ]; then
        printf "  Services → Podkop → секция '%s' (HTTP-прокси)\n" "$PODKOP_PROXY_SECTION"
    fi
    echo ""

    printf "${BOLD}Если что-то не работает:${NC}\n"
    printf "  logread | grep openconnect   Логи VPN\n"
    printf "  logread | grep sing-box      Логи Podkop\n"
    printf "  service podkop restart       Перезапуск Podkop\n"
    printf "  ls /tmp/dnsmasq.d/           Проверка DNS (не должно быть openconnect.*)\n"
    echo ""

}

# ============================================================
# Обновление на текущих параметрах
# ============================================================
read_existing_config() {
    info "Чтение текущей конфигурации..."

    if ! uci -q get "network.$IFACE_NAME.uri" > /dev/null 2>&1; then
        err "Интерфейс $IFACE_NAME не найден. Выполните полную установку:"
        err "  sh $0 install"
        exit 1
    fi

    VPN_SERVER=$(uci -q get "network.$IFACE_NAME.uri")
    VPN_USER=$(uci -q get "network.$IFACE_NAME.username")
    ok "VPN-сервер: $VPN_SERVER"
    ok "Пользователь: ${VPN_USER:-N/A}"

    # Серверы: из UCI corpvpn (новый формат) или из старого скрипта
    UCI_CONFIG_EXISTS=0
    if uci -q show "$CORPVPN_UCI.$CORPVPN_UCI_SECTION.servers" > /dev/null 2>&1; then
        UCI_CONFIG_EXISTS=1
        ok "UCI-конфиг найден — серверы сохранены"
    elif [ -f "$DAILY_SCRIPT" ] && grep -q "^VPN_SERVERS=" "$DAILY_SCRIPT"; then
        info "Миграция серверов из старого скрипта..."
        old_servers=$(grep "^VPN_SERVERS=" "$DAILY_SCRIPT" | sed 's/^VPN_SERVERS="//;s/"$//')
        first=1
        VPN_SERVERS_EXTRA=""
        for s in $old_servers; do
            if [ $first -eq 1 ]; then
                VPN_SERVER="$s"
                first=0
            else
                VPN_SERVERS_EXTRA="${VPN_SERVERS_EXTRA:+$VPN_SERVERS_EXTRA }$s"
            fi
        done
        ok "Серверы из старого скрипта: $VPN_SERVER $VPN_SERVERS_EXTRA"
    else
        VPN_SERVERS_EXTRA=""
        info "Один сервер: $VPN_SERVER"
    fi

    # Автоотключение: из UCI или из cron
    AUTO_DISCONNECT_TIME=$(uci -q get "$CORPVPN_UCI.$CORPVPN_UCI_SECTION.disconnect_time")
    if [ -z "$AUTO_DISCONNECT_TIME" ] && [ -f /etc/crontabs/root ]; then
        cron_line=$(grep "corpvpn-auto-disconnect" /etc/crontabs/root 2>/dev/null | head -1)
        if [ -n "$cron_line" ]; then
            cron_min=$(echo "$cron_line" | awk '{print $1}')
            cron_hour=$(echo "$cron_line" | awk '{print $2}')
            AUTO_DISCONNECT_TIME=$(printf "%02d:%02d" "$cron_hour" "$cron_min")
        fi
    fi
    if [ -n "$AUTO_DISCONNECT_TIME" ]; then
        ok "Автоотключение: $AUTO_DISCONNECT_TIME"
    fi

    echo ""
}

main_upgrade() {
    printf "${BOLD}${CYAN}"
    printf "╔══════════════════════════════════════════╗\n"
    printf "║  OpenConnect + Podkop — ОБНОВЛЕНИЕ       ║\n"
    printf "║  Корпоративный VPN на OpenWrt            ║\n"
    printf "╚══════════════════════════════════════════╝\n"
    printf "${NC}\n"

    info "Обновление скриптов и LuCI без изменения параметров VPN."
    echo ""

    read_existing_config

    # UCI-конфиг: создать если отсутствует, иначе сохранить
    if [ "$UCI_CONFIG_EXISTS" = "0" ]; then
        create_uci_config
    else
        ok "UCI-конфиг сохранён без изменений"
    fi

    create_daily_script
    reorder_podkop_sections

    # Синхронизация автоотключения (UCI + cron)
    if [ -n "$AUTO_DISCONNECT_TIME" ]; then
        "$DAILY_SCRIPT" schedule "$AUTO_DISCONNECT_TIME" > /dev/null 2>&1
        ok "Расписание синхронизировано: $AUTO_DISCONNECT_TIME"
    fi

    deploy_luci_app

    # Обновить версию в UCI
    uci set "$CORPVPN_UCI.$CORPVPN_UCI_SECTION.version=$CORPVPN_VERSION"
    uci commit "$CORPVPN_UCI"

    printf "\n${BOLD}${GREEN}══════════════════════════════════════${NC}\n"
    printf "${BOLD}${GREEN}  Обновление завершено (v$CORPVPN_VERSION)!${NC}\n"
    printf "${BOLD}${GREEN}══════════════════════════════════════${NC}\n\n"

    printf "${BOLD}Обновлено:${NC}\n"
    printf "  /usr/bin/corpvpn              Утилита командной строки\n"
    if [ "$UCI_CONFIG_EXISTS" = "0" ]; then
        printf "  /etc/config/corpvpn           UCI-конфиг (создан)\n"
    fi
    printf "  Services → Corp VPN           LuCI-приложение\n"
    echo ""

    printf "${BOLD}Не изменено:${NC}\n"
    printf "  Сетевой интерфейс %s\n" "$IFACE_NAME"
    printf "  Секции Podkop\n"
    printf "  Патч vpnc-script\n"
    echo ""
}

# ============================================================
# main
# ============================================================
main_install() {
    printf "${BOLD}${CYAN}"
    printf "╔══════════════════════════════════════════╗\n"
    printf "║  OpenConnect + Podkop Setup Wizard       ║\n"
    printf "║  Корпоративный VPN на OpenWrt            ║\n"
    printf "╚══════════════════════════════════════════╝\n"
    printf "${NC}\n"

    # Проверка: если уже установлен — предложить upgrade
    if uci -q get "network.$IFACE_NAME.uri" > /dev/null 2>&1; then
        warn "Обнаружена существующая установка ($IFACE_NAME)."
        echo ""
        printf "  ${BOLD}1)${NC} Обновить (upgrade) — обновить скрипты, сохранив параметры\n"
        printf "  ${BOLD}2)${NC} Переустановить (clean install) — настроить всё заново\n"
        echo ""
        local install_choice
        install_choice=$(ask "Выберите" "1")
        case "$install_choice" in
            1)
                main_upgrade
                return 0
                ;;
            2)
                warn "Будет выполнена полная переустановка."
                if ! ask_yesno "Продолжить?" "y"; then
                    info "Отменено."
                    exit 0
                fi
                ;;
        esac
    fi

    check_prerequisites
    install_packages
    gather_vpn_info
    test_connection
    patch_vpnc_script
    setup_interface
    setup_podkop
    gather_proxy_info
    setup_podkop_proxy
    reorder_podkop_sections
    create_uci_config
    create_daily_script
    setup_auto_disconnect
    deploy_luci_app
    first_connect
    verify
    show_summary
}

show_usage() {
    printf "${BOLD}Использование:${NC}\n"
    printf "  sh %s              Установка (интерактивный мастер)\n" "$0"
    printf "  sh %s upgrade      Обновить скрипты на текущих параметрах\n" "$0"
    printf "  sh %s uninstall    Откат всех изменений\n" "$0"
    printf "  sh %s help         Эта справка\n" "$0"
}

case "${1:-install}" in
    install|setup)     main_install ;;
    upgrade|update)    main_upgrade ;;
    uninstall|remove)  uninstall ;;
    help|--help|-h)    show_usage ;;
    *)
        err "Неизвестная команда: $1"
        show_usage
        exit 1
        ;;
esac
