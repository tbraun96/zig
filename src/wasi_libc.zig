const std = @import("std");
const mem = std.mem;
const path = std.fs.path;

const Allocator = std.mem.Allocator;
const Compilation = @import("Compilation.zig");
const build_options = @import("build_options");
const target_util = @import("target.zig");
const musl = @import("musl.zig");

pub const CRTFile = enum {
    crt1_reactor_o,
    crt1_command_o,
    libc_a,
    libwasi_emulated_process_clocks_a,
    libwasi_emulated_getpid_a,
    libwasi_emulated_mman_a,
    libwasi_emulated_signal_a,
};

pub fn getEmulatedLibCRTFile(lib_name: []const u8) ?CRTFile {
    if (mem.eql(u8, lib_name, "wasi-emulated-process-clocks")) {
        return .libwasi_emulated_process_clocks_a;
    }
    if (mem.eql(u8, lib_name, "wasi-emulated-getpid")) {
        return .libwasi_emulated_getpid_a;
    }
    if (mem.eql(u8, lib_name, "wasi-emulated-mman")) {
        return .libwasi_emulated_mman_a;
    }
    if (mem.eql(u8, lib_name, "wasi-emulated-signal")) {
        return .libwasi_emulated_signal_a;
    }
    return null;
}

pub fn emulatedLibCRFileLibName(crt_file: CRTFile) []const u8 {
    return switch (crt_file) {
        .libwasi_emulated_process_clocks_a => "libwasi-emulated-process-clocks.a",
        .libwasi_emulated_getpid_a => "libwasi-emulated-getpid.a",
        .libwasi_emulated_mman_a => "libwasi-emulated-mman.a",
        .libwasi_emulated_signal_a => "libwasi-emulated-signal.a",
        else => unreachable,
    };
}

pub fn execModelCrtFile(wasi_exec_model: std.builtin.WasiExecModel) CRTFile {
    return switch (wasi_exec_model) {
        .reactor => CRTFile.crt1_reactor_o,
        .command => CRTFile.crt1_command_o,
    };
}

pub fn execModelCrtFileFullName(wasi_exec_model: std.builtin.WasiExecModel) []const u8 {
    return switch (execModelCrtFile(wasi_exec_model)) {
        .crt1_reactor_o => "crt1-reactor.o",
        .crt1_command_o => "crt1-command.o",
        else => unreachable,
    };
}

pub fn buildCRTFile(comp: *Compilation, crt_file: CRTFile) !void {
    if (!build_options.have_llvm) {
        return error.ZigCompilerNotBuiltWithLLVMExtensions;
    }

    const gpa = comp.gpa;
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    switch (crt_file) {
        .crt1_reactor_o => {
            var args = std.ArrayList([]const u8).init(arena);
            try addCCArgs(comp, arena, &args, false);
            try addLibcBottomHalfIncludes(comp, arena, &args);
            return comp.build_crt_file("crt1-reactor", .Obj, &[1]Compilation.CSourceFile{
                .{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", try sanitize(arena, crt1_reactor_src_file),
                    }),
                    .extra_flags = args.items,
                },
            });
        },
        .crt1_command_o => {
            var args = std.ArrayList([]const u8).init(arena);
            try addCCArgs(comp, arena, &args, false);
            try addLibcBottomHalfIncludes(comp, arena, &args);
            return comp.build_crt_file("crt1-command", .Obj, &[1]Compilation.CSourceFile{
                .{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", try sanitize(arena, crt1_command_src_file),
                    }),
                    .extra_flags = args.items,
                },
            });
        },
        .libc_a => {
            var libc_sources = std.ArrayList(Compilation.CSourceFile).init(arena);

            {
                // Compile emmalloc.
                var args = std.ArrayList([]const u8).init(arena);
                try addCCArgs(comp, arena, &args, true);
                for (emmalloc_src_files) |file_path| {
                    try libc_sources.append(.{
                        .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                            "libc", try sanitize(arena, file_path),
                        }),
                        .extra_flags = args.items,
                    });
                }
            }

            {
                // Compile libc-bottom-half.
                var args = std.ArrayList([]const u8).init(arena);
                try addCCArgs(comp, arena, &args, true);
                try addLibcBottomHalfIncludes(comp, arena, &args);

                for (libc_bottom_half_src_files) |file_path| {
                    try libc_sources.append(.{
                        .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                            "libc", try sanitize(arena, file_path),
                        }),
                        .extra_flags = args.items,
                    });
                }
            }

            {
                // Compile libc-top-half.
                var args = std.ArrayList([]const u8).init(arena);
                try addCCArgs(comp, arena, &args, true);
                try addLibcTopHalfIncludes(comp, arena, &args);

                for (libc_top_half_src_files) |file_path| {
                    try libc_sources.append(.{
                        .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                            "libc", try sanitize(arena, file_path),
                        }),
                        .extra_flags = args.items,
                    });
                }
            }

            try comp.build_crt_file("c", .Lib, libc_sources.items);
        },
        .libwasi_emulated_process_clocks_a => {
            var args = std.ArrayList([]const u8).init(arena);
            try addCCArgs(comp, arena, &args, true);
            try addLibcBottomHalfIncludes(comp, arena, &args);

            var emu_clocks_sources = std.ArrayList(Compilation.CSourceFile).init(arena);
            for (emulated_process_clocks_src_files) |file_path| {
                try emu_clocks_sources.append(.{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", try sanitize(arena, file_path),
                    }),
                    .extra_flags = args.items,
                });
            }
            try comp.build_crt_file("wasi-emulated-process-clocks", .Lib, emu_clocks_sources.items);
        },
        .libwasi_emulated_getpid_a => {
            var args = std.ArrayList([]const u8).init(arena);
            try addCCArgs(comp, arena, &args, true);
            try addLibcBottomHalfIncludes(comp, arena, &args);

            var emu_getpid_sources = std.ArrayList(Compilation.CSourceFile).init(arena);
            for (emulated_getpid_src_files) |file_path| {
                try emu_getpid_sources.append(.{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", try sanitize(arena, file_path),
                    }),
                    .extra_flags = args.items,
                });
            }
            try comp.build_crt_file("wasi-emulated-getpid", .Lib, emu_getpid_sources.items);
        },
        .libwasi_emulated_mman_a => {
            var args = std.ArrayList([]const u8).init(arena);
            try addCCArgs(comp, arena, &args, true);
            try addLibcBottomHalfIncludes(comp, arena, &args);

            var emu_mman_sources = std.ArrayList(Compilation.CSourceFile).init(arena);
            for (emulated_mman_src_files) |file_path| {
                try emu_mman_sources.append(.{
                    .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                        "libc", try sanitize(arena, file_path),
                    }),
                    .extra_flags = args.items,
                });
            }
            try comp.build_crt_file("wasi-emulated-mman", .Lib, emu_mman_sources.items);
        },
        .libwasi_emulated_signal_a => {
            var emu_signal_sources = std.ArrayList(Compilation.CSourceFile).init(arena);

            {
                var args = std.ArrayList([]const u8).init(arena);
                try addCCArgs(comp, arena, &args, true);

                for (emulated_signal_bottom_half_src_files) |file_path| {
                    try emu_signal_sources.append(.{
                        .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                            "libc", try sanitize(arena, file_path),
                        }),
                        .extra_flags = args.items,
                    });
                }
            }

            {
                var args = std.ArrayList([]const u8).init(arena);
                try addCCArgs(comp, arena, &args, true);
                try addLibcTopHalfIncludes(comp, arena, &args);
                try args.append("-D_WASI_EMULATED_SIGNAL");

                for (emulated_signal_top_half_src_files) |file_path| {
                    try emu_signal_sources.append(.{
                        .src_path = try comp.zig_lib_directory.join(arena, &[_][]const u8{
                            "libc", try sanitize(arena, file_path),
                        }),
                        .extra_flags = args.items,
                    });
                }
            }

            try comp.build_crt_file("wasi-emulated-signal", .Lib, emu_signal_sources.items);
        },
    }
}

