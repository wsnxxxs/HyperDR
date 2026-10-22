#pragma once
#include "hevc_bits.hpp"
#include <algorithm>
#include <array>

namespace hyperdr::container {
// H.265 clauses 7.3.2, 7.3.3 and 7.3.4: bounded Main/Main10,
// single-layer parameter sets. Extensions are rejected, never skipped.
inline void hevc_require(bool valid) {
  if (!valid) throw std::invalid_argument("invalid or unsupported HEVC parameter syntax");
}
inline unsigned limited_ue(HevcBits& b, unsigned maximum) {
  const auto value=b.ue();hevc_require(value<=maximum);return value;
}
inline int limited_se(HevcBits& b,int minimum,int maximum) {
  const auto code=b.ue();
  const auto value=(code&1) ? std::int64_t(code/2)+1 : -std::int64_t(code/2);
  hevc_require(value>=minimum && value<=maximum);return static_cast<int>(value);
}
inline void zero_bits(HevcBits& b,unsigned count) {
  while(count) {const auto n=std::min(count,32U);hevc_require(b.take(n)==0);count-=n;}
}
inline void main_profile(std::span<const std::uint8_t> p) {
  const auto id=p[0]&31;
  hevc_require((p[0]>>6)==0 && (id==1 || id==2));
  // Only Main/Main10 compatibility bits; extension profiles change constraints.
  for(unsigned idc=4;idc<32;++idc) hevc_require(!(p[1+idc/8]&(0x80>>(idc%8))));
  // The 43 reserved bits start at bit 4 of p[5]; Main10 lets the eighth of
  // them be one_picture_only_constraint_flag. general_inbld_flag is zero.
  const bool main10=id==2 || (p[1]&0x20);
  hevc_require((p[5]&15)==0 && (p[6]&(main10?0xEF:0xFF))==0);
  hevc_require(p[7]==0 && p[8]==0 && p[9]==0 && p[10]==0);
}
inline std::array<std::uint8_t,12> profile_tier_level(HevcBits& b,unsigned layers) {
  std::array<std::uint8_t,12> p{};
  for(auto& byte:p)byte=static_cast<std::uint8_t>(b.take(8));
  main_profile(p);
  std::array<bool,7> profile{},level{};
  for(unsigned i=0;i<layers;++i){profile[i]=b.take(1);level[i]=b.take(1);}
  if(layers)zero_bits(b,2*(8-layers));
  for(unsigned i=0;i<layers;++i){
    if(profile[i]){
      auto sub=p;for(unsigned j=0;j<11;++j)sub[j]=static_cast<std::uint8_t>(b.take(8));
      main_profile(sub);
    }
    if(level[i])b.skip(8);
  }
  return p;
}
// Returns max_dec_pic_buffering_minus1 of the highest sub-layer.
inline unsigned ordering(HevcBits& b,unsigned layers) {
  const auto all=b.take(1);unsigned previous=0;
  for(unsigned i=all?0:layers;i<=layers;++i){
    const auto dpb=limited_ue(b,15);hevc_require(!all || !i || dpb>=previous);previous=dpb;
    (void)limited_ue(b,dpb);(void)b.ue();
  }
  return previous;
}
struct HrdCommon {bool nal{},vcl{},sub_pic{};};
inline void hrd(HevcBits& b,unsigned layers,HrdCommon& common,bool present=true) {
  if(present){
    common.nal=b.take(1);common.vcl=b.take(1);common.sub_pic=false;
    if(common.nal || common.vcl){
      common.sub_pic=b.take(1);if(common.sub_pic)b.skip(8+5+1+5);
      b.skip(4+4);if(common.sub_pic)b.skip(4);b.skip(5+5+5);
    }
  }
  for(unsigned i=0;i<=layers;++i){
    const bool fixed=b.take(1);const bool within=fixed || b.take(1);
    bool low=false;if(within)(void)limited_ue(b,2047);else low=b.take(1);
    const auto cpb=low?0:limited_ue(b,31);
    for(bool enabled:{common.nal,common.vcl})if(enabled)for(unsigned n=0;n<=cpb;++n){
      hevc_require(b.ue()!=UINT32_MAX);hevc_require(b.ue()!=UINT32_MAX);
      if(common.sub_pic){hevc_require(b.ue()!=UINT32_MAX);hevc_require(b.ue()!=UINT32_MAX);}
      b.skip(1);
    }
  }
}
struct VpsSyntax {unsigned id{},layers{};bool nested{};};
inline VpsSyntax validate_vps(HevcBits& b) {
  VpsSyntax out;out.id=b.take(4);
  hevc_require(b.take(1)==1 && b.take(1)==1 && b.take(6)==0);
  out.layers=b.take(3);hevc_require(out.layers<=6);out.nested=b.take(1);
  hevc_require(out.layers || out.nested);hevc_require(b.take(16)==0xFFFF);
  (void)profile_tier_level(b,out.layers);(void)ordering(b,out.layers);
  hevc_require(b.take(6)==0);hevc_require(b.ue()==0); // no other layer sets
  if(b.take(1)){
    hevc_require(b.take(32)!=0);hevc_require(b.take(32)!=0);
    if(b.take(1))hevc_require(b.ue()!=UINT32_MAX);
    const auto count=limited_ue(b,1);HrdCommon common;
    for(unsigned i=0;i<count;++i){hevc_require(b.ue()==0);hrd(b,out.layers,common);}
  }
  hevc_require(b.take(1)==0); // vps_extension_flag
  b.trailing();return out;
}
inline void scaling_list(HevcBits& b) {
  for(unsigned size=0;size<4;++size)for(unsigned matrix=0;matrix<6;matrix+=size==3?3:1){
    if(!b.take(1)){
      (void)limited_ue(b,size==3?matrix/3:matrix); // scaling_list_pred_matrix_id_delta
    }else{
      if(size>1)(void)limited_se(b,-7,247);
      for(unsigned i=0;i<std::min(64U,1U<<(4+2*size));++i)(void)limited_se(b,-128,127);
    }
  }
}
inline void vui(HevcBits& b,unsigned layers) {
  if(b.take(1)){
    const auto aspect=b.take(8);hevc_require(aspect<=16 || aspect==255);
    if(aspect==255)b.skip(32); // sar_width/sar_height; zero means unspecified
  }
  if(b.take(1))b.skip(1);
  if(b.take(1)){hevc_require(b.take(3)<=5);b.skip(1);if(b.take(1))b.skip(24);}
  if(b.take(1)){(void)limited_ue(b,5);(void)limited_ue(b,5);}
  b.skip(3); // neutral_chroma_indication, field_seq, frame_field_info
  if(b.take(1))for(unsigned i=0;i<4;++i)(void)b.ue();
  if(b.take(1)){
    hevc_require(b.take(32)!=0);hevc_require(b.take(32)!=0);
    if(b.take(1))hevc_require(b.ue()!=UINT32_MAX);
    if(b.take(1)){HrdCommon common;hrd(b,layers,common);}
  }
  if(b.take(1)){
    b.skip(3);(void)limited_ue(b,4095);
    (void)limited_ue(b,16);(void)limited_ue(b,16);(void)limited_ue(b,15);(void)limited_ue(b,15);
  }
}
inline void short_term_sets(HevcBits& b,unsigned dpb) {
  const auto count=limited_ue(b,64);std::array<unsigned,64> deltas{};
  for(unsigned i=0;i<count;++i){
    if(i && b.take(1)){
      b.skip(1);(void)limited_ue(b,32767); // delta_rps_sign, abs_delta_rps_minus1
      for(unsigned j=0;j<=deltas[i-1];++j){
        const bool used=b.take(1);const bool delta=used || b.take(1);
        deltas[i]+=delta;
      }
      hevc_require(deltas[i]<=dpb);
    }else{
      const auto negative=limited_ue(b,dpb),positive=limited_ue(b,dpb-negative);
      deltas[i]=negative+positive;
      for(unsigned j=0;j<deltas[i];++j){(void)limited_ue(b,32767);b.skip(1);}
    }
  }
}
struct SpsSyntax {
  unsigned id{},layers{},nested{},chroma{},depth{},width{},height{};
  unsigned coded_width{},coded_height{},ctb_log2{},cb_difference{};
  std::array<std::uint8_t,12> profile{};
};
inline SpsSyntax validate_sps(HevcBits& b,const VpsSyntax& vps) {
  SpsSyntax out;hevc_require(b.take(4)==vps.id);
  out.layers=b.take(3);hevc_require(out.layers<=vps.layers);out.nested=b.take(1);
  hevc_require(out.layers || out.nested);hevc_require(!vps.nested || out.nested);
  out.profile=profile_tier_level(b,out.layers);out.id=limited_ue(b,15);
  out.chroma=limited_ue(b,1);hevc_require(out.chroma==1);
  out.coded_width=limited_ue(b,131072);out.coded_height=limited_ue(b,131072);
  hevc_require(out.coded_width && out.coded_height);
  std::uint64_t crop_x=0,crop_y=0;
  if(b.take(1)){
    const auto left=b.ue(),right=b.ue(),top=b.ue(),bottom=b.ue();
    crop_x=(std::uint64_t(left)+right)*2;crop_y=(std::uint64_t(top)+bottom)*2;
  }
  hevc_require(crop_x<out.coded_width && crop_y<out.coded_height);
  out.width=out.coded_width-static_cast<unsigned>(crop_x);out.height=out.coded_height-static_cast<unsigned>(crop_y);
  out.depth=limited_ue(b,2);hevc_require(out.depth==0 || out.depth==2);hevc_require(b.ue()==out.depth);
  hevc_require((out.profile[0]&31)==2 || out.depth==0);
  const auto poc=limited_ue(b,12)+4;const auto dpb=ordering(b,out.layers);
  const auto min_cb=limited_ue(b,3)+3;out.cb_difference=limited_ue(b,6-min_cb);
  out.ctb_log2=min_cb+out.cb_difference;
  hevc_require(out.ctb_log2>=4);
  hevc_require(out.coded_width%(1U<<min_cb)==0 && out.coded_height%(1U<<min_cb)==0);
  const auto min_tb=limited_ue(b,3)+2;hevc_require(min_tb<min_cb);
  const auto max_tb=min_tb+limited_ue(b,std::min(5U,out.ctb_log2)-min_tb);
  (void)max_tb;
  (void)limited_ue(b,out.ctb_log2-min_tb);(void)limited_ue(b,out.ctb_log2-min_tb);
  if(b.take(1) && b.take(1))scaling_list(b);
  b.skip(2); // amp, sample_adaptive_offset
  if(b.take(1)){
    hevc_require(b.take(4)+1<=out.depth+8);hevc_require(b.take(4)+1<=out.depth+8);
    const auto pcm_max=std::min(5U,out.ctb_log2);
    const auto pcm=limited_ue(b,2)+3;hevc_require(pcm>=std::min(min_cb,5U) && pcm<=pcm_max);
    (void)limited_ue(b,pcm_max-pcm);b.skip(1);
  }
  short_term_sets(b,dpb);
  if(b.take(1))for(unsigned i=0,count=limited_ue(b,32);i<count;++i)b.skip(poc+1);
  b.skip(2);if(b.take(1))vui(b,out.layers);
  hevc_require(b.take(1)==0); // sps_extension_present_flag
  b.trailing();return out;
}
inline void validate_pps(HevcBits& b,const SpsSyntax& sps) {
  (void)limited_ue(b,63);hevc_require(b.ue()==sps.id);
  b.skip(2+3+2);(void)limited_ue(b,14);(void)limited_ue(b,14);
  (void)limited_se(b,-26-6*static_cast<int>(sps.depth),25);
  b.skip(2);if(b.take(1))(void)limited_ue(b,sps.cb_difference);
  (void)limited_se(b,-12,12);(void)limited_se(b,-12,12);b.skip(4);
  const auto tiles=b.take(1);b.skip(1); // entropy_coding_sync_enabled
  if(tiles){
    const auto ctb=1U<<sps.ctb_log2;
    const auto width=(sps.coded_width+ctb-1)/ctb,height=(sps.coded_height+ctb-1)/ctb;
    const auto columns=limited_ue(b,std::min(20U,width)-1),rows=limited_ue(b,std::min(22U,height)-1);
    hevc_require(columns || rows);
    if(!b.take(1)){
      unsigned sum=0;for(unsigned i=0;i<columns;++i){sum+=limited_ue(b,width-1)+1;hevc_require(sum<width);}
      sum=0;for(unsigned i=0;i<rows;++i){sum+=limited_ue(b,height-1)+1;hevc_require(sum<height);}
    }
    b.skip(1);
  }
  b.skip(1); // pps_loop_filter_across_slices_enabled
  if(b.take(1)){
    b.skip(1);if(!b.take(1)){(void)limited_se(b,-6,6);(void)limited_se(b,-6,6);}
  }
  if(b.take(1))scaling_list(b);
  b.skip(1);(void)limited_ue(b,sps.ctb_log2-2);b.skip(1);
  hevc_require(b.take(1)==0); // pps_extension_present_flag
  b.trailing();
}
} // namespace hyperdr::container
