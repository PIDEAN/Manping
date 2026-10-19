#ifndef MANPING_MPV_BRIDGE_H
#define MANPING_MPV_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
typedef struct bili_mpv bili_mpv;
// Commands/events belong to one serial worker. Render is serialized by the layer lock and uses one current CGL context.
bili_mpv *bili_mpv_create(const char *library_path, int isolated, char *error, size_t capacity);
// Read-back proof captured at initialization: bit 0 ytdl=no, bit 1 load-scripts=no,
// bit 2 cookies=no. Zero for ordinary engines; isolated creation fails unless all are set.
int bili_mpv_isolation_mask(bili_mpv *engine);
// Atomic intent publication may run on the main actor; it makes no mpv calls.
void bili_mpv_pause_intent(bili_mpv *engine, int paused);
// Serial-worker diagnostics: only isolated engines can hold a load before file options.
int bili_mpv_hold_next_load(bili_mpv *engine);
int bili_mpv_load_held(bili_mpv *engine);
int bili_mpv_loaded_files(bili_mpv *engine);
// An uncompleted load may own a pending hook: destroy it instead of parking it.
int bili_mpv_load_inflight(bili_mpv *engine);
void bili_mpv_release_load(bili_mpv *engine);
int bili_mpv_render_create(bili_mpv *engine);
int bili_mpv_render_pending(bili_mpv *engine);
int bili_mpv_render(bili_mpv *engine, int floating);
// Renders the current frame into an offscreen framebuffer of width x height and reads it back
// top row first into `pixels`: RGBA8 (width * height * 4 bytes), or with `floating` RGBA16F read
// as 32-bit floats (width * height * 16 bytes) for EDR output. Needs the render context current.
int bili_mpv_capture(bili_mpv *engine, int width, int height, int floating, void *pixels);
void bili_mpv_render_stats(bili_mpv *engine, char *buffer, size_t capacity);
void bili_mpv_render_destroy(bili_mpv *engine);
void bili_mpv_destroy(bili_mpv *engine);
int bili_mpv_load(bili_mpv *engine, const char *video, const char *audio, double start, int paused);
int bili_mpv_command(bili_mpv *engine, const char *const *args);
int bili_mpv_set(bili_mpv *engine, const char *name, const char *value);
int bili_mpv_number_checked(bili_mpv *engine, const char *name, double *value);
uint64_t bili_process_resident_bytes(void);
double bili_mpv_number(bili_mpv *engine, const char *name);
int bili_mpv_flag(bili_mpv *engine, const char *name);
// Copy and free strings in the same library that allocated them.
int bili_mpv_string(bili_mpv *engine, const char *name, char *buffer, size_t capacity);
void bili_mpv_log_level(bili_mpv *engine, const char *level);
void bili_mpv_report_swap(bili_mpv *engine);
int bili_mpv_passes(bili_mpv *engine, char *buffer, size_t capacity);
int bili_mpv_event(bili_mpv *engine, char *buffer, size_t capacity);
void bili_md5(const void *bytes, unsigned long length, unsigned char output[16]);
#endif
