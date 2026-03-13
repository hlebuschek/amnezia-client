# CLAUDE.md — Amnezia VPN Client

## Обзор проекта

**Amnezia VPN** — open-source VPN-клиент для подключения к собственному серверу. Поддерживает Windows, macOS, Linux, Android, iOS. Версия: `4.8.14.5`. Лицензия: GPLv3.

Ключевая особенность: клиент деплоит VPN-инфраструктуру на пользовательский сервер по SSH, а затем подключается к ней. Поддерживает маскировку трафика (обфускацию).

---

## Сборка

**Система:** CMake 3.25+, Qt 6.x (минимум 6.6.2 для iOS).
**Стандарт C++:** C++17.

### Ключевые CMake-флаги

| Флаг | Назначение |
|------|-----------|
| *(по умолчанию)* | Desktop-сборка (Windows/Linux/macOS x86_64) |
| `-DMACOS_NE=ON` | macOS через Network Extension (arm64 + x86_64 universal) |
| `-DIOS=ON` | iOS-сборка |
| `-DANDROID=ON` | Android-сборка |
| `-DDEPLOY=ON` | Включает подпись для дистрибуции (App Store) |

### Скрипты сборки

```
deploy/build_macos.sh       # стандартная macOS (x86_64)
deploy/build_macos_ne.sh    # macOS Network Extension (universal2)
deploy/build_linux.sh
deploy/build_ios.sh
deploy/build_android.sh
deploy/build_windows.bat
```

### Подмодули (git submodule update --init --recursive)

- `client/3rd/qtkeychain` — безопасное хранение учётных данных
- `client/3rd/amneziawg-apple` — AmneziaWG для Apple-платформ (Swift)
- `client/3rd/SortFilterProxyModel` — фильтрация Qt-моделей
- `client/3rd/QSimpleCrypto` — крипто-утилиты
- `client/3rd-prebuilt` — prebuilt-бинарники (`wireguard-go`, OpenVPN, Xray)

---

## Структура кода

```
client/
├── vpnconnection.h/cpp          # Центральная точка управления VPN-подключением
├── protocols/                   # Реализации протоколов (один класс = один протокол)
├── configurators/               # Формирование конфигов под каждый протокол
├── containers/containers_defs.h # Enum DockerContainer — перечень поддерживаемых контейнеров
├── core/
│   ├── controllers/             # Бизнес-логика (CoreController, ServerController, ...)
│   ├── ipcclient.h/cpp          # IPC-клиент (Qt Remote Objects) для desktop
│   └── sshclient.h/cpp          # SSH для деплоя сервера
├── platforms/
│   ├── macos/                   # macOS утилиты + daemon (WireGuard, DNS, firewall, routing)
│   ├── ios/                     # iOS/macOS NE: PacketTunnelProvider (Swift), IosController
│   ├── linux/
│   ├── windows/
│   └── android/
├── macos/
│   ├── networkextension/        # Цель AmneziaVPNNetworkExtension (MACOS_NE)
│   └── gobridge/                # Go-мост для WireGuard (api.go)
├── cmake/
│   ├── macos.cmake              # Стандартная macOS (x86_64, deployment 10.15)
│   └── macos_ne.cmake           # macOS NE (universal2, deployment 11.0, Swift)
└── mozilla/                     # Сетевой код из Firefox (DNS, маршрутизация, LocalSocketController)

service/
├── server/
│   ├── localserver.h/cpp        # IPC-сервер на стороне системного сервиса
│   ├── router_mac.h/cpp         # Управление маршрутами на macOS (route add/delete, DNS flush)
│   └── ipcserver.h/cpp          # Реализация IPC-интерфейса
└── src/qtservice*               # Обёртка над системным сервисом (launchd на macOS)

ipc/
├── ipc_interface.rep            # Определение IPC-контракта (Qt Remote Objects)
└── ipc_process_interface.rep    # Интерфейс запуска привилегированных процессов
```

---

## VPN-протоколы

| Класс | Протокол | Файл |
|-------|----------|------|
| `WireguardProtocol` | WireGuard | `protocols/wireguardprotocol.cpp` |
| `AwgProtocol` | AmneziaWG (обфусцированный WG) | `protocols/awgprotocol.cpp` |
| `OpenVpnProtocol` | OpenVPN | `protocols/openvpnprotocol.cpp` |
| `ShadowSocksVpnProtocol` | ShadowSocks | `protocols/shadowsocksvpnprotocol.cpp` |
| `OpenVpnOverCloakProtocol` | OpenVPN + Cloak | `protocols/openvpnovercloakprotocol.cpp` |
| `XrayVpnProtocol` | Xray/V2Ray | `protocols/xrayprotocol.cpp` |
| `Ikev2VpnProtocol` | IKEv2 (только Windows) | `protocols/ikev2_vpn_protocol_windows.cpp` |