fn sanitize(arena: Allocator, file_path: []const u8) ![]const u8 {
    // TODO do this at comptime on the comptime data rather than at runtime
    // probably best to wait until self-hosted is done and our comptime execution
    // is faster and uses less memory.
    const out_path = if (path.sep != '/') blk: {
        const mutable_file_path = try arena.dupe(u8, file_path);
        for (mutable_file_path) |*c| {
            if (c.* == '/') {
                c.* = path.sep;
            }
        }
        break :blk mutable_file_path;
    } else file_path;
    return out_path;
}

fn addCCArgs(
    comp: *Compilation,
    arena: Allocator,
    args: *std.ArrayList([]const u8),
    want_O3: bool,
) error{OutOfMemory}!void {
    const target = comp.getTarget();
    const arch_name = musl.archName(target.cpu.arch);
    const os_name = @tagName(target.os.tag);
    const triple = try std.fmt.allocPrint(arena, "{s}-{s}-musl", .{ arch_name, os_name });
    const o_arg = if (want_O3) "-O3" else "-Os";

    try args.appendSlice(&[_][]const u8{
        "-std=gnu17",
        "-fno-trapping-math",
        "-fno-stack-protector",
        "-w", // ignore all warnings

        o_arg,

        "-mthread-model",
        "single",

        "-isysroot",
        "/",

        "-iwithsysroot",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{ "libc", "include", triple }),

        "-DBULK_MEMORY_THRESHOLD=32",
    });
}

fn addLibcBottomHalfIncludes(
    comp: *Compilation,
    arena: Allocator,
    args: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    try args.appendSlice(&[_][]const u8{
        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasi",
            "libc-bottom-half",
            "headers",
            "private",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasi",
            "libc-bottom-half",
            "cloudlibc",
            "src",
            "include",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasi",
            "libc-bottom-half",
            "cloudlibc",
            "src",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasi",
            "libc-top-half",
            "musl",
            "src",
            "include",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasi",
            "libc-top-half",
            "musl",
            "src",
            "internal",
        }),
    });
}

fn addLibcTopHalfIncludes(
    comp: *Compilation,
    arena: Allocator,
    args: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    try args.appendSlice(&[_][]const u8{
        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "src",
            "include",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "include",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "src",
            "internal",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "src",
            "misc",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "src",
            "time",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "src",
            "unistd",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "src",
            "linux",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "arch",
            "wasm32",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "musl",
            "arch",
            "generic",
        }),

        "-I",
        try comp.zig_lib_directory.join(arena, &[_][]const u8{
            "libc",
            "wasix",
            "libc-top-half",
            "headers",
            "private",
        }),
    });
}

const emmalloc_src_files = [_][]const u8{
    "wasi/emmalloc/emmalloc.c",
};

const libc_bottom_half_src_files = [_][]const u8{
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/closedir.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/dirfd.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/fdclosedir.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/fdopendir.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/opendirat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/readdir.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/rewinddir.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/scandirat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/seekdir.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/dirent/telldir.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/errno/errno.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/fcntl/fcntl.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/fcntl/openat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/fcntl/posix_fadvise.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/fcntl/posix_fallocate.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/poll/poll.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sched/sched_yield.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/stdio/renameat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/stdlib/_Exit.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/ioctl/ioctl.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/select/pselect.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/select/select.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/socket/getsockopt.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/socket/recv.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/socket/send.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/socket/shutdown.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/stat/fstat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/stat/fstatat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/stat/futimens.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/stat/mkdirat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/stat/utimensat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/time/gettimeofday.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/uio/preadv.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/uio/pwritev.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/uio/readv.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/sys/uio/writev.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/time/CLOCK_MONOTONIC.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/time/CLOCK_REALTIME.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/time/clock_getres.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/time/clock_gettime.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/time/clock_nanosleep.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/time/nanosleep.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/time/time.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/close.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/faccessat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/fdatasync.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/fsync.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/ftruncate.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/linkat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/lseek.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/pread.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/pwrite.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/read.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/readlinkat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/sleep.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/symlinkat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/unlinkat.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/usleep.c",
    "wasi/libc-bottom-half/cloudlibc/src/libc/unistd/write.c",
    "wasi/libc-bottom-half/sources/__main_void.c",
    "wasi/libc-bottom-half/sources/__wasilibc_dt.c",
    "wasi/libc-bottom-half/sources/__wasilibc_environ.c",
    "wasi/libc-bottom-half/sources/__wasilibc_fd_renumber.c",
    "wasi/libc-bottom-half/sources/__wasilibc_initialize_environ.c",
    "wasi/libc-bottom-half/sources/__wasilibc_real.c",
    "wasi/libc-bottom-half/sources/__wasilibc_rmdirat.c",
    "wasi/libc-bottom-half/sources/__wasilibc_tell.c",
    "wasi/libc-bottom-half/sources/__wasilibc_unlinkat.c",
    "wasi/libc-bottom-half/sources/abort.c",
    "wasi/libc-bottom-half/sources/accept.c",
    "wasi/libc-bottom-half/sources/at_fdcwd.c",
    "wasi/libc-bottom-half/sources/complex-builtins.c",
    "wasi/libc-bottom-half/sources/environ.c",
    "wasi/libc-bottom-half/sources/errno.c",
    "wasi/libc-bottom-half/sources/getcwd.c",
    "wasi/libc-bottom-half/sources/getentropy.c",
    "wasi/libc-bottom-half/sources/isatty.c",
    "wasi/libc-bottom-half/sources/math/fmin-fmax.c",
    "wasi/libc-bottom-half/sources/math/math-builtins.c",
    "wasi/libc-bottom-half/sources/posix.c",
    "wasi/libc-bottom-half/sources/preopens.c",
    "wasi/libc-bottom-half/sources/reallocarray.c",
    "wasi/libc-bottom-half/sources/sbrk.c",
    "wasi/libc-bottom-half/sources/truncate.c",
    // TODO apparently, due to a bug in LLD, the weak refs are garbled
    // unless chdir.c is last in the archive
    // https://reviews.llvm.org/D85567
    "wasi/libc-bottom-half/sources/chdir.c",
};

