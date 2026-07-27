#!/bin/sh
# tests/test_tg_tls_roots.sh
#
# The TG tunnel client is Go, and Go verifies TLS against the SYSTEM trust store. On a
# Keenetic that store is whatever the firmware happens to ship plus whatever opkg's
# ca-certificates left behind, and on some routers neither carries an ISRG root. The
# tunnel then fails forever with
#     tls: failed to verify certificate: x509: certificate signed by unknown authority
# against the relay, whose Let's Encrypt chain is
#     213.176.74.63.nip.io -> YE1 -> ISRG Root YE -> ISRG Root X2 -> ISRG Root X1
#
# The standing advice was `opkg update && opkg install ca-certificates` plus an
# SSL_CERT_FILE export. It stopped working, and it was always fragile: it needs opkg to
# be healthy, which on exactly these routers it is not.
#
# So z2k carries the anchors. This ADDS two well-known public roots — it does not disable
# verification, and it does not remove the firmware's own store (SSL_CERT_DIR is exported
# alongside; Go merges file and directory sources).
#
# Verified by hand when the bundle was generated, and NOT re-checkable offline:
#   [x] both fingerprints match letsencrypt.org
#         X1 96BCEC06264976F37460779ACF28C5A7CFE8A3C0AAE11A8FFCEE05C0BDDF08C6
#         X2 69729B8E15A86EFC177A57AFB7171DFC64ADD28C2FCA8CF1507E34453CCB1470
#   [x] `openssl verify -CAfile <this bundle> -untrusted <relay intermediates> leaf` = OK,
#       i.e. these two roots ALONE validate the live relay certificate
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
PEM="$HERE/files/etc/z2k-roots.pem"
INIT="$HERE/files/init.d/S98tg-tunnel"
INSTALL="$HERE/lib/install.sh"
AU="$HERE/lib/auto_update.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tgtls.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

# --- the bundle itself -------------------------------------------------------
[ -f "$PEM" ] && ok "the trust bundle is shipped" \
              || { no "the trust bundle is shipped" "a file" "missing"; printf '\nPASSED: %d\nFAILED: %d\n' "$PASS" "$FAIL"; exit 1; }

n=$(grep -c 'BEGIN CERTIFICATE' "$PEM")
[ "$n" = 2 ] && ok "it carries exactly two certificates ($n)" \
             || no "it carries exactly two certificates" 2 "$n"

# Fingerprints, not names: a bundle can be swapped for a same-named forgery, and the
# whole point of shipping trust anchors is that WE decide which bytes are trusted.
if command -v openssl >/dev/null 2>&1; then
    awk '/BEGIN CERTIFICATE/{n++} n{print > ("'"$TMP"'/c" n ".pem")}' "$PEM"
    got=""
    for f in "$TMP"/c*.pem; do
        [ -f "$f" ] || continue
        fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ': ')
        [ -n "$fp" ] && got="$got $fp"
    done
    case "$got" in
        *96BCEC06264976F37460779ACF28C5A7CFE8A3C0AAE11A8FFCEE05C0BDDF08C6*)
            ok "ISRG Root X1 is present, by fingerprint" ;;
        *)  no "ISRG Root X1 is present, by fingerprint" "the X1 fingerprint" "$got" ;;
    esac
    case "$got" in
        *69729B8E15A86EFC177A57AFB7171DFC64ADD28C2FCA8CF1507E34453CCB1470*)
            ok "ISRG Root X2 is present, by fingerprint" ;;
        *)  no "ISRG Root X2 is present, by fingerprint" "the X2 fingerprint" "$got" ;;
    esac
    # An expired anchor is worse than none: it fails closed, silently, years later.
    for f in "$TMP"/c*.pem; do
        [ -f "$f" ] || continue
        s=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
        if openssl x509 -in "$f" -noout -checkend 31536000 >/dev/null 2>&1; then
            ok "$s is valid for at least another year"
        else
            no "$s is valid for at least another year" "not expiring" "expires within a year"
        fi
        # And it must actually be a CA, or it can anchor nothing.
        if openssl x509 -in "$f" -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then
            ok "$s is a CA certificate"
        else
            no "$s is a CA certificate" "CA:TRUE" "not a CA"
        fi
    done
