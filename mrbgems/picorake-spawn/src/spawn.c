#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/string.h>

extern char **environ;

#define ERR_MERGE 0
#define ERR_NULL 1
#define ERR_INHERIT 2

#define IO_CHUNK 65536

#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 34))
#define HAVE_ADDCLOSEFROM 1
#endif

#if defined(__APPLE__) || (defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 29)))
#define HAVE_ADDCHDIR 1
#endif

#define TERM_GRACE_MS 2000
#define FAIL_BUF_SIZE (PATH_MAX + 16)

typedef struct {
  char ***argvs;
  int n;
  const char *in_data;
  size_t in_len;
  int has_in;
  int err_mode;
  int capture;
  char *out;
  size_t out_len;
  int *statuses;
  int fail_index;
  const char *fail_op;
  const char *chdir_path;
  long long timeout_ms;
  int timed_out;
  char fail_buf[FAIL_BUF_SIZE];
} job_t;

static long long
now_ms(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void
wipe(void *p, size_t n)
{
  volatile unsigned char *v = (volatile unsigned char *)p;
  while (n-- > 0) *v++ = 0;
}

static char *
grow_buf(char *old, size_t len, size_t ncap)
{
  char *nbuf = malloc(ncap);
  if (!nbuf) return NULL;
  if (len > 0) memcpy(nbuf, old, len);
  wipe(old, len);
  free(old);
  return nbuf;
}

static int
buf_append(char **buf, size_t *len, size_t *cap, const char *data, size_t n)
{
  if (n == 0) return 0;
  if (*cap - *len < n) {
    size_t ncap = (*len + n) * 2;
    char *nbuf = grow_buf(*buf, *len, ncap);
    if (!nbuf) return ENOMEM;
    *buf = nbuf;
    *cap = ncap;
  }
  memcpy(*buf + *len, data, n);
  *len += n;
  return 0;
}

static void
close_fd(int *fd)
{
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

static int
make_pipe(int p[2])
{
  int raw[2], i;

  p[0] = p[1] = -1;
  if (pipe(raw) < 0) return errno;
  for (i = 0; i < 2; i++) {
    int fd = fcntl(raw[i], F_DUPFD_CLOEXEC, 3);
    if (fd < 0) {
      int e = errno;
      close(raw[0]);
      close(raw[1]);
      if (p[0] >= 0) close(p[0]);
      p[0] = p[1] = -1;
      return e;
    }
    p[i] = fd;
  }
  close(raw[0]);
  close(raw[1]);
  return 0;
}

static int
set_nonblock(int fd)
{
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return errno;
  if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return errno;
  return 0;
}

static int
inherit_fd(posix_spawn_file_actions_t *fa, int fd)
{
#if defined(__APPLE__)
  return posix_spawn_file_actions_addinherit_np(fa, fd);
#else
  (void)fa;
  (void)fd;
  return 0;
#endif
}

static int
build_actions(posix_spawn_file_actions_t *fa, const job_t *j, int i,
              int in_r, int cap_w, int (*links)[2])
{
  int rc;
  int last = (i == j->n - 1);
  int stdin_src = (i == 0) ? in_r : links[i - 1][0];
  int stdout_dst = last ? (j->capture ? cap_w : -1) : links[i][1];

#if defined(HAVE_ADDCHDIR)
  if (j->chdir_path) {
#if defined(__APPLE__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
    rc = posix_spawn_file_actions_addchdir_np(fa, j->chdir_path);
#if defined(__APPLE__)
#pragma clang diagnostic pop
#endif
    if (rc != 0) return rc;
  }
#endif

  switch (j->err_mode) {
  case ERR_MERGE:
    if ((rc = posix_spawn_file_actions_adddup2(fa, j->capture ? cap_w : 1, 2)) != 0) return rc;
    break;
  case ERR_NULL:
    if ((rc = posix_spawn_file_actions_addopen(fa, 2, "/dev/null", O_WRONLY, 0)) != 0) return rc;
    break;
  default:
    if ((rc = inherit_fd(fa, 2)) != 0) return rc;
    break;
  }

  if (stdout_dst >= 0) {
    if ((rc = posix_spawn_file_actions_adddup2(fa, stdout_dst, 1)) != 0) return rc;
  }
  else {
    if ((rc = inherit_fd(fa, 1)) != 0) return rc;
  }

  if (stdin_src >= 0) {
    if ((rc = posix_spawn_file_actions_adddup2(fa, stdin_src, 0)) != 0) return rc;
  }
  else {
    if ((rc = posix_spawn_file_actions_addopen(fa, 0, "/dev/null", O_RDONLY, 0)) != 0) return rc;
  }

#if defined(HAVE_ADDCLOSEFROM)
  if ((rc = posix_spawn_file_actions_addclosefrom_np(fa, 3)) != 0) return rc;
#endif
  return 0;
}

static void
reap(pid_t *pids, int started, int kill_first)
{
  int i;
  for (i = 0; i < started; i++) {
    int st;
    if (kill_first) kill(pids[i], SIGKILL);
    while (waitpid(pids[i], &st, 0) < 0 && errno == EINTR) {}
  }
}

static void
terminate_children(pid_t *pids, int count)
{
  long long start = now_ms();
  int i, alive;

  for (i = 0; i < count; i++) kill(pids[i], SIGTERM);
  for (;;) {
    alive = 0;
    for (i = 0; i < count; i++) {
      int st;
      pid_t w;
      if (pids[i] < 0) continue;
      w = waitpid(pids[i], &st, WNOHANG);
      if (w == pids[i] || (w < 0 && errno != EINTR)) pids[i] = -1;
      else alive++;
    }
    if (alive == 0) return;
    if (now_ms() - start >= TERM_GRACE_MS) break;
    poll(NULL, 0, 5);
  }
  for (i = 0; i < count; i++) {
    int st;
    if (pids[i] < 0) continue;
    kill(pids[i], SIGKILL);
    while (waitpid(pids[i], &st, 0) < 0 && errno == EINTR) {}
  }
}

static int
remaining_ms(const job_t *j, long long start)
{
  long long rem = j->timeout_ms - (now_ms() - start);
  if (rem <= 0) return 0;
  if (rem > INT_MAX) return INT_MAX;
  return (int)rem;
}

static int
job_run(job_t *j)
{
  int n = j->n, i, rc = 0, started = 0, failed = 0;
  int in_r = -1, in_w = -1, cap_r = -1, cap_w = -1;
  int (*links)[2];
  pid_t *pids;
  posix_spawnattr_t attr;
  int attr_ok = 0;
  struct sigaction ign, dfl, old, old_chld;
  int sig_saved = 0, chld_saved = 0, first_unreaped = 0;
  char *buf = NULL;
  size_t cap = 0, len = 0, off = 0;
  short flags;
  long long start_ms = 0;

  j->fail_index = -1;
  j->fail_op = NULL;
  j->out = NULL;
  j->out_len = 0;
  j->timed_out = 0;

  if (j->chdir_path) {
    struct stat sb;
    if (stat(j->chdir_path, &sb) < 0) rc = errno;
    else if (!S_ISDIR(sb.st_mode)) rc = ENOTDIR;
    if (rc != 0) {
      j->fail_index = 0;
      snprintf(j->fail_buf, sizeof(j->fail_buf), "chdir %s", j->chdir_path);
      j->fail_op = j->fail_buf;
      return rc;
    }
  }

  links = malloc(sizeof(int[2]) * (size_t)n);
  pids = malloc(sizeof(pid_t) * (size_t)n);
  if (!links || !pids) {
    free(links);
    free(pids);
    return ENOMEM;
  }
  for (i = 0; i < n; i++) links[i][0] = links[i][1] = -1;

  memset(&ign, 0, sizeof(ign));
  ign.sa_handler = SIG_IGN;
  sigemptyset(&ign.sa_mask);
  if (sigaction(SIGPIPE, &ign, &old) == 0) sig_saved = 1;
  memset(&dfl, 0, sizeof(dfl));
  dfl.sa_handler = SIG_DFL;
  sigemptyset(&dfl.sa_mask);
  if (sigaction(SIGCHLD, &dfl, &old_chld) == 0) chld_saved = 1;

  for (i = 0; i < n - 1 && !rc; i++) rc = make_pipe(links[i]);
  if (!rc && j->has_in) {
    int p[2];
    if ((rc = make_pipe(p)) == 0) {
      in_r = p[0];
      in_w = p[1];
    }
  }
  if (!rc && j->capture) {
    int p[2];
    if ((rc = make_pipe(p)) == 0) {
      cap_r = p[0];
      cap_w = p[1];
    }
  }

  if (!rc) {
    rc = posix_spawnattr_init(&attr);
    if (rc == 0) attr_ok = 1;
  }
  if (!rc) {
    sigset_t mask, def;
    sigemptyset(&mask);
    sigemptyset(&def);
    sigaddset(&def, SIGPIPE);
    flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if ((rc = posix_spawnattr_setflags(&attr, flags)) == 0 &&
        (rc = posix_spawnattr_setsigmask(&attr, &mask)) == 0) {
      rc = posix_spawnattr_setsigdefault(&attr, &def);
    }
  }

  start_ms = now_ms();
  for (i = 0; i < n && !rc; i++) {
    posix_spawn_file_actions_t fa;
    if ((rc = posix_spawn_file_actions_init(&fa)) != 0) break;
    rc = build_actions(&fa, j, i, in_r, cap_w, links);
    if (rc == 0) rc = posix_spawnp(&pids[i], j->argvs[i][0], &fa, &attr, j->argvs[i], environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) {
      j->fail_index = i;
      break;
    }
    started++;
    if (i == 0) close_fd(&in_r);
    if (i > 0) close_fd(&links[i - 1][0]);
    if (i < n - 1) close_fd(&links[i][1]);
  }
  if (rc) {
    failed = 1;
    goto cleanup;
  }

  close_fd(&cap_w);
  close_fd(&in_r);

  if (in_w >= 0 && j->in_len == 0) close_fd(&in_w);
  if (in_w >= 0 && (rc = set_nonblock(in_w)) != 0) {
    failed = 1;
    goto cleanup;
  }

  while (in_w >= 0 || cap_r >= 0) {
    struct pollfd p[2];
    int nfds = 0, wi = -1, ri = -1, pr, pto;

    if (in_w >= 0) {
      p[nfds].fd = in_w;
      p[nfds].events = POLLOUT;
      p[nfds].revents = 0;
      wi = nfds++;
    }
    if (cap_r >= 0) {
      p[nfds].fd = cap_r;
      p[nfds].events = POLLIN;
      p[nfds].revents = 0;
      ri = nfds++;
    }
    pto = -1;
    if (j->timeout_ms > 0) {
      pto = remaining_ms(j, start_ms);
      if (pto == 0) {
        j->timed_out = 1;
        rc = ETIMEDOUT;
        failed = 1;
        goto cleanup;
      }
    }
    pr = poll(p, (nfds_t)nfds, pto);
    if (pr < 0) {
      if (errno == EINTR) continue;
      rc = errno;
      failed = 1;
      goto cleanup;
    }

    if (wi >= 0 && p[wi].revents) {
      if (p[wi].revents & POLLOUT) {
        size_t want = j->in_len - off;
        ssize_t w;
        if (want > IO_CHUNK) want = IO_CHUNK;
        w = write(in_w, j->in_data + off, want);
        if (w < 0) {
          if (errno == EPIPE) close_fd(&in_w);
          else if (errno != EAGAIN && errno != EINTR) {
            rc = errno;
            failed = 1;
            goto cleanup;
          }
        }
        else {
          off += (size_t)w;
          if (off == j->in_len) close_fd(&in_w);
        }
      }
      else {
        close_fd(&in_w);
      }
    }

    if (ri >= 0 && p[ri].revents) {
      ssize_t r;
      if (cap - len < IO_CHUNK) {
        size_t ncap = cap ? cap * 2 : IO_CHUNK * 2;
        char *nbuf = grow_buf(buf, len, ncap);
        if (!nbuf) {
          rc = ENOMEM;
          failed = 1;
          goto cleanup;
        }
        buf = nbuf;
        cap = ncap;
      }
      r = read(cap_r, buf + len, cap - len);
      if (r < 0) {
        if (errno != EINTR && errno != EAGAIN) {
          rc = errno;
          failed = 1;
          goto cleanup;
        }
      }
      else if (r == 0) {
        close_fd(&cap_r);
      }
      else {
        len += (size_t)r;
      }
    }
  }

  for (i = 0; i < n; i++) {
    int st = 0;
    first_unreaped = i;
    for (;;) {
      pid_t w = waitpid(pids[i], &st, j->timeout_ms > 0 ? WNOHANG : 0);
      int rem;
      if (w == pids[i]) break;
      if (w < 0) {
        if (errno == EINTR) continue;
        rc = errno;
        failed = 1;
        j->fail_index = i;
        j->fail_op = "waitpid";
        goto cleanup;
      }
      rem = remaining_ms(j, start_ms);
      if (rem == 0) {
        j->timed_out = 1;
        rc = ETIMEDOUT;
        failed = 1;
        goto cleanup;
      }
      poll(NULL, 0, rem < 5 ? rem : 5);
    }
    first_unreaped = i + 1;
    if (WIFEXITED(st)) j->statuses[i] = WEXITSTATUS(st);
    else if (WIFSIGNALED(st)) j->statuses[i] = 128 + WTERMSIG(st);
    else j->statuses[i] = st;
  }
  started = 0;

cleanup:
  close_fd(&in_r);
  close_fd(&in_w);
  close_fd(&cap_r);
  close_fd(&cap_w);
  for (i = 0; i < n; i++) {
    close_fd(&links[i][0]);
    close_fd(&links[i][1]);
  }
  if (failed && j->timed_out) terminate_children(pids + first_unreaped, started - first_unreaped);
  else if (failed) reap(pids + first_unreaped, started - first_unreaped, 1);
  if (attr_ok) posix_spawnattr_destroy(&attr);
  if (chld_saved) sigaction(SIGCHLD, &old_chld, NULL);
  if (sig_saved) sigaction(SIGPIPE, &old, NULL);
  free(links);
  free(pids);
  if (failed) {
    wipe(buf, len);
    free(buf);
    return rc;
  }
  j->out = buf;
  j->out_len = len;
  return 0;
}

static void
free_argvs(char ***argvs, int n)
{
  int i;
  if (!argvs) return;
  for (i = 0; i < n; i++) free(argvs[i]);
  free(argvs);
}


static void
validate_pipeline(mrb_state *mrb, mrb_value argvs_v)
{
  mrb_int n = RARRAY_LEN(argvs_v), i, k;

  if (n < 1) mrb_raise(mrb, E_ARGUMENT_ERROR, "argv must not be empty");
  for (i = 0; i < n; i++) {
    mrb_value av = mrb_ary_ref(mrb, argvs_v, i);
    mrb_int an;
    if (!mrb_array_p(av)) mrb_raise(mrb, E_ARGUMENT_ERROR, "argv must be an Array");
    an = RARRAY_LEN(av);
    if (an < 1) mrb_raise(mrb, E_ARGUMENT_ERROR, "argv must not be empty");
    for (k = 0; k < an; k++) {
      mrb_value s = mrb_ary_ref(mrb, av, k);
      if (!mrb_string_p(s)) mrb_raise(mrb, E_ARGUMENT_ERROR, "argv must contain only Strings");
      mrb_string_value_cstr(mrb, &s);
    }
  }
}

static char ***
build_argvs(mrb_state *mrb, mrb_value argvs_v)
{
  mrb_int n = RARRAY_LEN(argvs_v), i, k;
  char ***argvs = calloc((size_t)n, sizeof(char **));

  if (!argvs) return NULL;
  for (i = 0; i < n; i++) {
    mrb_value av = mrb_ary_ref(mrb, argvs_v, i);
    mrb_int an = RARRAY_LEN(av);
    argvs[i] = malloc(sizeof(char *) * (size_t)(an + 1));
    if (!argvs[i]) {
      free_argvs(argvs, (int)n);
      return NULL;
    }
    for (k = 0; k < an; k++) {
      mrb_value s = mrb_ary_ref(mrb, av, k);
      argvs[i][k] = (char *)RSTRING_PTR(s);
    }
    argvs[i][an] = NULL;
  }
  return argvs;
}

static void
raise_spawn_error(mrb_state *mrb, int rc, int fail_index, const char *op, mrb_value argvs_v)
{
  struct RClass *spawn_mod = mrb_module_get_under(mrb, mrb_module_get(mrb, "Picorake"), "Spawn");
  struct RClass *error_class = mrb_class_get_under(mrb, spawn_mod, "Error");

  if (fail_index >= 0) {
    mrb_value av = mrb_ary_ref(mrb, argvs_v, fail_index);
    mrb_value cmd = mrb_ary_ref(mrb, av, 0);
    if (op) mrb_raisef(mrb, error_class, "%v: %s: %s", cmd, op, strerror(rc));
    mrb_raisef(mrb, error_class, "%v: %s", cmd, strerror(rc));
  }
  mrb_raisef(mrb, error_class, "%s", strerror(rc));
}

static void
raise_timeout(mrb_state *mrb, long long timeout_ms, mrb_value argvs_v)
{
  struct RClass *spawn_mod = mrb_module_get_under(mrb, mrb_module_get(mrb, "Picorake"), "Spawn");
  struct RClass *timeout_class = mrb_class_get_under(mrb, spawn_mod, "TimeoutError");
  mrb_value cmd = mrb_ary_ref(mrb, mrb_ary_ref(mrb, argvs_v, 0), 0);

  mrb_raisef(mrb, timeout_class, "%v: timed out after %v ms", cmd, mrb_fixnum_value((mrb_int)timeout_ms));
}

static mrb_value
exec_result(mrb_state *mrb, job_t *job, int rc, mrb_value argvs_v)
{
  mrb_int n = job->n, i;
  mrb_value result, statuses;

  if (rc != 0) {
    if (job->timed_out) {
      long long timeout_ms = job->timeout_ms;
      free(job->statuses);
      raise_timeout(mrb, timeout_ms, argvs_v);
    }
    int fail_index = job->fail_index;
    const char *op = job->fail_op;
    free(job->statuses);
    raise_spawn_error(mrb, rc, fail_index, op, argvs_v);
  }

  statuses = mrb_ary_new_capa(mrb, n);
  for (i = 0; i < n; i++) mrb_ary_push(mrb, statuses, mrb_fixnum_value(job->statuses[i]));
  free(job->statuses);

  result = mrb_ary_new_capa(mrb, 2);
  if (job->capture) {
    mrb_value out = mrb_str_new(mrb, job->out ? job->out : "", (mrb_int)job->out_len);
    free(job->out);
    mrb_ary_push(mrb, result, out);
  }
  else {
    free(job->out);
    mrb_ary_push(mrb, result, mrb_nil_value());
  }
  mrb_ary_push(mrb, result, statuses);
  return result;
}

static void
set_job_options(mrb_state *mrb, job_t *job, mrb_value chdir_v, mrb_int timeout_ms)
{
  if (!mrb_nil_p(chdir_v)) {
    if (!mrb_string_p(chdir_v)) mrb_raise(mrb, E_ARGUMENT_ERROR, "chdir must be a String");
#if !defined(HAVE_ADDCHDIR)
    mrb_raise(mrb, E_NOTIMP_ERROR, "chdir is not supported on this platform");
#endif
    job->chdir_path = mrb_string_value_cstr(mrb, &chdir_v);
  }
  if (timeout_ms < 0) mrb_raise(mrb, E_ARGUMENT_ERROR, "timeout_ms must be positive");
  job->timeout_ms = (long long)timeout_ms;
}

static mrb_value
spawn_exec(mrb_state *mrb, mrb_value self)
{
  mrb_value argvs_v, stdin_v, chdir_v;
  mrb_int err_mode, capture, n, timeout_ms;
  job_t job;
  char ***argvs;
  int rc;

  mrb_get_args(mrb, "Aoiioi", &argvs_v, &stdin_v, &err_mode, &capture, &chdir_v, &timeout_ms);

  n = RARRAY_LEN(argvs_v);
  if (n < 1) mrb_raise(mrb, E_ARGUMENT_ERROR, "argv must not be empty");
  if (err_mode < ERR_MERGE || err_mode > ERR_INHERIT) mrb_raise(mrb, E_ARGUMENT_ERROR, "invalid err mode");
  validate_pipeline(mrb, argvs_v);

  memset(&job, 0, sizeof(job));
  if (mrb_nil_p(stdin_v)) {
    job.has_in = 0;
  }
  else if (mrb_string_p(stdin_v)) {
    job.has_in = 1;
    job.in_data = RSTRING_PTR(stdin_v);
    job.in_len = (size_t)RSTRING_LEN(stdin_v);
  }
  else {
    mrb_raise(mrb, E_ARGUMENT_ERROR, "stdin must be a String or nil");
  }
  set_job_options(mrb, &job, chdir_v, timeout_ms);

  argvs = build_argvs(mrb, argvs_v);
  job.statuses = calloc((size_t)n, sizeof(int));
  if (!argvs || !job.statuses) {
    free_argvs(argvs, (int)n);
    free(job.statuses);
    mrb_raise(mrb, E_RUNTIME_ERROR, "out of memory");
  }

  job.argvs = argvs;
  job.n = (int)n;
  job.err_mode = (int)err_mode;
  job.capture = capture ? 1 : 0;

  rc = job_run(&job);
  free_argvs(argvs, (int)n);
  return exec_result(mrb, &job, rc, argvs_v);
}

typedef struct {
  char ***argvs;
  int n;
} feeder_t;

static void
free_feeders(feeder_t *feeders, mrb_int nf)
{
  mrb_int i;
  if (!feeders) return;
  for (i = 0; i < nf; i++) free_argvs(feeders[i].argvs, feeders[i].n);
  free(feeders);
}

static mrb_value
spawn_exec_feed(mrb_state *mrb, mrb_value self)
{
  mrb_value argvs_v, feeders_v, chdir_v, result;
  mrb_int err_mode, capture, n, nf, i, k, timeout_ms;
  job_t job;
  feeder_t *feeders;
  char ***argvs;
  char *buf = NULL;
  size_t blen = 0, bcap = 0;
  int rc = 0, spawn_feeder = -1, spawn_index = -1, feed_index = -1, feed_stage = -1, feed_status = 0;
  const char *spawn_op = NULL;

  mrb_get_args(mrb, "AAiioi", &argvs_v, &feeders_v, &err_mode, &capture, &chdir_v, &timeout_ms);

  n = RARRAY_LEN(argvs_v);
  nf = RARRAY_LEN(feeders_v);
  if (err_mode < ERR_MERGE || err_mode > ERR_INHERIT) mrb_raise(mrb, E_ARGUMENT_ERROR, "invalid err mode");
  validate_pipeline(mrb, argvs_v);
  memset(&job, 0, sizeof(job));
  set_job_options(mrb, &job, chdir_v, timeout_ms);
  for (i = 0; i < nf; i++) {
    mrb_value fv = mrb_ary_ref(mrb, feeders_v, i);
    if (!mrb_array_p(fv)) mrb_raise(mrb, E_ARGUMENT_ERROR, "stdin_from must be an Array of pipelines");
    validate_pipeline(mrb, fv);
  }

  feeders = calloc((size_t)(nf > 0 ? nf : 1), sizeof(feeder_t));
  argvs = build_argvs(mrb, argvs_v);
  if (!feeders || !argvs) {
    free(feeders);
    free_argvs(argvs, (int)n);
    mrb_raise(mrb, E_RUNTIME_ERROR, "out of memory");
  }
  for (i = 0; i < nf; i++) {
    mrb_value fv = mrb_ary_ref(mrb, feeders_v, i);
    feeders[i].n = (int)RARRAY_LEN(fv);
    feeders[i].argvs = build_argvs(mrb, fv);
    if (!feeders[i].argvs) {
      free_feeders(feeders, nf);
      free_argvs(argvs, (int)n);
      mrb_raise(mrb, E_RUNTIME_ERROR, "out of memory");
    }
  }

  for (i = 0; i < nf && rc == 0 && feed_status == 0; i++) {
    job_t fj;
    memset(&fj, 0, sizeof(fj));
    fj.argvs = feeders[i].argvs;
    fj.n = feeders[i].n;
    fj.err_mode = ERR_NULL;
    fj.capture = 1;
    fj.statuses = calloc((size_t)fj.n, sizeof(int));
    if (!fj.statuses) {
      rc = ENOMEM;
      break;
    }
    rc = job_run(&fj);
    if (rc != 0) {
      spawn_feeder = (int)i;
      spawn_index = fj.fail_index;
      spawn_op = fj.fail_op;
    }
    else {
      for (k = 0; k < fj.n; k++) {
        if (fj.statuses[k] != 0) {
          feed_index = (int)i;
          feed_stage = (int)k;
          feed_status = fj.statuses[k];
          break;
        }
      }
      if (feed_status == 0) rc = buf_append(&buf, &blen, &bcap, fj.out, fj.out_len);
      wipe(fj.out, fj.out_len);
      free(fj.out);
    }
    free(fj.statuses);
  }
  free_feeders(feeders, nf);

  if (rc != 0) {
    wipe(buf, blen);
    free(buf);
    free_argvs(argvs, (int)n);
    if (spawn_feeder >= 0) raise_spawn_error(mrb, rc, spawn_index, spawn_op, mrb_ary_ref(mrb, feeders_v, spawn_feeder));
    raise_spawn_error(mrb, rc, -1, NULL, argvs_v);
  }
  if (feed_status != 0) {
    wipe(buf, blen);
    free(buf);
    free_argvs(argvs, (int)n);
    result = mrb_ary_new_capa(mrb, 3);
    mrb_ary_push(mrb, result, mrb_nil_value());
    mrb_ary_push(mrb, result, mrb_nil_value());
    mrb_ary_push(mrb, result, mrb_ary_new_from_values(mrb, 3, (mrb_value[]){mrb_fixnum_value(feed_index), mrb_fixnum_value(feed_status), mrb_fixnum_value(feed_stage)}));
    return result;
  }

  job.has_in = 1;
  job.in_data = buf;
  job.in_len = blen;
  job.argvs = argvs;
  job.n = (int)n;
  job.err_mode = (int)err_mode;
  job.capture = capture ? 1 : 0;
  job.statuses = calloc((size_t)n, sizeof(int));
  if (!job.statuses) {
    wipe(buf, blen);
    free(buf);
    free_argvs(argvs, (int)n);
    mrb_raise(mrb, E_RUNTIME_ERROR, "out of memory");
  }

  rc = job_run(&job);
  wipe(buf, blen);
  free(buf);
  free_argvs(argvs, (int)n);
  return exec_result(mrb, &job, rc, argvs_v);
}

void
mrb_picorake_spawn_gem_init(mrb_state *mrb)
{
  struct RClass *picorake = mrb_define_module(mrb, "Picorake");
  struct RClass *spawn = mrb_define_module_under(mrb, picorake, "Spawn");
  struct RClass *error_class = mrb_define_class_under(mrb, spawn, "Error", E_STANDARD_ERROR);
  mrb_define_class_under(mrb, spawn, "TimeoutError", error_class);
  mrb_define_module_function(mrb, spawn, "_exec", spawn_exec, MRB_ARGS_REQ(6));
  mrb_define_module_function(mrb, spawn, "_exec_feed", spawn_exec_feed, MRB_ARGS_REQ(6));
}

void
mrb_picorake_spawn_gem_final(mrb_state *mrb)
{
}
