# Протоколы и форматы · 0.5.0

Сверка выполнена по `internal/database/model/model.go`, генераторам
`internal/sub/service.go`, `json_service.go` и `clash_service.go`.
Android и iOS используют одно native-ядро с проверяемым зеркалом исходников.
Это список реализованных путей, а не утверждение, что все серверные сочетания
проверены на устройствах. iOS в этой работе **не собирался**.

| Тип панели | Путь в Blink | Экспорт/импорт |
| --- | --- | --- |
| VLESS | Xray | URI, plain/base64 feed, Xray JSON; TLS/REALITY, Vision и VLESS encryption проверяет закреплённое ядро |
| VMess | Xray AEAD | URI, base64 JSON URI, JSON feed; alterId > 0 не поддерживается |
| Trojan | Xray | URI/JSON; удалённый из текущего Xray Trojan flow отклоняется |
| Shadowsocks / SS2022 | Xray | SIP002, legacy base64, JSON; внешние plugins требуют отдельной реализации |
| HTTP | Xray HTTP CONNECT | Ручной URI/JSON; отдельную share-ссылку панель не генерирует |
| Mixed (SOCKS/HTTP) | Xray SOCKS5 или HTTP CONNECT | Соответствующий клиентский протокол, не отдельный wire protocol |
| Hysteria | Xray Hysteria2 | `hy2://` / `hysteria2://`, JSON; действующая схема панели принудительно выбирает version2 |
| WireGuard | официальный WG-совместимый AWG backend; Xray WG для JSON | `wireguard://`, `.conf`, JSON |
| AmneziaWG | официальный AWG v3 backend | `vpn://` с plain INI в base64url, `.conf`, узлы Clash |
| TUIC v5 | официальный sing-quic | `tuic://`, узлы Clash; CC и UDP native/quic |
| MASQUE | Xray CONNECT-IP | Xray JSON; панель не генерирует универсальный MASQUE URI |
| MTProto | Telegram-specific proxy | Не является общесистемным VPN; ссылки предназначены Telegram, TUN-профиль из них не создаётся |
| Tunnel / Dokodemo-door | Серверная переадресация | Не отдельный клиентский VPN-протокол; используется транспорт целевого сервиса |

Дополнительно есть legacy Hysteria v1 через sing-quic для ручных импортов; это
не означает поддержку version1 действующим Xray-сервером панели.
OpenVPN, Cisco AnyConnect и Forti не добавлялись.

## Настройки и форматы

- TCP/raw, WS, gRPC, HTTPUpgrade, XHTTP, KCP — при допустимых сочетаниях Xray.
  XDRIVE передаётся через JSON, поскольку его URI панель не экспортирует.
- JSON сохраняет streamSettings, encryption/flow, mux, routing, DNS,
  observatory/balancers, policy и geodata. Desktop listeners удаляются;
  sniffing, inbound tag и userLevel переносятся в публичный packet/TUN context.
  Логи отключены; API/reverse, внешние файлы и platform-specific socket overrides
  не применяются. Недопустимый конфиг отклоняется.
- URI сохраняют TLS SNI/fingerprint/ALPN, REALITY pbk/sid/pqv, XHTTP extra,
  FinalMask fm, cipher suites. KCP seed/header преобразуются в актуальный
  mkcp-legacy FinalMask. Legacy alias `x_padding_bytes` согласуется с extra.
- AWG сохраняет J/S/H/I параметры, HeaderProtectionKey, padding/timing ranges,
  RandomTrailers, DisableCookies и keepalive range. Base64 header key из панели
  преобразуется в hex для UAPI. IPv6 AllowedIPs без IPv6 Address не создаёт
  фиктивный интерфейс IPv6; применяется только настроенное семейство.
- Xray JSON принимается одиночным объектом или массивом именованных конфигов.
  Страна/название каждого узла сохраняется отдельно. Plain/base64 URI feed и
  scoped Vokop JSON остаются отдельными форматами.
- Clash/Mihomo YAML импортирует **узлы** поддержанного набора параметров.
  Группы/правила/DNS Clash не эмулируются; клиент явно показывает это уведомление.
  Для сохранения маршрутизации экспортируйте Xray JSON. YAML aliases и дубли
  ключей отклоняются; неподдержанные узлы учитываются в результате импорта.
- Лимиты обычной подписки: 1 МиБ, до1024 узлов, зашифрованное хранилище до4 МиБ.
  Поиск страны/названия и независимое обновление feeds не объединяют разные узлы.

Не все произвольные параметры всех сторонних клиентов взаимозаменяемы.
Например, Hysteria leaf `pinSHA256` не подменяется Xray `pcs`, а отключение
TLS-проверки не включается молча. Такие ссылки отклоняются; используйте корректный
JSON с семантикой выбранного ядра. Полная совместимость со всеми опциями Happ
не заявляется.

## Проверяемый контракт

`TestMobileClientExportContract` создаёт детерминированные синтетические ссылки
реальными экспортёрами панели. Их fixture хранится в обоих клиентах и проверяется
общим native parser: VLESS TLS/REALITY/Vision/XHTTP, VMess, Trojan, SS/SS2022,
Hysteria2, WG, AWG3.1, TUIC и MASQUE JSON. Это тест форматов, не live acceptance.

Обновление fixture при изменении экспортёров (из корня панели):

```sh
BLINK_MOBILE_CONTRACT_OUTPUT=/path/to/blink-android/native/mobile/testdata/panel-exports.json \
  go test -run '^TestMobileClientExportContract$' ./internal/sub
# В Android: (cd native && go test -race ./...)
# В iOS: python3 tools/sync-native.py && python3 tools/sync-native.py --check
```

В fixture нет живых UUID/паролей/подписок. Не подставляйте туда действующие данные.
`tools/mobile-fixture.py` создаёт отдельный временный приватный TLS-профиль для
проверки разрешённого сервера. Он не меняет базу панели. Запуск Xray ограничивайте
RuntimeMaxSec и после проверки останавливайте unit/удаляйте конфигурацию.

Проверки устройств и ограничения: [Android](https://github.com/remzone/blink-android/blob/main/docs/validation.md),
[iOS source status](https://github.com/remzone/blink_ios/blob/main/docs/XRAY-MOBILE.md).
