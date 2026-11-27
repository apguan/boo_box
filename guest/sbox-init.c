#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/vm_sockets.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

/*
 * sbox-init: Minimal PID 1 + AF_VSOCK multi-PTY daemon for boo_box microVMs.
 *
 * Protocol on AF_VSOCK port 5123 (one connection per terminal pane / split):
 *   1. Host sends 1-line handshake terminated by '\n':
 *        "COLS=<u16> ROWS=<u16> TERM=<str> CWD=<str>\n"
 *   2. Bidirectional framed binary stream:
 *        [type: u8][len: u32 big-endian][payload: len bytes]
 *      Types:
 *        0x01 DATA   - raw PTY bytes (host -> guest stdin, guest stdout -> host)
 *        0x02 RESIZE - 4 bytes: [rows: u16 BE][cols: u16 BE] (host -> guest)
 *        0x03 EXIT   - 1 byte:  [exit_code: u8] (guest -> host)
 */
#define PTY_VSOCK_PORT 5123
#define FWD_VSOCK_PORT 5124
#define MSG_DATA   0x01
#define MSG_RESIZE 0x02
#define MSG_EXIT   0x03
static ssize_t write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, p + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return (ssize_t)off;
}

static ssize_t read_all(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, p + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return 0;
        off += (size_t)n;
    }
    return (ssize_t)off;
}

static int send_frame(int fd, uint8_t type, const void *payload, uint32_t len) {
    uint8_t hdr[5];
    hdr[0] = type;
    uint32_t net_len = htonl(len);
    memcpy(hdr + 1, &net_len, 4);
    if (write_all(fd, hdr, 5) < 0) return -1;
    if (len > 0 && write_all(fd, payload, len) < 0) return -1;
    return 0;
}

static int read_line(int fd, char *buf, size_t cap) {
    size_t pos = 0;
    while (pos + 1 < cap) {
        char c = 0;
        ssize_t n = read(fd, &c, 1);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) break;
        if (c == '\n') break;
        buf[pos++] = c;
    }
    buf[pos] = '\0';
    return (int)pos;
}

static void parse_handshake(const char *line, uint16_t *cols, uint16_t *rows,
                            char *term, size_t term_cap, char *cwd, size_t cwd_cap) {
    *cols = 80;
    *rows = 24;
    snprintf(term, term_cap, "xterm-ghostty");
    snprintf(cwd, cwd_cap, "/root");

    char copy[1024];
    snprintf(copy, sizeof(copy), "%s", line);

    char *saveptr = NULL;
    for (char *tok = strtok_r(copy, " ", &saveptr); tok != NULL; tok = strtok_r(NULL, " ", &saveptr)) {
        if (strncmp(tok, "COLS=", 5) == 0) {
            int v = atoi(tok + 5);
            if (v > 0 && v < 1000) *cols = (uint16_t)v;
        } else if (strncmp(tok, "ROWS=", 5) == 0) {
            int v = atoi(tok + 5);
            if (v > 0 && v < 1000) *rows = (uint16_t)v;
        } else if (strncmp(tok, "TERM=", 5) == 0 && tok[5] != '\0') {
            snprintf(term, term_cap, "%s", tok + 5);
        } else if (strncmp(tok, "CWD=", 4) == 0 && tok[4] != '\0') {
            snprintf(cwd, cwd_cap, "%s", tok + 4);
        }
    }
}

