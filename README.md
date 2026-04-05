# trusttunnel-openwrt

OpenWRT packages for [TrustTunnel VPN](https://trusttunnel.org) by AdGuard.

## Packages

| Package | Description |
|---|---|
| `trusttunnel-tools` | netifd proto handler, hotplug hook, downloads TT binary |
| `luci-app-trusttunnel` | LuCI protocol UI + status page |

## Installation

### Вариант A — скачать пакет вручную (без репозитория)

Найди свою архитектуру в [Releases](../../releases):

| Роутер | Архитектура |
|---|---|
| Flint 2, Xiaomi AX6000 (MT7986A) | `aarch64_cortex-a53` |
| GL.iNet Slate AX, RPi | `aarch64_generic` |
| TP-Link / Xiaomi (MT7621) | `mipsel_24kc` |
| Старые Atheros (ath79) | `mips_24kc` |
| x86 / VM | `x86_64` |

Узнать свою архитектуру:
```bash
ubus call system board | jsonfilter -e '@.release.arch'
```

Установить:
```bash
# OpenWRT 25.x
apk add --allow-untrusted trusttunnel-tools_v25.12.2_aarch64_cortex-a53_mediatek_filogic.apk
apk add --allow-untrusted luci-app-trusttunnel_v25.12.2_aarch64_cortex-a53_mediatek_filogic.apk

# OpenWRT 24.10
opkg install trusttunnel-tools_v24.10.3_aarch64_cortex-a53_mediatek_filogic.ipk
opkg install luci-app-trusttunnel_v24.10.3_aarch64_cortex-a53_mediatek_filogic.ipk
```

### После установки

1. Скопировать конфиг клиента с сервера:
```bash
scp config.toml root@<router>:/opt/trusttunnel_client/trusttunnel_client.toml
```

2. Поправить `[listener.tun]` в конфиге:
```toml
included_routes = []
excluded_routes = []
change_system_dns = false
```

3. Создать UCI интерфейс:
```bash
uci set network.tun0=interface
uci set network.tun0.proto=trusttunnel
uci set network.tun0.config_file=/opt/trusttunnel_client/trusttunnel_client.toml
uci commit network
service network restart
```

4. Или создать через LuCI: **Network → Interfaces → Add → Protocol: TrustTunnel VPN**

5. Статус: **Status → TrustTunnel**

## Сборка из исходников

```bash
# Клонировать SDK нужной версии
git clone https://github.com/openwrt/openwrt
cd openwrt
./scripts/feeds update -a && ./scripts/feeds install -a

# Добавить наши пакеты
cp -r /path/to/trusttunnel-tools     package/
cp -r /path/to/luci-app-trusttunnel  package/

make menuconfig  # выбрать Network > VPN > trusttunnel-tools
make package/trusttunnel-tools/compile V=s
make package/luci-app-trusttunnel/compile V=s
```

## Связанные проекты

- [TrustTunnelClient](https://github.com/TrustTunnel/TrustTunnelClient) — официальный CLI клиент
- [podkop](https://podkop.net) — маршрутизация трафика для OpenWRT
- [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt) — AmneziaWG для OpenWRT (послужил образцом)
