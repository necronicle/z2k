// z2k-warpd — собственный WARP-движок z2k для Keenetic.
package main

import (
	"fmt"
	"os"
)

var version = "dev"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println("z2k-warpd", version)
		return
	}
	fmt.Fprintln(os.Stderr, "usage: z2k-warpd version")
	os.Exit(2)
}
