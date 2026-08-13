# Qrecs

[English](#english) · [Русский](#russian) · [v0.1.0 release notes](docs/releases/v0.1.0.md)

<a id="english"></a>
## English

Qrecs is a native Quran recitation library and player for macOS 15 and later. It is built with SwiftUI, AVFoundation, and GRDB.

### Features

- A native two-column library with favorite reciters, search, and sortable surah tables.
- Streaming playback and user-requested offline downloads, with an explicit offline mode.
- A global mini-player and a queue ordered by surah number.
- Four independently mixed, gapless-looped ambient sounds: fire, birdsong, rain, and waterfall.
- English and Russian localization, System/Light/Dark appearance controls, and system Liquid Glass on supported macOS versions.
- A bundled, read-only SQLite catalog; normal builds, tests, and app launches do not fetch catalog metadata.

### Install v0.1.0

The v0.1.0 GitHub asset is an ad-hoc-signed, unnotarized pre-release ZIP:

1. Download `Qrecs-0.1.0-macOS.zip` and, optionally, verify it against `Qrecs-0.1.0-macOS.zip.sha256` with `shasum -a 256 -c Qrecs-0.1.0-macOS.zip.sha256`.
2. Extract the ZIP and move `Qrecs.app` to Applications.
3. On first launch, macOS may block the unnotarized app. In Finder, right-click (or Control-click) `Qrecs.app`, choose **Open**, then confirm **Open**. The same option may also appear after an initial double-click.

Do not bypass or disable Gatekeeper. Review the [v0.1.0 release notes](docs/releases/v0.1.0.md) before installing.

### Build and test

Requirements: macOS 15+, a compatible Xcode installation, and the command-line developer tools.

```sh
# Debug build and launch
./script/build_and_run.sh

# Build the app and both test runners
xcodebuild build-for-testing -project Qrecs.xcodeproj -scheme Qrecs \
  -destination 'platform=macOS'

# Run the complete test plan
xcodebuild test -project Qrecs.xcodeproj -scheme Qrecs \
  -destination 'platform=macOS'

# Validate the deterministic catalog builder
python3 -m unittest discover -s CatalogTools/Tests -v

# Run release packaging regression tests
bash script/tests/package_release_tests.sh
```

To build the ad-hoc Release ZIP and SHA-256 manifest in `dist/`:

```sh
./script/package_release.sh
```

The packaging script uses the exact dependency versions in `Package.resolved`, reuses an existing local Swift package checkout when available, builds the Release configuration, verifies version 0.1.0 and macOS 15.0 metadata, ad-hoc signs and validates the app, and excludes test/debug artifacts. Build and release output directories are ignored by Git.

### Catalog and user data

Qrecs ships `Qrecs/Resources/Catalog/catalog.sqlite` with 172 reciter entries, 114 surahs, and 19,608 track URLs. Its checked-in source catalog is under `CatalogTools/Data/`; it contains reviewed English/Russian names and source URLs pointing to third-party Quran audio hosts, including mp3quran.net and archive.org. At runtime the bundled catalog is read-only. Regenerate it locally with:

```sh
python3 CatalogTools/build_catalog.py
```

Because Qrecs is sandboxed, mutable files are stored under `~/Library/Containers/com.heezya.Qrecs/Data/Library/Application Support/Qrecs/`:

- `UserData/user.sqlite` — favorites and completed-download metadata.
- `AudioCache/` — Quran audio explicitly downloaded by the user.

Offline audio is not placed in the system Caches directory and is not automatically evicted. It can be removed per reciter or cleared from Settings.

### Audio notices and legal disclaimer

The bundled ambient recordings are CC0 1.0 assets from Freesound. Authors, source pages, and license details are listed in [`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES). CC0 applies to those ambient files, not to Quran recordings referenced by the catalog.

The MIT license covers this repository's code only. It does **not** grant streaming, downloading, redistribution, public-performance, or other rights to Quran recordings hosted by third parties. Hosts, URLs, availability, and applicable terms can change. Users and redistributors are responsible for obtaining any permissions required in their jurisdiction and by each source's terms.

### License

Qrecs source code is available under the [MIT License](LICENSE), subject to the third-party limitations above.

<a id="russian"></a>
## Русский

Qrecs — нативная библиотека и плеер чтений Корана для macOS 15 и новее. Приложение создано на SwiftUI, AVFoundation и GRDB.

### Возможности

- Нативная двухколоночная медиатека: избранные чтецы, поиск и сортируемая таблица сур.
- Потоковое воспроизведение и загрузка выбранных записей для офлайн-прослушивания, включая явный офлайн-режим.
- Глобальный мини-плеер и очередь по номерам сур.
- Четыре независимо настраиваемых зацикленных фоновых звука: огонь, птицы, дождь и водопад.
- Русская и английская локализации, режимы оформления Системный/Светлый/Тёмный и системный Liquid Glass в поддерживаемых версиях macOS.
- Встроенный каталог SQLite только для чтения; обычная сборка, тесты и запуск приложения не загружают метаданные каталога из сети.

### Установка v0.1.0

Файл v0.1.0 на GitHub — предварительная, ad-hoc подписанная и не нотаризованная ZIP-сборка:

1. Скачайте `Qrecs-0.1.0-macOS.zip`. При желании проверьте его по `Qrecs-0.1.0-macOS.zip.sha256` командой `shasum -a 256 -c Qrecs-0.1.0-macOS.zip.sha256`.
2. Распакуйте ZIP и переместите `Qrecs.app` в «Программы».
3. При первом запуске macOS может заблокировать ненотаризованное приложение. В Finder нажмите правой кнопкой мыши (или Control-кликом) на `Qrecs.app`, выберите **Открыть**, затем подтвердите **Открыть**. Эта возможность также может появиться после первой попытки запуска двойным щелчком.

Не отключайте и не обходите Gatekeeper. Перед установкой ознакомьтесь с [примечаниями к выпуску v0.1.0](docs/releases/v0.1.0.md#russian).

### Сборка и тесты

Требуются macOS 15+, совместимая версия Xcode и инструменты командной строки разработчика.

```sh
# Отладочная сборка и запуск
./script/build_and_run.sh

# Сборка приложения и тестовых раннеров
xcodebuild build-for-testing -project Qrecs.xcodeproj -scheme Qrecs \
  -destination 'platform=macOS'

# Полный план тестов
xcodebuild test -project Qrecs.xcodeproj -scheme Qrecs \
  -destination 'platform=macOS'

# Проверка детерминированного генератора каталога
python3 -m unittest discover -s CatalogTools/Tests -v

# Регрессионные тесты упаковки выпуска
bash script/tests/package_release_tests.sh
```

Создание ad-hoc подписанного Release ZIP и SHA-256-файла в `dist/`:

```sh
./script/package_release.sh
```

Скрипт использует точные версии зависимостей из `Package.resolved`, по возможности повторно использует локальную копию Swift-пакетов, собирает конфигурацию Release, проверяет версию 0.1.0 и минимальную macOS 15.0, подписывает приложение ad-hoc, проверяет подпись и исключает тестовые/отладочные артефакты. Каталоги сборки и выпуска исключены из Git.

### Каталог и данные пользователя

В `Qrecs/Resources/Catalog/catalog.sqlite` находятся 172 записи чтецов, 114 сур и 19 608 URL аудиодорожек. Исходный каталог в `CatalogTools/Data/` содержит проверенные русские/английские названия и URL сторонних аудиохостингов Корана, включая mp3quran.net и archive.org. Во время работы встроенный каталог доступен только для чтения. Локальная пересборка:

```sh
python3 CatalogTools/build_catalog.py
```

Из-за песочницы Qrecs изменяемые файлы хранятся в `~/Library/Containers/com.heezya.Qrecs/Data/Library/Application Support/Qrecs/`:

- `UserData/user.sqlite` — избранное и метаданные завершённых загрузок.
- `AudioCache/` — записи Корана, явно загруженные пользователем.

Офлайн-аудио не помещается в системный каталог Caches и не удаляется автоматически. В Настройках можно удалить записи отдельного чтеца или очистить весь аудиокэш.

### Уведомления об аудио и правовой дисклеймер

Встроенные фоновые записи распространяются как CC0 1.0 и получены с Freesound. Авторы, страницы источников и сведения о лицензии перечислены в [`THIRD_PARTY_NOTICES`](THIRD_PARTY_NOTICES). CC0 относится к этим фоновым файлам, но не к записям Корана из каталога.

Лицензия MIT распространяется только на код этого репозитория. Она **не** предоставляет прав на потоковое воспроизведение, загрузку, распространение, публичное исполнение или иное использование записей Корана, размещённых третьими лицами. Хостинги, URL, доступность и условия использования могут меняться. Пользователь или распространитель обязан самостоятельно получить разрешения, необходимые по законам своей юрисдикции и условиям каждого источника.

### Лицензия

Исходный код Qrecs доступен по [лицензии MIT](LICENSE) с учётом описанных выше ограничений для материалов третьих лиц.