Все наследуют `VpnProtocol` (базовый интерфейс: `start()`, `stop()`, `prepare()`).

---

## Архитектура VPN-подключения на macOS

### Два варианта macOS-сборки

#### 1. Стандартная macOS (x86_64) — «старая реализация»

Это классическая desktop-архитектура: **приложение + системный сервис (daemon)**. Используется на Intel Mac, cmake-флаг `MACOS_NE` **не задан**.

```
CMakeLists.txt: set(CMAKE_OSX_ARCHITECTURES "x86_64")
Deployment target: macOS 10.15
```

Задействован модуль `service/` — отдельный процесс с привилегиями root (управляется через `launchd`).

#### 2. macOS Network Extension (MACOS_NE) — новый путь

Universal2-сборка (arm64 + x86_64), используется в App Store. Реализована аналогично iOS — через `PacketTunnelProvider` (Swift) и `IosController`.

```
CMakeLists.txt: set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
Deployment target: macOS 11.0 (в Xcode-атрибутах)
```

---

### Детальный поток подключения: стандартная macOS (x86_64)

#### Шаг 1 — `VpnConnection::connectToVpn()` (`client/vpnconnection.cpp:222`)

```cpp
// Только для desktop (не iOS, не MACOS_NE):
m_vpnProtocol.reset(VpnProtocol::factory(container, m_vpnConfiguration));
m_vpnProtocol->prepare();
// ...
m_vpnProtocol->start();
```

#### Шаг 2 — Протокол-специфичный `start()`

**WireGuard / AWG** — `WireguardProtocol::start()` → `startMzImpl()`:
```cpp
// wireguardprotocol.cpp:65
m_impl->activate(m_rawConfig);   // m_impl = LocalSocketController
```

`LocalSocketController` (`mozilla/localsocketcontroller.h`) подключается по Unix-сокету к демону и отправляет JSON-команду `activate`.

**OpenVPN** — `OpenVpnProtocol::start()`:
- Через `IpcClient` запускает privileged-процесс OpenVPN (`IpcProcessInterfaceReplica`)
- Слушает management-порт `127.0.0.1:57775` для управления соединением

#### Шаг 3 — IPC-коммуникация с системным сервисом

Клиентская часть (`IpcClient`, `client/core/ipcclient.h`) соединяется с сервисом через Qt Remote Objects по локальному сокету.

Интерфейс определён в `ipc/ipc_interface.rep`:
```
routeAddList(gw, ips)    // добавить маршруты
clearSavedRoutes()       // очистить маршруты
flushDns()               // сбросить DNS-кэш (killall -HUP mDNSResponder)
refreshKillSwitch(bool)  // переключить kill switch
createTun(dev, subnet)   // создать TUN-интерфейс
xrayStart(config)        // запустить Xray
```

#### Шаг 4 — Системный сервис (macOS daemon)

`service/server/localserver.h` — точка входа сервиса. Включает:
- `MacOSDaemon` — главный демон, владеет `WireguardUtilsMacos`, `DnsUtilsMacos`, `IPUtilsMacos`
- `RouterMac` (`service/server/router_mac.cpp`) — маршрутизация через системный `route(8)`
- `IpcServer` — отвечает на запросы от клиента

#### Шаг 5 — WireGuard-тоннель (`WireguardUtilsMacos`)

Файл: `client/platforms/macos/daemon/wireguardutilsmacos.cpp`

```cpp
// addInterface() — создаёт WireGuard-интерфейс:
m_tunnel.start(appPath.filePath("wireguard-go"), {"-f", "utun"});
// Ждёт появления файла /var/run/amneziawg/<iface>.name
// Конфигурирует через UAPI-сокет /var/run/amneziawg/<iface>.sock
```

**AmneziaWG-параметры** передаются через UAPI (jc, jmin, jmax, s1–s4, h1–h4):
```cpp
out << "jc="   << config.m_junkPacketCount      << "\n";  // Junk Count
out << "jmin=" << config.m_junkPacketMinSize     << "\n";  // Junk Min
out << "jmax=" << config.m_junkPacketMaxSize     << "\n";  // Junk Max
out << "s1="   << config.m_initPacketJunkSize    << "\n";  // Special junk (init)
out << "h1="   << config.m_initPacketMagicHeader << "\n";  // Magic header
// ...
```

`wireguard-go` — Go-бинарник из `client/3rd-prebuilt/`. Для macOS/x86_64 используется архитектура `x86_64`, для MACOS_NE — `universal2`.

#### Шаг 6 — Маршрутизация после подключения

