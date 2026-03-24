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
VPNC_SCRIPT="/lib/netifd/vpnc-script"
AUTH_LOG="/tmp/oc_auth_result.log"
DAILY_SCRIPT="/usr/bin/corp-vpn"

# Собранные данные (заполняются в процессе)
VPN_SERVER=""
VPN_USER=""
VPN_PASS=""
VPN_PASS2=""
VPN_GROUP=""
VPN_SERVERHASH=""
CORP_DNS=""
CORP_DOMAINS=""

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
    read answer
    if [ -z "$answer" ] && [ -n "$default" ]; then
        echo "$default"
    else
        echo "$answer"
    fi
}

ask_password() {
    local prompt="$1" answer
    printf "${BOLD}%s${NC}: " "$prompt" >&2
    stty -echo 2>/dev/null
    read answer
    stty echo 2>/dev/null
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
    read answer
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

    # --- Server hash ---
    echo ""
    info "Хэш сертификата — уникальный отпечаток VPN-сервера для безопасности."
    info "Если не знаете — ответьте 'n'. Скрипт получит его автоматически на шаге тестирования."
    if ask_yesno "Знаете SHA256-хэш сертификата VPN-сервера?" "n"; then
        VPN_SERVERHASH=$(ask "Хэш (формат: pin-sha256:... или sha256:...)")
    fi

    echo ""
    ok "Параметры сохранены."
}

# ============================================================
# Шаг 3: Тестовое подключение
# ============================================================
test_connection() {
    step "3" "Тестовое подключение"

    if ! ask_yesno "Выполнить тест аутентификации?" "y"; then
        warn "Тест пропущен. Хэш сертификата и корп. DNS нужно будет ввести вручную."
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
        ${VPN_SERVERHASH:+--servercert="$VPN_SERVERHASH"} \
        "$VPN_SERVER" > "$AUTH_LOG"

    local rc=$?
    echo "-----------------------------------------------------------"

    if [ $rc -eq 0 ] && grep -q "^COOKIE=" "$AUTH_LOG" 2>/dev/null; then
        ok "Аутентификация успешна!"

        # Извлечь хэш сертификата
        local hash
        hash=$(grep "^FINGERPRINT=" "$AUTH_LOG" | head -1 | cut -d= -f2)
        if [ -n "$hash" ]; then
            VPN_SERVERHASH="$hash"
            info "Хэш сертификата: $hash"
        fi
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

    if [ -n "$VPN_SERVERHASH" ]; then
        uci set "network.$IFACE_NAME.serverhash=$VPN_SERVERHASH"
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
    uci set "podkop.$PODKOP_SECTION.interface=$IFACE_NAME"

    # Domain Resolver (Split DNS через VPN-туннель)
    if [ -n "$CORP_DNS" ]; then
        uci set "podkop.$PODKOP_SECTION.domain_resolver_enabled=1"
        uci set "podkop.$PODKOP_SECTION.domain_resolver_dns_type=udp"
        uci set "podkop.$PODKOP_SECTION.domain_resolver_dns_server=$CORP_DNS"
        info "Domain Resolver → $CORP_DNS (UDP)"
    fi

    # Пользовательские домены
    uci set "podkop.$PODKOP_SECTION.user_domain_list_type=text"
    uci set "podkop.$PODKOP_SECTION.user_domain_list=$CORP_DOMAINS"

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
# Шаг 7: Создание скрипта для ежедневного использования
# ============================================================
create_daily_script() {
    step "7" "Скрипт для ежедневного использования"

    info "Создаю $DAILY_SCRIPT..."

    cat > "$DAILY_SCRIPT" << 'SCRIPT_EOF'
#!/bin/sh
#
# corp-vpn — управление корпоративным VPN
# Использование: corp-vpn [connect|disconnect|status|restart]
#

IFACE="corp_vpn"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

get_status() {
    local up
    up=$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)
    echo "$up"
}

show_status() {
    local up
    up=$(get_status)
    if [ "$up" = "true" ]; then
        local ip
        ip=$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
        printf "${GREEN}[VPN]${NC} Подключен (IP: %s)\n" "${ip:-N/A}"
    else
        printf "${RED}[VPN]${NC} Отключен\n"
    fi
}

do_connect() {
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

    # Ждём подключения (макс. 60 сек)
    local i=0
    local max_wait=60
    printf "${BLUE}[i]${NC} Ожидание "
    while [ $i -lt $max_wait ]; do
        up=$(get_status)
        if [ "$up" = "true" ]; then
            printf "\n"
            printf "${GREEN}[+]${NC} Подключен!\n"
            show_status
            return 0
        fi
        printf "."
        sleep 2
        i=$((i + 2))
    done

    printf "\n"
    printf "${RED}[-]${NC} Не удалось подключиться за %s сек.\n" "$max_wait"
    printf "${YELLOW}[!]${NC} Проверьте: logread | grep openconnect\n"
    return 1
}

do_disconnect() {
    printf "${BLUE}[i]${NC} Отключение VPN...\n"
    ifdown "$IFACE"
    sleep 1
    printf "${GREEN}[+]${NC} VPN отключен\n"
}

do_restart() {
    do_disconnect
    sleep 2
    do_connect
}

show_help() {
    printf "${BOLD}Использование:${NC} corp-vpn [команда]\n\n"
    printf "  ${BOLD}connect${NC}     Подключиться (нужно подтвердить 2FA)\n"
    printf "  ${BOLD}disconnect${NC}  Отключиться\n"
    printf "  ${BOLD}status${NC}      Показать статус\n"
    printf "  ${BOLD}restart${NC}     Переподключиться\n"
    printf "  ${BOLD}logs${NC}        Показать логи OpenConnect\n"
    printf "  ${BOLD}help${NC}        Эта справка\n"
}

case "${1:-status}" in
    connect|up|on)       do_connect ;;
    disconnect|down|off) do_disconnect ;;
    status|st)           show_status ;;
    restart|re)          do_restart ;;
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
    info "  corp-vpn connect     — подключиться"
    info "  corp-vpn disconnect  — отключиться"
    info "  corp-vpn status      — статус"
    info "  corp-vpn restart     — переподключиться"
    info "  corp-vpn logs        — логи"
}

