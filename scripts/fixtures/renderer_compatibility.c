// Local-file CGL regression harness. Commands and render retain separate owners.
#include "bridge.h"
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

typedef struct {
    bili_mpv *mpv;
    int width, height;
    const char *capture;
    atomic_int ready, stop, failure;
} fixture;

static void *render(void *opaque) {
    fixture *f = opaque;
    CGLPixelFormatAttribute attrs[] = {kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, 0};
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint count = 0;
    if (CGLChoosePixelFormat(attrs, &format, &count) ||
        CGLCreateContext(format, NULL, &context) || CGLSetCurrentContext(context)) {
        atomic_store(&f->failure, 1); atomic_store(&f->ready, 1); return NULL;
    }
    CGLDestroyPixelFormat(format);
    GLuint texture, framebuffer;
    glGenTextures(1, &texture); glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, f->width, f->height, 0, GL_RGBA, GL_FLOAT, NULL);
    glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE ||
        bili_mpv_render_create(f->mpv) < 0) {
        atomic_store(&f->failure, 2); atomic_store(&f->ready, 1);
    } else {
        atomic_store(&f->ready, 1);
        while (!atomic_load(&f->stop)) {
            if (bili_mpv_render_pending(f->mpv)) {
                glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
                glViewport(0, 0, f->width, f->height);
                if (bili_mpv_render(f->mpv, 1) < 0) atomic_store(&f->failure, 3);
                bili_mpv_report_swap(f->mpv);
            }
            usleep(1000);
        }
        size_t pixels_count = (size_t)f->width * f->height * 3;
        float *pixels = malloc(pixels_count * sizeof(float));
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        glReadPixels(0, 0, f->width, f->height, GL_RGB, GL_FLOAT, pixels);
        FILE *capture = fopen(f->capture, "wb");
        if (!capture || glGetError() != GL_NO_ERROR) atomic_store(&f->failure, 5);
        if (capture) {
            fprintf(capture, "PF\n%d %d\n-1.0\n", f->width, f->height);
            if (fwrite(pixels, sizeof(float), pixels_count, capture) != pixels_count)
                atomic_store(&f->failure, 5);
            fclose(capture);
        }
        free(pixels);
        char stats[4096]; bili_mpv_render_stats(f->mpv, stats, sizeof(stats));
        fprintf(stdout, "RENDER %s\n", stats);
        bili_mpv_render_destroy(f->mpv);
    }
    glDeleteFramebuffers(1, &framebuffer); glDeleteTextures(1, &texture);
    CGLSetCurrentContext(NULL); CGLDestroyContext(context);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 7 || argv[2][0] != '/' || strstr(argv[2], "://")) return 64;
    setenv("MANPING_RENDER_DIAGNOSTICS", "1", 1);
    unsetenv("MANPING_CAPTURE_PATH");
    char error[2048] = {0};
    fixture f = {.width=atoi(argv[4]), .height=atoi(argv[5]), .capture=argv[3]};
    f.mpv = bili_mpv_create(argv[1], error, sizeof(error));
    if (!f.mpv) { fprintf(stderr, "%s\n", error); return 1; }
    bili_mpv_log_level(f.mpv, "trace");
    const char *options[][2] = {{"hwdec","no"},{"mute","yes"},
        {"target-prim","bt.709"},{"target-trc","srgb"},{"target-peak","203"},
        {"scale","bilinear"},{"cscale","bilinear"},{"dscale","bilinear"},
        {"tone-mapping","bt.2390"},{"dither-depth","no"}};
    for (size_t i=0;i<sizeof(options)/sizeof(options[0]);i++)
        if (bili_mpv_set(f.mpv,options[i][0],options[i][1])<0) return 2;
    const char *peak_step = NULL;
    int peak_sequence = 0, peak_updates = 0;
    double pause_at = -1;
    const char *source_min_step = NULL;
    for (int i=7;i<argc;i++) {
        char *equal = strchr(argv[i], '=');
        if (!equal) return 64;
        *equal = 0;
        if (!strcmp(argv[i], "fixture-pause-at")) { pause_at = atof(equal+1); continue; }
        if (!strcmp(argv[i], "fixture-source-min-step")) { source_min_step = equal+1; continue; }
        if (!strcmp(argv[i], "fixture-peak-sequence")) { peak_sequence = atoi(equal+1); continue; }
        if (!strcmp(argv[i], "fixture-peak-step")) { peak_step = equal+1; continue; }
        if (bili_mpv_set(f.mpv, argv[i], equal+1) < 0) {
            fprintf(stderr,"Rejected option %s\n",argv[i]); return 2;
        }
    }
    pthread_t thread; pthread_create(&thread,NULL,render,&f);
    while (!atomic_load(&f.ready)) usleep(1000);
    if (!atomic_load(&f.failure) && bili_mpv_load(f.mpv,argv[2],NULL,0,0)<0)
        atomic_store(&f.failure,4);
    struct timespec start, now; clock_gettime(CLOCK_MONOTONIC,&start);
    do {
        char event[8192];
        while (bili_mpv_event(f.mpv,event,sizeof(event))) fputs(event,stdout);
        usleep(10000); clock_gettime(CLOCK_MONOTONIC,&now);
        double elapsed = now.tv_sec-start.tv_sec + (now.tv_nsec-start.tv_nsec)/1e9;
        if (pause_at >= 0 && elapsed >= pause_at) {
            if (bili_mpv_set(f.mpv, "pause", "yes") < 0) atomic_store(&f.failure, 6);
            puts("PAUSE_UPDATE yes"); pause_at = -1;
        }
        if (source_min_step && elapsed >= 1) {
            char vf[128]; snprintf(vf, sizeof(vf), "format:min-luma=%s:max-luma=203", source_min_step);
            if (bili_mpv_set(f.mpv, "vf", vf) < 0) atomic_store(&f.failure, 6);
            printf("SOURCE_MIN_UPDATE %s\n", source_min_step); source_min_step = NULL;
        }
        if (peak_updates < peak_sequence && elapsed >= .1 * (peak_updates+1)) {
            char peak[32]; snprintf(peak, sizeof(peak), "%d", 203 + 20 * (peak_updates+1));
            if (bili_mpv_set(f.mpv, "target-peak", peak) < 0)
                atomic_store(&f.failure, 6);
            printf("PEAK_UPDATE %d %s\n", ++peak_updates, peak);
        }
        if (peak_step && now.tv_sec-start.tv_sec >= 1) {
            if (bili_mpv_set(f.mpv, "target-peak", peak_step) < 0)
                atomic_store(&f.failure, 6);
            peak_step = NULL;
        }
    } while (!atomic_load(&f.failure) && now.tv_sec-start.tv_sec < atoi(argv[6]));
    const char *properties[]={"video-params","video-out-params","osd-dimensions",
        "hwdec-current","pause","time-pos","target-contrast","target-peak","target-trc","target-prim"};
    for (size_t i=0;i<sizeof(properties)/sizeof(properties[0]);i++) {
        char value[4096]={0};
        bili_mpv_string(f.mpv,properties[i],value,sizeof(value));
        printf("PROPERTY %s=%s\n",properties[i],value);
    }
    atomic_store(&f.stop,1); pthread_join(thread,NULL);
    bili_mpv_destroy(f.mpv);
    return atomic_load(&f.failure);
}