const libc_top_half_src_files = [_][]const u8{
    "wasix/libc-top-half/musl/src/internal/syscall_ret.c",
    "wasix/libc-top-half/musl/src/misc/getrlimit.c",
    "wasix/libc-top-half/musl/src/misc/setrlimit.c",
    "wasix/libc-top-half/musl/src/misc/getrusage.c",
    "wasix/libc-top-half/musl/src/misc/syslog.c",
    "wasix/libc-top-half/musl/src/time/times.c",
    "wasix/libc-top-half/musl/src/time/gettimeofday.c",
    "wasix/libc-top-half/musl/src/unistd/tcgetpgrp.c",
    "wasix/libc-top-half/musl/src/unistd/tcsetpgrp.c",
    "wasix/libc-top-half/musl/src/unistd/getpgid.c",
    "wasix/libc-top-half/musl/src/unistd/getpgrp.c",
    "wasix/libc-top-half/musl/src/unistd/setpgid.c",
    "wasix/libc-top-half/musl/src/unistd/setpgrp.c",
    "wasix/libc-top-half/musl/src/unistd/getsid.c",
    "wasix/libc-top-half/musl/src/unistd/setsid.c",
    "wasix/libc-top-half/musl/src/unistd/gethostname.c",
    "wasix/libc-top-half/musl/src/unistd/alarm.c",
    "wasix/libc-top-half/musl/src/unistd/ualarm.c",
    "wasix/libc-top-half/musl/src/unistd/ttyname.c",
    "wasix/libc-top-half/musl/src/unistd/ttyname_r.c",
    "wasix/libc-top-half/musl/src/linux/wait3.c",
    "wasix/libc-top-half/musl/src/linux/wait4.c",
    "wasix/libc-top-half/musl/src/linux/eventfd.c",

    "wasix/libc-top-half/musl/src/misc/a64l.c",
    "wasix/libc-top-half/musl/src/misc/basename.c",
    "wasix/libc-top-half/musl/src/misc/dirname.c",
    "wasix/libc-top-half/musl/src/misc/ffs.c",
    "wasix/libc-top-half/musl/src/misc/ffsl.c",
    "wasix/libc-top-half/musl/src/misc/ffsll.c",
    "wasix/libc-top-half/musl/src/misc/fmtmsg.c",
    "wasix/libc-top-half/musl/src/misc/getdomainname.c",
    "wasix/libc-top-half/musl/src/misc/gethostid.c",
    "wasix/libc-top-half/musl/src/misc/getopt.c",
    "wasix/libc-top-half/musl/src/misc/getopt_long.c",
    "wasix/libc-top-half/musl/src/misc/getsubopt.c",
    "wasix/libc-top-half/musl/src/misc/uname.c",
    "wasix/libc-top-half/musl/src/misc/nftw.c",
    "wasix/libc-top-half/musl/src/errno/strerror.c",
    "wasix/libc-top-half/musl/src/network/htonl.c",
    "wasix/libc-top-half/musl/src/network/htons.c",
    "wasix/libc-top-half/musl/src/network/ntohl.c",
    "wasix/libc-top-half/musl/src/network/ntohs.c",
    "wasix/libc-top-half/musl/src/network/inet_ntop.c",
    "wasix/libc-top-half/musl/src/network/inet_pton.c",
    "wasix/libc-top-half/musl/src/network/inet_aton.c",
    "wasix/libc-top-half/musl/src/network/in6addr_any.c",
    "wasix/libc-top-half/musl/src/network/in6addr_loopback.c",
    "wasix/libc-top-half/musl/src/fenv/fenv.c",
    "wasix/libc-top-half/musl/src/fenv/fesetround.c",
    "wasix/libc-top-half/musl/src/fenv/feupdateenv.c",
    "wasix/libc-top-half/musl/src/fenv/fesetexceptflag.c",
    "wasix/libc-top-half/musl/src/fenv/fegetexceptflag.c",
    "wasix/libc-top-half/musl/src/fenv/feholdexcept.c",
    "wasix/libc-top-half/musl/src/exit/exit.c",
    "wasix/libc-top-half/musl/src/exit/atexit.c",
    "wasix/libc-top-half/musl/src/exit/assert.c",
    "wasix/libc-top-half/musl/src/exit/quick_exit.c",
    "wasix/libc-top-half/musl/src/exit/at_quick_exit.c",
    "wasix/libc-top-half/musl/src/time/strftime.c",
    "wasix/libc-top-half/musl/src/time/asctime.c",
    "wasix/libc-top-half/musl/src/time/asctime_r.c",
    "wasix/libc-top-half/musl/src/time/ctime.c",
    "wasix/libc-top-half/musl/src/time/ctime_r.c",
    "wasix/libc-top-half/musl/src/time/wcsftime.c",
    "wasix/libc-top-half/musl/src/time/strptime.c",
    "wasix/libc-top-half/musl/src/time/difftime.c",
    "wasix/libc-top-half/musl/src/time/timegm.c",
    "wasix/libc-top-half/musl/src/time/ftime.c",
    "wasix/libc-top-half/musl/src/time/gmtime.c",
    "wasix/libc-top-half/musl/src/time/gmtime_r.c",
    "wasix/libc-top-half/musl/src/time/timespec_get.c",
    "wasix/libc-top-half/musl/src/time/getdate.c",
    "wasix/libc-top-half/musl/src/time/localtime.c",
    "wasix/libc-top-half/musl/src/time/localtime_r.c",
    "wasix/libc-top-half/musl/src/time/mktime.c",
    "wasix/libc-top-half/musl/src/time/__tm_to_secs.c",
    "wasix/libc-top-half/musl/src/time/__month_to_secs.c",
    "wasix/libc-top-half/musl/src/time/__secs_to_tm.c",
    "wasix/libc-top-half/musl/src/time/__year_to_secs.c",
    "wasix/libc-top-half/musl/src/time/__tz.c",
    "wasix/libc-top-half/musl/src/fcntl/creat.c",
    "wasix/libc-top-half/musl/src/dirent/alphasort.c",
    "wasix/libc-top-half/musl/src/dirent/versionsort.c",
    "wasix/libc-top-half/musl/src/env/__stack_chk_fail.c",
    "wasix/libc-top-half/musl/src/env/clearenv.c",
    "wasix/libc-top-half/musl/src/env/getenv.c",
    "wasix/libc-top-half/musl/src/env/putenv.c",
    "wasix/libc-top-half/musl/src/env/setenv.c",
    "wasix/libc-top-half/musl/src/env/unsetenv.c",
    "wasix/libc-top-half/musl/src/unistd/posix_close.c",
    "wasix/libc-top-half/musl/src/stat/futimesat.c",
    "wasix/libc-top-half/musl/src/legacy/getpagesize.c",
    "wasix/libc-top-half/musl/src/thread/thrd_sleep.c",
    "wasix/libc-top-half/musl/src/internal/defsysinfo.c",
    "wasix/libc-top-half/musl/src/internal/floatscan.c",
    "wasix/libc-top-half/musl/src/internal/intscan.c",
    "wasix/libc-top-half/musl/src/internal/libc.c",
    "wasix/libc-top-half/musl/src/internal/shgetc.c",
    "wasix/libc-top-half/musl/src/stdio/__fclose_ca.c",
    "wasix/libc-top-half/musl/src/stdio/__fdopen.c",
    "wasix/libc-top-half/musl/src/stdio/__fmodeflags.c",
    "wasix/libc-top-half/musl/src/stdio/__fopen_rb_ca.c",
    "wasix/libc-top-half/musl/src/stdio/__overflow.c",
    "wasix/libc-top-half/musl/src/stdio/__stdio_close.c",
    "wasix/libc-top-half/musl/src/stdio/__stdio_exit.c",
    "wasix/libc-top-half/musl/src/stdio/__stdio_read.c",
    "wasix/libc-top-half/musl/src/stdio/__stdio_seek.c",
    "wasix/libc-top-half/musl/src/stdio/__stdio_write.c",
    "wasix/libc-top-half/musl/src/stdio/__stdout_write.c",
    "wasix/libc-top-half/musl/src/stdio/__toread.c",
    "wasix/libc-top-half/musl/src/stdio/__towrite.c",
    "wasix/libc-top-half/musl/src/stdio/__uflow.c",
    "wasix/libc-top-half/musl/src/stdio/asprintf.c",
    "wasix/libc-top-half/musl/src/stdio/clearerr.c",
    "wasix/libc-top-half/musl/src/stdio/dprintf.c",
    "wasix/libc-top-half/musl/src/stdio/ext.c",
    "wasix/libc-top-half/musl/src/stdio/ext2.c",
    "wasix/libc-top-half/musl/src/stdio/fclose.c",
    "wasix/libc-top-half/musl/src/stdio/feof.c",
    "wasix/libc-top-half/musl/src/stdio/ferror.c",
    "wasix/libc-top-half/musl/src/stdio/fflush.c",
    "wasix/libc-top-half/musl/src/stdio/fgetc.c",
    "wasix/libc-top-half/musl/src/stdio/fgetln.c",
    "wasix/libc-top-half/musl/src/stdio/fgetpos.c",
    "wasix/libc-top-half/musl/src/stdio/fgets.c",
    "wasix/libc-top-half/musl/src/stdio/fgetwc.c",
    "wasix/libc-top-half/musl/src/stdio/fgetws.c",
    "wasix/libc-top-half/musl/src/stdio/fileno.c",
    "wasix/libc-top-half/musl/src/stdio/fmemopen.c",
    "wasix/libc-top-half/musl/src/stdio/fopen.c",
    "wasix/libc-top-half/musl/src/stdio/fopencookie.c",
    "wasix/libc-top-half/musl/src/stdio/fprintf.c",
    "wasix/libc-top-half/musl/src/stdio/fputc.c",
    "wasix/libc-top-half/musl/src/stdio/fputs.c",
    "wasix/libc-top-half/musl/src/stdio/fputwc.c",
    "wasix/libc-top-half/musl/src/stdio/fputws.c",
    "wasix/libc-top-half/musl/src/stdio/fread.c",
    "wasix/libc-top-half/musl/src/stdio/freopen.c",
    "wasix/libc-top-half/musl/src/stdio/fscanf.c",
    "wasix/libc-top-half/musl/src/stdio/fseek.c",
    "wasix/libc-top-half/musl/src/stdio/fsetpos.c",
    "wasix/libc-top-half/musl/src/stdio/ftell.c",
    "wasix/libc-top-half/musl/src/stdio/fwide.c",
    "wasix/libc-top-half/musl/src/stdio/fwprintf.c",
    "wasix/libc-top-half/musl/src/stdio/fwrite.c",
    "wasix/libc-top-half/musl/src/stdio/fwscanf.c",
    "wasix/libc-top-half/musl/src/stdio/getc.c",
    "wasix/libc-top-half/musl/src/stdio/getc_unlocked.c",
    "wasix/libc-top-half/musl/src/stdio/getchar.c",
    "wasix/libc-top-half/musl/src/stdio/getchar_unlocked.c",
    "wasix/libc-top-half/musl/src/stdio/getdelim.c",
    "wasix/libc-top-half/musl/src/stdio/getline.c",
    "wasix/libc-top-half/musl/src/stdio/getw.c",
    "wasix/libc-top-half/musl/src/stdio/getwc.c",
    "wasix/libc-top-half/musl/src/stdio/getwchar.c",
    "wasix/libc-top-half/musl/src/stdio/ofl.c",
    "wasix/libc-top-half/musl/src/stdio/ofl_add.c",
    "wasix/libc-top-half/musl/src/stdio/open_memstream.c",
    "wasix/libc-top-half/musl/src/stdio/open_wmemstream.c",
    "wasix/libc-top-half/musl/src/stdio/perror.c",
    "wasix/libc-top-half/musl/src/stdio/printf.c",
    "wasix/libc-top-half/musl/src/stdio/putc.c",
    "wasix/libc-top-half/musl/src/stdio/putc_unlocked.c",
    "wasix/libc-top-half/musl/src/stdio/putchar.c",
    "wasix/libc-top-half/musl/src/stdio/putchar_unlocked.c",
    "wasix/libc-top-half/musl/src/stdio/puts.c",
    "wasix/libc-top-half/musl/src/stdio/putw.c",
    "wasix/libc-top-half/musl/src/stdio/putwc.c",
    "wasix/libc-top-half/musl/src/stdio/putwchar.c",
    "wasix/libc-top-half/musl/src/stdio/rewind.c",
    "wasix/libc-top-half/musl/src/stdio/scanf.c",
    "wasix/libc-top-half/musl/src/stdio/setbuf.c",
    "wasix/libc-top-half/musl/src/stdio/setbuffer.c",
    "wasix/libc-top-half/musl/src/stdio/setlinebuf.c",
    "wasix/libc-top-half/musl/src/stdio/setvbuf.c",
    "wasix/libc-top-half/musl/src/stdio/snprintf.c",
    "wasix/libc-top-half/musl/src/stdio/sprintf.c",
    "wasix/libc-top-half/musl/src/stdio/sscanf.c",
    "wasix/libc-top-half/musl/src/stdio/stderr.c",
    "wasix/libc-top-half/musl/src/stdio/stdin.c",
    "wasix/libc-top-half/musl/src/stdio/stdout.c",
    "wasix/libc-top-half/musl/src/stdio/swprintf.c",
    "wasix/libc-top-half/musl/src/stdio/swscanf.c",
    "wasix/libc-top-half/musl/src/stdio/ungetc.c",
    "wasix/libc-top-half/musl/src/stdio/ungetwc.c",
    "wasix/libc-top-half/musl/src/stdio/vasprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vdprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vfprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vfscanf.c",
    "wasix/libc-top-half/musl/src/stdio/vfwprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vfwscanf.c",
    "wasix/libc-top-half/musl/src/stdio/vprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vscanf.c",
    "wasix/libc-top-half/musl/src/stdio/vsnprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vsprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vsscanf.c",
    "wasix/libc-top-half/musl/src/stdio/vswprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vswscanf.c",
    "wasix/libc-top-half/musl/src/stdio/vwprintf.c",
    "wasix/libc-top-half/musl/src/stdio/vwscanf.c",
    "wasix/libc-top-half/musl/src/stdio/wprintf.c",
    "wasix/libc-top-half/musl/src/stdio/wscanf.c",
    "wasix/libc-top-half/musl/src/string/bcmp.c",
    "wasix/libc-top-half/musl/src/string/bcopy.c",
    "wasix/libc-top-half/musl/src/string/bzero.c",
    "wasix/libc-top-half/musl/src/string/explicit_bzero.c",
    "wasix/libc-top-half/musl/src/string/index.c",
    "wasix/libc-top-half/musl/src/string/memccpy.c",
    "wasix/libc-top-half/musl/src/string/memchr.c",
    "wasix/libc-top-half/musl/src/string/memcmp.c",
    "wasix/libc-top-half/musl/src/string/memcpy.c",
    "wasix/libc-top-half/musl/src/string/memmem.c",
    "wasix/libc-top-half/musl/src/string/memmove.c",
    "wasix/libc-top-half/musl/src/string/mempcpy.c",
    "wasix/libc-top-half/musl/src/string/memrchr.c",
    "wasix/libc-top-half/musl/src/string/memset.c",
    "wasix/libc-top-half/musl/src/string/rindex.c",
    "wasix/libc-top-half/musl/src/string/stpcpy.c",
    "wasix/libc-top-half/musl/src/string/stpncpy.c",
    "wasix/libc-top-half/musl/src/string/strcasecmp.c",
    "wasix/libc-top-half/musl/src/string/strcasestr.c",
    "wasix/libc-top-half/musl/src/string/strcat.c",
    "wasix/libc-top-half/musl/src/string/strchr.c",
    "wasix/libc-top-half/musl/src/string/strchrnul.c",
    "wasix/libc-top-half/musl/src/string/strcmp.c",
    "wasix/libc-top-half/musl/src/string/strcpy.c",
    "wasix/libc-top-half/musl/src/string/strcspn.c",
    "wasix/libc-top-half/musl/src/string/strdup.c",
    "wasix/libc-top-half/musl/src/string/strerror_r.c",
    "wasix/libc-top-half/musl/src/string/strlcat.c",
    "wasix/libc-top-half/musl/src/string/strlcpy.c",
    "wasix/libc-top-half/musl/src/string/strlen.c",
    "wasix/libc-top-half/musl/src/string/strncasecmp.c",
    "wasix/libc-top-half/musl/src/string/strncat.c",
    "wasix/libc-top-half/musl/src/string/strncmp.c",
    "wasix/libc-top-half/musl/src/string/strncpy.c",
    "wasix/libc-top-half/musl/src/string/strndup.c",
    "wasix/libc-top-half/musl/src/string/strnlen.c",
    "wasix/libc-top-half/musl/src/string/strpbrk.c",
    "wasix/libc-top-half/musl/src/string/strrchr.c",
    "wasix/libc-top-half/musl/src/string/strsep.c",
    "wasix/libc-top-half/musl/src/string/strspn.c",
    "wasix/libc-top-half/musl/src/string/strstr.c",
    "wasix/libc-top-half/musl/src/string/strtok.c",
    "wasix/libc-top-half/musl/src/string/strtok_r.c",
    "wasix/libc-top-half/musl/src/string/strverscmp.c",
    "wasix/libc-top-half/musl/src/string/swab.c",
    "wasix/libc-top-half/musl/src/string/wcpcpy.c",
    "wasix/libc-top-half/musl/src/string/wcpncpy.c",
    "wasix/libc-top-half/musl/src/string/wcscasecmp.c",
    "wasix/libc-top-half/musl/src/string/wcscasecmp_l.c",
    "wasix/libc-top-half/musl/src/string/wcscat.c",
    "wasix/libc-top-half/musl/src/string/wcschr.c",
    "wasix/libc-top-half/musl/src/string/wcscmp.c",
    "wasix/libc-top-half/musl/src/string/wcscpy.c",
    "wasix/libc-top-half/musl/src/string/wcscspn.c",
    "wasix/libc-top-half/musl/src/string/wcsdup.c",
    "wasix/libc-top-half/musl/src/string/wcslen.c",
    "wasix/libc-top-half/musl/src/string/wcsncasecmp.c",
    "wasix/libc-top-half/musl/src/string/wcsncasecmp_l.c",
    "wasix/libc-top-half/musl/src/string/wcsncat.c",
    "wasix/libc-top-half/musl/src/string/wcsncmp.c",
    "wasix/libc-top-half/musl/src/string/wcsncpy.c",
    "wasix/libc-top-half/musl/src/string/wcsnlen.c",
    "wasix/libc-top-half/musl/src/string/wcspbrk.c",
    "wasix/libc-top-half/musl/src/string/wcsrchr.c",
    "wasix/libc-top-half/musl/src/string/wcsspn.c",
    "wasix/libc-top-half/musl/src/string/wcsstr.c",
    "wasix/libc-top-half/musl/src/string/wcstok.c",
    "wasix/libc-top-half/musl/src/string/wcswcs.c",
    "wasix/libc-top-half/musl/src/string/wmemchr.c",
    "wasix/libc-top-half/musl/src/string/wmemcmp.c",
    "wasix/libc-top-half/musl/src/string/wmemcpy.c",
    "wasix/libc-top-half/musl/src/string/wmemmove.c",
    "wasix/libc-top-half/musl/src/string/wmemset.c",
    "wasix/libc-top-half/musl/src/locale/__lctrans.c",
    "wasix/libc-top-half/musl/src/locale/__mo_lookup.c",
    "wasix/libc-top-half/musl/src/locale/c_locale.c",
    "wasix/libc-top-half/musl/src/locale/catclose.c",
    "wasix/libc-top-half/musl/src/locale/catgets.c",
    "wasix/libc-top-half/musl/src/locale/catopen.c",
    "wasix/libc-top-half/musl/src/locale/duplocale.c",
    "wasix/libc-top-half/musl/src/locale/freelocale.c",
    "wasix/libc-top-half/musl/src/locale/iconv.c",
    "wasix/libc-top-half/musl/src/locale/iconv_close.c",
    "wasix/libc-top-half/musl/src/locale/langinfo.c",
    "wasix/libc-top-half/musl/src/locale/locale_map.c",
    "wasix/libc-top-half/musl/src/locale/localeconv.c",
    "wasix/libc-top-half/musl/src/locale/newlocale.c",
    "wasix/libc-top-half/musl/src/locale/pleval.c",
    "wasix/libc-top-half/musl/src/locale/setlocale.c",
    "wasix/libc-top-half/musl/src/locale/strcoll.c",
    "wasix/libc-top-half/musl/src/locale/strfmon.c",
    "wasix/libc-top-half/musl/src/locale/strxfrm.c",
    "wasix/libc-top-half/musl/src/locale/uselocale.c",
    "wasix/libc-top-half/musl/src/locale/wcscoll.c",
    "wasix/libc-top-half/musl/src/locale/wcsxfrm.c",
    "wasix/libc-top-half/musl/src/stdlib/abs.c",
    "wasix/libc-top-half/musl/src/stdlib/atof.c",
    "wasix/libc-top-half/musl/src/stdlib/atoi.c",
    "wasix/libc-top-half/musl/src/stdlib/atol.c",
    "wasix/libc-top-half/musl/src/stdlib/atoll.c",
    "wasix/libc-top-half/musl/src/stdlib/bsearch.c",
    "wasix/libc-top-half/musl/src/stdlib/div.c",
    "wasix/libc-top-half/musl/src/stdlib/ecvt.c",
    "wasix/libc-top-half/musl/src/stdlib/fcvt.c",
    "wasix/libc-top-half/musl/src/stdlib/gcvt.c",
    "wasix/libc-top-half/musl/src/stdlib/imaxabs.c",
    "wasix/libc-top-half/musl/src/stdlib/imaxdiv.c",
    "wasix/libc-top-half/musl/src/stdlib/labs.c",
    "wasix/libc-top-half/musl/src/stdlib/ldiv.c",
    "wasix/libc-top-half/musl/src/stdlib/llabs.c",
    "wasix/libc-top-half/musl/src/stdlib/lldiv.c",
    "wasix/libc-top-half/musl/src/stdlib/qsort.c",
    "wasix/libc-top-half/musl/src/stdlib/strtod.c",
    "wasix/libc-top-half/musl/src/stdlib/strtol.c",
    "wasix/libc-top-half/musl/src/stdlib/wcstod.c",
    "wasix/libc-top-half/musl/src/stdlib/wcstol.c",
    "wasix/libc-top-half/musl/src/search/hsearch.c",
    "wasix/libc-top-half/musl/src/search/insque.c",
    "wasix/libc-top-half/musl/src/search/lsearch.c",
    "wasix/libc-top-half/musl/src/search/tdelete.c",
    "wasix/libc-top-half/musl/src/search/tdestroy.c",
    "wasix/libc-top-half/musl/src/search/tfind.c",
    "wasix/libc-top-half/musl/src/search/tsearch.c",
    "wasix/libc-top-half/musl/src/search/twalk.c",
    "wasix/libc-top-half/musl/src/multibyte/btowc.c",
    "wasix/libc-top-half/musl/src/multibyte/c16rtomb.c",
    "wasix/libc-top-half/musl/src/multibyte/c32rtomb.c",
    "wasix/libc-top-half/musl/src/multibyte/internal.c",
    "wasix/libc-top-half/musl/src/multibyte/mblen.c",
    "wasix/libc-top-half/musl/src/multibyte/mbrlen.c",
    "wasix/libc-top-half/musl/src/multibyte/mbrtoc16.c",
    "wasix/libc-top-half/musl/src/multibyte/mbrtoc32.c",
    "wasix/libc-top-half/musl/src/multibyte/mbrtowc.c",
    "wasix/libc-top-half/musl/src/multibyte/mbsinit.c",
    "wasix/libc-top-half/musl/src/multibyte/mbsnrtowcs.c",
    "wasix/libc-top-half/musl/src/multibyte/mbsrtowcs.c",
    "wasix/libc-top-half/musl/src/multibyte/mbstowcs.c",
    "wasix/libc-top-half/musl/src/multibyte/mbtowc.c",
    "wasix/libc-top-half/musl/src/multibyte/wcrtomb.c",
    "wasix/libc-top-half/musl/src/multibyte/wcsnrtombs.c",
    "wasix/libc-top-half/musl/src/multibyte/wcsrtombs.c",
    "wasix/libc-top-half/musl/src/multibyte/wcstombs.c",
    "wasix/libc-top-half/musl/src/multibyte/wctob.c",
    "wasix/libc-top-half/musl/src/multibyte/wctomb.c",
    "wasix/libc-top-half/musl/src/regex/fnmatch.c",
    "wasix/libc-top-half/musl/src/regex/glob.c",
    "wasix/libc-top-half/musl/src/regex/regcomp.c",
    "wasix/libc-top-half/musl/src/regex/regerror.c",
    "wasix/libc-top-half/musl/src/regex/regexec.c",
    "wasix/libc-top-half/musl/src/regex/tre-mem.c",
    "wasix/libc-top-half/musl/src/prng/__rand48_step.c",
    "wasix/libc-top-half/musl/src/prng/__seed48.c",
    "wasix/libc-top-half/musl/src/prng/drand48.c",
    "wasix/libc-top-half/musl/src/prng/lcong48.c",
    "wasix/libc-top-half/musl/src/prng/lrand48.c",
    "wasix/libc-top-half/musl/src/prng/mrand48.c",
    "wasix/libc-top-half/musl/src/prng/rand.c",
    "wasix/libc-top-half/musl/src/prng/rand_r.c",
    "wasix/libc-top-half/musl/src/prng/random.c",
    "wasix/libc-top-half/musl/src/prng/seed48.c",
    "wasix/libc-top-half/musl/src/prng/srand48.c",
    "wasix/libc-top-half/musl/src/conf/confstr.c",
    "wasix/libc-top-half/musl/src/conf/fpathconf.c",
    "wasix/libc-top-half/musl/src/conf/legacy.c",
    "wasix/libc-top-half/musl/src/conf/pathconf.c",
    "wasix/libc-top-half/musl/src/conf/sysconf.c",
    "wasix/libc-top-half/musl/src/ctype/__ctype_b_loc.c",
    "wasix/libc-top-half/musl/src/ctype/__ctype_get_mb_cur_max.c",
    "wasix/libc-top-half/musl/src/ctype/__ctype_tolower_loc.c",
    "wasix/libc-top-half/musl/src/ctype/__ctype_toupper_loc.c",
    "wasix/libc-top-half/musl/src/ctype/isalnum.c",
    "wasix/libc-top-half/musl/src/ctype/isalpha.c",
    "wasix/libc-top-half/musl/src/ctype/isascii.c",
    "wasix/libc-top-half/musl/src/ctype/isblank.c",
    "wasix/libc-top-half/musl/src/ctype/iscntrl.c",
    "wasix/libc-top-half/musl/src/ctype/isdigit.c",
    "wasix/libc-top-half/musl/src/ctype/isgraph.c",
    "wasix/libc-top-half/musl/src/ctype/islower.c",
    "wasix/libc-top-half/musl/src/ctype/isprint.c",
    "wasix/libc-top-half/musl/src/ctype/ispunct.c",
    "wasix/libc-top-half/musl/src/ctype/isspace.c",
    "wasix/libc-top-half/musl/src/ctype/isupper.c",
    "wasix/libc-top-half/musl/src/ctype/iswalnum.c",
    "wasix/libc-top-half/musl/src/ctype/iswalpha.c",
    "wasix/libc-top-half/musl/src/ctype/iswblank.c",
    "wasix/libc-top-half/musl/src/ctype/iswcntrl.c",
    "wasix/libc-top-half/musl/src/ctype/iswctype.c",
    "wasix/libc-top-half/musl/src/ctype/iswdigit.c",
    "wasix/libc-top-half/musl/src/ctype/iswgraph.c",
    "wasix/libc-top-half/musl/src/ctype/iswlower.c",
    "wasix/libc-top-half/musl/src/ctype/iswprint.c",
    "wasix/libc-top-half/musl/src/ctype/iswpunct.c",
    "wasix/libc-top-half/musl/src/ctype/iswspace.c",
    "wasix/libc-top-half/musl/src/ctype/iswupper.c",
    "wasix/libc-top-half/musl/src/ctype/iswxdigit.c",
    "wasix/libc-top-half/musl/src/ctype/isxdigit.c",
    "wasix/libc-top-half/musl/src/ctype/toascii.c",
    "wasix/libc-top-half/musl/src/ctype/tolower.c",
    "wasix/libc-top-half/musl/src/ctype/toupper.c",
    "wasix/libc-top-half/musl/src/ctype/towctrans.c",
    "wasix/libc-top-half/musl/src/ctype/wcswidth.c",
    "wasix/libc-top-half/musl/src/ctype/wctrans.c",
    "wasix/libc-top-half/musl/src/ctype/wcwidth.c",
    "wasix/libc-top-half/musl/src/math/__cos.c",
    "wasix/libc-top-half/musl/src/math/__cosdf.c",
    "wasix/libc-top-half/musl/src/math/__cosl.c",
    "wasix/libc-top-half/musl/src/math/__expo2.c",
    "wasix/libc-top-half/musl/src/math/__expo2f.c",
    "wasix/libc-top-half/musl/src/math/__invtrigl.c",
    "wasix/libc-top-half/musl/src/math/__math_divzero.c",
    "wasix/libc-top-half/musl/src/math/__math_divzerof.c",
    "wasix/libc-top-half/musl/src/math/__math_invalid.c",
    "wasix/libc-top-half/musl/src/math/__math_invalidf.c",
    "wasix/libc-top-half/musl/src/math/__math_invalidl.c",
    "wasix/libc-top-half/musl/src/math/__math_oflow.c",
    "wasix/libc-top-half/musl/src/math/__math_oflowf.c",
    "wasix/libc-top-half/musl/src/math/__math_uflow.c",
    "wasix/libc-top-half/musl/src/math/__math_uflowf.c",
    "wasix/libc-top-half/musl/src/math/__math_xflow.c",
    "wasix/libc-top-half/musl/src/math/__math_xflowf.c",
    "wasix/libc-top-half/musl/src/math/__polevll.c",
    "wasix/libc-top-half/musl/src/math/__rem_pio2.c",
    "wasix/libc-top-half/musl/src/math/__rem_pio2_large.c",
    "wasix/libc-top-half/musl/src/math/__rem_pio2f.c",
    "wasix/libc-top-half/musl/src/math/__rem_pio2l.c",
    "wasix/libc-top-half/musl/src/math/__sin.c",
    "wasix/libc-top-half/musl/src/math/__sindf.c",
    "wasix/libc-top-half/musl/src/math/__sinl.c",
    "wasix/libc-top-half/musl/src/math/__tan.c",
    "wasix/libc-top-half/musl/src/math/__tandf.c",
    "wasix/libc-top-half/musl/src/math/__tanl.c",
    "wasix/libc-top-half/musl/src/math/acos.c",
    "wasix/libc-top-half/musl/src/math/acosf.c",
    "wasix/libc-top-half/musl/src/math/acosh.c",
    "wasix/libc-top-half/musl/src/math/acoshf.c",
    "wasix/libc-top-half/musl/src/math/acoshl.c",
    "wasix/libc-top-half/musl/src/math/acosl.c",
    "wasix/libc-top-half/musl/src/math/asin.c",
    "wasix/libc-top-half/musl/src/math/asinf.c",
    "wasix/libc-top-half/musl/src/math/asinh.c",
    "wasix/libc-top-half/musl/src/math/asinhf.c",
    "wasix/libc-top-half/musl/src/math/asinhl.c",
    "wasix/libc-top-half/musl/src/math/asinl.c",
    "wasix/libc-top-half/musl/src/math/atan.c",
    "wasix/libc-top-half/musl/src/math/atan2.c",
    "wasix/libc-top-half/musl/src/math/atan2f.c",
    "wasix/libc-top-half/musl/src/math/atan2l.c",
    "wasix/libc-top-half/musl/src/math/atanf.c",
    "wasix/libc-top-half/musl/src/math/atanh.c",
    "wasix/libc-top-half/musl/src/math/atanhf.c",
    "wasix/libc-top-half/musl/src/math/atanhl.c",
    "wasix/libc-top-half/musl/src/math/atanl.c",
    "wasix/libc-top-half/musl/src/math/cbrt.c",
    "wasix/libc-top-half/musl/src/math/cbrtf.c",
    "wasix/libc-top-half/musl/src/math/cbrtl.c",
    "wasix/libc-top-half/musl/src/math/ceill.c",
    "wasix/libc-top-half/musl/src/math/copysignl.c",
    "wasix/libc-top-half/musl/src/math/cos.c",
    "wasix/libc-top-half/musl/src/math/cosf.c",
    "wasix/libc-top-half/musl/src/math/cosh.c",
    "wasix/libc-top-half/musl/src/math/coshf.c",
    "wasix/libc-top-half/musl/src/math/coshl.c",
    "wasix/libc-top-half/musl/src/math/cosl.c",
    "wasix/libc-top-half/musl/src/math/erf.c",
    "wasix/libc-top-half/musl/src/math/erff.c",
    "wasix/libc-top-half/musl/src/math/erfl.c",
    "wasix/libc-top-half/musl/src/math/exp.c",
    "wasix/libc-top-half/musl/src/math/exp10.c",
    "wasix/libc-top-half/musl/src/math/exp10f.c",
    "wasix/libc-top-half/musl/src/math/exp10l.c",
    "wasix/libc-top-half/musl/src/math/exp2.c",
    "wasix/libc-top-half/musl/src/math/exp2f.c",
    "wasix/libc-top-half/musl/src/math/exp2f_data.c",
    "wasix/libc-top-half/musl/src/math/exp2l.c",
    "wasix/libc-top-half/musl/src/math/exp_data.c",
    "wasix/libc-top-half/musl/src/math/expf.c",
    "wasix/libc-top-half/musl/src/math/expl.c",
    "wasix/libc-top-half/musl/src/math/expm1.c",
    "wasix/libc-top-half/musl/src/math/expm1f.c",
    "wasix/libc-top-half/musl/src/math/expm1l.c",
    "wasix/libc-top-half/musl/src/math/fabsl.c",
    "wasix/libc-top-half/musl/src/math/fdim.c",
    "wasix/libc-top-half/musl/src/math/fdimf.c",
    "wasix/libc-top-half/musl/src/math/fdiml.c",
    "wasix/libc-top-half/musl/src/math/finite.c",
    "wasix/libc-top-half/musl/src/math/finitef.c",
    "wasix/libc-top-half/musl/src/math/floorl.c",
    "wasix/libc-top-half/musl/src/math/fma.c",
    "wasix/libc-top-half/musl/src/math/fmaf.c",
    "wasix/libc-top-half/musl/src/math/fmal.c",
    "wasix/libc-top-half/musl/src/math/fmaxl.c",
    "wasix/libc-top-half/musl/src/math/fminl.c",
    "wasix/libc-top-half/musl/src/math/fmod.c",
    "wasix/libc-top-half/musl/src/math/fmodf.c",
    "wasix/libc-top-half/musl/src/math/fmodl.c",
    "wasix/libc-top-half/musl/src/math/frexp.c",
    "wasix/libc-top-half/musl/src/math/frexpf.c",
    "wasix/libc-top-half/musl/src/math/frexpl.c",
    "wasix/libc-top-half/musl/src/math/hypot.c",
    "wasix/libc-top-half/musl/src/math/hypotf.c",
    "wasix/libc-top-half/musl/src/math/hypotl.c",
    "wasix/libc-top-half/musl/src/math/ilogb.c",
    "wasix/libc-top-half/musl/src/math/ilogbf.c",
    "wasix/libc-top-half/musl/src/math/ilogbl.c",
    "wasix/libc-top-half/musl/src/math/j0.c",
    "wasix/libc-top-half/musl/src/math/j0f.c",
    "wasix/libc-top-half/musl/src/math/j1.c",
    "wasix/libc-top-half/musl/src/math/j1f.c",
    "wasix/libc-top-half/musl/src/math/jn.c",
    "wasix/libc-top-half/musl/src/math/jnf.c",
    "wasix/libc-top-half/musl/src/math/ldexp.c",
    "wasix/libc-top-half/musl/src/math/ldexpf.c",
    "wasix/libc-top-half/musl/src/math/ldexpl.c",
    "wasix/libc-top-half/musl/src/math/lgamma.c",
    "wasix/libc-top-half/musl/src/math/lgamma_r.c",
    "wasix/libc-top-half/musl/src/math/lgammaf.c",
    "wasix/libc-top-half/musl/src/math/lgammaf_r.c",
    "wasix/libc-top-half/musl/src/math/lgammal.c",
    "wasix/libc-top-half/musl/src/math/llrint.c",
    "wasix/libc-top-half/musl/src/math/llrintf.c",
    "wasix/libc-top-half/musl/src/math/llrintl.c",
    "wasix/libc-top-half/musl/src/math/llround.c",
    "wasix/libc-top-half/musl/src/math/llroundf.c",
    "wasix/libc-top-half/musl/src/math/llroundl.c",
    "wasix/libc-top-half/musl/src/math/log.c",
    "wasix/libc-top-half/musl/src/math/log10.c",
    "wasix/libc-top-half/musl/src/math/log10f.c",
    "wasix/libc-top-half/musl/src/math/log10l.c",
    "wasix/libc-top-half/musl/src/math/log1p.c",
    "wasix/libc-top-half/musl/src/math/log1pf.c",
    "wasix/libc-top-half/musl/src/math/log1pl.c",
    "wasix/libc-top-half/musl/src/math/log2.c",
    "wasix/libc-top-half/musl/src/math/log2_data.c",
    "wasix/libc-top-half/musl/src/math/log2f.c",
    "wasix/libc-top-half/musl/src/math/log2f_data.c",
    "wasix/libc-top-half/musl/src/math/log2l.c",
    "wasix/libc-top-half/musl/src/math/log_data.c",
    "wasix/libc-top-half/musl/src/math/logb.c",
    "wasix/libc-top-half/musl/src/math/logbf.c",
    "wasix/libc-top-half/musl/src/math/logbl.c",
    "wasix/libc-top-half/musl/src/math/logf.c",
    "wasix/libc-top-half/musl/src/math/logf_data.c",
    "wasix/libc-top-half/musl/src/math/logl.c",
    "wasix/libc-top-half/musl/src/math/lrint.c",
    "wasix/libc-top-half/musl/src/math/lrintf.c",
    "wasix/libc-top-half/musl/src/math/lrintl.c",
    "wasix/libc-top-half/musl/src/math/lround.c",
    "wasix/libc-top-half/musl/src/math/lroundf.c",
    "wasix/libc-top-half/musl/src/math/lroundl.c",
    "wasix/libc-top-half/musl/src/math/modf.c",
    "wasix/libc-top-half/musl/src/math/modff.c",
    "wasix/libc-top-half/musl/src/math/modfl.c",
    "wasix/libc-top-half/musl/src/math/nan.c",
    "wasix/libc-top-half/musl/src/math/nanf.c",
    "wasix/libc-top-half/musl/src/math/nanl.c",
    "wasix/libc-top-half/musl/src/math/nearbyintl.c",
    "wasix/libc-top-half/musl/src/math/nextafter.c",
    "wasix/libc-top-half/musl/src/math/nextafterf.c",
    "wasix/libc-top-half/musl/src/math/nextafterl.c",
    "wasix/libc-top-half/musl/src/math/nexttoward.c",
    "wasix/libc-top-half/musl/src/math/nexttowardf.c",
    "wasix/libc-top-half/musl/src/math/nexttowardl.c",
    "wasix/libc-top-half/musl/src/math/pow.c",
    "wasix/libc-top-half/musl/src/math/pow_data.c",
    "wasix/libc-top-half/musl/src/math/powf.c",
    "wasix/libc-top-half/musl/src/math/powf_data.c",
    "wasix/libc-top-half/musl/src/math/powl.c",
    "wasix/libc-top-half/musl/src/math/remainder.c",
    "wasix/libc-top-half/musl/src/math/remainderf.c",
    "wasix/libc-top-half/musl/src/math/remainderl.c",
    "wasix/libc-top-half/musl/src/math/remquo.c",
    "wasix/libc-top-half/musl/src/math/remquof.c",
    "wasix/libc-top-half/musl/src/math/remquol.c",
    "wasix/libc-top-half/musl/src/math/rintl.c",
    "wasix/libc-top-half/musl/src/math/round.c",
    "wasix/libc-top-half/musl/src/math/roundf.c",
    "wasix/libc-top-half/musl/src/math/roundl.c",
    "wasix/libc-top-half/musl/src/math/scalb.c",
    "wasix/libc-top-half/musl/src/math/scalbf.c",
    "wasix/libc-top-half/musl/src/math/scalbln.c",
    "wasix/libc-top-half/musl/src/math/scalblnf.c",
    "wasix/libc-top-half/musl/src/math/scalblnl.c",
    "wasix/libc-top-half/musl/src/math/scalbn.c",
    "wasix/libc-top-half/musl/src/math/scalbnf.c",
    "wasix/libc-top-half/musl/src/math/scalbnl.c",
    "wasix/libc-top-half/musl/src/math/signgam.c",
    "wasix/libc-top-half/musl/src/math/significand.c",
    "wasix/libc-top-half/musl/src/math/significandf.c",
    "wasix/libc-top-half/musl/src/math/sin.c",
    "wasix/libc-top-half/musl/src/math/sincos.c",
    "wasix/libc-top-half/musl/src/math/sincosf.c",
    "wasix/libc-top-half/musl/src/math/sincosl.c",
    "wasix/libc-top-half/musl/src/math/sinf.c",
    "wasix/libc-top-half/musl/src/math/sinh.c",
    "wasix/libc-top-half/musl/src/math/sinhf.c",
    "wasix/libc-top-half/musl/src/math/sinhl.c",
    "wasix/libc-top-half/musl/src/math/sinl.c",
    "wasix/libc-top-half/musl/src/math/sqrt_data.c",
    "wasix/libc-top-half/musl/src/math/sqrtl.c",
    "wasix/libc-top-half/musl/src/math/tan.c",
    "wasix/libc-top-half/musl/src/math/tanf.c",
    "wasix/libc-top-half/musl/src/math/tanh.c",
    "wasix/libc-top-half/musl/src/math/tanhf.c",
    "wasix/libc-top-half/musl/src/math/tanhl.c",
    "wasix/libc-top-half/musl/src/math/tanl.c",
    "wasix/libc-top-half/musl/src/math/tgamma.c",
    "wasix/libc-top-half/musl/src/math/tgammaf.c",
    "wasix/libc-top-half/musl/src/math/tgammal.c",
    "wasix/libc-top-half/musl/src/math/truncl.c",
    "wasix/libc-top-half/musl/src/complex/__cexp.c",
    "wasix/libc-top-half/musl/src/complex/__cexpf.c",
    "wasix/libc-top-half/musl/src/complex/cabs.c",
    "wasix/libc-top-half/musl/src/complex/cabsf.c",
    "wasix/libc-top-half/musl/src/complex/cabsl.c",
    "wasix/libc-top-half/musl/src/complex/cacos.c",
    "wasix/libc-top-half/musl/src/complex/cacosf.c",
    "wasix/libc-top-half/musl/src/complex/cacosh.c",
    "wasix/libc-top-half/musl/src/complex/cacoshf.c",
    "wasix/libc-top-half/musl/src/complex/cacoshl.c",
    "wasix/libc-top-half/musl/src/complex/cacosl.c",
    "wasix/libc-top-half/musl/src/complex/carg.c",
    "wasix/libc-top-half/musl/src/complex/cargf.c",
    "wasix/libc-top-half/musl/src/complex/cargl.c",
    "wasix/libc-top-half/musl/src/complex/casin.c",
    "wasix/libc-top-half/musl/src/complex/casinf.c",
    "wasix/libc-top-half/musl/src/complex/casinh.c",
    "wasix/libc-top-half/musl/src/complex/casinhf.c",
    "wasix/libc-top-half/musl/src/complex/casinhl.c",
    "wasix/libc-top-half/musl/src/complex/casinl.c",
    "wasix/libc-top-half/musl/src/complex/catan.c",
    "wasix/libc-top-half/musl/src/complex/catanf.c",
    "wasix/libc-top-half/musl/src/complex/catanh.c",
    "wasix/libc-top-half/musl/src/complex/catanhf.c",
    "wasix/libc-top-half/musl/src/complex/catanhl.c",
    "wasix/libc-top-half/musl/src/complex/catanl.c",
    "wasix/libc-top-half/musl/src/complex/ccos.c",
    "wasix/libc-top-half/musl/src/complex/ccosf.c",
    "wasix/libc-top-half/musl/src/complex/ccosh.c",
    "wasix/libc-top-half/musl/src/complex/ccoshf.c",
    "wasix/libc-top-half/musl/src/complex/ccoshl.c",
    "wasix/libc-top-half/musl/src/complex/ccosl.c",
    "wasix/libc-top-half/musl/src/complex/cexp.c",
    "wasix/libc-top-half/musl/src/complex/cexpf.c",
    "wasix/libc-top-half/musl/src/complex/cexpl.c",
    "wasix/libc-top-half/musl/src/complex/clog.c",
    "wasix/libc-top-half/musl/src/complex/clogf.c",
    "wasix/libc-top-half/musl/src/complex/clogl.c",
    "wasix/libc-top-half/musl/src/complex/conj.c",
    "wasix/libc-top-half/musl/src/complex/conjf.c",
    "wasix/libc-top-half/musl/src/complex/conjl.c",
    "wasix/libc-top-half/musl/src/complex/cpow.c",
    "wasix/libc-top-half/musl/src/complex/cpowf.c",
    "wasix/libc-top-half/musl/src/complex/cpowl.c",
    "wasix/libc-top-half/musl/src/complex/cproj.c",
    "wasix/libc-top-half/musl/src/complex/cprojf.c",
    "wasix/libc-top-half/musl/src/complex/cprojl.c",
    "wasix/libc-top-half/musl/src/complex/csin.c",
    "wasix/libc-top-half/musl/src/complex/csinf.c",
    "wasix/libc-top-half/musl/src/complex/csinh.c",
    "wasix/libc-top-half/musl/src/complex/csinhf.c",
    "wasix/libc-top-half/musl/src/complex/csinhl.c",
    "wasix/libc-top-half/musl/src/complex/csinl.c",
    "wasix/libc-top-half/musl/src/complex/csqrt.c",
    "wasix/libc-top-half/musl/src/complex/csqrtf.c",
    "wasix/libc-top-half/musl/src/complex/csqrtl.c",
    "wasix/libc-top-half/musl/src/complex/ctan.c",
    "wasix/libc-top-half/musl/src/complex/ctanf.c",
    "wasix/libc-top-half/musl/src/complex/ctanh.c",
    "wasix/libc-top-half/musl/src/complex/ctanhf.c",
    "wasix/libc-top-half/musl/src/complex/ctanhl.c",
    "wasix/libc-top-half/musl/src/complex/ctanl.c",
    "wasix/libc-top-half/musl/src/crypt/crypt.c",
    "wasix/libc-top-half/musl/src/crypt/crypt_blowfish.c",
    "wasix/libc-top-half/musl/src/crypt/crypt_des.c",
    "wasix/libc-top-half/musl/src/crypt/crypt_md5.c",
    "wasix/libc-top-half/musl/src/crypt/crypt_r.c",
    "wasix/libc-top-half/musl/src/crypt/crypt_sha256.c",
    "wasix/libc-top-half/musl/src/crypt/crypt_sha512.c",
    "wasix/libc-top-half/musl/src/crypt/encrypt.c",
    "wasix/libc-top-half/sources/arc4random.c",
};

const crt1_command_src_file = "wasi/libc-bottom-half/crt/crt1-command.c";
const crt1_reactor_src_file = "wasi/libc-bottom-half/crt/crt1-reactor.c";

const emulated_process_clocks_src_files = &[_][]const u8{
    "wasi/libc-bottom-half/clocks/clock.c",
    "wasi/libc-bottom-half/clocks/getrusage.c",
    "wasi/libc-bottom-half/clocks/times.c",
};

const emulated_getpid_src_files = &[_][]const u8{
    "wasi/libc-bottom-half/getpid/getpid.c",
};

const emulated_mman_src_files = &[_][]const u8{
    "wasi/libc-bottom-half/mman/mman.c",
};

const emulated_signal_bottom_half_src_files = &[_][]const u8{
    "wasi/libc-bottom-half/signal/signal.c",
};

const emulated_signal_top_half_src_files = &[_][]const u8{
    "wasi/libc-top-half/musl/src/signal/psignal.c",
    "wasi/libc-top-half/musl/src/string/strsignal.c",
};