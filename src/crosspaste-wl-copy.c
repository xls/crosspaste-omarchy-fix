// crosspaste-wl-copy: put stdin on the Wayland clipboard as text, marked so
// CrossPaste does not record it.
//
// Like `wl-copy`, but the selection also offers application/x-crosspaste-origin,
// the MIME type CrossPaste tags its own clipboard writes with. CrossPaste's
// Wayland monitor skips any selection offering that type, so text that
// crosspaste-path-sync writes for a paste CrossPaste already has is not captured
// again as a new local paste and synced back to the device it came from.
//
// Uses ext-data-control-v1, so it works without a focused surface. Forks into
// the background and serves the selection until another client replaces it.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

#include "ext-data-control-v1-client-protocol.h"

#define ORIGIN_MIME "application/x-crosspaste-origin"

static const char *const text_mimes[] = {
  "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT",
};

static struct wl_seat *seat;
static struct ext_data_control_manager_v1 *manager;
static char *data;
static size_t data_len;
static int running = 1;

static void die(const char *msg) {
  fprintf(stderr, "crosspaste-wl-copy: %s\n", msg);
  exit(1);
}

static void read_stdin(void) {
  size_t cap = 4096;
  data = malloc(cap);
  if (!data) die("out of memory");
  for (;;) {
    if (data_len == cap) {
      cap *= 2;
      data = realloc(data, cap);
      if (!data) die("out of memory");
    }
    ssize_t n = read(STDIN_FILENO, data + data_len, cap - data_len);
    if (n == 0) break;
    if (n < 0) {
      if (errno == EINTR) continue;
      die("reading stdin failed");
    }
    data_len += n;
  }
}

static void registry_global(void *d, struct wl_registry *reg, uint32_t name,
                            const char *iface, uint32_t version) {
  (void)d;
  if (!seat && strcmp(iface, wl_seat_interface.name) == 0)
    seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
  else if (strcmp(iface, ext_data_control_manager_v1_interface.name) == 0)
    manager = wl_registry_bind(reg, name, &ext_data_control_manager_v1_interface, 1);
  (void)version;
}

static void registry_global_remove(void *d, struct wl_registry *reg, uint32_t name) {
  (void)d; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
  .global = registry_global,
  .global_remove = registry_global_remove,
};

static void source_send(void *d, struct ext_data_control_source_v1 *src,
                        const char *mime, int32_t fd) {
  (void)d; (void)src;
  // The origin marker only needs to be listed; answer it with nothing.
  if (strcmp(mime, ORIGIN_MIME) != 0) {
    size_t off = 0;
    while (off < data_len) {
      ssize_t n = write(fd, data + off, data_len - off);
      if (n < 0) {
        if (errno == EINTR) continue;
        break;
      }
      off += n;
    }
  }
  close(fd);
}

static void source_cancelled(void *d, struct ext_data_control_source_v1 *src) {
  (void)d; (void)src;
  running = 0;
}

static const struct ext_data_control_source_v1_listener source_listener = {
  .send = source_send,
  .cancelled = source_cancelled,
};

// The device reports every selection change, including ours; we only need to
// release the offers it hands us.
static void device_data_offer(void *d, struct ext_data_control_device_v1 *dev,
                              struct ext_data_control_offer_v1 *offer) {
  (void)d; (void)dev; (void)offer;
}

static void device_selection(void *d, struct ext_data_control_device_v1 *dev,
                             struct ext_data_control_offer_v1 *offer) {
  (void)d; (void)dev;
  if (offer) ext_data_control_offer_v1_destroy(offer);
}

static void device_finished(void *d, struct ext_data_control_device_v1 *dev) {
  (void)d; (void)dev;
  running = 0;
}

static const struct ext_data_control_device_v1_listener device_listener = {
  .data_offer = device_data_offer,
  .selection = device_selection,
  .finished = device_finished,
  .primary_selection = device_selection,
};

int main(void) {
  read_stdin();

  struct wl_display *display = wl_display_connect(NULL);
  if (!display) die("cannot connect to the Wayland display");

  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!seat) die("no wl_seat");
  if (!manager) die("compositor lacks ext-data-control-v1");

  struct ext_data_control_device_v1 *device =
      ext_data_control_manager_v1_get_data_device(manager, seat);
  ext_data_control_device_v1_add_listener(device, &device_listener, NULL);

  struct ext_data_control_source_v1 *source =
      ext_data_control_manager_v1_create_data_source(manager);
  ext_data_control_source_v1_add_listener(source, &source_listener, NULL);
  for (size_t i = 0; i < sizeof text_mimes / sizeof *text_mimes; i++)
    ext_data_control_source_v1_offer(source, text_mimes[i]);
  ext_data_control_source_v1_offer(source, ORIGIN_MIME);

  ext_data_control_device_v1_set_selection(device, source);
  if (wl_display_roundtrip(display) < 0) die("setting the selection failed");

  // Return to the caller like wl-copy does; the child keeps serving pastes.
  signal(SIGPIPE, SIG_IGN);
  pid_t pid = fork();
  if (pid < 0) die("fork failed");
  if (pid > 0) _exit(0);
  setsid();
  int null = open("/dev/null", O_RDWR);
  if (null >= 0) {
    dup2(null, STDIN_FILENO);
    dup2(null, STDOUT_FILENO);
    dup2(null, STDERR_FILENO);
    if (null > STDERR_FILENO) close(null);
  }

  while (running && wl_display_dispatch(display) >= 0) {}

  ext_data_control_source_v1_destroy(source);
  ext_data_control_device_v1_destroy(device);
  wl_display_disconnect(display);
  return 0;
}
