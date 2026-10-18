#include <stdio.h>
#include <string.h>
#include <mpv/client.h>
int main(int argc,char **argv) {
 if(argc!=3)return 1;
 mpv_handle *m=mpv_create();mpv_set_option_string(m,"vo","null");mpv_set_option_string(m,"ao","null");mpv_set_option_string(m,"pause","yes");
 if(mpv_initialize(m)<0)return 2;
 char *keys[]={"audio-files-append"};mpv_node value={.format=MPV_FORMAT_STRING,.u.string=argv[2]};mpv_node_list options={1,&value,keys};
 mpv_node args[]={{.format=MPV_FORMAT_STRING,.u.string="loadfile"},{.format=MPV_FORMAT_STRING,.u.string=argv[1]},{.format=MPV_FORMAT_STRING,.u.string="replace"},{.format=MPV_FORMAT_INT64,.u.int64=-1},{.format=MPV_FORMAT_NODE_MAP,.u.list=&options}};
 mpv_node_list list={5,args,NULL};mpv_node cmd={.format=MPV_FORMAT_NODE_ARRAY,.u.list=&list};if(mpv_command_node(m,&cmd,NULL)<0)return 3;
 int loaded=0;for(int i=0;i<100;i++){if(mpv_wait_event(m,.1)->event_id==MPV_EVENT_FILE_LOADED){loaded=1;break;}}
 char *s=mpv_get_property_string(m,"track-list/1/external-filename");int ok=loaded && s && strcmp(s,argv[2])==0;
 printf("{\"fileLocalOption\":\"audio-files-append\",\"inputHasCommaAndColon\":true,\"fileLoaded\":%s,\"exactExternalFilenameEqual\":%s}\n",loaded?"true":"false",ok?"true":"false");
 mpv_free(s);mpv_terminate_destroy(m);return ok?0:4;
}
