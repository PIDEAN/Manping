#include "bridge.h"
#include "client.h"
#include "render.h"
#include "render_gl.h"
#include <CommonCrypto/CommonDigest.h>
#include <OpenGL/gl3.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach/mach.h>

struct bili_mpv {
    void *library;
    mpv_handle *handle;
    mpv_render_context *render;
    mpv_handle *(*create)(void);
    int (*initialize)(mpv_handle *);
    int (*set_option_string)(mpv_handle *, const char *, const char *);
    int (*set_property_string)(mpv_handle *, const char *, const char *);
    int (*get_property)(mpv_handle *, const char *, mpv_format, void *);
    char *(*get_property_string)(mpv_handle *, const char *);
    int (*command)(mpv_handle *, const char *const *);
    int (*command_node)(mpv_handle *, mpv_node *, mpv_node *);
    mpv_event *(*wait_event)(mpv_handle *, double);
    int (*request_log_messages)(mpv_handle *, const char *);
    void (*terminate_destroy)(mpv_handle *);
    void (*free)(void *);
    void (*free_node_contents)(mpv_node *);
    uint64_t (*render_update)(mpv_render_context *);
    void (*render_set_update)(mpv_render_context *, mpv_render_update_fn, void *);
    atomic_bool dirty;
    atomic_int target_peak;
    int diagnostics, sample_frame, sample_target_peak, capture_done;
    int isolation_mask;
    int shader_links, shader_link_failures, max_active_attributes;
    int width, height;
    unsigned long frames, background_frames;
    int fbo, component_type, red_bits;
    float peak;
    unsigned long long sample_hash;
    const char *(*error_string)(int);
    int (*render_create)(mpv_render_context **, mpv_handle *, mpv_render_param *);
    int (*render_render)(mpv_render_context *, mpv_render_param *);
    void (*render_report_swap)(mpv_render_context *);
    void (*render_free)(mpv_render_context *);
};
static _Thread_local bili_mpv *active_engine;
static void diagnostic_link_program(GLuint program) {
    glLinkProgram(program);
    if(!active_engine) return;
    GLint status=0, attributes=0;
    glGetProgramiv(program,GL_LINK_STATUS,&status);
    glGetProgramiv(program,GL_ACTIVE_ATTRIBUTES,&attributes);
    active_engine->shader_links++;
    if(!status) active_engine->shader_link_failures++;
    if(attributes>active_engine->max_active_attributes) active_engine->max_active_attributes=attributes;
}
static void render_updated(void *ctx) {
    bili_mpv *e = ctx;
    atomic_store(&e->dirty, 1);
}
static void *gl_proc(void *ctx, const char *name) {
    bili_mpv *e=ctx;
    if(e->diagnostics && strcmp(name,"glLinkProgram")==0) return (void *)diagnostic_link_program;
    return dlsym(RTLD_DEFAULT, name);
}
bili_mpv *bili_mpv_create(const char *path, int isolated, char *error, size_t capacity) {
    bili_mpv *e = calloc(1, sizeof(*e));
    e->diagnostics = getenv("MANPING_RENDER_DIAGNOSTICS") != NULL;
    e->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!e->library) { snprintf(error, capacity, "%s", dlerror()); free(e); return NULL; }
#define LOAD(field, name) do { *(void **)(&e->field) = dlsym(e->library, name); if (!e->field) { snprintf(error, capacity, "Missing public mpv symbol: %s", name); bili_mpv_destroy(e); return NULL; } } while (0)
    LOAD(create, "mpv_create"); LOAD(initialize, "mpv_initialize");
    LOAD(set_option_string, "mpv_set_option_string"); LOAD(set_property_string, "mpv_set_property_string");
    LOAD(get_property, "mpv_get_property"); LOAD(get_property_string, "mpv_get_property_string");
    LOAD(command_node, "mpv_command_node"); LOAD(command, "mpv_command"); LOAD(wait_event, "mpv_wait_event");
    LOAD(request_log_messages, "mpv_request_log_messages"); LOAD(terminate_destroy, "mpv_terminate_destroy");
    LOAD(free, "mpv_free"); LOAD(free_node_contents, "mpv_free_node_contents"); LOAD(render_update, "mpv_render_context_update"); LOAD(error_string, "mpv_error_string");
    LOAD(render_set_update, "mpv_render_context_set_update_callback");
    LOAD(render_create, "mpv_render_context_create"); LOAD(render_render, "mpv_render_context_render");
    LOAD(render_report_swap, "mpv_render_context_report_swap"); LOAD(render_free, "mpv_render_context_free");
