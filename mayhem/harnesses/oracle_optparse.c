/*
 * libfuse/mayhem golden oracle — known-answer tests over the FUZZED surface (lib/fuse_opt.c:
 * fuse_opt_parse and friends). libfuse's own test suite is a pytest suite that mounts a real
 * FUSE filesystem (needs /dev/fuse + CAP_SYS_ADMIN) and is NOT self-contained inside a build
 * container; this oracle instead asserts byte-exact behaviour of the exact functions the
 * fuzzer drives. It links the real libfuse3.a, so a no-op / exit(0) patch to fuse_opt.c — or
 * any change that alters parser results — fails it.
 *
 * Each TEST(...) is one CTRF "test". main() prints "ORACLE pass=<n> fail=<n>" for test.sh to
 * parse, and exits non-zero if any test failed.
 */
#define FUSE_USE_VERSION 31

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

#include <fuse_opt.h>

static int g_pass = 0, g_fail = 0;

#define CHECK(cond, name) do {                                            \
    if (cond) { g_pass++; printf("  ok   - %s\n", (name)); }              \
    else      { g_fail++; printf("  FAIL - %s\n", (name)); }              \
  } while (0)

/* ---- option spec mirroring the harness's spec ---------------------------- */
struct options {
    const char *char_opt1;
    const char *char_opt2;
    int int_opt3;
};
#define OPT(t, p) { t, offsetof(struct options, p), 1 }
static const struct fuse_opt option_spec[] = {
    OPT("--char_opt1=%s", char_opt1),
    OPT("--char_opt2=%s", char_opt2),
    OPT("-i", int_opt3),
    OPT("--intopt3", int_opt3),
    FUSE_OPT_END
};

/* collect non-options / kept args via a proc */
struct collector { int nonopt_calls; int opt_calls; char last_nonopt[256]; };
static int collect_proc(void *data, const char *arg, int key,
                        struct fuse_args *outargs) {
    (void)outargs;
    struct collector *c = data;
    if (key == FUSE_OPT_KEY_NONOPT) {
        c->nonopt_calls++;
        snprintf(c->last_nonopt, sizeof c->last_nonopt, "%s", arg ? arg : "");
    } else if (key == FUSE_OPT_KEY_OPT) {
        c->opt_calls++;
    }
    return 1; /* keep */
}

int main(void) {
    /* -- 1) string-format options set struct members ------------------------ */
    {
        struct options o = {0};
        const char *vec[] = {"prog", "--char_opt1=hello", "--char_opt2=world", NULL};
        struct fuse_args args = { 3, (char **)vec, 0 };
        int rc = fuse_opt_parse(&args, &o, option_spec, NULL);
        CHECK(rc == 0, "fuse_opt_parse returns 0 on valid --char_opt args");
        CHECK(o.char_opt1 && strcmp(o.char_opt1, "hello") == 0, "--char_opt1=hello captured");
        CHECK(o.char_opt2 && strcmp(o.char_opt2, "world") == 0, "--char_opt2=world captured");
        fuse_opt_free_args(&args);
    }

    /* -- 2) flag option sets int member to 'value' (1) ---------------------- */
    {
        struct options o = {0};
        const char *vec[] = {"prog", "-i", NULL};
        struct fuse_args args = { 2, (char **)vec, 0 };
        int rc = fuse_opt_parse(&args, &o, option_spec, NULL);
        CHECK(rc == 0, "fuse_opt_parse returns 0 for -i flag");
        CHECK(o.int_opt3 == 1, "-i sets int_opt3 to 1");
    }

    /* -- 3) non-option arg reaches the proc with KEY_NONOPT ----------------- */
    {
        struct collector c = {0};
        const char *vec[] = {"prog", "plainfile", NULL};
        struct fuse_args args = { 2, (char **)vec, 0 };
        int rc = fuse_opt_parse(&args, &c, option_spec, collect_proc);
        CHECK(rc == 0, "fuse_opt_parse returns 0 with a non-option");
        CHECK(c.nonopt_calls == 1, "exactly one NONOPT callback");
        CHECK(strcmp(c.last_nonopt, "plainfile") == 0, "NONOPT arg is 'plainfile'");
    }

    /* -- 4) fuse_opt_add_arg grows the vector ------------------------------- */
    {
        struct fuse_args args = FUSE_ARGS_INIT(0, NULL);
        CHECK(fuse_opt_add_arg(&args, "a") == 0, "add_arg 'a' ok");
        CHECK(fuse_opt_add_arg(&args, "b") == 0, "add_arg 'b' ok");
        CHECK(args.argc == 2, "argc == 2 after two adds");
        CHECK(args.argv[0] && strcmp(args.argv[0], "a") == 0, "argv[0] == 'a'");
        CHECK(args.argv[1] && strcmp(args.argv[1], "b") == 0, "argv[1] == 'b'");
        CHECK(args.argv[2] == NULL, "argv NULL-terminated");
        fuse_opt_free_args(&args);
    }

    /* -- 5) fuse_opt_insert_arg places at index ----------------------------- */
    {
        struct fuse_args args = FUSE_ARGS_INIT(0, NULL);
        fuse_opt_add_arg(&args, "x");
        fuse_opt_add_arg(&args, "z");
        CHECK(fuse_opt_insert_arg(&args, 1, "y") == 0, "insert_arg at 1 ok");
        CHECK(args.argc == 3, "argc == 3 after insert");
        CHECK(strcmp(args.argv[1], "y") == 0, "inserted 'y' at index 1");
        CHECK(strcmp(args.argv[2], "z") == 0, "'z' shifted to index 2");
        fuse_opt_free_args(&args);
    }

    /* -- 6) fuse_opt_match against the spec --------------------------------- */
    {
        CHECK(fuse_opt_match(option_spec, "-i") == 1, "match -i == 1");
        CHECK(fuse_opt_match(option_spec, "--nope") == 0, "match unknown == 0");
    }

    /* -- 7) fuse_opt_add_opt builds comma-separated list -------------------- */
    {
        char *opts = NULL;
        CHECK(fuse_opt_add_opt(&opts, "ro") == 0, "add_opt 'ro' ok");
        CHECK(fuse_opt_add_opt(&opts, "allow_other") == 0, "add_opt 'allow_other' ok");
        CHECK(opts && strcmp(opts, "ro,allow_other") == 0, "opts == 'ro,allow_other'");
        free(opts);
    }

    /* -- 8) '--' ends option processing; following args are non-options ----- */
    {
        struct collector c = {0};
        const char *vec[] = {"prog", "--", "-i", NULL};
        struct fuse_args args = { 3, (char **)vec, 0 };
        int rc = fuse_opt_parse(&args, &c, option_spec, collect_proc);
        CHECK(rc == 0, "parse with '--' separator ok");
        CHECK(c.nonopt_calls == 1, "'-i' after '--' delivered as one NONOPT");
        CHECK(strcmp(c.last_nonopt, "-i") == 0, "'-i' after '--' kept verbatim as NONOPT arg");
        fuse_opt_free_args(&args);
    }

    printf("ORACLE pass=%d fail=%d\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