`VpnConnection::onConnectionStateChanged()` при `Connected`:
```cpp
iface->resetIpStack();
iface->flushDns();
iface->routeAddList(gateway, {dns1, dns2});
// Split tunneling:
iface->routeDeleteList(gateway, {"0.0.0.0"});   // VpnOnlyForwardSites
// или:
iface->routeAddList(gateway, {"0.0.0.0/1", "128.0.0.0/1"});  // VpnAllExceptSites
```

`RouterMac::routeAdd()` вызывает внутренний `mainRouteIface()` (`service/server/helper_route_mac.h`) — прямой аналог команды `route add`.

#### Шаг 7 — Kill Switch (пакетный фильтр pf)

`WireguardUtilsMacos::applyFirewallRules()` управляет `pfctl` через `MacOSFirewall`:
```
000.allowLoopback   — разрешить lo0
100.blockAll        — заблокировать весь трафик
110.allowNets       — разрешить конкретные сети (если не block-all режим)
200.allowVPN        — разрешить трафик через VPN
250.blockIPv6       — заблокировать IPv6
290.allowDHCP       — разрешить DHCP
300.allowLAN        — разрешить LAN
310.blockDNS        — блокировать сторонние DNS (таблица dnsaddr)
```

---

### Поток подключения: macOS MACOS_NE (Network Extension)

Использует тот же `VpnConnection::connectToVpn()`, но ветку для iOS:
```cpp
// vpnconnection.cpp:258
IosController::Instance()->connectVpn(proto, m_vpnConfiguration);
```

`IosController` (`client/platforms/ios/ios_controller.h/.mm`) взаимодействует с `PacketTunnelProvider` (Swift, `client/platforms/ios/PacketTunnelProvider.swift`) через XPC. PacketTunnelProvider запускается macOS как отдельный sandbox-процесс.

---

## Ключевые файлы — быстрый справочник

| Задача | Файл |
|--------|------|
| Точка входа VPN | `client/vpnconnection.cpp` |
| IPC-интерфейс (контракт) | `ipc/ipc_interface.rep` |
| IPC-клиент (app→service) | `client/core/ipcclient.h` |
| IPC-сервер (service) | `service/server/ipcserver.h` |
| WireGuard UAPI на macOS | `client/platforms/macos/daemon/wireguardutilsmacos.cpp` |
| Маршруты на macOS | `service/server/router_mac.cpp` |
| DNS на macOS | `client/platforms/macos/daemon/dnsutilsmacos.cpp` |
| Firewall / pf | `client/platforms/macos/daemon/macosfirewall.cpp` |
| Мониторинг маршрутов | `client/platforms/macos/daemon/macosroutemonitor.cpp` |
| macOS Daemon (root) | `service/server/localserver.h` + `macosdaemon.cpp` |
| WireGuard протокол | `client/protocols/wireguardprotocol.cpp` |
| OpenVPN протокол | `client/protocols/openvpnprotocol.cpp` |
| LocalSocketController | `client/mozilla/localsocketcontroller.cpp` |
| iOS/NE контроллер | `client/platforms/ios/ios_controller.mm` |
| PacketTunnelProvider | `client/platforms/ios/PacketTunnelProvider.swift` |
| CMake macOS std | `client/cmake/macos.cmake` |
| CMake macOS NE | `client/cmake/macos_ne.cmake` |

---

## Split Tunneling

Конфигурируется в `VpnConnection::appendSplitTunnelingConfig()`:

- **VpnAllSites** — весь трафик через VPN (дефолт)
- **VpnOnlyForwardSites** — через VPN только перечисленные сайты/IP
- **VpnAllExceptSites** — через VPN всё, кроме перечисленного

Для WireGuard/AWG с `AllowedIPs = 0.0.0.0/0` поддерживается site-based split tunneling. Для native-конфигов с ограниченными AllowedIPs — нет.

---

## Советы для разработки

- **Не путать два macOS-пути**: стандартный (daemon + IPC + `WireguardUtilsMacos`) и MACOS_NE (Swift Network Extension + `IosController`). Код в `#ifdef MACOS_NE` / `#if defined(Q_OS_IOS) || defined(MACOS_NE)`.
- **wireguard-go** — внешний Go-процесс, запускается из `<app>/Contents/MacOS/wireguard-go`. UAPI-сокет: `/var/run/amneziawg/<ifname>.sock`.
- **Системный сервис** собирается как отдельная цель `service/` и не входит в MACOS_NE/iOS/Android-сборки.
- **Qt Remote Objects** (.rep-файлы) генерируют replica/source автоматически при сборке — не редактируй `rep_ipc_interface_replica.h` вручную.
- **Логирование**: класс `Logger` из `common/logger/`. В debug-режиме `WireguardGo`-логи пишутся через отдельный `logger("WireguardGo")`.
- **AmneziaWG** отличается от vanilla WireGuard дополнительными UAPI-полями (`jc`, `jmin`, `jmax`, `s1`–`s4`, `h1`–`h4`) — параметры обфускации трафика.
