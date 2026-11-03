#include "LinkHelperPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

pid_t wl_pty_spawn(const char *path, char *const argv[], char *const envp[],
                   unsigned short cols, unsigned short rows, int *master) {
    struct winsize size = {.ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0};
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, &size);
    if (pid < 0) return -1;
    if (pid == 0) {
        // Only async-signal-safe calls between fork and exec: the helper is multithreaded.
        int max = (int)sysconf(_SC_OPEN_MAX);
        for (int i = 3; i < max; i++) close(i);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        signal(SIGPIPE, SIG_DFL);
        execve(path, argv, envp);
        _exit(127);
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    *master = fd;
    return pid;
}

int wl_pty_resize(int master, unsigned short cols, unsigned short rows) {
    struct winsize size = {.ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0};
    return ioctl(master, TIOCSWINSZ, &size);
}
