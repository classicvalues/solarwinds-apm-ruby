// Copyright (c) 2021 SolarWinds, LLC.
// All rights reserved.

#ifndef PROFILING_H
#define PROFILING_H

#include <ruby/ruby.h>
#include <ruby/debug.h>
#include <signal.h>
#include <time.h>

#include <atomic>
#include <functional>
#include <unordered_map>
#include <vector>

#include "frames.h"
#include "logging.h"
#include "oboe_api.h"

#define BUF_SIZE 2048

// these definitions are based on the assumption that there are no
// frames with VALUE == 1 or VALUE == 2 in Ruby
// profiling won't blow up if there are, because there is also a check to see
// if the stack has size == 1 when assuming what these frames refer to
#define PR_OTHER_THREAD 1
#define PR_IN_GC 2

#if !defined(AO_GETTID)
     #if defined(_WIN32)
        #define AO_GETTID GetCurrentThreadId
     #else
        #include <unistd.h>
        #include <sys/syscall.h>
        #ifdef SYS_gettid
           #define AO_GETTID syscall(SYS_gettid);
        #endif
     #endif
#endif

class Profiling {
   public:
    static const string string_job_handler, string_gc_handler, string_signal_handler, string_stop;

    static void create_sigaction();
    static void create_timer();

    static int try_catch_shutdown(std::function<int()>, const string& fun_name);
    static void profiler_job_handler(void* data);
    static void profiler_gc_handler(void* data);
    // This is used when catching an exception
    static void shut_down();

    // The following are made available to Ruby and have to return VALUE
    static VALUE profiling_run(VALUE self, VALUE rb_thread_val, VALUE interval);
    static VALUE get_interval();
    static VALUE set_interval(VALUE self, VALUE interval);
    static VALUE getTid();

   private:
    static void profiling_start(pid_t tid);

    // This is used via rb_ensure and therefore needs VALUE as a return type
    static VALUE profiling_stop(pid_t tid);

    static void process_snapshot(VALUE* frames_buffer,
                                 int num,
                                 pid_t tid,
                                 long ts);
    static void profiler_record_frames();
    static void profiler_record_gc();
    static void send_omitted(pid_t tid, long ts);
};

extern "C" void Init_profiling(void);

#endif // PROFILING_H
