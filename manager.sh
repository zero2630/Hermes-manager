#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BROWSER_SCRIPT="$SCRIPT_DIR/camofox.sh"
readonly CAMOFOX_SCRIPT_URL='https://raw.githubusercontent.com/zero2630/Hermes-manager/refs/heads/main/camofox.sh'
readonly CAMOFOX_ENDPOINT='http://127.0.0.1:9377'
readonly HERMES_INSTALLER='https://hermes-agent.nousresearch.com/install.sh'

export PATH="$HOME/.local/bin:${HERMES_HOME:-$HOME/.hermes}/bin:$PATH"

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Нужна команда $1."
}

install_apt_package() {
    require_command apt-get
    require_command sudo
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "$1"
}

ensure_whiptail() {
    if command -v whiptail >/dev/null 2>&1; then
        return 0
    fi

    printf 'Устанавливаю whiptail для меню…\n'
    install_apt_package whiptail
    require_command whiptail
}

require_hermes() {
    command -v hermes >/dev/null 2>&1 || fail 'Сначала выберите Install Hermes в меню.'
}

prepare_browser_script() (
    if [[ -f "$BROWSER_SCRIPT" && -r "$BROWSER_SCRIPT" ]]; then
        exit 0
    fi

    download="$(mktemp "$SCRIPT_DIR/.camofox.sh.XXXXXXXX")" ||
        fail "Нужна возможность записать camofox.sh в $SCRIPT_DIR."
    trap 'rm -f -- "$download"' EXIT

    printf 'Скачиваю camofox.sh…\n'
    curl --proto '=https' --proto-redir '=https' --location --fail \
        --silent --show-error --connect-timeout 10 --max-time 60 \
        --output "$download" "$CAMOFOX_SCRIPT_URL" || fail 'Не удалось скачать camofox.sh.'

    IFS= read -r shebang < "$download" || fail 'Получен пустой или неполный camofox.sh.'
    case "$shebang" in
        '#!/usr/bin/env bash'|'#!/bin/bash') ;;
        *) fail 'Полученный camofox.sh не начинается с Bash shebang.' ;;
    esac
    bash -n "$download" || fail 'Полученный camofox.sh содержит синтаксическую ошибку.'
    chmod u+x "$download"
    mv -nT -- "$download" "$BROWSER_SCRIPT"
    [[ -f "$BROWSER_SCRIPT" && -r "$BROWSER_SCRIPT" ]] ||
        fail "Не удалось сохранить camofox.sh в $SCRIPT_DIR."
)

browser_healthy() {
    curl --noproxy '*' --fail --silent --max-time 5 \
        --output /dev/null "$CAMOFOX_ENDPOINT/health"
}

manage_browser() {
    require_command curl
    prepare_browser_script
    # Соседний скрипт управляет Docker и ждёт готовности API перед выходом.
    bash "$BROWSER_SCRIPT"
    browser_healthy || fail "Camofox не отвечает на $CAMOFOX_ENDPOINT/health."
    printf 'Camofox отвечает на %s.\n' "$CAMOFOX_ENDPOINT"
}

ensure_libatomic() {
    if ! command -v dpkg-query >/dev/null 2>&1; then
        return 0
    fi

    local architecture
    architecture="$(dpkg --print-architecture)"
    if [[ "$(dpkg-query -W -f='${db:Status-Status}' "libatomic1:$architecture" 2>/dev/null)" == installed ]]; then
        return 0
    fi

    printf 'Устанавливаю libatomic1 для Node.js…\n'
    install_apt_package libatomic1
}

install_hermes() (
    ensure_libatomic

    if command -v hermes >/dev/null 2>&1; then
        printf 'Hermes уже установлен.\n'
        exit 0
    fi

    installer="$(mktemp)"
    trap 'rm -f -- "$installer"' EXIT
    curl --fail --silent --show-error --location "$HERMES_INSTALLER" --output "$installer"
    bash "$installer" --non-interactive --skip-browser --skip-computer-use
)

select_terminal_backend() {
    whiptail --title 'Terminal backend' --notags --default-item local \
        --ok-button 'Select' --cancel-button 'Back' --output-fd 3 \
        --menu 'Where should Hermes run commands?' 0 0 0 \
        local 'Local - run commands on the VPS' \
        docker 'Docker sandbox - run commands in a separate container' \
        3>&1 1>&2
}

