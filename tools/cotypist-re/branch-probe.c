#include <mach-o/dyld.h>
#include <mach/arm/thread_status.h>
#include <mach/mach.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>

static const uintptr_t pruneFileAddress = 0x100318238;
static uintptr_t pruneRuntimeAddress;
static int outputFD = STDERR_FILENO;

static uint64_t arrayCount(uint64_t variableAddress) {
    if (variableAddress == 0) {
        return UINT64_MAX;
    }
    uint64_t storage = *(const uint64_t *)variableAddress;
    if (storage == 0) {
        return UINT64_MAX;
    }
    return *(const uint64_t *)(storage + 0x10);
}

static void handleTrap(int signalNumber, siginfo_t *info, void *rawContext) {
    (void)signalNumber;
    (void)info;

    ucontext_t *context = rawContext;
    struct __darwin_mcontext64 *machine = context->uc_mcontext;
    if (machine->__ss.__pc != pruneRuntimeAddress) {
        signal(SIGTRAP, SIG_DFL);
        raise(SIGTRAP);
        return;
    }

    uint64_t completed = arrayCount(machine->__ss.__x[0]);
    uint64_t active = arrayCount(machine->__ss.__x[1]);
    uint64_t width = machine->__ss.__x[5];
    uint64_t metricMode = machine->__ss.__x[6] & 0xff;
    uint64_t aggregationMode = machine->__ss.__x[7] & 0xff;

    char line[256];
    int length = snprintf(
        line,
        sizeof(line),
        "COTYPIST_PRUNE k=%llu active=%llu completed=%llu"
        " metric_mode=%llu aggregation_mode=%llu\n",
        width,
        active,
        completed,
        metricMode,
        aggregationMode
    );
    if (length > 0) {
        write(outputFD, line, (size_t)length);
    }

    uint64_t stackPointer = machine->__ss.__sp - 0x70;
    uint64_t d9;
    uint64_t d8;
    memcpy(&d9, &machine->__ns.__v[9], sizeof(d9));
    memcpy(&d8, &machine->__ns.__v[8], sizeof(d8));
    *(uint64_t *)stackPointer = d9;
    *(uint64_t *)(stackPointer + 8) = d8;
    machine->__ss.__sp = stackPointer;
    machine->__ss.__pc += sizeof(uint32_t);
}

static void installHardwareBreakpoint(thread_act_t thread) {
    arm_debug_state64_t state = {0};
    mach_msg_type_number_t stateCount = ARM_DEBUG_STATE64_COUNT;
    kern_return_t readResult = thread_get_state(
        thread,
        ARM_DEBUG_STATE64,
        (thread_state_t)&state,
        &stateCount
    );
    if (readResult != KERN_SUCCESS) {
        return;
    }

    state.__bvr[0] = pruneRuntimeAddress;
    state.__bcr[0] = 0x1e5;
    thread_set_state(
        thread,
        ARM_DEBUG_STATE64,
        (thread_state_t)&state,
        ARM_DEBUG_STATE64_COUNT
    );
}

static void *monitorThreads(void *unused) {
    (void)unused;
    while (true) {
        thread_act_array_t threads;
        mach_msg_type_number_t threadCount = 0;
        kern_return_t result = task_threads(
            mach_task_self(),
            &threads,
            &threadCount
        );
        if (result == KERN_SUCCESS) {
            for (mach_msg_type_number_t index = 0; index < threadCount; index++) {
                installHardwareBreakpoint(threads[index]);
            }
            vm_deallocate(
                mach_task_self(),
                (vm_address_t)threads,
                threadCount * sizeof(thread_act_t)
            );
        }
        usleep(10 * 1000);
    }
    return NULL;
}

__attribute__((constructor))
static void installBranchProbe(void) {
    const char *outputPath = getenv("COTYPIST_BRANCH_LOG");
    if (outputPath != NULL) {
        outputFD = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (outputFD < 0) {
            outputFD = STDERR_FILENO;
        }
    }

    struct sigaction action = {0};
    action.sa_sigaction = handleTrap;
    action.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTRAP, &action, NULL);

    pruneRuntimeAddress = pruneFileAddress + _dyld_get_image_vmaddr_slide(0);
    dprintf(
        outputFD,
        "COTYPIST_PRUNE_PROBE address=0x%llx\n",
        (uint64_t)pruneRuntimeAddress
    );

    pthread_t monitor;
    if (pthread_create(&monitor, NULL, monitorThreads, NULL) == 0) {
        pthread_detach(monitor);
    }
}
