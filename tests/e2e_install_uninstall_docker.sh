#!/bin/sh
# tests/e2e_install_uninstall_docker.sh — установка, затем удаление: система обязана
# вернуться к тому, что было до установки.
#
# Снимает слепок (файлы и их содержимое, правила, наборы, маршруты, записи DNS, ускорители,
# процессы, cron), ставит z2k и панель настоящими установщиками, поднимает WARP настоящими
# правилами и интерфейсом, удаляет и сравнивает. Нужны Docker и выход в сеть: движок качается
# с релизов GitHub. В основной набор не входит. На настоящем Keenetic это не заменяет проверку.
#
# Запуск: sh tests/e2e_install_uninstall_docker.sh [main|cleanup]
DIR="$(cd "$(dirname "$0")/.." && pwd)"
KIND="${1:-main}"
PORT="${Z2K_E2E_PORT:-8770}"
IMAGE="${Z2K_E2E_IMAGE:-alpine:3.22}"
docker info >/dev/null 2>&1 || { echo "Docker недоступен"; exit 2; }
tmp=$(mktemp -d) || exit 1
trap 'kill "$hs" 2>/dev/null; rm -rf "$tmp"' EXIT
# Раздаём дерево как релиз: gen_file_hashes берёт список файлов из git, отсюда клон с коммитом.
git clone -q --no-hardlinks "$DIR" "$tmp/serve" || exit 1
(cd "$DIR" && git status --short | awk '{print $2}') | while read -r f; do
    [ -f "$DIR/$f" ] || continue
    mkdir -p "$tmp/serve/$(dirname "$f")"; cp "$DIR/$f" "$tmp/serve/$f"
done
(cd "$tmp/serve" && git add -A && git -c user.name=e2e -c user.email=e2e@local commit -qm e2e --no-verify; sh scripts/gen_file_hashes.sh >/dev/null 2>&1)
(cd "$tmp/serve" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 >/dev/null 2>&1) &
hs=$!
sleep 1
mkdir "$tmp/pack"
cp "$tmp/serve/z2k_cleanup.sh" "$DIR/tests/e2e/install_uninstall_rig.sh" "$tmp/pack/"
cp -R "$tmp/serve/webpanel" "$tmp/pack/webpanel"
tar -cf - -C "$tmp/pack" . | docker run --rm -i --privileged --add-host=host.docker.internal:host-gateway \
    -e GITHUB_RAW="http://host.docker.internal:$PORT" -e UNINSTALL_PATH="$KIND" "$IMAGE" \
    sh -c 'mkdir -p /src; tar -xf - -C /src; exec sh /src/install_uninstall_rig.sh'
