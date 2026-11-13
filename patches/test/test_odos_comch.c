/*
 * Exercises odos_comch.h against an in-process mock of the DOCA Comch API:
 * a "service" thread and a "host" thread talk through the shim using the
 * ODOS bf_send_buf()/bf_recv_buf() protocol (2 KB chunks, ack every 64 KB).
 *
 * The mock delivers a send only on a *later* progress call, reading the
 * message from the pointer given to task_send_alloc_init() at that time -- so
 * a shim that reused a send buffer before completion would corrupt data.
 *
 *   cc -DDOCA_ALLOW_EXPERIMENTAL_API -I.. -I$DOCA/include -pthread \
 *      test_odos_comch.c -o test_odos_comch && ./test_odos_comch
 */
#include "odos_comch.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

/* ------------------------------------------------------------------------ */
/* Mock DOCA                                                                 */
/* ------------------------------------------------------------------------ */

#define MOCK_MAX_MSG    4080
#define MOCK_SEND_TASKS 4 /* small, so the shim has to wait for free slots */

struct doca_dev { int unused; };
struct doca_devinfo { int unused; };
struct doca_dev_rep { int unused; };
struct doca_devinfo_rep { int unused; };

struct doca_ctx {
	int is_server;
	enum doca_ctx_states state;
	union doca_data ud;
	struct doca_pe *pe;
};

struct doca_task {
	struct doca_ctx *ctx;
	union doca_data ud;
	const void *msg; /* NOT copied, like (possibly) the real thing */
	uint32_t len;
	doca_error_t status;
	struct doca_task *next;
};
struct doca_comch_task_send { struct doca_task t; };

struct doca_comch_connection { int is_server_side; union doca_data ud; };

struct doca_comch_server {
	struct doca_ctx ctx; /* first: server <-> ctx casts */
	doca_comch_event_msg_recv_cb_t recv_cb;
	doca_comch_event_connection_status_changed_cb_t connect_cb, disconnect_cb;
	doca_comch_task_send_completion_cb_t done_cb, err_cb;
	uint32_t ntasks, used;
	struct doca_comch_connection conn;
	struct doca_task *submitted;
};
struct doca_comch_client {
	struct doca_ctx ctx;
	doca_comch_event_msg_recv_cb_t recv_cb;
	doca_comch_task_send_completion_cb_t done_cb, err_cb;
	uint32_t ntasks, used;
	struct doca_comch_connection conn;
	struct doca_task *submitted;
};
struct doca_pe { struct doca_ctx *ctx; };

/* The wire: one queue per direction, plus connection state. */
struct wmsg { struct wmsg *next; uint32_t len; unsigned char d[MOCK_MAX_MSG]; };
static struct { struct wmsg *head, *tail; } to_server, to_client;
static pthread_mutex_t wire_lock = PTHREAD_MUTEX_INITIALIZER;
static struct doca_comch_server *listening;
static int connect_pending, connected, client_gone, server_gone;
static unsigned long long delivered;

static void wire_push(int to_srv, const void *buf, uint32_t len)
{
	struct wmsg *m = calloc(1, sizeof(*m));
	m->len = len;
	memcpy(m->d, buf, len);
	if (to_srv) {
		if (to_server.tail) to_server.tail->next = m; else to_server.head = m;
		to_server.tail = m;
	} else {
		if (to_client.tail) to_client.tail->next = m; else to_client.head = m;
		to_client.tail = m;
	}
}
static struct wmsg *wire_pop(int to_srv)
{
	struct wmsg *m = to_srv ? to_server.head : to_client.head;
	if (m == NULL) return NULL;
	if (to_srv) { to_server.head = m->next; if (!to_server.head) to_server.tail = NULL; }
	else        { to_client.head = m->next; if (!to_client.head) to_client.tail = NULL; }
	return m;
}

