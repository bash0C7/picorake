#include "picoruby.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <task.h>

#ifndef HEAP_SIZE
#define HEAP_SIZE (1024 * 6400)
#endif
static uint8_t vm_heap[HEAP_SIZE] __attribute__((aligned(8)));

static const char *const PROGRAM = "exit(Picorake::CLI.run(ARGV))";

int
main(int argc, char **argv)
{
  mrb_state *vm = NULL;
  picorb_vm_init();

  picorb_value ARGV = picorb_array_new(vm, argc > 0 ? argc - 1 : 0);
  for (int i = 1; i < argc; i++) {
    picorb_array_push(vm, ARGV, picorb_string_new(vm, argv[i], strlen(argv[i])));
  }
  picorb_define_const(vm, "ARGV", ARGV);
  picorb_gv_set(vm, "$0", picorb_string_new(vm, "picorake", 8));

  mrc_ccontext *cc = mrc_ccontext_new(vm);
  mrc_ccontext_filename(cc, "picorake");
  const uint8_t *source = (const uint8_t *)PROGRAM;
  mrc_irep *irep = mrc_load_string_cxt(cc, &source, strlen(PROGRAM));
  if (irep == NULL) {
    fprintf(stderr, "picorake: failed to compile the entry program\n");
    return EXIT_FAILURE;
  }

  mrb_value name = mrb_str_new_cstr(vm, "main");
  mrb_value task = mrc_create_task(cc, irep, name, mrb_nil_value(), mrb_obj_value(vm->top_self));
  if (mrb_nil_p(task)) {
    fprintf(stderr, "picorake: mrc_create_task failed\n");
    return EXIT_FAILURE;
  }

  int status = EXIT_SUCCESS;
  mrb_task_run(vm);
  mrb_vm_ci_env_clear(vm, vm->c->cibase);
  if (vm->exc) {
    MRB_EXC_CHECK_EXIT(vm, vm->exc);
    mrb_print_error(vm);
    status = EXIT_FAILURE;
  }
  mrb_value result = mrb_task_value(vm, task);
  if (mrb_exception_p(result)) {
    vm->exc = mrb_obj_ptr(result);
    MRB_EXC_CHECK_EXIT(vm, vm->exc);
    mrb_print_error(vm);
    status = EXIT_FAILURE;
  }
  return status;
}