else
    skip "certificate identity and expiry" "no openssl on this host"
fi

# --- the init exports it, and only when it exists ----------------------------
grep -q 'SSL_CERT_FILE=/opt/zapret2/etc/z2k-roots.pem' "$INIT" \
    && ok "the init exports SSL_CERT_FILE at our bundle" \
    || no "the init exports SSL_CERT_FILE at our bundle" "the export" "absent"
grep -q 'SSL_CERT_DIR=/etc/ssl/certs' "$INIT" \
    && ok "the init also keeps the firmware store via SSL_CERT_DIR" \
    || no "the init also keeps the firmware store via SSL_CERT_DIR" "the export" "absent"

# Behavioural: a MISSING bundle must leave the environment untouched. Exporting
# SSL_CERT_FILE at a nonexistent path empties Go's pool and would break TLS on a router
# where it currently works — turning a fix into an outage.
line=$(grep -m1 'SSL_CERT_FILE=' "$INIT")
out=$(sh -c "$(printf '%s\n' "$line" | sed "s#/opt/zapret2/etc/z2k-roots.pem#$TMP/absent.pem#g"); echo \"v=\${SSL_CERT_FILE-unset}\"")
case "$out" in
    *"v=unset"*) ok "a missing bundle leaves SSL_CERT_FILE unset" ;;
    *)           no "a missing bundle leaves SSL_CERT_FILE unset" "unset" "$out" ;;
esac
: > "$TMP/present.pem"
out=$(sh -c "$(printf '%s\n' "$line" | sed "s#/opt/zapret2/etc/z2k-roots.pem#$TMP/present.pem#g"); echo \"v=\${SSL_CERT_FILE-unset}\"")
case "$out" in
    *"$TMP/present.pem"*) ok "a present bundle IS exported" ;;
    *)                    no "a present bundle IS exported" "$TMP/present.pem" "$out" ;;
esac
dline=$(grep -m1 'SSL_CERT_DIR=' "$INIT")
out=$(sh -c "$(printf '%s\n' "$dline" | sed "s#/etc/ssl/certs#$TMP/nodir#g"); echo \"v=\${SSL_CERT_DIR-unset}\"")
case "$out" in
    *"v=unset"*) ok "a missing firmware dir leaves SSL_CERT_DIR unset" ;;
    *)           no "a missing firmware dir leaves SSL_CERT_DIR unset" "unset" "$out" ;;
esac

# The export has to happen BEFORE the daemon is started, or it does not apply to it.
exp_ln=$(grep -n 'SSL_CERT_FILE=' "$INIT" | head -1 | cut -d: -f1)
run_ln=$(grep -nE 'start-stop-daemon|tg-mtproxy-client' "$INIT" | head -1 | cut -d: -f1)
if [ -n "$exp_ln" ] && [ -n "$run_ln" ] && [ "$exp_ln" -lt "$run_ln" ]; then
    ok "the export precedes the daemon start (line $exp_ln < $run_ln)"
else
    no "the export precedes the daemon start" "export first" "$exp_ln/$run_ln"
fi

# --- delivery ----------------------------------------------------------------
grep -q 'files/etc/z2k-roots.pem' "$INSTALL" \
    && ok "install.sh deploys the bundle" \
    || no "install.sh deploys the bundle" "a deploy line" "absent"
grep -q 'mkdir -p "${ZAPRET2_DIR}/etc"' "$INSTALL" \
    && ok "install.sh creates the directory first" \
    || no "install.sh creates the directory first" "mkdir" "absent"
# Patch-deliverable BY THE UPDATER ALREADY ON THE ROUTER. This is why the bundle lives
# under files/etc/ and not a new directory: delivery is performed by the INSTALLED
# lib/auto_update.sh, which knows nothing about paths added in the same release. A new
# mapping would have been skipped and the fix would have reached nobody until the update
# after next.
p=$(sh -c "Z2K_AU_SOURCE_ONLY=1 . '$AU' 2>/dev/null; au_install_paths files/etc/z2k-roots.pem")
[ "$p" = "/opt/zapret2/etc/z2k-roots.pem" ] \
    && ok "the bundle is patch-deliverable ($p)" \
    || no "the bundle is patch-deliverable" "/opt/zapret2/etc/z2k-roots.pem" "$p"

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