install_stack() {
    local terminal_backend=local
    if [[ -t 0 && -t 2 ]]; then
        ensure_whiptail
        terminal_backend="$(select_terminal_backend)" || return 130
    fi

    require_command curl
    prepare_browser_script
    install_hermes
    require_hermes

    if ! browser_healthy; then
        manage_browser
    fi

    if [[ "$terminal_backend" == docker ]]; then
        require_command docker
        docker info >/dev/null ||
            fail 'Для Docker sandbox пользователю Hermes нужен доступ к Docker без sudo. Настройте доступ и повторите Install Hermes.'
    fi
    hermes config set terminal.backend "$terminal_backend"

    hermes config set CAMOFOX_URL "$CAMOFOX_ENDPOINT"
    if hermes plugins show camofox >/dev/null 2>&1; then
        hermes plugins enable camofox
    else
        hermes plugins install camofox --enable --yes-deps
    fi
    hermes camofox --help >/dev/null 2>&1 || fail 'Hermes не загрузил плагин Camofox. Проверьте его состояние через hermes plugins list и версию Hermes.'
    hermes tools enable camofox terminal --platform telegram

    cat <<'NEXT'

Hermes и Camofox настроены. Для нового бота выберите в меню по порядку:
  Select model
  Set up Telegram gateway
  Start gateway

Если Gateway уже работал, примените настройки через hermes gateway restart.
NEXT
}

start_gateway() {
    require_hermes
    require_command systemctl
    require_command loginctl

    local username linger
    username="$(id -un)"
    linger="$(loginctl show-user "$username" --property=Linger --value 2>/dev/null || true)"
    if [[ "$linger" != yes ]]; then
        if ! loginctl enable-linger "$username"; then
            require_command sudo
            sudo loginctl enable-linger "$username"
        fi
    fi

    hermes gateway install --start-on-login --no-start-now
    hermes gateway start
    hermes gateway status
}

show_status() {
    require_hermes
    require_command curl

    local result=0
    printf 'Терминал Hermes\n'
    hermes config get terminal.backend || result=1

    printf '\nCamofox\n'
    if browser_healthy; then
        printf 'API отвечает на %s.\n' "$CAMOFOX_ENDPOINT"
    else
        printf 'API не отвечает на %s/health.\n' "$CAMOFOX_ENDPOINT" >&2
        result=1
    fi

    printf '\nTelegram Gateway\n'
    hermes gateway status || result=1
    return "$result"
}

usage() {
    cat <<'USAGE'
Запуск от обычного пользователя на Linux VPS с systemd:
  bash manager.sh            Открыть меню whiptail (пакет установится при необходимости)

Прямые команды:
  bash manager.sh install    Установить Hermes и Camofox, выбрать терминал
  bash manager.sh model      Настроить модель и провайдера
  bash manager.sh telegram   Настроить Telegram Gateway
  bash manager.sh gateway    Включить автозапуск и запустить Gateway
  bash manager.sh tools      Настроить доступные инструменты Hermes
  bash manager.sh browser    Отдельно обновить или восстановить Camofox
  bash manager.sh status     Проверить терминал, браузер и Gateway

При установке manager.sh скачивает camofox.sh из zero2630/Hermes-manager, если файла нет рядом.
USAGE
}

run_action() {
    case "$1" in
        install) install_stack ;;
        model) require_hermes; hermes model ;;
        telegram) require_hermes; hermes gateway setup ;;
        gateway) start_gateway ;;
        tools) require_hermes; hermes tools ;;
        browser) manage_browser ;;
        status|diagnostics|diag) show_status ;;
        *) usage >&2; fail "Неизвестная команда: $1" ;;
    esac
}

menu() {
    [[ -t 0 && -t 2 ]] || fail 'Откройте bash manager.sh в интерактивном терминале.'
    ensure_whiptail

    local action status
    while true; do
        action="$(whiptail --title 'Hermes Manager' --notags \
            --ok-button 'Select' --cancel-button 'Exit' --output-fd 3 \
            --menu 'Use the arrow keys to choose an action.' 0 0 0 \
            install 'Install Hermes' \
            model 'Select model' \
            telegram 'Set up Telegram gateway' \
            gateway 'Start gateway' \
            3>&1 1>&2)" || return 0

        status=0
        # Run each action separately so a failure returns to the menu.
        bash "${BASH_SOURCE[0]}" "$action" || status=$?
        if (( status == 130 )); then
            continue
        fi
        if (( status != 0 )); then
            printf 'The action failed. See the message above.\n' >&2
        fi
        printf '\nPress Enter to return to the menu... '
        IFS= read -r _ || return 0
    done
}

[[ $# -le 1 ]] || fail 'Укажите одно действие. Список команд: bash manager.sh --help.'
case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
esac

[[ "$(uname -s)" == Linux ]] || fail 'Нужен Linux VPS.'
[[ "$(id -u)" != 0 ]] || fail 'Запустите manager.sh от пользователя Hermes без sudo: локальные команды агента выполняются от его имени.'

if [[ $# -eq 0 ]]; then
    menu
else
    run_action "${1#--}"
fi
