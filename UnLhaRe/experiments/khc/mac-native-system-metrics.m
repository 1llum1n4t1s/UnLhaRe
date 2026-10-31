#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <mach/mach.h>
#include <mach/host_info.h>
#include <mach/machine.h>
#include <stdio.h>

// 読取専用の集計値だけを返し、process一覧や電源設定を操作しない。
int main(void) {
    @autoreleasepool {
        host_cpu_load_info_data_t cpu = {0};
        mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
        mach_port_t host = mach_host_self();
        kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count);
        (void)mach_port_deallocate(mach_task_self(), host);
        if (result != KERN_SUCCESS || count != HOST_CPU_LOAD_INFO_COUNT) {
            fputs("CPU aggregate unavailable\n", stderr);
            return 1;
        }
        CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
        if (snapshot == NULL) {
            fputs("Power source unavailable\n", stderr);
            return 1;
        }
        CFStringRef source = IOPSGetProvidingPowerSourceType(snapshot);
        if (source == NULL) {
            CFRelease(snapshot);
            fputs("Power source type unavailable\n", stderr);
            return 1;
        }
        const int ac = CFEqual(source, CFSTR(kIOPSACPowerValue));
        CFRelease(snapshot);
        NSProcessInfo *info = [NSProcessInfo processInfo];
        printf("{\"schema\":1,\"cpu_ticks\":[%u,%u,%u,%u],\"logical_cpus\":%lu,"
               "\"thermal_state\":%ld,\"ac_power\":%s}\n",
               cpu.cpu_ticks[CPU_STATE_USER], cpu.cpu_ticks[CPU_STATE_SYSTEM],
               cpu.cpu_ticks[CPU_STATE_IDLE], cpu.cpu_ticks[CPU_STATE_NICE],
               (unsigned long)info.processorCount, (long)info.thermalState, ac ? "true" : "false");
    }
    return 0;
}