doca_error_t doca_pe_create(struct doca_pe **pe) { *pe = calloc(1, sizeof(**pe)); return DOCA_SUCCESS; }
doca_error_t doca_pe_destroy(struct doca_pe *pe) { free(pe); return DOCA_SUCCESS; }
doca_error_t doca_pe_connect_ctx(struct doca_pe *pe, struct doca_ctx *ctx) { pe->ctx = ctx; ctx->pe = pe; return DOCA_SUCCESS; }

doca_error_t doca_ctx_set_user_data(struct doca_ctx *ctx, union doca_data ud) { ctx->ud = ud; return DOCA_SUCCESS; }
doca_error_t doca_ctx_get_user_data(const struct doca_ctx *ctx, union doca_data *ud) { *ud = ctx->ud; return DOCA_SUCCESS; }
doca_error_t doca_ctx_get_state(const struct doca_ctx *ctx, enum doca_ctx_states *st) { *st = ctx->state; return DOCA_SUCCESS; }

doca_error_t doca_ctx_start(struct doca_ctx *ctx)
{
	pthread_mutex_lock(&wire_lock);
	if (ctx->is_server) {
		listening = (struct doca_comch_server *)ctx;
		server_gone = 0;
		ctx->state = DOCA_CTX_STATE_RUNNING;
		pthread_mutex_unlock(&wire_lock);
		return DOCA_SUCCESS;
	}
	connect_pending = 1;
	client_gone = 0;
	ctx->state = DOCA_CTX_STATE_STARTING;
	pthread_mutex_unlock(&wire_lock);
	return DOCA_ERROR_IN_PROGRESS;
}

doca_error_t doca_ctx_stop(struct doca_ctx *ctx)
{
	pthread_mutex_lock(&wire_lock);
	if (ctx->is_server) {
		if (listening == (struct doca_comch_server *)ctx) listening = NULL;
		server_gone = 1;
		connected = 0;
	} else {
		client_gone = 1;
		connected = 0;
		connect_pending = 0;
	}
	ctx->state = DOCA_CTX_STATE_IDLE;
	pthread_mutex_unlock(&wire_lock);
	return DOCA_SUCCESS;
}

static void flush_one(struct doca_ctx *ctx, struct doca_task **list, uint32_t *used,
		      doca_comch_task_send_completion_cb_t done, doca_comch_task_send_completion_cb_t err,
		      int to_srv, int peer_alive)
{
	struct doca_task *t = *list;
	*list = t->next;
	pthread_mutex_lock(&wire_lock);
	if (peer_alive) {
		wire_push(to_srv, t->msg, t->len); /* reads the caller's buffer only now */
		delivered++;
	}
	pthread_mutex_unlock(&wire_lock);
	(*used)--;
	t->status = peer_alive ? DOCA_SUCCESS : DOCA_ERROR_NOT_CONNECTED;
	(peer_alive ? done : err)((struct doca_comch_task_send *)t, t->ud, ctx->ud);
}

uint8_t doca_pe_progress(struct doca_pe *pe)
{
	struct doca_ctx *ctx = pe->ctx;
	struct wmsg *m = NULL;
	int did = 0, alive;

	if (ctx->is_server) {
		struct doca_comch_server *s = (struct doca_comch_server *)ctx;
		int accept = 0, lost = 0;
		pthread_mutex_lock(&wire_lock);
		if (connect_pending && listening == s) { connect_pending = 0; connected = 1; accept = 1; }
		if (client_gone && s->conn.ud.u64 == 1) { s->conn.ud.u64 = 0; lost = 1; client_gone = 0; }
		alive = connected;
		if (alive) m = wire_pop(1);
		pthread_mutex_unlock(&wire_lock);
		if (accept) { s->conn.ud.u64 = 1; s->connect_cb(NULL, &s->conn, 1); did = 1; }
		if (lost) { s->disconnect_cb(NULL, &s->conn, 1); did = 1; }
		if (s->submitted) { flush_one(ctx, &s->submitted, &s->used, s->done_cb, s->err_cb, 0, alive); did = 1; }
		if (m) { s->recv_cb(NULL, m->d, m->len, &s->conn); free(m); did = 1; }
	} else {
		struct doca_comch_client *c = (struct doca_comch_client *)ctx;
		pthread_mutex_lock(&wire_lock);
		if (ctx->state == DOCA_CTX_STATE_STARTING) {
			if (connected) ctx->state = DOCA_CTX_STATE_RUNNING;
			else if (listening == NULL) { ctx->state = DOCA_CTX_STATE_IDLE; connect_pending = 0; } /* refused */
		}
		if (ctx->state == DOCA_CTX_STATE_RUNNING && server_gone) ctx->state = DOCA_CTX_STATE_IDLE;
		alive = ctx->state == DOCA_CTX_STATE_RUNNING;
		if (alive) m = wire_pop(0);
		pthread_mutex_unlock(&wire_lock);
		if (c->submitted) { flush_one(ctx, &c->submitted, &c->used, c->done_cb, c->err_cb, 1, alive); did = 1; }
		if (m) { c->recv_cb(NULL, m->d, m->len, &c->conn); free(m); did = 1; }
	}
	return (uint8_t)did;
}

