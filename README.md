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
- Доступ к серверу TrustTunnel. Либо свой VPS с Linux (x86\_64 или aarch64) —
  см. [Часть 1](#часть-1-настройка-сервера-на-vps), либо готовые данные
  подключения к чужому серверу — см.
  [Часть 1-Б](#часть-1-б-если-сервер-не-свой)

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

> **Если сертификат от Let's Encrypt** — передавайте в `-a` **домен**, а не IP:
> сертификат такого типа в конфиг не вписывается (клиент проверяет его по
> системному хранилищу), и `hostname` обязан совпадать с именем в сертификате.
> С IP вместо домена проверка упадёт с ошибкой `OPENSSL_internal`.
> Self-signed сертификат экспортируется в конфиг автоматически — с ним IP в
> `-a` допустим.

## Часть 1-Б. Если сервер не свой

Часть 1 нужна только если вы поднимаете сервер сами. Если сервер чужой и вам
выдали готовые данные подключения — пропустите её целиком и начните с
[Части 2.1](#21-установить) (установка на роутер), а конфиг клиента создайте
одним из трёх способов ниже.

### Что нужно получить у владельца сервера

| Параметр | Пример | Обязателен |
| -------- | ------ | ---------- |
| Хост для TLS (`hostname`) | `vpn.example.com` | да |
| Адрес и порт (`addresses`) | `203.0.113.10:443` | да |
| Логин (`username`) | `router` | да |
| Пароль (`password`) | `s3cret` | да |
| Сертификат сервера (PEM) | `server.pem` | только если self-signed |

`hostname` и `addresses` — **разные вещи**, и именно здесь чаще всего
ошибаются. `addresses` — куда подключаться (IP или домен с портом),
`hostname` — имя, по которому проверяется TLS-сертификат. Если сертификат
выпущен на `vpn.example.com`, то `hostname` обязан быть `vpn.example.com`,
даже если в `addresses` стоит голый IP.

### Вариант А. Есть файл конфига от сервера

Владелец сервера может отдать готовый экспорт (`config.toml`, он же
`--format toml` из шага 1.4) или deeplink. Тогда конфиг клиента собирается
мастером:

```bash
scp -O config.toml root@<router>:/opt/trusttunnel_client/

cd /opt/trusttunnel_client
./setup_wizard --mode non-interactive \
    --endpoint_config config.toml \
    --settings trusttunnel_client.toml
```

### Вариант Б. Есть только логин, пароль и адрес

Мастер умеет собирать конфиг прямо из параметров — VPS для этого не нужен:

```bash
cd /opt/trusttunnel_client
./setup_wizard --mode non-interactive \
    --address 203.0.113.10:443 \
    --hostname vpn.example.com \
    --creds router:s3cret \
    --settings trusttunnel_client.toml
```

- `--address` можно указать несколько раз — клиент сам выберет лучший адрес
- если сертификат self-signed, добавьте `--cert /opt/trusttunnel_client/server.pem`

После этого всё равно откройте файл и поправьте `[listener.tun]` под роутер —
мастер ставит дефолты для десктопа (см. [2.2](#22-настроить-конфиг-клиента)).

### Вариант В. Написать конфиг руками

Минимальный рабочий `trusttunnel_client.toml` для связки OpenWRT + podkop.
Положить в `/opt/trusttunnel_client/trusttunnel_client.toml`:

```toml
loglevel = "info"
vpn_mode = "general"
killswitch_enabled = false
exclusions = []

[endpoint]
hostname = "vpn.example.com"
addresses = ["203.0.113.10:443"]
username = "router"
password = "s3cret"
certificate = ""
skip_verification = false
upstream_protocol = "http2"
anti_dpi = false

[listener]

[listener.tun]
device_name = "tun0"
included_routes = []
excluded_routes = []
change_system_dns = false
mtu_size = 1280
```

Что здесь важно именно для роутера — остальное можно не трогать:

| Поле | Значение | Почему |
| ---- | -------- | ------ |
| `included_routes` | `[]` | Маршрутами управляет podkop. С `["0.0.0.0/0"]` весь трафик уйдёт в тоннель и обычный интернет отвалится |
| `change_system_dns` | `false` | Иначе клиент перепишет DNS роутера и сломает dnsmasq |
| `killswitch_enabled` | `false` | Дефолт `true` режет трафик при падении VPN. На роутере тоннель нужен только для выбранных доменов, поэтому killswitch отключаем — иначе падение тоннеля утащит за собой всю LAN |
| `mtu_size` | `1280` | Дефолт `1350` не переживает PPPoE/двойную инкапсуляцию |
| `device_name` | `"tun0"` | Имя TUN-интерфейса. Пустое значение — имя даёт ядро, и proto handler'у приходится переименовывать устройство. С явным `tun0` совпадает с именем UCI-интерфейса |
| `certificate` | `""` | Пусто — проверка по системному хранилищу (нужен `ca-bundle`). Для self-signed вписать PEM, см. ниже |
| `bound_if` | не указывать | Вызывает падение бинарника при фоновом запуске |

Self-signed сертификат вписывается многострочной строкой TOML:

```toml
[endpoint]
hostname = "vpn.example.com"
certificate = """
-----BEGIN CERTIFICATE-----
MIIBkTCB+wIJAKk...
-----END CERTIFICATE-----
"""
```

Полный список полей со всеми дефолтами —
[в документации клиента](https://github.com/TrustTunnel/TrustTunnelClient/blob/master/trusttunnel/README.md#configuration-reference).

Проверить конфиг до создания UCI-интерфейса можно запуском в foreground:

```bash
/opt/trusttunnel_client/trusttunnel_client \
  -c /opt/trusttunnel_client/trusttunnel_client.toml
# ожидаем "Successfully connected to endpoint", затем Ctrl+C
```

Дальше — [2.3. Создать UCI интерфейс](#23-создать-uci-интерфейс).

## Часть 2. Установка на роутере

### 2.1. Установить

```bash
sh <(wget -O - https://raw.githubusercontent.com/iamvladdy/trusttunnel-openwrt/refs/heads/master/install.sh)
```

Скрипт автоматически:
- Определит менеджер пакетов (apk / opkg)
- Установит зависимости: `kmod-tun`, `ip-full`, `curl`, `ca-bundle`
- Скачает и установит netifd proto handler, hotplug-хук и LuCI плагин
- Загрузит официальный бинарник TrustTunnel клиента для архитектуры роутера

### 2.2. Настроить конфиг клиента

> Если сервер не свой и у вас только данные подключения — этот шаг описан в
> [Части 1-Б](#часть-1-б-если-сервер-не-свой).

Скопировать `config.toml` с сервера на роутер:

```bash
scp -O config.toml root@<router>:/opt/trusttunnel_client
```

Создать конфиг клиента

```bash
./opt/trusttunnel_client/setup_wizard --mode non-interactive \
    --endpoint_config config.toml \
    --settings trusttunnel_client.toml
```

Открыть файл и убедиться что секция `[listener.tun]` выглядит так:

```toml
[listener]

[listener.tun]
device_name = "tun0"
included_routes = []
excluded_routes = []
change_system_dns = false
mtu_size = 1280
```

> **Важно:** `included_routes = []` — клиент не прописывает маршруты сам, маршрутизацией управляет podkop. Если поставить `["0.0.0.0/0"]`, весь трафик пойдёт через TrustTunnel и обычный интернет перестанет работать.

А в корне конфига — выключить killswitch, иначе падение тоннеля отрежет
трафик всей LAN:

```toml
killswitch_enabled = false
```

Назначение остальных полей — в
[таблице из Части 1-Б](#вариант-в-написать-конфиг-руками).

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

Повторный запуск установщика обновит все скрипты и бинарник клиента до
актуальных версий:

```bash
sh <(wget -O - https://raw.githubusercontent.com/iamvladdy/trusttunnel-openwrt/refs/heads/master/install.sh)
```

Установщик сам остановит активные `proto=trusttunnel` интерфейсы перед
заменой файлов и поднимет их обратно после — иначе старый процесс продолжил
бы работать со старым бинарником (апстрим-установщик делает `rm -f` на
запущенный файл, что лишь отвязывает inode). Интерфейсы с `disabled=1` в UCI
не трогаются.

Конфиг `trusttunnel_client.toml` при обновлении не затрагивается —
апстрим-установщик удаляет только `trusttunnel_client`, `setup_wizard` и
`LICENSE`.

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

## Диагностика

### `Error: 7 ... invalid library (0):OPENSSL_internal:unknown library`

```
TRUSTTUNNEL_CLIENT_APP operator(): Error: 7
error:00000001:invalid library (0):OPENSSL_internal:unknown library
```

Несмотря на формулировку, это **не** проблема с библиотекой. Клиент собран
статически с BoringSSL, и такое сообщение с пустой очередью ошибок означает,
что **не удалось проверить сертификат сервера**. Три причины, по частоте:

**1. На роутере нет системного хранилища корневых сертификатов.**
Если в конфиге `certificate = ""`, клиент использует системное хранилище —
BoringSSL ищет `/etc/ssl/cert.pem`. В ванильном OpenWRT этого файла нет.

```bash
ls -l /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt
apk add ca-bundle      # или: opkg install ca-bundle
ifdown tun0 && ifup tun0
```

**2. `hostname` не совпадает с сертификатом сервера.**
Проверка идёт по `hostname` из секции `[endpoint]`, а не по адресу из
`addresses`. Если сертификат выпущен Let's Encrypt на домен, а в `hostname`
попал IP VPS (например, при экспорте конфига через `-a <IP>` без `-n`),
проверка не пройдёт.

```bash
grep -A3 '^\[endpoint\]' /opt/trusttunnel_client/trusttunnel_client.toml
# hostname должен быть доменом из сертификата, IP остаётся в addresses:
#   hostname  = "vpn.example.com"
#   addresses = ["203.0.113.10:443"]
```

Проверить, какое имя реально в сертификате сервера:

```bash
openssl s_client -connect <IP_VPS>:443 -servername vpn.example.com \
  </dev/null 2>/dev/null | openssl x509 -noout -subject -dates -ext subjectAltName
```

**3. Сертификат self-signed и не закреплён в конфиге.**
Self-signed сертификат нельзя проверить через системное хранилище — его PEM
нужно вписать в конфиг клиента. Забрать с VPS и вставить в `[endpoint]`:

```toml
[endpoint]
hostname = "vpn.example.com"
certificate = """
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
"""
```

> `skip_verification = true` тоже уберёт ошибку, но отключит проверку
> сертификата целиком — трафик станет уязвим к MITM. Только для отладки.

**Ещё одна причина — неверные часы роутера.** Сертификат проверяется по
системному времени, и до синхронизации NTP любой сертификат выглядит как
«ещё не действительный»:

```bash
date                      # сверить с реальным временем
service sysntpd restart
```

Proto handler теперь сам ждёт синхронизации времени и подставляет
`SSL_CERT_FILE`, а при отсутствии хранилища пишет в syslog конкретную
причину вместо ожидания таймаута:

```bash
logread | grep trusttunnel | tail -20
```

### Общая диагностика

```bash
# Полный лог клиента — там настоящая причина падения
tail -n 50 /var/run/trusttunnel/tun0.log

# Проверить, что порт VPS доступен с роутера
nc -z <IP_VPS> 443 && echo reachable

# Проверить конфиг клиента вручную, в foreground
/opt/trusttunnel_client/trusttunnel_client \
  -c /opt/trusttunnel_client/trusttunnel_client.toml
```

## Известные ограничения

- **Имя интерфейса** — имя UCI-интерфейса должно совпадать с `device_name` из `[listener.tun]`. Если `device_name` пустой, ядро выдаёт имя само (`tun0`), и proto handler переименовывает устройство — работает, но надёжнее задать `device_name` явно. Протестировано только с `tun0`.
- **`bound_if`** — задавать нельзя: вызывает crash бинарника при фоновом запуске (баг в TrustTunnelClient).
- **Hotplug** — если WAN называется не `wan` (например `pppoe-wan`), нужно поправить `/etc/hotplug.d/iface/99-trusttunnel`, заменив `[ "$INTERFACE" = "wan" ]` на своё имя. Узнать имя WAN: `uci show network | grep proto`.
- **Протестировано** — OpenWRT 25.12.2, Flint 2 (MT7986A, aarch64).

## Ссылки

- [TrustTunnel](https://trusttunnel.org) — официальный сайт
- [TrustTunnelClient](https://github.com/TrustTunnel/TrustTunnelClient) — официальный CLI клиент
- [podkop](https://podkop.net) — маршрутизация трафика для OpenWRT
- [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) — AmneziaWG для OpenWRT (послужил образцом)
