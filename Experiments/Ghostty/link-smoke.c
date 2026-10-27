#include <stdio.h>
#include "ghostty.h"

// Link the embedding API without initializing it or spawning a terminal.
int main(void) {
    ghostty_info_s info = ghostty_info();
    printf("Ghostty %.*s\n", (int)info.version_len, info.version);
    return info.version_len == 0;
}
