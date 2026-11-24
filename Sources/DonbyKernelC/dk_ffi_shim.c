#include "donby_kernel.h"
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <libavutil/log.h>

// Lock C header layout to KernelRust/src/abi.rs at compile time.
_Static_assert(sizeof(DKPlayerState) == 4, "DKPlayerState size drift");
_Static_assert(sizeof(DKRuntimeStats) == 160, "DKRuntimeStats size drift");
_Static_assert(sizeof(DKTrackInfo) == 204, "DKTrackInfo size drift");
_Static_assert(sizeof(DKChapterInfo) == 152, "DKChapterInfo size drift");
_Static_assert(sizeof(DKSubtitleInterval) == 16, "DKSubtitleInterval size drift");
_Static_assert(sizeof(DKSubtitleStyleConfig) == 64, "DKSubtitleStyleConfig size drift");
_Static_assert(sizeof(DKGpuColorUniforms) == 3088, "DKGpuColorUniforms size drift");

extern void dk_rust_forward_ffmpeg_log(int level, const char* message);

static void dk_shim_ffmpeg_log_cb(void* ptr, int level, const char* fmt, va_list vl) {
    (void)ptr;
    if (level > AV_LOG_WARNING || !fmt) {
        return;
    }
    char line[1024];
    int n = vsnprintf(line, sizeof(line), fmt, vl);
    if (n <= 0) {
        return;
    }
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
        line[--len] = '\0';
    }
    if (len == 0) {
        return;
    }
    int mapped = (level <= AV_LOG_ERROR) ? 2 : 1;
    dk_rust_forward_ffmpeg_log(mapped, line);
}

void dk_shim_install_ffmpeg_log_bridge(void) {
    av_log_set_level(AV_LOG_WARNING);
    av_log_set_callback(dk_shim_ffmpeg_log_cb);
}