#undef LOAD
    e->handle = e->create();
    if (!e->handle) { snprintf(error, capacity, "mpv_create failed"); bili_mpv_destroy(e); return NULL; }
    const char *options[][2] = {{"vo","libmpv"},{"dither-depth","no"},{"hwdec","videotoolbox"},{"keep-open","yes"},{"idle","yes"},{"config","no"},{"terminal","no"},{"tls-verify","yes"},{"input-default-bindings","no"},{"user-agent","Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"},{"referrer","https://www.bilibili.com/"}};
    for (size_t i=0;i<sizeof(options)/sizeof(options[0]);i++) {
        int status=e->set_option_string(e->handle,options[i][0],options[i][1]);
        if(status<0) { snprintf(error,capacity,"%s: %s",options[i][0],e->error_string(status)); bili_mpv_destroy(e);return NULL; }
    }
    // mpv_create's embedding contract plus config=no above disables config files;
    // config-dir is only needed when config loading is explicitly re-enabled (client.h).
    const char *isolated_options[] = {"ytdl", "load-scripts", "cookies"};
    if (isolated) {
        for (size_t i = 0; i < 3; i++) {
            if (e->set_option_string(e->handle, isolated_options[i], "no") < 0) {
                snprintf(error, capacity, "Media isolation option configuration failed");
                bili_mpv_destroy(e); return NULL;
            }
        }
    }
    // App clipboard actions use NSPasteboard. The unused native backend in
    // mpv 0.41 retains a Clipboard object per instance. Older custom libraries
    // may not expose this option, so keep this optional for compatibility.
    (void)e->set_option_string(e->handle,"clipboard-backends","");
    int status=e->initialize(e->handle);
    if(status<0) { snprintf(error,capacity,"%s",e->error_string(status));bili_mpv_destroy(e);return NULL; }
    if (isolated) {
        const char *properties[] = {"options/ytdl", "options/load-scripts", "options/cookies"};
        for (size_t i = 0; i < 3; i++) {
            char *value = e->get_property_string(e->handle, properties[i]);
            int disabled = value && strcmp(value, "no") == 0;
            if (value) e->free(value);
            if (!disabled) {
                snprintf(error, capacity, "Media isolation option verification failed");
                bili_mpv_destroy(e); return NULL;
            }
            e->isolation_mask |= 1 << i;
        }
    }
    e->request_log_messages(e->handle,"warn");
    return e;
}
int bili_mpv_isolation_mask(bili_mpv *e) { return e ? e->isolation_mask : 0; }
int bili_mpv_render_create(bili_mpv *e) {
    if(!e) return MPV_ERROR_INVALID_PARAMETER;
    mpv_opengl_init_params gl = {gl_proc, e};
    mpv_render_param params[]={{MPV_RENDER_PARAM_API_TYPE,MPV_RENDER_API_TYPE_OPENGL},{MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&gl},{0,NULL}};
    active_engine=e;
    int result=e->render_create(&e->render,e->handle,params);
    active_engine=NULL;
    if(result>=0) e->render_set_update(e->render,render_updated,e);
    return result;
}
int bili_mpv_render_pending(bili_mpv *e) {
    if(!e || !e->render || !atomic_exchange(&e->dirty,0)) return 0;
    return (e->render_update(e->render) & MPV_RENDER_UPDATE_FRAME)!=0;
}
int bili_mpv_capture(bili_mpv *e,int width,int height,int floating,void *pixels) {
    if(!e || !e->render || width<=0 || height<=0 || width>8192 || height>8192 || !pixels) return MPV_ERROR_INVALID_PARAMETER;
    GLint previous=0, viewport[4];
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&previous);
    glGetIntegerv(GL_VIEWPORT,viewport);
    GLuint texture=0, framebuffer=0;
    glGenTextures(1,&texture);
    glBindTexture(GL_TEXTURE_2D,texture);
    glTexImage2D(GL_TEXTURE_2D,0,floating?GL_RGBA16F:GL_RGBA8,width,height,0,GL_RGBA,floating?GL_FLOAT:GL_UNSIGNED_BYTE,NULL);
    glGenFramebuffers(1,&framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
    int result=MPV_ERROR_GENERIC;
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE) {
        glViewport(0,0,width,height);
        // Not flipped: in a texture-backed framebuffer mpv writes the top row first.
        mpv_opengl_fbo fbo={(int)framebuffer,width,height,floating?GL_RGBA16F:GL_RGBA8};
        int flip=0;
        mpv_render_param params[]={{MPV_RENDER_PARAM_OPENGL_FBO,&fbo},{MPV_RENDER_PARAM_FLIP_Y,&flip},{0,NULL}};
        active_engine=e;
        result=e->render_render(e->render,params);
        active_engine=NULL;
        if(result>=0) {
            glBindFramebuffer(GL_READ_FRAMEBUFFER,framebuffer);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glPixelStorei(GL_PACK_ALIGNMENT,1);
            glReadPixels(0,0,width,height,GL_RGBA,floating?GL_FLOAT:GL_UNSIGNED_BYTE,pixels);
        }
    }
    glBindFramebuffer(GL_FRAMEBUFFER,(GLuint)previous);
    glViewport(viewport[0],viewport[1],viewport[2],viewport[3]);
    glDeleteFramebuffers(1,&framebuffer);
    glDeleteTextures(1,&texture);
    return result;
}

