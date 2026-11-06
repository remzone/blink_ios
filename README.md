# Blink for iOS

Исходники клиента iOS 16+ для **Xray, WireGuard, AmneziaWG и Vokop / VK TURN**.
Обычные VPN-профили работают напрямую, без VK и CAPTCHA. Новый основной интерфейс:
главная, VPN-профили, подписка Vokop, настройки.

**Статус:** iOS по просьбе владельца не собирался. Swift type checking, XCTest,
подпись, запуск на iPhone/iPad и работа NetworkExtension не выполнялись.
Есть только проверка синтаксиса Swift и статических конфигураций. Это реализация
в исходниках, не готовый проверенный iOS-релиз. Android с тем же native ядром
проверяется отдельно в [blink-android](https://github.com/remzone/blink-android).

## Профили и подписки

| Движок | Импорт |
| --- | --- |
| Xray | `vless://`, `vmess://` (AEAD, включая base64 JSON aid=0), `trojan://`, `ss://` (SIP002/legacy), `socks://`, `hy2://` / `hysteria2://` |
| WireGuard | `[Interface]` / `[Peer]` `.conf` |
| AmneziaWG | `.conf` с AWG v3 параметрами Jc/Jmin/Jmax, S1–S4, H1–H4, I1–I5 |
| Vokop VK TURN | Scoped HTTPS JSON `vokop.subscription.v1`, явный выбор TURN TCP/UDP |

Для Xray реализованы TCP/raw, WS, gRPC, HTTPUpgrade, базовый XHTTP, KCP и TLS/REALITY
при допустимых сочетаниях. Hysteria — версии 2. Проверка импорта использует
закреплённый Xray. Полная совместимость со всеми настройками Happ **не заявляется**:
произвольный Xray JSON, XHTTP `extra`/`fm`, SS plugins, Clash YAML, Amnezia `vpn://`
backups и legacy VMess alterId>0 не импортируются. OpenVPN, Cisco AnyConnect,
Forti и TUIC не добавлены. Неизвестные/неприменимые параметры и TLS insecure
отклоняются; shell-команды из WG-конфигов не выполняются.

В «VPN-профили» можно вставить URI, импортировать файл или HTTPS-подписку
plain/base64 со списком URI. Каждая подписка обновляется отдельно, сохраняя
ручные профили и другие feeds. Лимиты: 128 КиБ на ответ/файл, 256 профилей,
512 КиБ на vault. Все исходные URI, конфиги и URL подписок содержат секреты и
хранятся в общем Keychain `AfterFirstUnlockThisDeviceOnly`. Provider preferences
содержат только ID и режим. Серверные inbound/peers должны быть настроены заранее.

Системный статус «VPN подключён» подтверждает запуск локального транспорта,
а не интернет или успешный WireGuard handshake. Автоматического выбора узла,
фонового refresh, QR, kill switch и on-demand нет. После смены физической сети
пока требуется ручное переподключение; миграция Wi-Fi ↔ cellular не проверена.

## Экраны и VK

Для компактной ширины используется TabView, для iPad/regular — NavigationSplitView
с боковым меню. Главная прокручивается, контент ограничен по ширине; используются
системные светлая/тёмная темы, Dynamic Type и масштабируемая иконка. Формы и
файловый импорт общие. Это изменения исходников; визуальная проверка размеров,
поворота, клавиатуры, VoiceOver и accessibility на iOS ещё предстоит.

VK авторизуется **в основном приложении до установки VPN-маршрутов**. Современная
ручная CAPTCHA открывается официальным VKCaptchaSDK 0.1.6; legacy изображение
принимает код. Автоматического решения CAPTCHA и доступа к cookies приложения
VK нет. В расширение через Keychain передаётся привязанный к профилю private
handoff на 90 секунд; значение потребляется до запуска. После остановки/запроса
новой проверки нужна авторизация из приложения. Сворачивание отменяет preflight.

Обычные Xray-профили и WG/AWG этот путь не используют. Vokop показывает срок и
revision; денежного баланса в API панели нет — он остаётся в Telegram-боте.

## Архитектура и проверка

Основной проект содержит приложение и **одно** расширение `BlinkXrayTunnel` с
`BlinkCore.xcframework`: Xray + AWG backend + VK TURN в одном Go runtime.
Старые WireGuardKit/FreeTurn файлы сохранены исторически, но старый target и его
Go frameworks исключены из активного проекта. Старые профили автоматически
не преобразуются — импортируйте обычный `.conf` или новый URI.

Xray/VK используют IPv4; DNS идёт по TCP внутри прокси, AAAA получает пустой ответ.
WG/AWG следуют Address/AllowedIPs/DNS/MTU `.conf`, включая явный IPv6. Проверка
настоящего IPv6, отсутствия утечек и поведения iOS full/split routing ещё нужна.
Подробности, ограничения и лицензии: [docs/XRAY-MOBILE.md](docs/XRAY-MOBILE.md).

Выполнено на Linux: статические guards проекта/entitlements/fixtures и syntax
parser для 42 Swift-файлов. Это **не компиляция Swift**. Native mirror проверяется
`python3 tools/sync-native.py --check`; тесты Go выполнялись в Android-репозитории,
а не как iOS-тесты. Приватные журналы и реквизиты исключены из Git.

## Будущая сборка на Mac — сейчас не запускалась

Нужны Xcode 16.4+, XcodeGen и Go 1.27.3+. Когда будет отдельно запрошена сборка:

```sh
make prepare
open Blink.xcodeproj
```

`make prepare` создаёт только единый BlinkCore и проект. Выберите Apple Team для
`Blink` и `BlinkXrayTunnel`. Bundle IDs: `com.blink.tunnel`,
`com.blink.tunnel.XrayTunnel`; App Group `group.com.blink.tunnel`, Keychain group
`$(AppIdentifierPrefix)com.blink.tunnel.shared`. Нужны соответствующие App Groups,
Keychain Sharing и Network Extensions provisioning. При смене идентификаторов
обновите `project.yml` и `SharedConstants.swift` согласованно.

Артефакты, ключи и Vendor исключены из Git. GitHub Actions/Releases и TestFlight
в этой работе не запускались; сохранённые workflows допускают только ручной запуск.
Перед распространением требуется отдельная проверка лицензий, Apple provisioning
и работоспособности на физических устройствах.
