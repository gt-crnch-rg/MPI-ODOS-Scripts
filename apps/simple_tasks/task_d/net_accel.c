#include <err.h>
#include <errno.h>

#include <omp.h> 
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <sys/types.h>
#include <sys/socket.h>

#include <arpa/inet.h>

#define _PORT_ 3310
#define _ITERATIONS_ (10)

/*
 * Runs on the DPU, inside the long-running ODOS service. So it reports errors
 * with warn() and returns -EAGAIN: err() would exit() the service itself. It
 * also closes every socket it does not return, or the next run finds the port
 * still taken.
 */
int tcp_init(char MODE, char *server_ip)
{
	int fd, conn_fd, ret;
	int enable_reuse = 1;
	socklen_t socklen_;
	struct sockaddr_in sockaddr_;

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd == -1) {
		warn("failed to create socket.");
		return -EAGAIN;
	}
	ret = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, \
					 &enable_reuse, sizeof(enable_reuse));
	if (ret == -1) {
		warn("failed to set socket to reuse.");
		goto err_close;
	}


	sockaddr_.sin_family = AF_INET;
	sockaddr_.sin_port = htons(_PORT_);

	if (MODE == 'c') {
		sockaddr_.sin_addr.s_addr = inet_addr(server_ip);
		ret = connect(fd, (struct sockaddr *)&sockaddr_, sizeof(sockaddr_));
		if (ret == -1) {
			warn("failed to connect socket to %s.", server_ip);
			goto err_close;
		}
		return fd;
	}

	sockaddr_.sin_addr.s_addr= INADDR_ANY;

	ret = bind(fd, (struct sockaddr *) &sockaddr_, sizeof(sockaddr_));
	if (ret == -1) {
		warn("failed to bind socket.");
		goto err_close;
	}

	ret = listen(fd, 1);
	if (ret == -1) {
		warn("failed to listen socket.");
		goto err_close;
	}

	socklen_ = sizeof(sockaddr_);
	conn_fd = accept(fd, (struct sockaddr *)&sockaddr_, &socklen_);
	if (conn_fd == -1) {
		warn("failed to accept connection.");
		goto err_close;
	}
	close(fd);	/* only the accepted connection is needed from here on */
	return conn_fd;

err_close:
	close(fd);
	return -EAGAIN;
}

void ping_pong(int fd, char mode)
{
	int i, m;
	m = 0;

	for (i = 0; i < _ITERATIONS_; ++i) {
		if (mode == 'c') {
			printf("to   server > %02d\n", m);
			send(fd, &m, sizeof(m), 0);
			recv(fd, &m, sizeof(m), 0);
			++m;
		} else {
			recv(fd, &m, sizeof(m), 0);
			++m;
			printf("to   client > %02d\n", m);
			send(fd, &m, sizeof(m), 0);
		}
	}

}

int main(int argc, char *argv[])
{
	int fd;
	char mode;
	/* Fixed-size and NUL-terminated, so the whole buffer can be mapped to the
	 * DPU in both modes (the server does not use it). */
	char ip[INET_ADDRSTRLEN] = "";
	
	if (argc < 2) {
		mode = 's';
	} else if (argc > 2 && argv[1][0] == 'c') {
		mode = 'c';
		strncpy(ip, argv[2], sizeof(ip) - 1);
	} else {
		err(-EINVAL, "invalid argument. Leave empty for server. c for client");
		return -EINVAL;
	}

#pragma omp target map(to:ip) nowait
{
	fd = tcp_init(mode, ip);

	if (fd < 0) {
		warnx("init failed.");
		goto err_out;
	}

	puts("connection established.");

	ping_pong(fd, mode);

	close(fd);
err_out:
}

#pragma omp taskwait

	return 0;
}