struct doca_devinfo mock_devinfo;
struct doca_devinfo *doca_dev_as_devinfo(const struct doca_dev *dev) { (void)dev; return &mock_devinfo; }
doca_error_t doca_comch_cap_get_max_msg_size(const struct doca_devinfo *d, uint32_t *v) { (void)d; *v = MOCK_MAX_MSG; return DOCA_SUCCESS; }
doca_error_t doca_comch_cap_get_max_send_tasks(const struct doca_devinfo *d, uint32_t *v) { (void)d; *v = MOCK_SEND_TASKS; return DOCA_SUCCESS; }
doca_error_t doca_comch_cap_get_max_recv_queue_size(const struct doca_devinfo *d, uint32_t *v) { (void)d; *v = 8192; return DOCA_SUCCESS; }
doca_error_t doca_comch_cap_server_is_supported(const struct doca_devinfo *d) { (void)d; return DOCA_SUCCESS; }
doca_error_t doca_comch_cap_client_is_supported(const struct doca_devinfo *d) { (void)d; return DOCA_SUCCESS; }

doca_error_t doca_comch_server_create(struct doca_dev *d, struct doca_dev_rep *r, const char *n, struct doca_comch_server **s)
{ (void)d; (void)r; (void)n; *s = calloc(1, sizeof(**s)); (*s)->ctx.is_server = 1; (*s)->conn.is_server_side = 1; return DOCA_SUCCESS; }
doca_error_t doca_comch_server_destroy(struct doca_comch_server *s) { free(s); return DOCA_SUCCESS; }
struct doca_ctx *doca_comch_server_as_ctx(struct doca_comch_server *s) { return &s->ctx; }
doca_error_t doca_comch_server_task_send_set_conf(struct doca_comch_server *s, doca_comch_task_send_completion_cb_t d,
						  doca_comch_task_send_completion_cb_t e, uint32_t n)
{ s->done_cb = d; s->err_cb = e; s->ntasks = n; return DOCA_SUCCESS; }
doca_error_t doca_comch_server_event_msg_recv_register(struct doca_comch_server *s, doca_comch_event_msg_recv_cb_t cb) { s->recv_cb = cb; return DOCA_SUCCESS; }
doca_error_t doca_comch_server_event_connection_status_changed_register(struct doca_comch_server *s,
	doca_comch_event_connection_status_changed_cb_t c, doca_comch_event_connection_status_changed_cb_t d)
{ s->connect_cb = c; s->disconnect_cb = d; return DOCA_SUCCESS; }
doca_error_t doca_comch_server_set_max_msg_size(struct doca_comch_server *s, uint32_t v) { (void)s; assert(v <= MOCK_MAX_MSG); return DOCA_SUCCESS; }
doca_error_t doca_comch_server_set_recv_queue_size(struct doca_comch_server *s, uint32_t v) { (void)s; (void)v; return DOCA_SUCCESS; }
doca_error_t doca_comch_server_disconnect(struct doca_comch_server *s, struct doca_comch_connection *c)
{ (void)s; (void)c; pthread_mutex_lock(&wire_lock); server_gone = 1; connected = 0; pthread_mutex_unlock(&wire_lock); return DOCA_SUCCESS; }
struct doca_comch_server *doca_comch_server_get_server_ctx(const struct doca_comch_connection *c)
{ return (struct doca_comch_server *)((char *)c - offsetof(struct doca_comch_server, conn)); }

