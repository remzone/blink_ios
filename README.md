# Blink for iOS

**Новый интерфейс:** общая дизайн-система, SF Symbols, материалы и мягкие градиенты, кольцо подключения, адаптивные карточки серверов и диагностики. iPhone использует вкладки, iPad — боковую навигацию. Поддержаны Dynamic Type и Reduce Motion. Apple TV служил только визуальным референсом: отдельного tvOS-клиента нет. [Подробности дизайна](docs/UI-DESIGN.md).

Исходники клиента iOS 16+ для **Xray, WireGuard, AmneziaWG и Vokop / VK TURN**.
Обычные VPN-профили работают напрямую, без VK и CAPTCHA. Новый основной интерфейс:
главная, VPN-профили, подписка Vokop, настройки.

**Статус:** iOS по просьбе владельца не собирался. Swift type checking, XCTest,
подпись, запуск на iPhone/iPad и работа NetworkExtension не выполнялись.
Есть только проверка синтаксиса Swift и статических конфигураций. Это реализация
в исходниках, не готовый проверенный iOS-релиз. Android с тем же native ядром
проверяется отдельно в [blink-android](https://github.com/remzone/blink-android).

## Профили и подписки

Подробная [матрица протоколов и форматов панели](docs/PROTOCOLS.md) общая с Android.
Xray обслуживает VLESS, VMess AEAD, Trojan, SS/SS2022, HTTP CONNECT/SOCKS,
Hysteria2 и MASQUE JSON. TUIC v5 и legacy Hysteria v1 используют sing-quic;
WireGuard/AmneziaWG — официальный AWG backend.

Импорт: URI, plain/base64 HTTPS feed, одиночный Xray JSON или массив именованных
configs, узлы Clash/Mihomo YAML, WG/AWG `.conf`, `wireguard://` и plain INI
`vpn://` панели. Сохраняются отдельные названия стран/узлов; есть поиск и
независимое обновление feeds. Пределы: 1 МиБ, до1024 узлов, Keychain vault до4 МиБ.
Clash groups/rules/DNS не эмулируются; результат импорта явно сообщает это.
Xray JSON сохраняет собственные routing/DNS/mux/policy/sniffing/streamSettings;
внешние файлы, API/reverse, платформенные socket overrides отклоняются.
XHTTP extra/FinalMask и geodata реализованы в общем ядре.

Не заявляется полная совместимость всех опций Happ. Legacy VMess alterId>0,
внешние SS plugins и неподдержанные URI-параметры отклоняются; отключение
TLS-проверки не включается молча. MTProto предназначен Telegram, серверный
Dokodemo/tunnel не является отдельным клиентским VPN. OpenVPN/Cisco/Forti
не добавлены. Секреты остаются в общем Keychain
`AfterFirstUnlockThisDeviceOnly`; provider preferences содержат ID/режим.
Серверные inbound/peers должны быть настроены заранее.

Системный статус «VPN подключён» подтверждает запуск локального транспорта,
а не интернет или успешный WireGuard handshake. Автоматического выбора узла,
фонового refresh, QR, kill switch и on-demand нет. После смены физической сети
пока требуется ручное переподключение; миграция Wi-Fi ↔ cellular не проверена.

## Экраны и VK

Для компактной ширины используется TabView, для iPad/regular — NavigationSplitView
с боковым меню. Главная прокручивается, контент ограничен по ширине; используются
системные светлая/тёмная темы, Dynamic Type и масштабируемая иконка. Формы, профили, настройки, журналы и диагностика используют общую тему с mint-акцентом.
Добавлены кнопки физического IP, IP туннеля, Google и YouTube HTTPS-пинга;
это только исходники, iOS-привязка к физическому интерфейсу ещё не проверена.
Файловый импорт общий. Это изменения исходников; визуальная проверка размеров,
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

Xray/VK используют IPv4; URI/VK DNS идёт по TCP внутри прокси, AAAA получает пустой ответ. Пользовательский JSON сохраняет собственные DNS/routing.
WG/AWG следуют Address/AllowedIPs/DNS/MTU `.conf`, включая явный IPv6. Проверка
настоящего IPv6, отсутствия утечек и поведения iOS full/split routing ещё нужна.
Подробности, ограничения и лицензии: [docs/XRAY-MOBILE.md](docs/XRAY-MOBILE.md).

Выполнено на Linux: статические guards проекта/entitlements/fixtures и syntax
parser для 46 Swift-файлов. Это **не компиляция Swift**. Native mirror проверяется
`python3 tools/sync-native.py --check`; тесты Go выполнялись в Android-репозитории,
а не как iOS-тесты. Приватные журналы и реквизиты исключены из Git.

Исправлена ошибка сборки `SubscriptionView`: имена `highestRevision` и
`minimumRevision` согласованы с моделью и API. `tools/check-source.py` теперь
дополнительно сверяет используемые поля, метки инициализатора и аргументы fetch
с их объявлениями; исходный ошибочный вариант эту проверку не проходит.
Это узкая статическая проверка контракта, а не замена компиляции Xcode.

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
