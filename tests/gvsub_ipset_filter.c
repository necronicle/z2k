// Проверяем настоящий фильтр профиля; очередь и отправка пакетов не нужны.
#include "ipset.h"
// Включаем единицу трансляции для доступа к настоящему static dp_match.
#include "desync.c"
#include <assert.h>
#include <unistd.h>

struct params_s params;
// В стенде отключён только вывод журнала, логика фильтра взята из движка.
int DLOG(const char *format, ...) { return 0; }
int DLOG_ERR(const char *format, ...) { return 0; }
int DLOG_CONDUP(const char *format, ...) { return 0; }
int DLOG_PERROR(const char *s) { return 0; }

static void check(struct desync_profile *dp, bool expected)
{
    struct in_addr a4;
    struct in6_addr a6;
    assert(inet_pton(AF_INET, "1.1.1.1", &a4) == 1);
    assert(inet_pton(AF_INET6, "2606:4700::1111", &a6) == 1);
    struct dp_match_data m = {.l3proto=IPPROTO_TCP, .port=443, .ip=&a4};
    assert(dp_match(dp, &m) == expected);
    m.ip = NULL;
    m.ip6 = &a6;
    assert(dp_match(dp, &m) == expected);
    assert(IpsetCheck(dp, &a4, NULL, NULL, NULL) == expected);
    assert(IpsetCheck(dp, NULL, &a6, NULL, NULL) == expected);
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    struct desync_profile dp = {0};
    dp.filter_ipv4 = dp.filter_ipv6 = true;
    struct ipset_file *file = RegisterIpset(&dp, false, argv[1]);
    assert(file);
    assert(LoadAllIpsets());
    assert(!IPSET_EMPTY(&file->ipset));
    assert(file->ipset.ips4 && file->ipset.ips6);
    check(&dp, false);

    // Пересоздаём через rename, как оба писателя; размер тоже меняется.
    char tmp[PATH_MAX];
    assert(snprintf(tmp, sizeof(tmp), "%s.new", argv[1]) < sizeof(tmp));
    FILE *f = fopen(tmp, "w");
    assert(f);
    fputs("0.0.0.0/32\n::/128\n1.1.1.1\n2606:4700::1111\n", f);
    assert(!fclose(f));
    assert(!rename(tmp, argv[1]));
    check(&dp, true);

    // Отсутствующий файл сохраняет прежний набор в текущем форке.
    assert(!unlink(argv[1]));
    check(&dp, true);
    struct desync_profile missing = {0};
    assert(!RegisterIpset(&missing, false, argv[1]));
    struct in_addr unrelated;
    assert(inet_pton(AF_INET, "9.9.9.9", &unrelated) == 1);
    assert(!IpsetCheck(&dp, &unrelated, NULL, NULL, NULL));

    // Пересозданный безопасный файл снова выключает профиль для этих адресов.
    f = fopen(tmp, "w");
    assert(f);
    fputs("0.0.0.0/32\n::/128\n", f);
    assert(!fclose(f) && !rename(tmp, argv[1]));
    check(&dp, false);

    // Контроль воспроизведения: пустой файл действительно пропускает всех.
    f = fopen(argv[1], "w");
    assert(f && !fclose(f));
    check(&dp, true);
    assert(IPSET_EMPTY(&file->ipset));
    assert(IpsetCheck(&dp, &unrelated, NULL, NULL, NULL));
    puts("PASS: настоящие dp_match (TCP/443) и IpsetCheck, IPv4/IPv6, reload и воспроизведение пустого списка");
    return 0;
}