doca_error_t doca_comch_client_create(struct doca_dev *d, const char *n, struct doca_comch_client **c)
{ (void)d; (void)n; *c = calloc(1, sizeof(**c)); return DOCA_SUCCESS; }
doca_error_t doca_comch_client_destroy(struct doca_comch_client *c) { free(c); return DOCA_SUCCESS; }
struct doca_ctx *doca_comch_client_as_ctx(struct doca_comch_client *c) { return &c->ctx; }
doca_error_t doca_comch_client_task_send_set_conf(struct doca_comch_client *c, doca_comch_task_send_completion_cb_t d,
						  doca_comch_task_send_completion_cb_t e, uint32_t n)
{ c->done_cb = d; c->err_cb = e; c->ntasks = n; return DOCA_SUCCESS; }
doca_error_t doca_comch_client_event_msg_recv_register(struct doca_comch_client *c, doca_comch_event_msg_recv_cb_t cb) { c->recv_cb = cb; return DOCA_SUCCESS; }
doca_error_t doca_comch_client_set_max_msg_size(struct doca_comch_client *c, uint32_t v) { (void)c; assert(v <= MOCK_MAX_MSG); return DOCA_SUCCESS; }
doca_error_t doca_comch_client_set_recv_queue_size(struct doca_comch_client *c, uint32_t v) { (void)c; (void)v; return DOCA_SUCCESS; }
doca_error_t doca_comch_client_get_connection(const struct doca_comch_client *c, struct doca_comch_connection **conn)
{ *conn = (struct doca_comch_connection *)&c->conn; return DOCA_SUCCESS; }
struct doca_comch_client *doca_comch_client_get_client_ctx(const struct doca_comch_connection *c)
{ return (struct doca_comch_client *)((char *)c - offsetof(struct doca_comch_client, conn)); }

static doca_error_t task_alloc(struct doca_ctx *ctx, uint32_t *used, uint32_t n, const void *msg, uint32_t len, struct doca_comch_task_send **task)
{
	struct doca_task *t;
	if (*used >= n) return DOCA_ERROR_NO_MEMORY;
	assert(len <= MOCK_MAX_MSG);
	t = calloc(1, sizeof(struct doca_comch_task_send));
	t->ctx = ctx; t->msg = msg; t->len = len;
	(*used)++;
	*task = (struct doca_comch_task_send *)t;
	return DOCA_SUCCESS;
}
doca_error_t doca_comch_server_task_send_alloc_init(struct doca_comch_server *s, struct doca_comch_connection *p, const void *msg, uint32_t len, struct doca_comch_task_send **task)
{ assert(p == &s->conn); return task_alloc(&s->ctx, &s->used, s->ntasks, msg, len, task); }
doca_error_t doca_comch_client_task_send_alloc_init(struct doca_comch_client *c, struct doca_comch_connection *p, const void *msg, uint32_t len, struct doca_comch_task_send **task)
{ assert(p == &c->conn); return task_alloc(&c->ctx, &c->used, c->ntasks, msg, len, task); }
struct doca_task *doca_comch_task_send_as_task(struct doca_comch_task_send *t) { return &t->t; }
void doca_task_set_user_data(struct doca_task *t, union doca_data ud) { t->ud = ud; }
union doca_data doca_task_get_user_data(const struct doca_task *t) { return t->ud; }
doca_error_t doca_task_get_status(const struct doca_task *t) { return t->status; }
void doca_task_free(struct doca_task *t) { free(t); }
doca_error_t doca_task_submit(struct doca_task *t)
{
	struct doca_task **list = t->ctx->is_server ? &((struct doca_comch_server *)t->ctx)->submitted
						    : &((struct doca_comch_client *)t->ctx)->submitted;
	while (*list) list = &(*list)->next; /* FIFO */
	t->next = NULL;
	*list = t;
	return DOCA_SUCCESS;
}

