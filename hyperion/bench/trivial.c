/* trivial.c --- the load generator's own ceiling (#413).
 *
 *     cc -O2 -o /tmp/trivial hyperion/bench/trivial.c && /tmp/trivial 8098
 *
 * A server that does as little as a server can: one thread, poll(), and the same response
 * to every request -- 200, "ok", keep-alive. run.sh drives it with the load generator before
 * any Hyperion backend, and the rate it reaches is the most the generator can measure on this
 * machine. A backend whose rate comes close to it is reported as limited by the generator,
 * not given a number.
 *
 * Not a web server: it answers once per "\r\n\r\n" it reads and never reads a body. That is
 * exactly what GET without a body sends, and all it needs to do.
 */
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_CONNS 4096

static const char RESPONSE[] =
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n"
    "Connection: keep-alive\r\n\r\nok"; /* the header an HTTP/1.0 keep-alive client (ab -k) waits for */

int main(int argc, char **argv) {
  int port = argc > 1 ? atoi(argv[1]) : 8098;
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(listener, 1024) != 0) {
    perror("trivial: bind/listen");
    return 1;
  }
  printf("trivial: listening on 127.0.0.1:%d\n", port);
  fflush(stdout);

  static struct pollfd fds[MAX_CONNS + 1];
  static int matched[MAX_CONNS + 1]; /* how much of "\r\n\r\n" each connection has seen */
  int n = 1;
  fds[0].fd = listener;
  fds[0].events = POLLIN;
  char buf[16384];

  for (;;) {
    if (poll(fds, n, -1) < 0 && errno != EINTR) { perror("trivial: poll"); return 1; }
    if ((fds[0].revents & POLLIN) && n <= MAX_CONNS) {
      int c = accept(listener, NULL, NULL);
      if (c >= 0) {
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        fds[n].fd = c; fds[n].events = POLLIN; matched[n] = 0; n++;
      }
    }
    for (int i = 1; i < n; i++) {
      if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
      ssize_t got = read(fds[i].fd, buf, sizeof buf);
      if (got <= 0) {
        close(fds[i].fd);
        fds[i] = fds[n - 1]; matched[i] = matched[n - 1]; n--; i--;
        continue;
      }
      static const char END[] = "\r\n\r\n";
      for (ssize_t k = 0; k < got; k++) {
        matched[i] = (buf[k] == END[matched[i]]) ? matched[i] + 1 : (buf[k] == '\r' ? 1 : 0);
        if (matched[i] == 4) {
          matched[i] = 0;
          if (write(fds[i].fd, RESPONSE, sizeof RESPONSE - 1) < 0) break;
        }
      }
    }
  }
}