static void handle_pty_session(int vsock_fd) {
    char line[1024];
    if (read_line(vsock_fd, line, sizeof(line)) < 0) {
        close(vsock_fd);
        return;
    }

    uint16_t cols = 80, rows = 24;
    char term[128], cwd[512];
    parse_handshake(line, &cols, &rows, term, sizeof(term), cwd, sizeof(cwd));

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;

    int master_fd = -1;
    pid_t child = forkpty(&master_fd, NULL, NULL, &ws);
    if (child < 0) {
        close(vsock_fd);
        return;
    }

    if (child == 0) {
        /* Inside child shell process */
        close(vsock_fd);
        signal(SIGCHLD, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);

        setenv("TERM", term, 1);
        setenv("HOME", "/root", 1);
        setenv("USER", "root", 1);
        setenv("LOGNAME", "root", 1);
        setenv("LANG", "C.UTF-8", 1);
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
        setenv("GHOSTTY_RESOURCES_DIR", "/etc/ghostty", 1);
        setenv("BOOBOX_SANDBOX", "1", 1);

        if (chdir(cwd) != 0) {
            if (chdir("/workspace") != 0) {
                (void)chdir("/root");
            }
        }

        if (access("/bin/zsh", X_OK) == 0) {
            setenv("SHELL", "/bin/zsh", 1);
            char *argv[] = { "-zsh", NULL };
            execv("/bin/zsh", argv);
        } else if (access("/bin/bash", X_OK) == 0) {
            setenv("SHELL", "/bin/bash", 1);
            char *argv[] = { "-bash", NULL };
            execv("/bin/bash", argv);
        }
        setenv("SHELL", "/bin/sh", 1);
        char *argv[] = { "-sh", NULL };
        execv("/bin/sh", argv);
        _exit(127);
    }

    /* Relay loop between vsock_fd and master_fd */
    struct pollfd pfds[2];
    pfds[0].fd = master_fd;
    pfds[0].events = POLLIN;
    pfds[1].fd = vsock_fd;
    pfds[1].events = POLLIN;

    uint8_t buf[16384];
    int running = 1;

    while (running) {
        int rc = poll(pfds, 2, 250);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* PTY -> host */
        if (pfds[0].revents & POLLIN) {
            ssize_t n = read(master_fd, buf, sizeof(buf));
            if (n > 0) {
                if (send_frame(vsock_fd, MSG_DATA, buf, (uint32_t)n) < 0) {
                    running = 0;
                    break;
                }
            } else {
                running = 0;
                break;
            }
        }
        if (pfds[0].revents & (POLLHUP | POLLERR)) {
            /* Drain any remaining bytes from PTY before exit */
            ssize_t n;
            while ((n = read(master_fd, buf, sizeof(buf))) > 0) {
                if (send_frame(vsock_fd, MSG_DATA, buf, (uint32_t)n) < 0) break;
            }
            running = 0;
            break;
        }

        /* Host -> PTY */
        if (pfds[1].revents & POLLIN) {
            uint8_t hdr[5];
            ssize_t hn = read_all(vsock_fd, hdr, 5);
            if (hn <= 0) {
                running = 0;
                break;
            }
            uint8_t type = hdr[0];
            uint32_t net_len = 0;
            memcpy(&net_len, hdr + 1, 4);
            uint32_t plen = ntohl(net_len);

            if (type == MSG_DATA) {
                uint32_t rem = plen;
                while (rem > 0) {
                    uint32_t chunk = rem > sizeof(buf) ? (uint32_t)sizeof(buf) : rem;
                    if (read_all(vsock_fd, buf, chunk) <= 0) {
                        running = 0;
                        break;
                    }
                    if (write_all(master_fd, buf, chunk) < 0) {
                        running = 0;
                        break;
                    }
                    rem -= chunk;
                }
            } else if (type == MSG_RESIZE && plen == 4) {
                uint8_t rbuf[4];
                if (read_all(vsock_fd, rbuf, 4) <= 0) {
                    running = 0;
                    break;
                }
                uint16_t n_rows = 0, n_cols = 0;
                memcpy(&n_rows, rbuf, 2);
                memcpy(&n_cols, rbuf + 2, 2);
                struct winsize nws;
                memset(&nws, 0, sizeof(nws));
                nws.ws_row = ntohs(n_rows);
                nws.ws_col = ntohs(n_cols);
                ioctl(master_fd, TIOCSWINSZ, &nws);
                kill(-child, SIGWINCH);
            } else {
                /* Skip unknown frame payload */
                uint32_t rem = plen;
                while (rem > 0) {
                    uint32_t chunk = rem > sizeof(buf) ? (uint32_t)sizeof(buf) : rem;
                    if (read_all(vsock_fd, buf, chunk) <= 0) {
                        running = 0;
                        break;
                    }
                    rem -= chunk;
                }
            }
        }
        if (pfds[1].revents & (POLLHUP | POLLERR)) {
            running = 0;
            break;
        }
    }

    int status = 0;
    if (waitpid(child, &status, WNOHANG) == 0) {
        kill(-child, SIGHUP);
        usleep(50000);
        if (waitpid(child, &status, WNOHANG) == 0) {
            kill(-child, SIGKILL);
            waitpid(child, &status, 0);
        }
    }

    uint8_t exit_code = WIFEXITED(status) ? (uint8_t)WEXITSTATUS(status) : 1;
    (void)send_frame(vsock_fd, MSG_EXIT, &exit_code, 1);

    close(master_fd);
    close(vsock_fd);
}

/* ---------- vsock:5124 TCP Port Forwarder & Live Listening-Port Discovery ---------- */

static int cmp_u16(const void *a, const void *b) {
    uint16_t pa = *(const uint16_t *)a;
    uint16_t pb = *(const uint16_t *)b;
    return (pa > pb) - (pa < pb);
}

