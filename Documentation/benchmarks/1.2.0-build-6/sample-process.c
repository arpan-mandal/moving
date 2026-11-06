#include <inttypes.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s PID SECONDS\n", argv[0]);
        return 2;
    }
    const int pid = atoi(argv[1]);
    const int seconds = atoi(argv[2]);
    if (pid <= 0 || seconds <= 0) return 2;
    puts("elapsed_ns,cpu_ns,physical_footprint_bytes,package_idle_wakeups,interrupt_wakeups");
    const uint64_t start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    for (int i = 0; i <= seconds; i++) {
        struct rusage_info_v4 usage = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
            perror("proc_pid_rusage");
            return 1;
        }
        const uint64_t elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start;
        printf("%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
               elapsed, usage.ri_user_time + usage.ri_system_time, usage.ri_phys_footprint,
               usage.ri_pkg_idle_wkups, usage.ri_interrupt_wkups);
        fflush(stdout);
        if (i < seconds) sleep(1);
    }
}