/* Referenced only by helpers this test does not call. */
doca_error_t doca_devinfo_rep_create_list(struct doca_dev *d, int f, struct doca_devinfo_rep ***l, uint32_t *n) { (void)d; (void)f; (void)l; *n = 0; return DOCA_ERROR_NOT_SUPPORTED; }
doca_error_t doca_devinfo_rep_destroy_list(struct doca_devinfo_rep **l) { (void)l; return DOCA_SUCCESS; }
doca_error_t doca_devinfo_rep_is_equal_pci_addr(const struct doca_devinfo_rep *r, const char *a, uint8_t *e) { (void)r; (void)a; *e = 0; return DOCA_SUCCESS; }
doca_error_t doca_devinfo_rep_get_is_uplink_representor(const struct doca_devinfo_rep *r, uint8_t *u) { (void)r; *u = 0; return DOCA_SUCCESS; }
doca_error_t doca_dev_rep_open(struct doca_devinfo_rep *r, struct doca_dev_rep **d) { (void)r; (void)d; return DOCA_ERROR_NOT_SUPPORTED; }
doca_error_t doca_log_backend_create_standard(void) { return DOCA_SUCCESS; }
doca_error_t doca_log_level_set_global_lower_limit(uint32_t l) { (void)l; return DOCA_SUCCESS; }
doca_error_t doca_log_level_set_global_sdk_limit(uint32_t l) { (void)l; return DOCA_SUCCESS; }

/* ------------------------------------------------------------------------ */
/* The ODOS protocol, as in rtl.cpp / doca-omp-service.c (after the port)    */
/* ------------------------------------------------------------------------ */

#define __MAX_SZ__ 2048
#define __ACK_RESET__ 65536

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

/* ------------------------------------------------------------------------ */
/* Test                                                                      */
/* ------------------------------------------------------------------------ */

enum { CMD_SUBMIT = 1, CMD_RETRIEVE, CMD_BYE };
struct cmd { int32_t cmd; int64_t sz; uint64_t seed; };

static uint64_t fnv(const unsigned char *p, size_t n)
{
	uint64_t h = 1469598103934665603ULL;
	while (n--) h = (h ^ *p++) * 1099511628211ULL;
	return h;
}
static void fill(unsigned char *p, size_t n, uint64_t seed)
{
	size_t i;
	for (i = 0; i < n; ++i) { seed = seed * 6364136223846793005ULL + 1442695040888963407ULL; p[i] = (unsigned char)(seed >> 56); }
}

static struct doca_dev dev;
static struct doca_dev_rep rep;
static int sessions_served;

/* doca-omp-service's main(): init, serve until the host goes away, repeat. */
static void *service(void *arg)
{
	int want_sessions = *(int *)arg;
	while (sessions_served < want_sessions) {
		static struct bf_conn conn;
		struct cmd cmd;
		unsigned char *buf;
		uint64_t h;
		assert(odos_comch_server_start(&conn.cc, &dev, &rep, "odos_test") == DOCA_SUCCESS);
		while (bf_recv_buf(&conn, &cmd, sizeof(cmd)) == 0) {
			if (cmd.cmd == CMD_BYE)
				continue; /* the host disconnects next */
			buf = malloc(cmd.sz ? cmd.sz : 1);
			if (cmd.cmd == CMD_SUBMIT) {
				assert(bf_recv_buf(&conn, buf, cmd.sz) == 0);
				h = fnv(buf, cmd.sz);
				assert(bf_send_buf(&conn, &h, sizeof(h)) == 0);
			} else {
				fill(buf, cmd.sz, cmd.seed);
				assert(bf_send_buf(&conn, buf, cmd.sz) == 0);
			}
			free(buf);
		}
		odos_comch_destroy(&conn.cc); /* recv failed: host disconnected */
		sessions_served++;
	}
	return NULL;
}

