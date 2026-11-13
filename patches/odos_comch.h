/*
 * odos_comch.h -- blocking message send/recv on top of DOCA Comch (DOCA >= 3.0)
 *
 * The ODOS host plugins and the DPU service were written against the DOCA 2.0
 * Comm Channel API (doca_comm_channel_ep_sendto/_recvfrom), which DOCA 3.x
 * removed. Comch is asynchronous: sends are tasks completed on a progress
 * engine (PE) and received messages are delivered to a callback. This header
 * rebuilds the old blocking, one-message-at-a-time semantics on top of it, so
 * the ODOS protocol code above it (2 KB chunks, an ack every 64 KB) does not
 * change:
 *
 *   odos_comch_send()  copies the message into a free send slot, submits it
 *                      and returns; the slot is released when the send task
 *                      completes, so the caller's buffer is free immediately.
 *   odos_comch_recv()  progresses the PE until a message is queued, then copies
 *                      out up to *len bytes. A message longer than *len is
 *                      handed out in order across several calls.
 *
 * Both calls busy-poll the PE, as the old code busy-polled on DOCA_ERROR_AGAIN.
 *
 * Environment:
 *   ODOS_COMCH_REP_PCI          DPU side: PCI address of the representor the
 *                               server listens on (default: the first network
 *                               representor that is not an uplink).
 *   ODOS_COMCH_CONNECT_TIMEOUT  Host side: seconds to keep retrying the
 *                               connection to the server; -1 retries forever.
 *                               Overrides the caller's default.
 *
 * This file is shared verbatim by the ompi-bf pml/osc plugins, the ODOS
 * BlueField offload plugin and doca-omp-service. It is maintained in
 * MPI-ODOS-Scripts/patches/ and copied into each tree by apply_patches.sh.
 */
#ifndef ODOS_COMCH_H
#define ODOS_COMCH_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <doca_comch.h>
#include <doca_ctx.h>
#include <doca_dev.h>
#include <doca_error.h>
#include <doca_log.h>
#include <doca_pe.h>
#include <doca_types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ODOS_COMCH_MAX_SEND_TASKS 64
#define ODOS_COMCH_MAX_RECV_QUEUE 256 /* > the ~33 messages one 64 KB ack window keeps in flight */
#define ODOS_COMCH_STOP_TIMEOUT   5.0 /* seconds to wait for a ctx to stop */
#define ODOS_COMCH_ATTEMPT_TIMEOUT 5.0 /* seconds per client connection attempt */

struct odos_comch_msg {
	struct odos_comch_msg *next;
	uint32_t len;
	uint32_t off; /* bytes already handed out by odos_comch_recv() */
	unsigned char data[1];
};

struct odos_comch {
	struct doca_pe *pe;
	struct doca_ctx *ctx;
	struct doca_comch_server *server;
	struct doca_comch_client *client;
	struct doca_comch_connection *conn; /* peer we send to */

	int disconnected;   /* server side: the peer went away */
	doca_error_t err;   /* first asynchronous error seen */

	uint32_t max_msg_size;
	uint32_t recv_queue_size;

	/* Send slots: a message must stay valid until its task completes. */
	uint32_t nslots;
	uint32_t next_slot;
	uint32_t inflight;
	unsigned char *slot_busy;
	char *slot_buf;

	/* Received messages, oldest first. */
	struct odos_comch_msg *rq_head;
	struct odos_comch_msg *rq_tail;
};

static inline double odos_comch_now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static inline struct odos_comch *odos_comch_from_ctx(struct doca_ctx *ctx)
{
	union doca_data ud;
	ud.ptr = NULL;
	(void)doca_ctx_get_user_data(ctx, &ud);
	return (struct odos_comch *)ud.ptr;
}

static inline void odos_comch_enqueue(struct odos_comch *c, const uint8_t *buf, uint32_t len)
{
	struct odos_comch_msg *m = (struct odos_comch_msg *)malloc(sizeof(*m) + len);
	if (m == NULL) {
		if (c->err == DOCA_SUCCESS)
			c->err = DOCA_ERROR_NO_MEMORY;
		return;
	}
	m->next = NULL;
	m->len = len;
	m->off = 0;
	memcpy(m->data, buf, len);
	if (c->rq_tail != NULL)
		c->rq_tail->next = m;
	else
		c->rq_head = m;
	c->rq_tail = m;
}

