# TrustTunnel для OpenWRT

Интеграция [TrustTunnel](https://github.com/TrustTunnel/TrustTunnelClient) (VPN-протокол от AdGuard) с ванильным OpenWRT через netifd — по образцу того, как устроен AmneziaWG.

После установки `tun0` появляется как полноценный сетевой интерфейс в системе, а [podkop](https://podkop.net) может маршрутизировать через него выбранные домены — так же, как через `awg0`.

## Как это устроено

Вместо init.d-скриптов и shell-watchdog (как в Keenetic/Entware-портах) здесь используется **netifd proto handler** — `/lib/netifd/proto/trusttunnel.sh`. Это тот же подход, что у AmneziaWG: netifd управляет жизненным циклом интерфейса, перезапускает при падении, интегрирует с firewall и UCI.

```
netifd → proto_trusttunnel_setup() → trusttunnel_client → tun0
```

## Требования

- OpenWRT 24.10 (opkg) или 25.x (apk) — определяется автоматически
- Минимум 20 MB свободного места
- VPS с Linux (x86\_64 или aarch64) для сервера TrustTunnel

## Часть 1. Настройка сервера на VPS

### 1.1. Установить сервер

```bash
curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh | sh -s -
```

### 1.2. Запустить мастер настройки

```bash
cd /opt/trusttunnel/
sudo ./setup_wizard
```

Мастер спросит:
- **Listen address** — `0.0.0.0:443`
- **Username / Password** — логин и пароль клиента
- **Certificate** — Let's Encrypt если есть домен, иначе self-signed

### 1.3. Включить автозапуск

```bash
cp /opt/trusttunnel/trusttunnel.service.template /etc/systemd/system/trusttunnel.service
sudo systemctl daemon-reload
sudo systemctl enable --now trusttunnel
```

### 1.4. Экспортировать конфиг для клиента

```bash
cd /opt/trusttunnel/
./trusttunnel_endpoint vpn.toml hosts.toml \
  -c router \
  -a <ПУБЛИЧНЫЙ_IP_VPS> \
  --format toml > config.toml
```

## Часть 2. Установка на роутере

### 2.1. Установить

```bash
sh <(wget -O - https://raw.githubusercontent.com/iamvladdy/trusttunnel-openwrt/refs/heads/master/install.sh)
```

Скрипт автоматически:
- Определит менеджер пакетов (apk / opkg)
- Установит зависимости: `kmod-tun`, `ip-full`, `curl`
- Скачает и установит netifd proto handler, hotplug-хук и LuCI плагин
- Загрузит официальный бинарник TrustTunnel клиента для архитектуры роутера

### 2.2. Настроить конфиг клиента

Скопировать `config.toml` с сервера на роутер:

```bash
scp -O config.toml root@<router>:/opt/trusttunnel_client/trusttunnel_client.toml
```

Открыть файл и убедиться что секция `[listener.tun]` выглядит так:

```toml
[listener]

[listener.tun]
bound_if = ""
included_routes = []
excluded_routes = []
change_system_dns = false
mtu_size = 1280
```

> **Важно:** `included_routes = []` — клиент не прописывает маршруты сам, маршрутизацией управляет podkop. Если поставить `["0.0.0.0/0"]`, весь трафик пойдёт через TrustTunnel и обычный интернет перестанет работать.

### 2.3. Создать UCI интерфейс

```bash
uci set network.tun0=interface
uci set network.tun0.proto=trusttunnel
uci set network.tun0.config_file=/opt/trusttunnel_client/trusttunnel_client.toml
uci commit network
service network restart
```

Или через LuCI: **Network → Interfaces → Add → Protocol: TrustTunnel VPN**

### 2.4. Проверить

```bash
ip addr show tun0
logread | grep trusttunnel | tail -5
grep 'Successfully connected' /var/run/trusttunnel/tun0.log
```

Ожидаемый результат:
```
331: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280 ...
    inet 172.16.219.2/32 ...
...
Successfully connected to endpoint
```

## Часть 3. Подключение к podkop

```bash
uci set podkop.trusttunnel=section
uci set podkop.trusttunnel.connection_type='vpn'
uci set podkop.trusttunnel.interface='tun0'
uci commit podkop
service podkop restart
```

Или через LuCI — podkop увидит `tun0` в списке интерфейсов.

### Проверить что трафик идёт через тоннель

```bash
curl --interface tun0 -s https://ifconfig.me
# Должен вернуть IP вашего VPS
```

## LuCI

После установки:

- **Network → Interfaces → Add → Protocol: TrustTunnel VPN** — создать интерфейс с выбором конфига и MTU
- **Status → TrustTunnel** — страница статуса с автообновлением каждые 5 секунд: состояние соединения, IP тоннеля, endpoint, PID, последняя ошибка

## Управление

```bash
ifup tun0      # поднять
ifdown tun0    # опустить
```

Логи:
```bash
logread | grep trusttunnel
tail -f /var/run/trusttunnel/tun0.log
```

## Структура файлов

```
/lib/netifd/proto/trusttunnel.sh                          ← netifd proto handler
/etc/hotplug.d/iface/99-trusttunnel                       ← WAN reconnect hook
/www/luci-static/resources/protocol/trusttunnel.js        ← LuCI protocol UI
/www/luci-static/resources/view/trusttunnel/status.js     ← LuCI status page
/usr/share/rpcd/ucode/luci.trusttunnel                    ← LuCI rpcd backend
/opt/trusttunnel_client/
  ├── trusttunnel_client                                  ← бинарник (официальный)
  └── trusttunnel_client.toml                             ← конфиг (скопировать с сервера)
/var/run/trusttunnel/
  ├── tun0.pid                                            ← PID процесса
  └── tun0.log                                            ← лог клиента
```

## Обновление

Повторный запуск установщика обновит все скрипты до актуальной версии из репозитория:

```bash
sh <(wget -O - https://raw.githubusercontent.com/iamvladdy/trusttunnel-openwrt/refs/heads/master/install.sh)
```

Для обновления только бинарника клиента:

```bash
ifdown tun0
curl -fsSL \
  https://raw.githubusercontent.com/TrustTunnel/TrustTunnelClient/refs/heads/master/scripts/install.sh \
  | sh -s - -o /opt/trusttunnel_client
ifup tun0
```

## Удаление
```bash
sh <(wget -O - https://raw.githubusercontent.com/iamvladdy/trusttunnel-openwrt/refs/heads/master/uninstall.sh)
```

Или своими руками

```bash
# Остановить и убрать интерфейс
ifdown tun0
uci del network.tun0
uci commit network

# Убрать из podkop (если добавляли)
uci del podkop.trusttunnel
uci commit podkop
service podkop restart

# Удалить скрипты
rm /lib/netifd/proto/trusttunnel.sh
rm /etc/hotplug.d/iface/99-trusttunnel

# Удалить LuCI плагин
rm /www/luci-static/resources/protocol/trusttunnel.js
rm -rf /www/luci-static/resources/view/trusttunnel
rm /usr/share/rpcd/ucode/luci.trusttunnel
rm /usr/share/luci/menu.d/luci-app-trusttunnel.json
rm /usr/share/rpcd/acl.d/luci-app-trusttunnel.json

# Удалить клиент и данные
rm -rf /opt/trusttunnel_client
rm -rf /var/run/trusttunnel

# Очистить routing state (если остались)
ip rule del prio 30801 lookup 880 2>/dev/null
ip rule del prio 30800 sport 1-1024 lookup main 2>/dev/null
ip rule del prio 30800 sport 5900-5920 lookup main 2>/dev/null
ip route flush table 880 2>/dev/null

service rpcd restart
service network restart
```

## Известные ограничения

- **Имя интерфейса** — должно быть `tun0`. Параметр `bound_if` в конфиге клиента вызывает crash бинарника при фоновом запуске (баг в TrustTunnelClient).
- **Hotplug** — если WAN называется не `wan` (например `pppoe-wan`), нужно поправить `/etc/hotplug.d/iface/99-trusttunnel`, заменив `[ "$INTERFACE" = "wan" ]` на своё имя. Узнать имя WAN: `uci show network | grep proto`.
- **Протестировано** — OpenWRT 25.12.2, Flint 2 (MT7986A, aarch64).

## Ссылки

- [TrustTunnel](https://trusttunnel.org) — официальный сайт
- [TrustTunnelClient](https://github.com/TrustTunnel/TrustTunnelClient) — официальный CLI клиент
- [podkop](https://podkop.net) — маршрутизация трафика для OpenWRT
- [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) — AmneziaWG для OpenWRT (послужил образцом)