static void scan_proc_net_tcp(const char *path, uint16_t *ports, size_t *count, size_t max_ports) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[512];
    /* Skip header */
    if (!fgets(line, sizeof(line), f)) {
        fclose(f);
        return;
    }
    while (fgets(line, sizeof(line), f)) {
        unsigned int sl = 0;
        char local_addr[128] = {0};
        char rem_addr[128] = {0};
        unsigned int state = 0;
        if (sscanf(line, " %u: %127s %127s %x", &sl, local_addr, rem_addr, &state) < 4) {
            continue;
        }
        /* 0x0A == TCP_LISTEN */
        if (state != 0x0A) continue;
        char *colon = strrchr(local_addr, ':');
        if (!colon) continue;
        unsigned int port = 0;
        if (sscanf(colon + 1, "%x", &port) != 1 || port == 0 || port > 65535) continue;

        int exists = 0;
        for (size_t i = 0; i < *count; i++) {
            if (ports[i] == (uint16_t)port) {
                exists = 1;
                break;
            }
        }
        if (!exists && *count < max_ports) {
            ports[(*count)++] = (uint16_t)port;
        }
    }
    fclose(f);
}

static int connect_guest_tcp(uint16_t port) {
    /* Try IPv4 loopback first */
    int fd4 = socket(AF_INET, SOCK_STREAM, 0);
    if (fd4 >= 0) {
        struct sockaddr_in sa4;
        memset(&sa4, 0, sizeof(sa4));
        sa4.sin_family = AF_INET;
        sa4.sin_port = htons(port);
        sa4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd4, (struct sockaddr *)&sa4, sizeof(sa4)) == 0) {
            return fd4;
        }
        close(fd4);
    }
    /* Fallback to IPv6 loopback (for Node/Vite/Bun servers bound only to ::1) */
    int fd6 = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd6 >= 0) {
        struct sockaddr_in6 sa6;
        memset(&sa6, 0, sizeof(sa6));
        sa6.sin6_family = AF_INET6;
        sa6.sin6_port = htons(port);
        sa6.sin6_addr = in6addr_loopback;
        if (connect(fd6, (struct sockaddr *)&sa6, sizeof(sa6)) == 0) {
            return fd6;
        }
        close(fd6);
    }
    return -1;
}

