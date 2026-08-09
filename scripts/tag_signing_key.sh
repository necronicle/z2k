#!/bin/sh
# scripts/tag_signing_key.sh — выдать тот же релизный ключ в формате, который
# понимает git, и напечатать путь к нему.
#
# ЗАЧЕМ ЭТО ВООБЩЕ СУЩЕСТВУЕТ. Тег релиза обязан быть подписан, а подписывать
# теги git умеет либо GPG, либо SSH-ключом. Наш релизный ключ лежит в PKCS8-PEM
# (его пишет и читает openssl), и ssh-keygen такой файл не открывает вовсе:
# «invalid format».
#
# Вариант «завести второй ключ для тегов» отвергнут: второй секрет — это второе
# место, где его можно потерять, и вторая пара «а этот у нас какой». Ключ должен
# остаться ОДИН.
#
# Поэтому здесь тот же самый ключ переупаковывается в формат OpenSSH. Это не
# новый ключ и не производный: seed берётся из существующего файла как есть,
# публичная часть совпадает с files/etc/z2k-update-pub.pem байт в байт (сверяется
# ниже). Результат кладётся во временный файл с правами 600 и удаляется вызывающим.
#
# Использование:
#   KEY=$(sh scripts/tag_signing_key.sh) || exit 1
#   git -c gpg.format=ssh -c user.signingkey="$KEY" tag -s ...
#   rm -f "$KEY" "$KEY.pub"
#
# POSIX sh.

set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="${Z2K_SIGNING_KEY:-$HOME/.z2k-signing/z2k-update.key}"
PUB="$ROOT/files/etc/z2k-update-pub.pem"

die() { printf 'tag_signing_key: %s\n' "$1" >&2; exit 1; }

[ -f "$SRC" ] || die "нет ключа подписи ($SRC)"
command -v python3 >/dev/null 2>&1 || die "нужен python3"

_find_openssl() {
    for _c in /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl \
              /usr/local/bin/openssl "$(command -v openssl 2>/dev/null)"; do
        [ -x "$_c" ] || continue
        "$_c" genpkey -algorithm ed25519 -out /dev/null >/dev/null 2>&1 || continue
        printf '%s' "$_c"; return 0
    done
    return 1
}
OSSL=$(_find_openssl) || die "не нашёл OpenSSL с поддержкой Ed25519 (у macOS системный — LibreSSL)"

OUT=$(mktemp -t z2k-tagkey) || die "mktemp"
chmod 600 "$OUT"

OSSL="$OSSL" SRC="$SRC" OUT="$OUT" python3 - <<'PY' || die "переупаковка ключа не удалась"
import base64, os, struct, subprocess, sys

ossl, src, out = os.environ["OSSL"], os.environ["SRC"], os.environ["OUT"]
text = subprocess.run([ossl, "pkey", "-in", src, "-noout", "-text"],
                      capture_output=True, text=True, check=True).stdout

def grab(label):
    # openssl печатает байты как «xx:xx:...» с переносами; берём до первой
    # строки, которая перестала быть шестнадцатеричной.
    hx = ""
    for line in text.split(label)[1].splitlines()[1:]:
        line = line.strip()
        if not line or ":" not in line or not all(c in "0123456789abcdef:" for c in line):
            break
        hx += line.replace(":", "")
    return bytes.fromhex(hx)

seed, pub = grab("priv:"), grab("pub:")
if len(seed) != 32 or len(pub) != 32:
    sys.exit("неожиданная длина ключа: seed=%d pub=%d" % (len(seed), len(pub)))

def s(b): return struct.pack(">I", len(b)) + b

pubblob = s(b"ssh-ed25519") + s(pub)
# Два одинаковых «checkint» — так формат подтверждает, что расшифровка удалась;
# у незашифрованного ключа они просто совпадают.
priv = struct.pack(">II", 0x7a326b00, 0x7a326b00) + s(b"ssh-ed25519") + s(pub) \
       + s(seed + pub) + s(b"z2k-release")
pad = 0
while len(priv) % 8:
    pad += 1
    priv += bytes([pad])
blob = b"openssh-key-v1\0" + s(b"none") + s(b"none") + s(b"") + struct.pack(">I", 1) \
       + s(pubblob) + s(priv)
b64 = base64.b64encode(blob).decode()
body = "\n".join(b64[i:i + 70] for i in range(0, len(b64), 70))
with open(out, "w") as fh:
    fh.write("-----BEGIN OPENSSH PRIVATE KEY-----\n" + body + "\n-----END OPENSSH PRIVATE KEY-----\n")
PY

# Публичная часть ОБЯЗАНА совпасть с опубликованным ключом. Разойдись она —
# теги подписывались бы не тем, чем проверяется манифест, и это заметили бы
# только когда проверка перестала бы сходиться.
ssh-keygen -y -f "$OUT" > "${OUT}.pub" 2>/dev/null || { rm -f "$OUT"; die "полученный ключ не читается ssh-keygen"; }
_a=$(awk '{print $2}' < "${OUT}.pub" | base64 -d 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n')
_b=$("$OSSL" pkey -pubin -in "$PUB" -noout -text 2>/dev/null \
     | sed -n '/pub:/,$p' | tail -n +2 | tr -d ' :\n')
if [ "$_a" != "$_b" ]; then
    rm -f "$OUT" "${OUT}.pub"
    die "переупакованный ключ не совпал с $PUB — подписывать теги им нельзя"
fi

printf '%s\n' "$OUT"