static inline void odos_comch_server_recv_cb(struct doca_comch_event_msg_recv *event, uint8_t *buf,
					     uint32_t len, struct doca_comch_connection *conn)
{
	struct odos_comch *c =
		odos_comch_from_ctx(doca_comch_server_as_ctx(doca_comch_server_get_server_ctx(conn)));
	(void)event;
	/* As with the old recvfrom(): reply to whoever sent last. */
	c->conn = conn;
	c->disconnected = 0;
	odos_comch_enqueue(c, buf, len);
}

static inline void odos_comch_client_recv_cb(struct doca_comch_event_msg_recv *event, uint8_t *buf,
					     uint32_t len, struct doca_comch_connection *conn)
{
	struct odos_comch *c =
		odos_comch_from_ctx(doca_comch_client_as_ctx(doca_comch_client_get_client_ctx(conn)));
	(void)event;
	odos_comch_enqueue(c, buf, len);
}

static inline void odos_comch_connect_cb(struct doca_comch_event_connection_status_changed *event,
					 struct doca_comch_connection *conn, uint8_t ok)
{
	struct odos_comch *c =
		odos_comch_from_ctx(doca_comch_server_as_ctx(doca_comch_server_get_server_ctx(conn)));
	(void)event;
	if (!ok)
		return;
	c->conn = conn;
	c->disconnected = 0;
}

static inline void odos_comch_disconnect_cb(struct doca_comch_event_connection_status_changed *event,
					    struct doca_comch_connection *conn, uint8_t ok)
{
	struct odos_comch *c =
		odos_comch_from_ctx(doca_comch_server_as_ctx(doca_comch_server_get_server_ctx(conn)));
	(void)event;
	(void)ok;
	if (conn == c->conn) {
		c->conn = NULL;
		c->disconnected = 1;
	}
}

static inline void odos_comch_release_slot(struct odos_comch *c, struct doca_comch_task_send *task,
					   union doca_data task_ud)
{
	c->slot_busy[task_ud.u64] = 0;
	c->inflight--;
	doca_task_free(doca_comch_task_send_as_task(task));
}

static inline void odos_comch_send_done_cb(struct doca_comch_task_send *task, union doca_data task_ud,
					   union doca_data ctx_ud)
{
	odos_comch_release_slot((struct odos_comch *)ctx_ud.ptr, task, task_ud);
}

static inline void odos_comch_send_err_cb(struct doca_comch_task_send *task, union doca_data task_ud,
					  union doca_data ctx_ud)
{
	struct odos_comch *c = (struct odos_comch *)ctx_ud.ptr;
	if (c->err == DOCA_SUCCESS)
		c->err = doca_task_get_status(doca_comch_task_send_as_task(task));
	odos_comch_release_slot(c, task, task_ud);
}

static inline enum doca_ctx_states odos_comch_state(struct odos_comch *c)
{
	enum doca_ctx_states st = DOCA_CTX_STATE_IDLE;
	if (c->ctx != NULL)
		(void)doca_ctx_get_state(c->ctx, &st);
	return st;
}

/* Wait (bounded) for every submitted send to complete. */
static inline void odos_comch_flush(struct odos_comch *c, double timeout)
{
	double deadline = odos_comch_now() + timeout;
	while (c->inflight > 0 && c->err == DOCA_SUCCESS && odos_comch_now() < deadline)
		(void)doca_pe_progress(c->pe);
}

/* Tear everything down. Safe on a partially initialised or zeroed object. */
static inline void odos_comch_destroy(struct odos_comch *c)
{
	struct odos_comch_msg *m;

	if (c->ctx != NULL) {
		odos_comch_flush(c, 1.0);
		if (c->server != NULL && c->conn != NULL && !c->disconnected)
			(void)doca_comch_server_disconnect(c->server, c->conn);
		if (odos_comch_state(c) != DOCA_CTX_STATE_IDLE) {
			double deadline = odos_comch_now() + ODOS_COMCH_STOP_TIMEOUT;
			(void)doca_ctx_stop(c->ctx);
			while (odos_comch_state(c) != DOCA_CTX_STATE_IDLE && odos_comch_now() < deadline)
				(void)doca_pe_progress(c->pe);
		}
	}
	if (c->server != NULL)
		(void)doca_comch_server_destroy(c->server);
	if (c->client != NULL)
		(void)doca_comch_client_destroy(c->client);
	if (c->pe != NULL)
		(void)doca_pe_destroy(c->pe);

	while ((m = c->rq_head) != NULL) {
		c->rq_head = m->next;
		free(m);
	}
	free(c->slot_busy);
	free(c->slot_buf);
	memset(c, 0, sizeof(*c));
}

