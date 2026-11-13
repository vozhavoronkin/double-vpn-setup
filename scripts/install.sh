#!/bin/bash
#
# Установщик VPN Chain Setup из GitHub Releases.
#
# Скачивает zip и SHA256SUMS.txt, проверяет контрольную сумму до любых
# изменений в системе, распаковывает архив, снимает карантинный флаг и
# копирует VPNChainSetup.app в /Applications (sudo — только при необходимости).
#
# Использование:
#   bash install.sh            # последний релиз
#   bash install.sh v1.2.3     # конкретная версия (можно без «v»)
#
set -euo pipefail

REPO="vozhavoronkin/double-vpn-setup"
APP_NAME="VPNChainSetup.app"
DEST="/Applications/${APP_NAME}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpnchain-install.XXXXXX")"
cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

# Версия: аргумент (v1.2.3 или 1.2.3) либо последний релиз.
resolve_version() {
    local requested="${1:-}"
    local tag

    if [ -n "${requested}" ]; then
        case "${requested}" in
            v*) tag="${requested}" ;;
            *) tag="v${requested}" ;;
        esac
        echo "Версия: ${tag}" >&2
        if ! curl -fsIL -o /dev/null --connect-timeout 15 --max-time 60 \
            "https://github.com/${REPO}/releases/tag/${tag}"; then
            die "релиз ${tag} не найден"
        fi
    else
        local latest_url
        latest_url="$(curl -fsIL -o /dev/null -w '%{url_effective}' \
            --connect-timeout 15 --max-time 60 \
            "https://github.com/${REPO}/releases/latest")" \
            || die "не удалось определить последний релиз (проверьте доступ к github.com)"
        tag="${latest_url##*/}"
        case "${tag}" in
            v[0-9]*) ;;
            *) die "не удалось определить версию последнего релиза (получено «${tag}»)" ;;
        esac
        echo "Последний релиз: ${tag}" >&2
    fi
    echo "${tag}"
}

TAG="$(resolve_version "${1:-}")"
VERSION="${TAG#v}"
ZIP_NAME="VPNChainSetup-${VERSION}-macos-universal.zip"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

echo "Скачивание ${ZIP_NAME} и SHA256SUMS.txt..."
curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
    -o "${TMP_DIR}/${ZIP_NAME}" "${BASE_URL}/${ZIP_NAME}"
curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
    -o "${TMP_DIR}/SHA256SUMS.txt" "${BASE_URL}/SHA256SUMS.txt"

echo "Проверка контрольной суммы..."
EXPECTED="$(awk -v f="${ZIP_NAME}" '$2 == f {print $1; exit}' "${TMP_DIR}/SHA256SUMS.txt")"
if [ -z "${EXPECTED}" ]; then
    die "в SHA256SUMS.txt нет записи для ${ZIP_NAME}; установка отменена"
fi
ACTUAL="$(shasum -a 256 "${TMP_DIR}/${ZIP_NAME}" | awk '{print $1}')"
if [ "${ACTUAL}" != "${EXPECTED}" ]; then
    die "контрольная сумма не совпала (ожидалось ${EXPECTED}, получено ${ACTUAL}); установка отменена"
fi

echo "Распаковка..."
ARCHIVE_DIR="${TMP_DIR}/unpack"
mkdir -p "${ARCHIVE_DIR}"
ditto -x -k "${TMP_DIR}/${ZIP_NAME}" "${ARCHIVE_DIR}"
APP_PATH="${ARCHIVE_DIR}/${APP_NAME}"
[ -d "${APP_PATH}" ] || die "в архиве нет ${APP_NAME}"

if xattr -p com.apple.quarantine "${APP_PATH}" >/dev/null 2>&1; then
    echo "Снятие карантинного флага..."
    xattr -dr com.apple.quarantine "${APP_PATH}"
fi

echo "Установка в /Applications..."
echo "Если VPNChainSetup запущен — закройте его: после обновления понадобится перезапуск."
if ! { rm -rf "${DEST}.new" && ditto "${APP_PATH}" "${DEST}.new" \
    && rm -rf "${DEST}" && mv "${DEST}.new" "${DEST}"; } 2>/dev/null; then
    echo "Первая попытка не удалась; повтор с правами администратора (sudo)..."
    sudo rm -rf "${DEST}.new" || die "не удалось подготовить место в /Applications"
    sudo ditto "${APP_PATH}" "${DEST}.new" || die "не удалось скопировать приложение в /Applications"
    sudo rm -rf "${DEST}" && sudo mv "${DEST}.new" "${DEST}" \
        || die "не удалось заменить приложение в /Applications"
fi

echo
echo "Готово: ${DEST}"
echo "Сборка не подписана Apple. Напоминание из релиза: при проблемах с запуском"
echo "снимите карантин вручную — xattr -dr com.apple.quarantine \"${DEST}\"."
