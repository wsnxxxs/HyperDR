#include "hyperdr/hyperdr.h"
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define REQUIRE(c) do {if(!(c)){fprintf(stderr,"failed: %s\n",#c);return (void*)1;}}while(0)
static int rows(void* user,uint32_t y,uint32_t count,float* base,float* gain) {
 (void)user;(void)y;
 for(size_t i=0;i<(size_t)count*16*3;++i)base[i]=.25F;
 if(gain)for(size_t i=0;i<(size_t)count*16;++i)gain[i]=1;
 return 0;
}
static void progress(void* user,uint32_t phase,uint32_t done,uint32_t total){(void)user;(void)phase;(void)done;(void)total;}
static void* work(void* unused) {
 const char* raw=unused;hyperdr_engine* engine=NULL;hyperdr_error* error=NULL;char* text=NULL;
 REQUIRE(hyperdr_abi_version()==6);
 REQUIRE(!hyperdr_engine_create(NULL,&engine,&error));
 REQUIRE(!hyperdr_capabilities(engine,&text,&error));const int hevc=strstr(text,"\"main10\":true")!=NULL;hyperdr_string_free(text);
 REQUIRE(!hyperdr_frame_layout("{\"margins\":0.05}",16,16,&text,&error));hyperdr_string_free(text);
 REQUIRE(hyperdr_raw_converter_id()&&strstr(hyperdr_raw_converter_id(),"libraw-"));
 char dng[512],preview[512],cancelled[512];
 snprintf(dng,sizeof dng,"%s/stack-%d.dng",getenv("TMPDIR")?getenv("TMPDIR"):"/tmp",getpid());
 snprintf(preview,sizeof preview,"%s/stack-%d.jpg",getenv("TMPDIR")?getenv("TMPDIR"):"/tmp",getpid());
 snprintf(cancelled,sizeof cancelled,"%s/stack-%d-cancelled.dng",getenv("TMPDIR")?getenv("TMPDIR"):"/tmp",getpid());
 unlink(dng);unlink(preview);unlink(cancelled);
 REQUIRE(!hyperdr_raw_convert_dng(engine,raw,dng,NULL,&text,&error));REQUIRE(strstr(text,"\"layout\":\"cfa\""));hyperdr_string_free(text);
 REQUIRE(!hyperdr_raw_extract_preview(engine,raw,preview,NULL,&text,&error));REQUIRE(strstr(text,"\"width\":"));hyperdr_string_free(text);
 unlink(dng);unlink(preview);
 hyperdr_cancel* raw_cancel=hyperdr_cancel_create();REQUIRE(raw_cancel);hyperdr_cancel_request(raw_cancel);
 REQUIRE(hyperdr_raw_convert_dng(engine,raw,cancelled,raw_cancel,&text,&error));
 REQUIRE(!text&&error&&!strcmp(error->code,"cancelled"));hyperdr_error_free(error);error=NULL;
 REQUIRE(access(cancelled,F_OK)!=0);hyperdr_cancel_destroy(raw_cancel);
 const char* formats[]={"sdr-jpeg","sdr-tiff","iso-gainmap-jpeg","avif-pq","adaptive","pq","hlg"};
 for(unsigned f=0;f<7;++f){
  if(f>=4&&!hevc)continue;
  char path[512];snprintf(path,sizeof path,"%s/stack-%d-%u",getenv("TMPDIR")?getenv("TMPDIR"):"/tmp",getpid(),f);
  float base[16*16*3],gain[16*16];rows(NULL,0,16,base,gain);
  hyperdr_package_plane plane={base,0,sizeof base,16,16,3,HYPERDR_PLANE_F32};
  hyperdr_package_gain auxiliary={0};auxiliary.plane=(hyperdr_package_plane){gain,0,sizeof gain,16,16,1,HYPERDR_PLANE_F32};auxiliary.alternate_headroom=2;
  hyperdr_package_request request={0};request.output_path=path;request.format=formats[f];request.parameters_json="{\"overwrite\":true}";request.sdr=&plane;request.gain=&auxiliary;
  REQUIRE(!hyperdr_package(engine,&request,&text,&error));hyperdr_string_free(text);
  REQUIRE(!hyperdr_probe(engine,path,&text,&error));hyperdr_string_free(text);
  if(hyperdr_package_rows_supported(formats[f])){REQUIRE(!hyperdr_package_rows(engine,&request,8,rows,NULL,&text,&error));hyperdr_string_free(text);
   REQUIRE(!hyperdr_package_rows_progress(engine,&request,8,rows,progress,NULL,&text,&error));hyperdr_string_free(text);}
  unlink(path);
 }
 hyperdr_cancel* cancel=hyperdr_cancel_create();REQUIRE(cancel);hyperdr_cancel_request(cancel);hyperdr_cancel_destroy(cancel);
 hyperdr_engine_destroy(engine);return NULL;
}
int main(int argc,char**argv){pthread_attr_t attr;pthread_t thread;void* result=NULL;
 if(argc<2)return 2;
 if(pthread_attr_init(&attr)||pthread_attr_setstacksize(&attr,512*1024)||pthread_create(&thread,&attr,work,argv[1])||pthread_join(thread,&result))return 1;
 pthread_attr_destroy(&attr);return result!=NULL;
}
