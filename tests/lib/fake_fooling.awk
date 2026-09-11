# fake_fooling.awk — печатает фейки, у которых FRAGILE единственный фулинг.
# Вызов: awk -v FRAGILE=tcp_ts -f fake_fooling.awk <файл>
# FRAGILE — tcp_ts или badsum: оба срабатывают не всегда (см. шапку теста).
{
  n = split($0, t, " ")
  for (i = 1; i <= n; i++) {
    tok = t[i]
    if (tok !~ /lua-desync=(fake|fakedsplit|fakeddisorder|hostfakesplit|syndata)/) continue
    if (index(tok, FRAGILE) == 0) continue
    other = 0
    if (FRAGILE != "badsum"  && tok ~ /badsum/)       other = 1
    if (FRAGILE != "tcp_ts"  && tok ~ /tcp_ts=/)      other = 1
    if (tok ~ /badseq/)        other = 1
    if (tok ~ /tcp_md5/)       other = 1
    if (tok ~ /tcp_seq=/)      other = 1
    if (tok ~ /tcp_ack=/)      other = 1
    if (tok ~ /ip_ttl=/)       other = 1
    if (tok ~ /ip_autottl=/)   other = 1
    if (tok ~ /ip6_ttl=/)      other = 1
    if (tok ~ /ip6_autottl=/)  other = 1
    if (other == 0) print FILENAME ":" NR ": " substr(tok, 1, 120)
  }
}