#define ODOS_COMCH_TRY(expr)                    \
	do {                                    \
		r = (expr);                     \
		if (r != DOCA_SUCCESS)          \
			goto fail;              \
	} while (0)

static inline doca_error_t odos_comch_init_common(struct odos_comch *c, struct doca_dev *dev)
{
	struct doca_devinfo *di = doca_dev_as_devinfo(dev);
	uint32_t cap;
	doca_error_t r;

	memset(c, 0, sizeof(*c));
	ODOS_COMCH_TRY(doca_comch_cap_get_max_msg_size(di, &c->max_msg_size));
	ODOS_COMCH_TRY(doca_comch_cap_get_max_send_tasks(di, &cap));
	c->nslots = cap < ODOS_COMCH_MAX_SEND_TASKS ? cap : ODOS_COMCH_MAX_SEND_TASKS;
	if (c->nslots == 0) {
		r = DOCA_ERROR_NOT_SUPPORTED;
		goto fail;
	}
	ODOS_COMCH_TRY(doca_comch_cap_get_max_recv_queue_size(di, &cap));
	c->recv_queue_size = cap < ODOS_COMCH_MAX_RECV_QUEUE ? cap : ODOS_COMCH_MAX_RECV_QUEUE;

	c->slot_busy = (unsigned char *)calloc(c->nslots, 1);
	c->slot_buf = (char *)malloc((size_t)c->nslots * c->max_msg_size);
	if (c->slot_busy == NULL || c->slot_buf == NULL) {
		r = DOCA_ERROR_NO_MEMORY;
		goto fail;
	}
	ODOS_COMCH_TRY(doca_pe_create(&c->pe));
	return DOCA_SUCCESS;
fail:
	odos_comch_destroy(c);
	return r;
}

/*
 * DPU side: create a server named `name` on `dev`, listening on `rep`.
 * Returns once the server is running; a client connects asynchronously, and
 * the first odos_comch_send()/_recv() waits for it.
 */
static inline doca_error_t odos_comch_server_start(struct odos_comch *c, struct doca_dev *dev,
						   struct doca_dev_rep *rep, const char *name)
{
	union doca_data ud;
	doca_error_t r;

	r = odos_comch_init_common(c, dev);
	if (r != DOCA_SUCCESS)
		return r;

	ODOS_COMCH_TRY(doca_comch_server_create(dev, rep, name, &c->server));
	c->ctx = doca_comch_server_as_ctx(c->server);
	ODOS_COMCH_TRY(doca_pe_connect_ctx(c->pe, c->ctx));
	ODOS_COMCH_TRY(doca_comch_server_task_send_set_conf(c->server, odos_comch_send_done_cb,
							    odos_comch_send_err_cb, c->nslots));
	ODOS_COMCH_TRY(doca_comch_server_event_msg_recv_register(c->server, odos_comch_server_recv_cb));
	ODOS_COMCH_TRY(doca_comch_server_event_connection_status_changed_register(
		c->server, odos_comch_connect_cb, odos_comch_disconnect_cb));
	ODOS_COMCH_TRY(doca_comch_server_set_max_msg_size(c->server, c->max_msg_size));
	ODOS_COMCH_TRY(doca_comch_server_set_recv_queue_size(c->server, c->recv_queue_size));
	ud.ptr = c;
	ODOS_COMCH_TRY(doca_ctx_set_user_data(c->ctx, ud));
	ODOS_COMCH_TRY(doca_ctx_start(c->ctx));
	return DOCA_SUCCESS;
fail:
	odos_comch_destroy(c);
	return r;
}