static void host_session(int session)
{
	static const size_t sizes[] = { 1, 7, 2047, 2048, 2049, 65535, 65536, 65537, 67585,
					4080 * 33 + 5, 1 << 20, (8 << 20) + 3 };
	struct bf_conn conn;
	struct cmd cmd;
	unsigned char *buf, *want;
	uint64_t h;
	size_t i;

	assert(odos_comch_client_connect(&conn.cc, &dev, "odos_test", 10) == DOCA_SUCCESS);
	for (i = 0; i < sizeof(sizes) / sizeof(sizes[0]); ++i) {
		size_t n = sizes[i];
		buf = malloc(n);
		want = malloc(n);

		/* host -> DPU (CMD_DATA_SUBMIT-like), checksum back */
		fill(buf, n, 1000 + i + 100 * session);
		cmd.cmd = CMD_SUBMIT; cmd.sz = n; cmd.seed = 0;
		assert(bf_send_buf(&conn, &cmd, sizeof(cmd)) == 0);
		assert(bf_send_buf(&conn, buf, n) == 0);
		assert(bf_recv_buf(&conn, &h, sizeof(h)) == 0);
		assert(h == fnv(buf, n));

		/* DPU -> host (CMD_DATA_RETRIEVE-like) */
		cmd.cmd = CMD_RETRIEVE; cmd.sz = n; cmd.seed = 77 + i;
		assert(bf_send_buf(&conn, &cmd, sizeof(cmd)) == 0);
		memset(buf, 0, n);
		assert(bf_recv_buf(&conn, buf, n) == 0);
		fill(want, n, 77 + i);
		assert(memcmp(buf, want, n) == 0);

		free(buf);
		free(want);
	}
	cmd.cmd = CMD_BYE; cmd.sz = 0;
	assert(bf_send_buf(&conn, &cmd, sizeof(cmd)) == 0);
	odos_comch_destroy(&conn.cc);
	printf("  session %d: %zu transfer sizes, both directions, checksums match\n", session,
	       sizeof(sizes) / sizeof(sizes[0]));
}

int main(void)
{
	pthread_t svc;
	int sessions = 3, s;
	struct odos_comch c;
	char small[3];
	size_t len;
	double t0;

	/* 1. No server: connect gives up after the timeout. */
	t0 = odos_comch_now();
	assert(odos_comch_client_connect(&c, &dev, "nobody", 0.3) != DOCA_SUCCESS);
	printf("  connect without a server fails after %.1fs (timeout 0.3s)\n", odos_comch_now() - t0);

	/* 2. A message longer than the reader's buffer is handed out in pieces. */
	memset(&c, 0, sizeof(c));
	c.ctx = (struct doca_ctx *)1; /* only rq_* are used below */
	odos_comch_enqueue(&c, (const uint8_t *)"abcdefgh", 8);
	{
		char out[9] = "";
		size_t got = 0;
		while (got < 8) {
			len = sizeof(small);
			assert(odos_comch_recv(&c, small, &len) == DOCA_SUCCESS && len > 0);
			memcpy(out + got, small, len);
			got += len;
		}
		assert(strcmp(out, "abcdefgh") == 0 && c.rq_head == NULL);
	}
	printf("  8-byte message read through a 3-byte buffer: ok\n");

	/* 3. Full protocol, several host sessions against one service loop. */
	pthread_create(&svc, NULL, service, &sessions);
	for (s = 0; s < sessions; ++s)
		host_session(s);
	pthread_join(svc, NULL);
	assert(sessions_served == sessions);
	printf("  service re-initialised after each host disconnect: %d sessions\n", sessions_served);
	printf("  %llu messages crossed the mock wire\n", delivered);

	puts("PASS");
	return 0;
}
