/*
 * Host-side round-trip test for doca-omp-service over DOCA Comch.
 *
 * Speaks the service's own protocol (the structs and bf_send_buf/bf_recv_buf
 * below are copied from doca-omp-service.c): per buffer size it does
 * CMD_DATA_ALLOC, CMD_DATA_SUBMIT of a pattern, CMD_DATA_RETRIEVE, compares,
 * then CMD_DATA_DELETE. Runs N sessions (disconnect + reconnect between them)
 * to check that the service re-initialises after a host leaves.
 *
 * usage: rt_client [host PCI address of the BlueField PF] [sessions]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <doca_dev.h>
#include <doca_log.h>
#include "odos_comch.h"

#define SERVER_NAME "omp_test0"
#define __MAX_SZ__ 2048
#define __ACK_RESET__ 65536

enum { CMD_DATA_ALLOC = 3, CMD_DATA_SUBMIT = 4, CMD_DATA_RETRIEVE = 6, CMD_DATA_DELETE = 8 };

struct data_cmd { int cmd; int64_t sz; int64_t ptr; };
struct run_cmd  { int64_t entry; int64_t total_args; };
struct load_cmd { int64_t imglen; int64_t total_entries; };
struct bf_openmp_cmd {
	int cmd;
	union { struct load_cmd load; struct data_cmd data; struct run_cmd run; };
};

struct bf_conn { struct odos_comch cc; char sbuf[__MAX_SZ__]; char rbuf[__MAX_SZ__]; };

static int bf_recv_buf(struct bf_conn *conn, void *buf, size_t sz);
static int bf_send_buf(struct bf_conn *conn, void *buf, size_t sz)
{
	size_t len, sent_len, ack_reset = 0;
	for (sent_len = 0; sent_len < sz;) {
		len = sz - sent_len > __MAX_SZ__ ? __MAX_SZ__ : sz - sent_len;
		if (odos_comch_send(&conn->cc, (char *)buf + sent_len, len) != DOCA_SUCCESS)
			return -1;
		if (ack_reset > __ACK_RESET__) {
			bf_recv_buf(conn, conn->rbuf, __MAX_SZ__);
			ack_reset = 0;
		}
		ack_reset += len;
		sent_len += len;
	}
	return 0;
}
static int bf_recv_buf(struct bf_conn *conn, void *buf, size_t sz)
{
	size_t len, recvd_len, ack_reset = 0;
	for (recvd_len = 0; recvd_len < sz;) {
		len = sz - recvd_len > __MAX_SZ__ ? __MAX_SZ__ : sz - recvd_len;
		if (odos_comch_recv(&conn->cc, (char *)buf + recvd_len, &len) != DOCA_SUCCESS)
			return -1;
		if (ack_reset > __ACK_RESET__) {
			bf_send_buf(conn, conn->sbuf, __MAX_SZ__);
			ack_reset = 0;
		}
		ack_reset += len;
		recvd_len += len;
	}
	return 0;
}

static int send_cmd(struct bf_conn *c, int cmd, int64_t sz, int64_t ptr)
{
	struct bf_openmp_cmd m;
	memset(&m, 0, sizeof(m));
	m.cmd = cmd;
	m.data.cmd = cmd;
	m.data.sz = sz;
	m.data.ptr = ptr;
	return bf_send_buf(c, &m, sizeof(m));
}

static int roundtrip(struct bf_conn *c, size_t sz, unsigned seed)
{
	unsigned char *out = malloc(sz), *in = malloc(sz);
	int64_t rptr = 0;
	double t0, t1;
	size_t i;
	int ok;

	for (i = 0; i < sz; i++)
		out[i] = (unsigned char)(i * 2654435761u + seed);
	memset(in, 0, sz);

	if (send_cmd(c, CMD_DATA_ALLOC, sz, 0) || bf_recv_buf(c, &rptr, sizeof(rptr))) {
		printf("  %9zu B: ALLOC failed\n", sz);
		return 1;
	}
	t0 = odos_comch_now();
	if (send_cmd(c, CMD_DATA_SUBMIT, sz, rptr) || bf_send_buf(c, out, sz)) {
		printf("  %9zu B: SUBMIT failed\n", sz);
		return 1;
	}
	if (send_cmd(c, CMD_DATA_RETRIEVE, sz, rptr) || bf_recv_buf(c, in, sz)) {
		printf("  %9zu B: RETRIEVE failed\n", sz);
		return 1;
	}
	t1 = odos_comch_now();
	send_cmd(c, CMD_DATA_DELETE, sz, rptr);
	ok = memcmp(out, in, sz) == 0;
	printf("  %9zu B: dpu ptr 0x%llx  submit+retrieve %8.3f ms  %7.1f MB/s  %s\n", sz,
	       (unsigned long long)rptr, (t1 - t0) * 1e3, 2.0 * sz / (t1 - t0) / 1e6,
	       ok ? "data OK" : "DATA MISMATCH");
	free(out);
	free(in);
	return !ok;
}

int main(int argc, char **argv)
{
	const char *pci = argc > 1 ? argv[1] : "0000:27:00.0";
	int sessions = argc > 2 ? atoi(argv[2]) : 2;
	size_t sizes[] = { 8, 2048, 4096, 65536, 1 << 20, 16 << 20 };
	struct doca_devinfo **list;
	struct doca_dev *dev = NULL;
	uint32_t n, i;
	uint8_t match;
	int s, fails = 0;

	if (doca_devinfo_create_list(&list, &n) != DOCA_SUCCESS)
		return 2;
	for (i = 0; i < n && dev == NULL; i++) {
		match = 0;
		doca_devinfo_is_equal_pci_addr(list[i], pci, &match);
		if (match && odos_comch_dev_supported(list[i], 0))
			doca_dev_open(list[i], &dev);
	}
	if (dev == NULL) {
		fprintf(stderr, "no Comch-client-capable device at %s\n", pci);
		return 2;
	}

	for (s = 1; s <= sessions; s++) {
		static struct bf_conn conn;
		doca_error_t r;
		memset(&conn, 0, sizeof(conn));
		r = odos_comch_client_connect(&conn.cc, dev, SERVER_NAME, 30);
		if (r != DOCA_SUCCESS) {
			printf("session %d: connect to %s via %s failed: %s\n", s, SERVER_NAME, pci,
			       doca_error_get_name(r));
			return 1;
		}
		printf("session %d: connected to %s via %s (max msg %u B)\n", s, SERVER_NAME, pci,
		       conn.cc.max_msg_size);
		for (i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++)
			fails += roundtrip(&conn, sizes[i], s * 131 + i);
		odos_comch_destroy(&conn.cc);
		printf("session %d: disconnected\n", s);
	}
	doca_dev_close(dev);
	doca_devinfo_destroy_list(list);
	printf(fails ? "FAIL: %d round trip(s) failed\n" : "OK: all round trips passed\n", fails);
	return fails != 0;
}
