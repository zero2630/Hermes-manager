#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE='ghcr.io/jo-inc/camofox-browser:latest'
readonly CONTAINER='camofox-browser'
readonly PREVIOUS_CONTAINER='camofox-browser-previous'
readonly HEALTH_URL='http://127.0.0.1:9377/health'

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[[ $# -eq 0 ]] || fail 'Запуск: bash camofox.sh'
[[ "$(uname -s)" == Linux ]] || fail 'Нужен Linux VPS с systemd.'
command -v systemctl >/dev/null || fail 'Нужен systemd для запуска Docker.'
command -v flock >/dev/null || fail 'Нужна команда flock из пакета util-linux.'

# Do not let two runs from this checkout replace the same container at once.
exec 9<"${BASH_SOURCE[0]}"
flock -n 9 || fail 'Дождитесь завершения другого запуска camofox.sh.'

elevate=()
if (( EUID != 0 )); then
    command -v sudo >/dev/null || fail 'Для управления системным Docker нужен sudo.'
    elevate=(sudo)
fi

packages=()
command -v docker >/dev/null || packages+=(docker.io)
command -v curl >/dev/null || packages+=(curl ca-certificates)
if (( ${#packages[@]} > 0 )); then
    command -v apt-get >/dev/null || fail "Установите зависимости вручную: ${packages[*]}."
    "${elevate[@]}" apt-get update
    "${elevate[@]}" apt-get install -y --no-install-recommends "${packages[@]}"
fi

"${elevate[@]}" systemctl enable --now docker.service
docker_cmd=("${elevate[@]}" docker --host unix:///var/run/docker.sock)

if "${docker_cmd[@]}" container inspect "$PREVIOUS_CONTAINER" >/dev/null 2>&1; then
    fail "Найден контейнер $PREVIOUS_CONTAINER от предыдущего запуска. Проверьте его перед повторным обновлением."
fi

printf 'Загружаю образ %s…\n' "$IMAGE"
"${docker_cmd[@]}" pull "$IMAGE"
image_id="$("${docker_cmd[@]}" image inspect --format '{{.Id}}' "$IMAGE")"

previous_id=''
previous_running=false
new_id=''

rollback() {
    local status=$?
    if (( status == 0 )); then
        return
    fi

    if [[ -n "$new_id" ]]; then
        "${docker_cmd[@]}" logs --tail 80 "$new_id" >&2 || true
        if ! "${docker_cmd[@]}" rm -f "$new_id" >/dev/null; then
            printf 'Не удалось удалить новый контейнер %s.\n' "$new_id" >&2
            return
        fi
    fi

    if [[ -n "$previous_id" ]]; then
        if ! "${docker_cmd[@]}" rename "$previous_id" "$CONTAINER"; then
            printf 'Прежний контейнер сохранён. Проверьте %s.\n' "$PREVIOUS_CONTAINER" >&2
            return
        fi
        if [[ "$previous_running" == true ]]; then
            "${docker_cmd[@]}" start "$previous_id" >/dev/null || {
                printf 'Имя прежнего контейнера восстановлено, но запустить его не удалось.\n' >&2
                return
            }
        fi
        printf 'Прежний контейнер Camofox восстановлен.\n' >&2
    fi
}

trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if old_id="$("${docker_cmd[@]}" container inspect --format '{{.Id}}' "$CONTAINER" 2>/dev/null)"; then
    previous_running="$("${docker_cmd[@]}" container inspect --format '{{.State.Running}}' "$old_id")"
    "${docker_cmd[@]}" rename "$old_id" "$PREVIOUS_CONTAINER"
    previous_id="$old_id"
    if [[ "$previous_running" == true ]]; then
        "${docker_cmd[@]}" stop "$previous_id" >/dev/null
    fi
fi

new_id="$("${docker_cmd[@]}" create \
    --name "$CONTAINER" \
    --restart unless-stopped \
    --shm-size=2g \
    --publish 127.0.0.1:9377:9377 \
    --env CAMOFOX_PORT=9377 \
    "$image_id")"
"${docker_cmd[@]}" start "$new_id" >/dev/null

printf 'Жду Camofox API…\n'
deadline=$(( SECONDS + 120 ))
until curl --noproxy '*' --fail --silent --max-time 3 --output /dev/null "$HEALTH_URL"; do
    (( SECONDS < deadline )) || fail "Camofox не ответил за 120 секунд на $HEALTH_URL."
    sleep 2
done

trap - EXIT INT TERM
if [[ -n "$previous_id" ]]; then
    "${docker_cmd[@]}" rm "$previous_id" >/dev/null ||
        fail "Новый Camofox работает, но не удалось удалить прежний контейнер $PREVIOUS_CONTAINER."
fi

printf 'Camofox готов. API отвечает на %s.\n' "$HEALTH_URL"
