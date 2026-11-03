#ifndef LINK_HELPER_PTY_H
#define LINK_HELPER_PTY_H

#include <sys/types.h>

/// Starts `path` with `argv`/`envp` on the slave side of a new pseudo-terminal sized
/// `cols` x `rows`, as a session leader with that terminal as its controlling tty, so it
/// gets SIGWINCH when the master is resized. Returns the child's pid and stores the master
/// fd (close-on-exec) in `master`; returns -1 with errno set on failure.
pid_t wl_pty_spawn(const char *path, char *const argv[], char *const envp[],
                   unsigned short cols, unsigned short rows, int *master);

/// TIOCSWINSZ on the master; 0 on success, -1 with errno set.
int wl_pty_resize(int master, unsigned short cols, unsigned short rows);

#endif
