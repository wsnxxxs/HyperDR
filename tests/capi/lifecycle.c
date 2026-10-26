#include "hyperdr/hyperdr.h"
#include <stdio.h>
#include <string.h>
#define REQUIRE(c) do { if (!(c)) {fprintf(stderr,"failed: %s\n",#c);return 1;} } while(0)
int main(void) {
 char* output=NULL;hyperdr_error* error=NULL;hyperdr_engine* engine=NULL;
 REQUIRE(hyperdr_abi_version()==6 && strlen(hyperdr_version())>0);
 REQUIRE(hyperdr_raw_converter_id() && strstr(hyperdr_raw_converter_id(), "/dng-3"));
 REQUIRE(!hyperdr_frame_layout("{\"margins\":0.05,\"caption\":0.1}",3000,2000,&output,&error));
 REQUIRE(strstr(output,"photo"));hyperdr_string_free(output);
 REQUIRE(hyperdr_frame_layout("{\"margin\":0.05}",3000,2000,&output,&error));
 REQUIRE(!output && error && !strcmp(error->code,"invalid_options"));hyperdr_error_free(error);
 REQUIRE(hyperdr_frame_layout("{}",0,2000,&output,&error));REQUIRE(!output);hyperdr_error_free(error);
 REQUIRE(hyperdr_engine_create("{\"heic_tile_workers\":5}",&engine,&error));REQUIRE(!engine);hyperdr_error_free(error);
 REQUIRE(!hyperdr_engine_create("{\"hevc_override\":\"unavailable\"}",&engine,&error));
 REQUIRE(!hyperdr_capabilities(engine,&output,&error));REQUIRE(strstr(output,"encoder"));hyperdr_string_free(output);
 REQUIRE(hyperdr_probe(engine,NULL,&output,&error));REQUIRE(!output&&error);hyperdr_error_free(error);
 REQUIRE(hyperdr_capabilities(NULL,&output,&error));REQUIRE(!output&&error);hyperdr_error_free(error);
 REQUIRE(hyperdr_probe(engine,"/no/such/photo",&output,&error));REQUIRE(!output&&error);hyperdr_error_free(error);
 REQUIRE(hyperdr_package(engine,NULL,&output,&error));REQUIRE(!output&&error);hyperdr_error_free(error);
 hyperdr_cancel* cancel=hyperdr_cancel_create();REQUIRE(cancel);hyperdr_cancel_request(cancel);hyperdr_cancel_destroy(cancel);
 hyperdr_engine_destroy(engine);hyperdr_engine_destroy(NULL);hyperdr_string_free(NULL);hyperdr_error_free(NULL);
 return 0;
}