/* One client connection attempt, bounded by ODOS_COMCH_ATTEMPT_TIMEOUT. */
static inline doca_error_t odos_comch_client_try(struct odos_comch *c, struct doca_dev *dev,
						 const char *name)
{
	union doca_data ud;
	double deadline;
	enum doca_ctx_states st;
	doca_error_t r;

	r = odos_comch_init_common(c, dev);
	if (r != DOCA_SUCCESS)
		return r;

	ODOS_COMCH_TRY(doca_comch_client_create(dev, name, &c->client));
	c->ctx = doca_comch_client_as_ctx(c->client);
	ODOS_COMCH_TRY(doca_pe_connect_ctx(c->pe, c->ctx));
	ODOS_COMCH_TRY(doca_comch_client_task_send_set_conf(c->client, odos_comch_send_done_cb,
							    odos_comch_send_err_cb, c->nslots));
	ODOS_COMCH_TRY(doca_comch_client_event_msg_recv_register(c->client, odos_comch_client_recv_cb));
	ODOS_COMCH_TRY(doca_comch_client_set_max_msg_size(c->client, c->max_msg_size));
	ODOS_COMCH_TRY(doca_comch_client_set_recv_queue_size(c->client, c->recv_queue_size));
	ud.ptr = c;
	ODOS_COMCH_TRY(doca_ctx_set_user_data(c->ctx, ud));

	r = doca_ctx_start(c->ctx);
	if (r != DOCA_SUCCESS && r != DOCA_ERROR_IN_PROGRESS)
		goto fail;

	/* The ctx reaches RUNNING once the server has accepted us. */
	deadline = odos_comch_now() + ODOS_COMCH_ATTEMPT_TIMEOUT;
	for (;;) {
		(void)doca_pe_progress(c->pe);
		st = odos_comch_state(c);
		if (st == DOCA_CTX_STATE_RUNNING)
			break;
		if (st == DOCA_CTX_STATE_IDLE || odos_comch_now() > deadline) {
			r = DOCA_ERROR_NOT_CONNECTED;
			goto fail;
		}
	}
	ODOS_COMCH_TRY(doca_comch_client_get_connection(c->client, &c->conn));
	return DOCA_SUCCESS;
fail:
	odos_comch_destroy(c);
	return r;
}

/*
 * Host side: connect to the server named `name`, retrying for up to
 * `timeout` seconds (-1: forever) while the DPU service is not up yet.
 * ODOS_COMCH_CONNECT_TIMEOUT overrides `timeout`.
 */
static inline doca_error_t odos_comch_client_connect(struct odos_comch *c, struct doca_dev *dev,
						     const char *name, double timeout)
{
	const char *env = getenv("ODOS_COMCH_CONNECT_TIMEOUT");
	struct timespec pause;
	double deadline;
	doca_error_t r;

	if (env != NULL && *env != '\0')
		timeout = atof(env);
	deadline = odos_comch_now() + timeout;
	pause.tv_sec = 0;
	pause.tv_nsec = 100 * 1000 * 1000;

	for (;;) {
		r = odos_comch_client_try(c, dev, name);
		if (r == DOCA_SUCCESS)
			return DOCA_SUCCESS;
		if (timeout >= 0 && odos_comch_now() > deadline)
			return r;
		nanosleep(&pause, NULL);
	}
}

/* Send one message of at most max_msg_size bytes. */
static inline doca_error_t odos_comch_send(struct odos_comch *c, const void *buf, size_t len)
{
	struct doca_comch_task_send *task;
	struct doca_task *t;
	union doca_data ud;
	uint32_t i, slot = 0;
	doca_error_t r;

	if (len > c->max_msg_size)
		return DOCA_ERROR_INVALID_VALUE;

	/* Server side: nobody to send to until a client has connected. */
	while (c->conn == NULL) {
		if (c->err != DOCA_SUCCESS)
			return c->err;
		if (c->disconnected || c->ctx == NULL)
			return DOCA_ERROR_NOT_CONNECTED;
		(void)doca_pe_progress(c->pe);
	}

	for (;;) {
		for (i = 0; i < c->nslots; ++i) {
			slot = (c->next_slot + i) % c->nslots;
			if (!c->slot_busy[slot])
				break;
		}
		if (i < c->nslots)
			break;
		if (c->err != DOCA_SUCCESS)
			return c->err;
		(void)doca_pe_progress(c->pe);
	}
	c->next_slot = (slot + 1) % c->nslots;
	memcpy(c->slot_buf + (size_t)slot * c->max_msg_size, buf, len);

	for (;;) {
		if (c->server != NULL)
			r = doca_comch_server_task_send_alloc_init(c->server, c->conn,
								   c->slot_buf + (size_t)slot * c->max_msg_size,
								   (uint32_t)len, &task);
		else
			r = doca_comch_client_task_send_alloc_init(c->client, c->conn,
								   c->slot_buf + (size_t)slot * c->max_msg_size,
								   (uint32_t)len, &task);
		if (r != DOCA_ERROR_NO_MEMORY)
			break;
		(void)doca_pe_progress(c->pe);
	}
	if (r != DOCA_SUCCESS)
		return r;

	t = doca_comch_task_send_as_task(task);
	ud.u64 = slot;
	doca_task_set_user_data(t, ud);
	c->slot_busy[slot] = 1;
	c->inflight++;

	r = doca_task_submit(t);
	if (r != DOCA_SUCCESS) {
		c->slot_busy[slot] = 0;
		c->inflight--;
		doca_task_free(t);
	}
	return r;
}

