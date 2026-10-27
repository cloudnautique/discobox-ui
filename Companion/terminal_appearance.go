package main

import (
	"fmt"
	"io"
)

// Configure only the local emulator through its output stream. These OSCs are
// never written to the remote exec's input. Applications retain control of
// their own explicit true-color output.
func writeTerminalAppearance(output io.Writer) {
	fmt.Fprint(output, "\x1b]10;#c0caf5\x1b\\\x1b]11;#1a1b26\x1b\\\x1b]12;#c0caf5\x1b\\")
	palette := []string{
		"15161e", "f7768e", "9ece6a", "e0af68", "7aa2f7", "bb9af7", "7dcfff", "a9b1d6",
		"565f89", "ff899d", "b9f27c", "f0c987", "9ab8ff", "d0b2ff", "a4e4ff", "c0caf5",
	}
	for index, color := range palette {
		fmt.Fprintf(output, "\x1b]4;%d;#%s\x1b\\", index, color)
	}
}
