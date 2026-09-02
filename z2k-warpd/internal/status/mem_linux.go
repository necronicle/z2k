package status

import (
	"os"
	"strconv"
	"strings"
)

// RSSKB — резидентная память текущего процесса в КБ из /proc/self/statm;
// 0, если прочитать не удалось. Страница считается 4 КБ: у всех наших арок
// она такая, а os.Getpagesize() на MIPS с softfloat возвращает то же.
func RSSKB() int {
	b, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b))
	if len(f) < 2 {
		return 0
	}
	pages, err := strconv.Atoi(f[1])
	if err != nil {
		return 0
	}
	return pages * os.Getpagesize() / 1024
}