# ============================================================
# Шаг 8: Первое подключение и проверка
# ============================================================
first_connect() {
    step "8" "Первое подключение"

    if ! ask_yesno "Подключиться к корп. VPN сейчас?" "y"; then
        info "Пропущено. Для подключения: corp-vpn connect"
        return 0
    fi

    info "Перезапуск Podkop..."
    service podkop restart
    sleep 3

    info "Подключение к $VPN_SERVER..."
    warn "Подтвердите 2FA на телефоне!"
    echo ""
    ifup "$IFACE_NAME"

    # Ожидание подключения
    local i=0
    local max_wait=90
    printf "Ожидание "
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
            return 0
        fi
        printf "."
        sleep 2
        i=$((i + 2))
    done

    printf "\n"
    err "Не удалось подключиться за ${max_wait}с."
    warn "Проверьте логи: logread | grep openconnect"
    warn "Возможно, 2FA не была подтверждена вовремя."
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
    printf "  3. Удаление секции '%s' из /etc/config/podkop\n" "$PODKOP_SECTION"
    printf "  4. Восстановление vpnc-script из бэкапа\n"
    printf "  5. Удаление скрипта %s\n" "$DAILY_SCRIPT"
    printf "  6. (опционально) Удаление пакетов openconnect\n"
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
        uci commit podkop
        ok "Секция '$PODKOP_SECTION' удалена из /etc/config/podkop"
    else
        ok "Секция '$PODKOP_SECTION' не найдена (уже удалена)"
    fi
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
    printf "  uci show podkop              Нет секции %s\n" "$PODKOP_SECTION"
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
    printf "  corp-vpn connect      Подключиться (+ 2FA)\n"
    printf "  corp-vpn disconnect   Отключиться\n"
    printf "  corp-vpn status       Проверить статус\n"
    printf "  corp-vpn logs         Посмотреть логи\n"
    echo ""

    printf "${BOLD}Что проверить в LuCI:${NC}\n"
    printf "  Network → Interfaces → $IFACE_NAME\n"
    printf "  Services → Podkop → секция '$PODKOP_SECTION'\n"
    echo ""

    printf "${BOLD}Если что-то не работает:${NC}\n"
    printf "  logread | grep openconnect   Логи VPN\n"
    printf "  logread | grep sing-box      Логи Podkop\n"
    printf "  service podkop restart       Перезапуск Podkop\n"
    printf "  ls /tmp/dnsmasq.d/           Проверка DNS (не должно быть openconnect.*)\n"
    echo ""

    if [ -n "$VPN_SERVERHASH" ]; then
        printf "${BOLD}Хэш сертификата сервера (сохраните):${NC}\n"
        printf "  %s\n" "$VPN_SERVERHASH"
        echo ""
    fi
}

# ============================================================
# main
# ============================================================
main_install() {
    printf "${BOLD}${CYAN}"
    printf "╔══════════════════════════════════════════╗\n"
    printf "║  OpenConnect + Podkop Setup Wizard       ║\n"
    printf "║  Корпоративный VPN на OpenWrt             ║\n"
    printf "╚══════════════════════════════════════════╝\n"
    printf "${NC}\n"

    check_prerequisites
    install_packages
    gather_vpn_info
    test_connection
    patch_vpnc_script
    setup_interface
    setup_podkop
    create_daily_script
    first_connect
    verify
    show_summary
}

show_usage() {
    printf "${BOLD}Использование:${NC}\n"
    printf "  sh %s              Установка (интерактивный мастер)\n" "$0"
    printf "  sh %s uninstall    Откат всех изменений\n" "$0"
    printf "  sh %s help         Эта справка\n" "$0"
}

case "${1:-install}" in
    install|setup)     main_install ;;
    uninstall|remove)  uninstall ;;
    help|--help|-h)    show_usage ;;
    *)
        err "Неизвестная команда: $1"
        show_usage
        exit 1
        ;;
esac
