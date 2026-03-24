# OpenConnect + Podkop для OpenWrt

Скрипт и инструкции для настройки корпоративного VPN (Cisco AnyConnect / OpenConnect) на роутере с OpenWrt, **не ломая** [Podkop](https://github.com/itdoginfo/podkop).

## Проблема

Когда корпоративный VPN подключен на устройстве, он перехватывает DNS — Podkop перестаёт работать. Решение: перенести корпоративный VPN на роутер и настроить split DNS.

## Файлы

| Файл | Описание |
|------|----------|
| `setup-corp-vpn.sh` | **Скрипт установки** — интерактивный мастер, запускается на роутере. Устанавливает пакеты, патчит DNS, создаёт интерфейс и секцию Podkop. Поддерживает откат (`uninstall`). |
| `openconnect-podkop-setup.md` | **Ручная инструкция** — пошаговый гайд для тех, кто предпочитает настраивать вручную. |
| `podkop-docs/` | Локальная копия документации Podkop для справки. |

## Быстрый старт

### Вариант 1: Скачать и запустить прямо на роутере

```bash
# SSH на роутер
ssh root@ROUTER

# Скачать скрипт с GitHub и запустить
wget -O /tmp/setup-corp-vpn.sh https://raw.githubusercontent.com/gundone/openwrt-corp-vpn/main/setup-corp-vpn.sh
sh /tmp/setup-corp-vpn.sh
```

### Вариант 2: Скопировать с компьютера

```bash
# С ПК (Windows/macOS/Linux)
scp setup-corp-vpn.sh root@ROUTER:/tmp/

ssh root@ROUTER
sed -i 's/\r$//' /tmp/setup-corp-vpn.sh   # исправить переводы строк, если копировали с Windows
sh /tmp/setup-corp-vpn.sh
```

### Откат всех изменений

```bash
sh /tmp/setup-corp-vpn.sh uninstall
```

Скрипт проведёт через 9 шагов: проверка системы → установка пакетов → ввод параметров VPN → тест 2FA → патч DNS → создание интерфейса → настройка Podkop → создание утилиты `corp-vpn` → первое подключение → верификация.

## После установки

На роутере появляется утилита `corp-vpn`:

```bash
corp-vpn connect      # подключиться (+ подтвердить push на телефоне)
corp-vpn disconnect   # отключиться
corp-vpn status       # проверить статус
corp-vpn restart      # переподключиться
corp-vpn logs         # посмотреть логи
```

## Требования

- OpenWrt 24.10+
- Podkop уже установлен и работает
- Корпоративный VPN совместим с Cisco AnyConnect / OpenConnect
- SSH-доступ к роутеру

## Архитектура

```
┌──────────────────────────────────────────────┐
│              Клиентское устройство            │
│         DNS → роутер, Gateway → роутер       │
└─────────────────────┬────────────────────────┘
                      │
┌─────────────────────▼────────────────────────┐
│               Роутер (OpenWrt)               │
│                                              │
│  dnsmasq :53 → sing-box 127.0.0.42:53       │
│                                              │
│  Podkop "main":                              │
│    заблокированные сайты → VLESS/WG/...      │
│                                              │
│  Podkop "corp":                              │
│    корп. домены → OpenConnect интерфейс      │
│    Domain Resolver → корп. DNS через туннель │
│                                              │
│  Остальной трафик → напрямую через WAN       │
└──────────────────────────────────────────────┘
```
