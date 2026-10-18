#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/ttycom.h>
#elif defined(__linux__)
#include <linux/tty.h>
#endif

int mynim_pty_open_master(char *slave_name, size_t capacity) {
  int fd = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (fd < 0) return -1;

#if defined(__APPLE__)
  if (ioctl(fd, 0x20007454, 0) < 0 || ioctl(fd, 0x20007452, 0) < 0 ||
      ioctl(fd, 0x40807453, slave_name) < 0) {
    int error = errno;
    close(fd);
    errno = error;
    return -1;
  }
  if (slave_name[capacity - 1] != '\0') {
    close(fd);
    errno = ENAMETOOLONG;
    return -1;
  }
#elif defined(__linux__)
  int unlock = 0;
  unsigned int number = 0;
  if (ioctl(fd, TIOCSPTLCK, &unlock) < 0 || ioctl(fd, TIOCGPTN, &number) < 0) {
    int error = errno;
    close(fd);
    errno = error;
    return -1;
  }
  int length = snprintf(slave_name, capacity, "/dev/pts/%u", number);
  if (length < 0 || (size_t)length >= capacity) {
    close(fd);
    errno = ENAMETOOLONG;
    return -1;
  }
#else
  close(fd);
  errno = ENOTSUP;
  return -1;
#endif
  return fd;
}

int mynim_pty_open_slave(const char *slave_name) {
  return open(slave_name, O_RDWR | O_NOCTTY);
}

int mynim_pty_set_size(int master, int cols, int rows, int width, int height) {
  struct winsize size;
  size.ws_col = (unsigned short)(cols < 0 ? 0 : cols > 65535 ? 65535 : cols);
  size.ws_row = (unsigned short)(rows < 0 ? 0 : rows > 65535 ? 65535 : rows);
  size.ws_xpixel = (unsigned short)(width < 0 ? 0 : width > 65535 ? 65535 : width);
  size.ws_ypixel = (unsigned short)(height < 0 ? 0 : height > 65535 ? 65535 : height);
  return ioctl(master, TIOCSWINSZ, &size);
}

static void child_fail(int error_fd) {
  int error = errno;
  (void)write(error_fd, &error, sizeof(error));
  _exit(127);
}

int mynim_pty_spawn(int master, int slave, const char *path,
                    char *const args[], char *const environment[],
                    const char *directory) {
  int errors[2];
  if (pipe(errors) < 0) {
    int error = errno;
    close(slave);
    errno = error;
    return -1;
  }
  if (fcntl(errors[1], F_SETFD, FD_CLOEXEC) < 0) {
    int error = errno;
    close(errors[0]);
    close(errors[1]);
    close(slave);
    errno = error;
    return -1;
  }
  pid_t pid = fork();
  if (pid < 0) {
    int error = errno;
    close(errors[0]);
    close(errors[1]);
    close(slave);
    errno = error;
    return -1;
  }
  if (pid == 0) {
    close(errors[0]);
    if (setsid() < 0) child_fail(errors[1]);
    if (ioctl(slave, TIOCSCTTY, 0) < 0) child_fail(errors[1]);
    if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 ||
        dup2(slave, STDERR_FILENO) < 0) child_fail(errors[1]);
    close(master);
    if (slave > STDERR_FILENO) close(slave);
    if (directory != NULL && directory[0] != '\0' && chdir(directory) < 0)
      child_fail(errors[1]);
    execve(path, args, environment);
    child_fail(errors[1]);
  }

  close(errors[1]);
  close(slave);
  int child_error = 0;
  size_t received = 0;
  while (received < sizeof(child_error)) {
    ssize_t count = read(errors[0], (char *)&child_error + received,
                         sizeof(child_error) - received);
    if (count == 0) break;
    if (count < 0) {
      if (errno == EINTR) continue;
      int error = errno;
      close(errors[0]);
      kill(-pid, SIGKILL);
      int status;
      while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
      errno = error;
      return -1;
    }
    received += (size_t)count;
  }
  close(errors[0]);
  if (received != 0) {
    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    errno = child_error;
    return -1;
  }
  return (int)pid;
}

int mynim_pty_exit_code(int status) {
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return -1;
}
