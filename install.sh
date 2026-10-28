#!/bin/sh
# Встановлення або оновлення NotchIsland однією командою в Терміналі:
#   curl -fsSL https://raw.githubusercontent.com/HyperIT-Academy/NotchIsland-releases/main/install.sh | sh
#
# Чому не pkg: завантажений браузером непідписаний pkg macOS блокує, і відкрити його можна
# лише через Системні параметри → «Усе одно відкрити» — найдовший шлях для друга. curl не
# ставить quarantine, тож Gatekeeper не втручається; справжність перевіряємо самі: sha256
# з того самого appcast.json, що читає автооновлення, і сертифікат підпису бандла.
# Пароль потрібен лише тоді, коли наявна копія належить іншому користувачу (стара pkg-установка).
set -eu

APPCAST_URL="${NI_APPCAST_URL:-https://raw.githubusercontent.com/HyperIT-Academy/NotchIsland-releases/main/appcast.json}"
INSTALL_DIR="${NI_INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/NotchIsland.app"
LEAF="7085390383351b1118135f25b8e0e98059613d61"
REQUIREMENT="=identifier \"com.hypercode.notchisland\" and certificate leaf = H\"$LEAF\""
RELEASES_PREFIX="${NI_RELEASES_PREFIX:-https://github.com/HyperIT-Academy/NotchIsland-releases/releases/download/}"

say() { printf '%s\n' "$*"; }
die() { printf 'NotchIsland: %s\n' "$*" >&2; exit 1; }

# 0 — якщо версія $1 не менша за $2 (покомпонентно, як UpdateService.components).
version_at_least() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, "."); n = na > nb ? na : nb
        for (i = 1; i <= n; i++) { p = x[i] + 0; q = y[i] + 0; if (p != q) exit !(p > q) }
        exit 0 }'
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/notchisland-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

say "==> Перевіряю останню версію"
curl -fsSL --retry 3 -o "$WORK/appcast.json" "$APPCAST_URL" || die "не вдалось завантажити appcast"
field() { plutil -extract "$1" raw -o - "$WORK/appcast.json" 2>/dev/null || die "appcast без поля $1"; }
VERSION="$(field version)"
BUILD="$(field build)"
URL="$(field url)"
SHA="$(field sha256)"
MIN_OS="$(field minSystemVersion)"

case "$URL" in
    "$RELEASES_PREFIX"*) ;;
    *) die "неочікуване джерело завантаження: $URL" ;;
esac
OS="$(sw_vers -productVersion)"
version_at_least "$OS" "$MIN_OS" || die "потрібна macOS $MIN_OS або новіша (зараз $OS)"

if [ -d "$DEST" ]; then
    INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo 0)"
    INSTALLED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist" 2>/dev/null || echo 0)"
    # Новіша або та сама версія: нічого не міняємо, лише запускаємо — повторна команда
    # не повинна ні переставляти застосунок, ні відкочувати його назад.
    UP_TO_DATE=0
    if [ "$INSTALLED" = "$VERSION" ]; then
        [ "$INSTALLED_BUILD" -lt "$BUILD" ] 2>/dev/null || UP_TO_DATE=1
    elif version_at_least "$INSTALLED" "$VERSION"; then
        UP_TO_DATE=1
    fi
    if [ "$UP_TO_DATE" = 1 ]; then
        say "==> Уже встановлено NotchIsland $INSTALLED — це остання версія"
        [ "${NI_NO_LAUNCH:-0}" = 1 ] || open "$DEST"
        exit 0
    fi
    ACTION="Оновлено з $INSTALLED до $VERSION"
else
    ACTION="Встановлено NotchIsland $VERSION"
fi

say "==> Завантажую NotchIsland $VERSION"
curl -fL --retry 3 --progress-bar -o "$WORK/app.zip" "$URL" || die "не вдалось завантажити застосунок"
ACTUAL="$(shasum -a 256 "$WORK/app.zip" | awk '{print $1}')"
[ "$ACTUAL" = "$SHA" ] || die "контрольна сума не збігається — файл пошкоджено або підмінено"

ditto -x -k "$WORK/app.zip" "$WORK/x" || die "не вдалось розпакувати архів"
NEW="$WORK/x/NotchIsland.app"
[ -d "$NEW" ] || die "в архіві немає NotchIsland.app"
codesign --verify --deep --strict -R "$REQUIREMENT" "$NEW" 2>/dev/null \
    || die "підпис застосунку не збігається з сертифікатом NotchIsland"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW/Contents/Info.plist")" = "$VERSION" ] \
    || die "версія в архіві не збігається з appcast"

# Пароль лише коли без нього не обійтись: копію від pkg-інсталятора міг покласти root.
SUDO=""
[ -w "$INSTALL_DIR" ] || SUDO="sudo"
[ ! -e "$DEST" ] || [ -O "$DEST" ] || SUDO="sudo"
[ -z "$SUDO" ] || say "==> Потрібен пароль від Mac (наявна копія належить системі)"

# Живий процес зі старого бандла падає при заміні файлів під ним; SIGTERM застосунок ловить
# і виходить коректно (знімає блок клавіатури й lease кришки). Той самий порядок, що в
# installer/scripts/preinstall, включно зі збереженням увімкненого режиму кришки.
if [ "${NI_SKIP_STOP:-0}" != 1 ] && pgrep -x NotchIsland >/dev/null 2>&1; then
    LID=0
    [ "$(defaults read com.hypercode.notchisland lidModeActive 2>/dev/null || true)" = "1" ] && LID=1
    pkill -x NotchIsland 2>/dev/null || true
    i=0
    while pgrep -x NotchIsland >/dev/null 2>&1 && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    if pgrep -x NotchIsland >/dev/null 2>&1; then pkill -KILL -x NotchIsland 2>/dev/null || true; sleep 0.2; fi
    [ "$LID" = 0 ] || defaults write com.hypercode.notchisland lidModeActive -bool true
fi

# Копія ПОРУЧ і обмін лише після успішного копіювання: збій посередині не має лишати
# «Програми» без застосунку. Невдалий обмін повертає стару версію на місце.
STAGE="$DEST.new"
OLD="$DEST.old"
$SUDO rm -rf "$STAGE" "$OLD"
$SUDO ditto "$NEW" "$STAGE" || die "не вдалось скопіювати в $INSTALL_DIR"
if [ -e "$DEST" ]; then $SUDO mv "$DEST" "$OLD" || { $SUDO rm -rf "$STAGE"; die "не вдалось замінити стару версію"; }; fi
if ! $SUDO mv "$STAGE" "$DEST"; then
    [ ! -e "$OLD" ] || $SUDO mv "$OLD" "$DEST"
    die "не вдалось встановити нову версію — стару повернено"
fi
$SUDO rm -rf "$OLD"
# Бандл має належати користувачу, інакше автооновлення вимагатиме ручного кроку.
[ -z "$SUDO" ] || sudo chown -R "$(id -un)" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ ! -x "$LSREG" ] || "$LSREG" -f "$DEST" >/dev/null 2>&1 || true

say "==> $ACTION"
if [ "${NI_NO_LAUNCH:-0}" != 1 ]; then
    open "$DEST"
    say "==> Запущено. Наведи курсор на чолку зверху екрана. Далі оновлення приходять самі."
fi
