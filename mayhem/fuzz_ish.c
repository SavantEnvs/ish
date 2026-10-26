// Runs the fuzzer's file as the init program of a full iSH instance (ELF loader,
// emulator, syscall layer, procfs) whose root is a private scratch directory holding
// only that file. The guest's own exit status is not a finding, so the host exits 0.
#define _GNU_SOURCE
#include <errno.h>
#include <dirent.h>
#include <signal.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "kernel/calls.h"
#include "kernel/init.h"
#include "kernel/task.h"
#include "emu/interrupt.h"
#include "emu/tlb.h"
#include "kernel/memory.h"
#include "xX_main_Xx.h"

#define MAX_STEPS 100000

static char root[4096];

struct linux_dirent64 {
    unsigned long long d_ino;
    long long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[];
};

// Allocation-free recursive removal, so it is safe from the SIGTERM handler and the death callback.
static void remove_tree(int dirfd, int depth) {
    char buf[2048];
    long n;
    while ((n = syscall(SYS_getdents64, dirfd, buf, sizeof(buf))) > 0) {
        for (long off = 0; off < n;) {
            struct linux_dirent64 *d = (struct linux_dirent64 *) (buf + off);
            off += d->d_reclen;
            if (d->d_name[0] == '.' && (d->d_name[1] == 0 || (d->d_name[1] == '.' && d->d_name[2] == 0)))
                continue;
            if (d->d_type == DT_DIR && depth < 16) {
                int sub = openat(dirfd, d->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
                if (sub >= 0) {
                    remove_tree(sub, depth + 1);
                    close(sub);
                }
                unlinkat(dirfd, d->d_name, AT_REMOVEDIR);
            } else {
                unlinkat(dirfd, d->d_name, 0);
            }
        }
    }
}

static void cleanup_root(void) {
    int fd = open(root, O_RDONLY | O_DIRECTORY);
    if (fd >= 0) {
        remove_tree(fd, 0);
        close(fd);
    }
    rmdir(root);
}

static void guest_exited(struct task *task, int code) {
    if (task->parent != NULL)
        return;
    cleanup_root();
    _exit(0);
}

// halt_system() SIGTERMs the host process when init dies with tasks left: a normal shutdown.
static void on_sigterm(int sig) {
    cleanup_root();
    _exit(0);
}

void __sanitizer_set_death_callback(void (*callback)(void));

static int stage_input(const char *input) {
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof(root), "%s/ish-XXXXXX", tmp != NULL && *tmp != '\0' ? tmp : "/tmp");
    if (mkdtemp(root) == NULL)
        return -1;
    char path[4200];
    snprintf(path, sizeof(path), "%s/dev", root);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/proc", root);
    mkdir(path, 0755);

    snprintf(path, sizeof(path), "%s/init", root);
    int in = open(input, O_RDONLY);
    int out = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (in < 0 || out < 0)
        return -1;
    char buf[65536];
    ssize_t n;
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        if (write(out, buf, n) != n)
            return -1;
    }
    close(in);
    close(out);
    return 0;
}

int main(int argc, char *const argv[]) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <i386-elf>\n", argv[0]);
        return 2;
    }
    if (stage_input(argv[1]) < 0) {
        perror("stage_input");
        return 2;
    }
    signal(SIGTERM, on_sigterm);
    __sanitizer_set_death_callback(cleanup_root);
    char *const guest_argv[] = {argv[0], "-r", root, "/init", NULL};
    char envp[2] = {0};
    int err = xX_main_Xx(4, guest_argv, envp);
    if (err < 0) {
        guest_exited(&(struct task) {0}, 0);
        return 0;
    }
    exit_hook = guest_exited;
    create_some_device_nodes();
    do_mount(&procfs, "proc", "/proc", "", 0);

    // task_run_current() with a deterministic budget. The engine only preempts a guest loop when
    // another thread pokes it, so instead the task is single-stepped (cpu.tf) and steps are counted;
    // forked children inherit tf and die on the resulting SIGTRAP.
    struct cpu_state *cpu = &current->cpu;
    struct tlb tlb = {};
    tlb_refresh(&tlb, &current->mem->mmu);
    for (int steps = 0; steps < MAX_STEPS; steps++) {
        cpu->tf = 1;
        read_wrlock(&current->mem->lock);
        int interrupt = cpu_run_to_interrupt(cpu, &tlb);
        read_wrunlock(&current->mem->lock);
        if (interrupt != INT_DEBUG)
            handle_interrupt(interrupt);
    }
    guest_exited(&(struct task) {0}, 0);
}