/*
 * Receive up to *len bytes of the next message into buf; *len is updated to
 * the number of bytes copied. Blocks until data arrives or the peer is gone.
 */
static inline doca_error_t odos_comch_recv(struct odos_comch *c, void *buf, size_t *len)
{
	struct odos_comch_msg *m;
	size_t n;

	while (c->rq_head == NULL) {
		if (c->err != DOCA_SUCCESS)
			return c->err;
		if (c->disconnected || c->ctx == NULL)
			return DOCA_ERROR_NOT_CONNECTED;
		if (c->client != NULL && odos_comch_state(c) != DOCA_CTX_STATE_RUNNING)
			return DOCA_ERROR_NOT_CONNECTED;
		(void)doca_pe_progress(c->pe);
	}

	m = c->rq_head;
	n = m->len - m->off;
	if (n > *len)
		n = *len;
	memcpy(buf, m->data + m->off, n);
	m->off += (uint32_t)n;
	if (m->off == m->len) {
		c->rq_head = m->next;
		if (c->rq_head == NULL)
			c->rq_tail = NULL;
		free(m);
	}
	*len = n;
	return DOCA_SUCCESS;
}

/* Whether `di` can act as a Comch server (DPU) or client (host). */
static inline int odos_comch_dev_supported(const struct doca_devinfo *di, int is_server)
{
	if (is_server)
		return doca_comch_cap_server_is_supported(di) == DOCA_SUCCESS;
	return doca_comch_cap_client_is_supported(di) == DOCA_SUCCESS;
}

/*
 * DPU side: open the representor the server listens on -- the network
 * representor whose PCI address is $ODOS_COMCH_REP_PCI, or else the first one
 * that is not an uplink (DOCA 3.x lists the uplink among the network reps).
 */
static inline doca_error_t odos_comch_open_rep(struct doca_dev *dev, struct doca_dev_rep **rep)
{
	const char *want = getenv("ODOS_COMCH_REP_PCI");
	struct doca_devinfo_rep **list;
	uint32_t n, i;
	uint8_t match, uplink;
	doca_error_t r;

	*rep = NULL;
	r = doca_devinfo_rep_create_list(dev, DOCA_DEVINFO_REP_FILTER_NET, &list, &n);
	if (r != DOCA_SUCCESS)
		return r;

	r = DOCA_ERROR_NOT_FOUND;
	for (i = 0; i < n; ++i) {
		match = 0;
		if (want != NULL && *want != '\0') {
			(void)doca_devinfo_rep_is_equal_pci_addr(list[i], want, &match);
		} else {
			uplink = 0;
			(void)doca_devinfo_rep_get_is_uplink_representor(list[i], &uplink);
			match = !uplink;
		}
		if (match) {
			r = doca_dev_rep_open(list[i], rep);
			break;
		}
	}
	(void)doca_devinfo_rep_destroy_list(list);
	return r;
}

/*
 * Replacement for DOCA 2.0's doca_log_global_level_set(): DOCA 3.x needs an
 * explicit backend for application logs, and limits SDK and application
 * logging separately.
 */
static inline void odos_doca_log_level_set(uint32_t level)
{
	static int have_backend;
	if (!have_backend) {
		(void)doca_log_backend_create_standard();
		have_backend = 1;
	}
	(void)doca_log_level_set_global_lower_limit(level);
	(void)doca_log_level_set_global_sdk_limit(level);
}

#undef ODOS_COMCH_TRY

#ifdef __cplusplus
}
#endif

#endif /* ODOS_COMCH_H */