int bili_mpv_render(bili_mpv *e,int floating) {
    if(!e || !e->render) return MPV_ERROR_INVALID_PARAMETER;
    GLint viewport[4], framebuffer=0;
    glGetIntegerv(GL_VIEWPORT,viewport);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&framebuffer);
    if(viewport[2]<=0 || viewport[3]<=0) return 0;
    mpv_opengl_fbo fbo={framebuffer,viewport[2],viewport[3],floating?GL_RGBA16F:GL_RGBA8};
    int flip=1;
    mpv_render_param params[]={{MPV_RENDER_PARAM_OPENGL_FBO,&fbo},{MPV_RENDER_PARAM_FLIP_Y,&flip},{0,NULL}};
    active_engine=e;
    int result=e->render_render(e->render,params);
    active_engine=NULL;
    if(result>=0) {
        e->frames++; if(!pthread_main_np()) e->background_frames++;
        e->width=viewport[2]; e->height=viewport[3]; e->fbo=framebuffer;
        glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);
        GLenum attachment=framebuffer?GL_COLOR_ATTACHMENT0:GL_BACK_LEFT;
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,attachment,GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE,&e->component_type);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,attachment,GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE,&e->red_bits);
        const char *capture=getenv("MANPING_CAPTURE_PATH");
        if(e->diagnostics && capture && !e->capture_done && e->frames>=30) {
            e->capture_done=1;
            size_t count=(size_t)viewport[2]*viewport[3]*3;
            float *pixels=malloc(count*sizeof(float));
            if(pixels) {
                glReadBuffer(framebuffer?GL_COLOR_ATTACHMENT0:GL_BACK);
                glReadPixels(0,0,viewport[2],viewport[3],GL_RGB,GL_FLOAT,pixels);
                FILE *file=fopen(capture,"wb");
                if(file) { fprintf(file,"PF\n%d %d\n-1.0\n",viewport[2],viewport[3]); fwrite(pixels,sizeof(float),count,file); fclose(file); }
                free(pixels);
            }
        }
        // Bounded diagnostic samples only; production rendering never reads pixels back.
        if(e->diagnostics && (e->frames==10 || e->frames%30==0)) {
            e->peak=0; e->sample_frame=(int)e->frames;
            e->sample_target_peak=atomic_load(&e->target_peak);
            e->sample_hash=1469598103934665603ULL;
            float sample[4]={0};
            glReadBuffer(framebuffer?GL_COLOR_ATTACHMENT0:GL_BACK);
            for(int y=1;y<8;y++) for(int x=1;x<8;x++) {
                glReadPixels(viewport[2]*x/8,viewport[3]*y/8,1,1,GL_RGBA,GL_FLOAT,sample);
                for(int c=0;c<3;c++) {
                    if(sample[c]>e->peak) e->peak=sample[c];
                    int quantized=(int)(sample[c]*4096);
                    e->sample_hash=(e->sample_hash^(unsigned int)quantized)*1099511628211ULL;
                }
            }
        }
    }
    return result<0?result:1;
}
void bili_mpv_render_stats(bili_mpv *e,char *buffer,size_t capacity) {
    snprintf(buffer,capacity,"frames=%lu backgroundFrames=%lu fbo=%d size=%dx%d componentType=0x%x redBits=%d sampledPeak=%g sampleHash=%llx sampleFrame=%d sampleTargetNits=%d shaderLinks=%d linkFailures=%d maxActiveAttributes=%d",e->frames,e->background_frames,e->fbo,e->width,e->height,e->component_type,e->red_bits,e->peak,e->sample_hash,e->sample_frame,e->sample_target_peak,e->shader_links,e->shader_link_failures,e->max_active_attributes);
}
void bili_mpv_render_destroy(bili_mpv *e) {
    if(e && e->render) {
        e->render_set_update(e->render,NULL,NULL);
        e->render_free(e->render); e->render=NULL;
    }
}
void bili_mpv_destroy(bili_mpv *e) {
    if(!e) return;
    // The caller makes the original OpenGL context current before freeing render state.
    if(e->render && e->render_free) { e->render_free(e->render); e->render=NULL; }
    if(e->handle && e->terminate_destroy) e->terminate_destroy(e->handle);
    if(e->library) dlclose(e->library);
    free(e);
}
int bili_mpv_load(bili_mpv *e,const char *video,const char *audio,double start,int paused) {
    char start_text[64]; snprintf(start_text,sizeof(start_text),"%.6f",start);
    // The node map preserves commas; -append treats the entire URL as one path
    // (unlike audio-files, which splits colons). These are file-local options.
    char *keys[]={"start","pause","audio-files-append"};
    mpv_node values[3]={{.u.string=start_text,.format=MPV_FORMAT_STRING},
      {.u.string=paused?"yes":"no",.format=MPV_FORMAT_STRING},
      {.u.string=(char *)audio,.format=MPV_FORMAT_STRING}};
    mpv_node_list options={audio?3:2,values,keys};
    mpv_node args[5]={ {.u.string="loadfile",.format=MPV_FORMAT_STRING},
      {.u.string=(char *)video,.format=MPV_FORMAT_STRING},
      {.u.string="replace",.format=MPV_FORMAT_STRING},
      {.u.int64=-1,.format=MPV_FORMAT_INT64},
      {.u.list=&options,.format=MPV_FORMAT_NODE_MAP}};
    mpv_node_list list={5,args,NULL}; mpv_node command={.u.list=&list,.format=MPV_FORMAT_NODE_ARRAY};
    mpv_node result={0}; int status=e->command_node(e->handle,&command,&result);
    e->free_node_contents(&result); return status;
}
int bili_mpv_command(bili_mpv *e,const char *const *args) { return e ?e->command(e->handle,args):MPV_ERROR_INVALID_PARAMETER; }
int bili_mpv_set(bili_mpv *e,const char *name,const char *value) {
    if(!e) return MPV_ERROR_INVALID_PARAMETER;
    int result=e->set_property_string(e->handle,name,value);
    if(result>=0 && strcmp(name,"target-peak")==0) atomic_store(&e->target_peak,atoi(value));
    return result;
}
int bili_mpv_number_checked(bili_mpv *e,const char *name,double *value) { return e?e->get_property(e->handle,name,MPV_FORMAT_DOUBLE,value):MPV_ERROR_INVALID_PARAMETER; }
uint64_t bili_process_resident_bytes(void) {
    mach_task_basic_info_data_t info; mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&info,&count)==KERN_SUCCESS?info.resident_size:0;
}
double bili_mpv_number(bili_mpv *e,const char *name) { double value=0;if(e) e->get_property(e->handle,name,MPV_FORMAT_DOUBLE,&value);return value; }
int bili_mpv_flag(bili_mpv *e,const char *name) { int value=0;if(e) e->get_property(e->handle,name,MPV_FORMAT_FLAG,&value);return value; }
int bili_mpv_string(bili_mpv *e,const char *name,char *buffer,size_t capacity) {
    if(!e) return -1;
    char *value=e->get_property_string(e->handle,name);if(!value) return -1;
    snprintf(buffer,capacity,"%s",value);e->free(value);return 0;
}
int bili_mpv_event(bili_mpv *e,char *buffer,size_t capacity) {
    if(!e) return 0;
    mpv_event *event=e->wait_event(e->handle,0);
    if(event->event_id==MPV_EVENT_NONE) return 0;
    if(event->event_id==MPV_EVENT_END_FILE) { mpv_event_end_file *end=event->data;snprintf(buffer,capacity,"end-file: %s",e->error_string(end->error)); }
    else if(event->event_id==MPV_EVENT_LOG_MESSAGE) { mpv_event_log_message *log=event->data;snprintf(buffer,capacity,"%s: %s",log->prefix,log->text); }
    else snprintf(buffer,capacity,"event:%d",event->event_id);
    return (int)event->event_id;
}
void bili_md5(const void *bytes,unsigned long length,unsigned char output[16]) { CC_MD5(bytes,(CC_LONG)length,output); }

