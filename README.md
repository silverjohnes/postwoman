# Postwoman

**Much better than Postman (for simple jobs)**

A free, native macOS app for working with Postman collections. Fast and lightweight. Collections can be stored locally or in a remote location (for example a synced or network folder), with an optional backup copy; sensitive data is encrypted. Node.js and Newman are bundled, so there is nothing else to install.

**English** · [Русский](#postwoman-ru)

Version **0.8.3.5** (build 0080305)

## Features

- Import and export Postman collections (v2.1), folders, drag & drop, search
- Request editor with headers, body (raw / form-data / urlencoded / binary), Basic auth, and pre-request / post-response scripts (`pm.*`)
- Result pane next to the request: large responses open instantly, JSON is beautified, with search
- Collection and folder runner with CSV / JSON data files, iterations, preview of the data and an errors CSV
- Variables with highlighting; secret ones are stored encrypted, the key lives in the Keychain
- Import from and copy as cURL
- History, log, undo / redo, backup storage folder, 25 interface languages

For advanced features and team collaboration, use Postman.

## Requirements

macOS 15+, Apple Silicon (arm64), Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Build

```bash
git clone https://github.com/<you>/Postwoman.git && cd Postwoman
bash scripts/update-runtime.sh      # downloads Newman + Node into Vendor/ (needs npm, once)
xcodegen generate                   # creates Postwoman.xcodeproj
open Postwoman.xcodeproj            # or: bash scripts/build-app.sh
```

`Vendor/` (about 55 MB: Newman and the official Node.js binary) is not in the repository; `scripts/update-runtime.sh` creates it and checksums are verified on every build. You may commit it to your own repo to build offline.

In Xcode, enable **Automatically manage signing** (select your Team) under **Signing & Capabilities**: without it the Keychain, and so secret variables, are unavailable.

## Distribution

An ad-hoc signed app is blocked by Gatekeeper on other Macs: `xattr -dr com.apple.quarantine Postwoman.app` or right-click → Open. For proper distribution use a Developer ID certificate and notarization (see `docs/DEVELOPMENT.ru.md`).

## License

[MIT](LICENSE). Bundled components keep their own licenses: Newman (Apache-2.0), Node.js (MIT).

---

<a id="postwoman-ru"></a>

# Postwoman (RU)

**Much better than Postman (for simple jobs)**

**Гораздо лучше, чем Постман (для простых задач)**

Бесплатное нативное приложение для macOS для работы с коллекциями Postman. Быстрое и лёгкое. Коллекции можно хранить локально или удалённо (например, в синхронизируемой или сетевой папке), с необязательной резервной копией; чувствительные данные шифруются. Node.js и Newman встроены, ставить больше ничего не нужно.

Версия **0.8.3.5** (сборка 0080305)

## Возможности

- Импорт и экспорт коллекций Postman (v2.1), папки, перетаскивание, поиск
- Редактор запроса: заголовки, тело (raw / form-data / urlencoded / binary), Basic-авторизация, pre-request и post-response скрипты (`pm.*`)
- Результат рядом с запросом: большие ответы открываются сразу, JSON форматируется, есть поиск
- Раннер коллекций и папок с файлами данных CSV / JSON, итерациями, предпросмотром данных и CSV ошибок
- Переменные с подсветкой; секретные хранятся в зашифрованном виде, ключ — в Связке ключей
- Импорт из cURL и копирование как cURL
- История, журнал, отмена и повтор, резервная папка хранилища, 25 языков интерфейса

Для продвинутых функций и командной работы используйте Postman.

## Требования

macOS 15+, Apple Silicon (arm64), Xcode 16+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Сборка

```bash
git clone https://github.com/<вы>/Postwoman.git && cd Postwoman
bash scripts/update-runtime.sh      # скачает Newman и Node в Vendor/ (нужен npm, один раз)
xcodegen generate                   # создаст Postwoman.xcodeproj
open Postwoman.xcodeproj            # или: bash scripts/build-app.sh
```

Папки `Vendor/` (около 55 МБ: Newman и официальный бинарник Node.js) в репозитории нет; её создаёт `scripts/update-runtime.sh`, контрольные суммы проверяются при каждой сборке. Можно закоммитить её в свой репозиторий, чтобы собирать без сети.

В Xcode включите **Automatically manage signing** (выберите свою Team) в **Signing & Capabilities**: без этого Связка ключей, а с ней секретные переменные, недоступны.

## Раздача

Приложение с ad-hoc подписью на чужом Mac блокирует Gatekeeper: `xattr -dr com.apple.quarantine Postwoman.app` или правый клик → Открыть. Для нормальной раздачи нужны сертификат Developer ID и нотаризация (см. `docs/DEVELOPMENT.ru.md`).

## Лицензия

[MIT](LICENSE). Встроенные компоненты сохраняют свои лицензии: Newman (Apache-2.0), Node.js (MIT).