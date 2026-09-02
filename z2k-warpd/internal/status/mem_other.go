//go:build !linux

package status

// RSSKB вне Linux не измеряется: панели там нет, а тесты живут на macOS.
func RSSKB() int { return 0 }