void bili_mpv_log_level(bili_mpv *e,const char *level) {if(e) e->request_log_messages(e->handle,level);}
void bili_mpv_report_swap(bili_mpv *e) {if(e && e->render) e->render_report_swap(e->render);}
int bili_mpv_passes(bili_mpv *e,char *buffer,size_t capacity) {
    if(!e || !capacity) return -1;
    mpv_node root={0};buffer[0]=0;
    int status=e->get_property(e->handle,"vo-passes",MPV_FORMAT_NODE,&root);
    if(status<0) return status;
    size_t used=0;
    if(root.format==MPV_FORMAT_NODE_MAP) {
        for(int i=0;i<root.u.list->num;i++) {
            mpv_node *group=&root.u.list->values[i];
            if(group->format!=MPV_FORMAT_NODE_ARRAY) continue;
            for(int j=0;j<group->u.list->num;j++) {
                mpv_node *pass=&group->u.list->values[j];
                if(pass->format!=MPV_FORMAT_NODE_MAP) continue;
                for(int k=0;k<pass->u.list->num;k++) {
                    mpv_node *value=&pass->u.list->values[k];
                    if(strcmp(pass->u.list->keys[k],"desc")==0 && value->format==MPV_FORMAT_STRING && used<capacity-1) {
                        int n=snprintf(buffer+used,capacity-used,"%s\n",value->u.string);
                        if(n>0) used+= (size_t)n<capacity-used?(size_t)n:capacity-used-1;
                    }
                }
            }
        }
    }
    e->free_node_contents(&root);return 0;
}
