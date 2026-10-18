// Independent CPU libplacebo transfer oracle for neutral SDR bars; no image edits.
#include <libplacebo/colorspace.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc != 4) return 64;
    float peak = atof(argv[1]), contrast = atof(argv[2]), source_min = atof(argv[3]);
    struct pl_color_space src = {.primaries=PL_COLOR_PRIM_BT_709,
        .transfer=PL_COLOR_TRC_BT_1886, .hdr={.max_luma=203, .min_luma=source_min}};
    struct pl_color_space dst = {.primaries=PL_COLOR_PRIM_BT_2020,
        .transfer=PL_COLOR_TRC_LINEAR, .hdr={.max_luma=peak}};
    if (contrast < 0) dst.hdr.min_luma=1e-7f;
    if (contrast > 0) dst.hdr.min_luma=peak/contrast;
    pl_color_space_infer_map(&src,&dst);
    const int y[] = {16,64,128,235};
    printf("{\"sourceMin\":%.9g,\"sourceMax\":%.9g,\"targetMin\":%.9g,\"targetMax\":%.9g,\"linearBars\":[",
        src.hdr.min_luma,src.hdr.max_luma,dst.hdr.min_luma,dst.hdr.max_luma);
    for (int i=0;i<4;i++) {
        float v=(y[i]-16)/219.0f, color[]={v,v,v};
        pl_color_linearize(&src,color);
        printf("%s%.9g",i?",":"",color[0]);
    }
    puts("]}");
    return 0;
}