static void handle_fwd_session(int vsock_fd) {
    char line[256];
    if (read_line(vsock_fd, line, sizeof(line)) <= 0) {
        close(vsock_fd);
        return;
    }

    if (strcmp(line, "LIST") == 0) {
        uint16_t ports[64];
        size_t count = 0;
        scan_proc_net_tcp("/proc/net/tcp", ports, &count, 64);
        scan_proc_net_tcp("/proc/net/tcp6", ports, &count, 64);
        if (count > 1) {
            qsort(ports, count, sizeof(uint16_t), cmp_u16);
        }
        char resp[1024];
        int pos = snprintf(resp, sizeof(resp), "PORTS");
        for (size_t i = 0; i < count && pos + 8 < (int)sizeof(resp); i++) {
            pos += snprintf(resp + pos, sizeof(resp) - (size_t)pos, " %u", (unsigned)ports[i]);
        }
        if (pos + 2 < (int)sizeof(resp)) {
            resp[pos++] = '\n';
            resp[pos] = '\0';
        }
        (void)write_all(vsock_fd, resp, (size_t)pos);
        close(vsock_fd);
        return;
    }

    if (strncmp(line, "TCP ", 4) != 0) {
        (void)write_all(vsock_fd, "ERR\n", 4);
        close(vsock_fd);
        return;
    }

    int port = atoi(line + 4);
    if (port < 1 || port > 65535) {
        (void)write_all(vsock_fd, "ERR\n", 4);
        close(vsock_fd);
        return;
    }

    int tcp_fd = connect_guest_tcp((uint16_t)port);
    if (tcp_fd < 0) {
        (void)write_all(vsock_fd, "ERR\n", 4);
        close(vsock_fd);
        return;
    }

    if (write_all(vsock_fd, "OK\n", 3) < 0) {
        close(tcp_fd);
        close(vsock_fd);
        return;
    }

    /* Full-duplex TCP <-> vsock splice with clean half-close (SHUT_WR) propagation */
    uint8_t buf[32768];
    int vsock_eof = 0;
    int tcp_eof = 0;
    while (!vsock_eof || !tcp_eof) {
        struct pollfd pfds[2];
        pfds[0].fd = vsock_eof ? -1 : vsock_fd;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        pfds[1].fd = tcp_eof ? -1 : tcp_fd;
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;

        int rc = poll(pfds, 2, 30000);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (rc == 0) continue;

        if (!vsock_eof && (pfds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t n = read(vsock_fd, buf, sizeof(buf));
            if (n > 0) {
                if (write_all(tcp_fd, buf, (size_t)n) < 0) break;
            } else {
                vsock_eof = 1;
                (void)shutdown(tcp_fd, SHUT_WR);
            }
        }

        if (!tcp_eof && (pfds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t n = read(tcp_fd, buf, sizeof(buf));
            if (n > 0) {
                if (write_all(vsock_fd, buf, (size_t)n) < 0) break;
            } else {
                tcp_eof = 1;
                (void)shutdown(vsock_fd, SHUT_WR);
            }
        }
    }

    close(tcp_fd);
    close(vsock_fd);
}

static void mount_fs(const char *src, const char *dst, const char *fstype, unsigned long flags, const char *opts) {
    mkdir(dst, 0755);
    (void)mount(src, dst, fstype, flags, opts);
}

static void bootstrap_guest_os(void) {
    (void)mount(NULL, "/", NULL, MS_REMOUNT, NULL);
    mount_fs("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    mount_fs("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
    mount_fs("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "gid=5,mode=0620,ptmxmode=0666");
    mount_fs("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755");
    mount_fs("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
    mkdir("/root", 0700);
    mkdir("/workspace", 0755);

    /* Optional VirtioFS workspace mount (succeeds silently when host shares "workspace") */
    (void)mount("workspace", "/workspace", "virtiofs", 0, NULL);

    (void)sethostname("boobox", 6);

    /* Bring up loopback and DHCP on eth0 asynchronously so vsock accepts connections immediately */
    pid_t net_pid = fork();
    if (net_pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, 0);
            dup2(devnull, 1);
            dup2(devnull, 2);
            close(devnull);
        }
        (void)system("ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up 2>/dev/null");
        (void)system("ip link set eth0 up 2>/dev/null && udhcpc -i eth0 -b -q -n -t 3 2>/dev/null");
        _exit(0);
    }
}

static void sigchld_handler(int sig) {
    (void)sig;
    int saved = errno;
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    errno = saved;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, sigchld_handler);

    bootstrap_guest_os();

    int listen_fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("socket(AF_VSOCK)");
        sleep(5);
        return 1;
    }

    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = PTY_VSOCK_PORT;

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind(AF_VSOCK PTY)");
        sleep(5);
        return 1;
    }
    if (listen(listen_fd, 32) < 0) {
        perror("listen(AF_VSOCK PTY)");
        sleep(5);
        return 1;
    }

    int fwd_fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fwd_fd >= 0) {
        struct sockaddr_vm faddr;
        memset(&faddr, 0, sizeof(faddr));
        faddr.svm_family = AF_VSOCK;
        faddr.svm_cid = VMADDR_CID_ANY;
        faddr.svm_port = FWD_VSOCK_PORT;
        if (bind(fwd_fd, (struct sockaddr *)&faddr, sizeof(faddr)) < 0 || listen(fwd_fd, 64) < 0) {
            close(fwd_fd);
            fwd_fd = -1;
        }
    }

    /* Announce readiness on hvc0 console for host observability */
    const char *ready_msg = "BOOBOX_READY\n";
    (void)write(1, ready_msg, strlen(ready_msg));

    for (;;) {
        struct pollfd pfds[2];
        pfds[0].fd = listen_fd;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        pfds[1].fd = fwd_fd;
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;

        int rc = poll(pfds, fwd_fd >= 0 ? 2 : 1, -1);
        if (rc < 0) {
            if (errno == EINTR) continue;
            usleep(10000);
            continue;
        }

        if (pfds[0].revents & POLLIN) {
            int client_fd = accept(listen_fd, NULL, NULL);
            if (client_fd >= 0) {
                pid_t worker = fork();
                if (worker == 0) {
                    close(listen_fd);
                    if (fwd_fd >= 0) close(fwd_fd);
                    handle_pty_session(client_fd);
                    _exit(0);
                }
                close(client_fd);
            }
        }

        if (fwd_fd >= 0 && (pfds[1].revents & POLLIN)) {
            int client_fd = accept(fwd_fd, NULL, NULL);
            if (client_fd >= 0) {
                pid_t worker = fork();
                if (worker == 0) {
                    close(listen_fd);
                    close(fwd_fd);
                    handle_fwd_session(client_fd);
                    _exit(0);
                }
                close(client_fd);
            }
        }
    }
    return 0;
}
