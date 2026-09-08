#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
namespace obd {
constexpr size_t MaxPdu=4095;
enum class Result : uint8_t { Ok=0, Timeout=1, Negative=2, Malformed=3, Transport=4, BusOff=5 };
enum class Step { Ignore, FlowControl, Waiting, Done, Pending, Error };
struct Pids {
  uint8_t bits[32]{};
  bool has(uint8_t pid) const { return (bits[pid/8] & (1u<<(pid%8)))!=0; }
  bool addPage(uint8_t base,const uint8_t* p,size_t n) {
    if(n!=4 || base%32) return false;
    for(unsigned i=0;i<32;++i) {
      unsigned pid=unsigned(base)+1+i;
      if(pid<256 && (p[i/8] & (0x80u>>(i%8)))) bits[pid/8]|=uint8_t(1u<<(pid%8));
    }
    return true;
  }
};
// Classical CAN, normal addressing. Caller validates CAN ID, flags and timeouts.
struct Receiver {
  uint8_t bytes[MaxPdu]{};
  uint16_t length=0,used=0;
  uint8_t next=1,pid=0,negative=0;
  bool active=false;
  void reset(uint8_t requested) {
    length=used=0; next=1; pid=requested; negative=0; active=false;
  }
  bool matches(const uint8_t* p,size_t n) const {
    return (n>=2 && p[0]==0x41 && p[1]==pid) || (n>=3 && p[0]==0x7f && p[1]==0x01);
  }
  Step complete() {
    active=false;
    if(length>=3 && bytes[0]==0x7f && bytes[1]==0x01) {
      negative=bytes[2]; return negative==0x78 ? Step::Pending : Step::Done;
    }
    return Step::Done;
  }
  Step feed(const uint8_t* p,size_t n) {
    if(n==0 || n>8) return Step::Ignore;
    const uint8_t type=p[0]>>4;
    if(type==0) {
      const size_t len=p[0]&15;
      if(!matches(p+1,n-1)) return Step::Ignore;
      if(active || len<2 || len>7 || len>n-1 || !matches(p+1,len)) return Step::Error;
      length=used=uint16_t(len); memcpy(bytes,p+1,len); return complete();
    }
    if(type==1) {
      if(n<4 || !matches(p+2,n-2)) return Step::Ignore;
      unsigned len=((p[0]&15)<<8)|p[1];
      if(active || n!=8 || len<=7 || len>MaxPdu) return Step::Error;
      length=uint16_t(len); used=6; next=1; active=true;
      memcpy(bytes,p+2,6); return Step::FlowControl;
    }
    if(type==2 && active) {
      if(n<2 || (p[0]&15)!=next) { active=false; return Step::Error; }
      size_t remaining=length-used, take=remaining<7 ? remaining : 7;
      if(n-1<take) { active=false; return Step::Error; }
      memcpy(bytes+used,p+1,take); used+=uint16_t(take); next=(next+1)&15;
      return used==length ? complete() : Step::Waiting;
    }
    return Step::Ignore;
  }
};
inline void put16(uint8_t* p,uint16_t v) { p[0]=uint8_t(v); p[1]=uint8_t(v>>8); }
inline void put32(uint8_t* p,uint32_t v) { for(unsigned i=0;i<4;++i) p[i]=uint8_t(v>>(8*i)); }
// Fixed 20-byte notification; explicit byte order, no compiler struct packing.
inline bool packet(uint8_t out[20],uint8_t kind,uint16_t seq,uint16_t ecu,
 uint8_t pid,Result status,uint32_t time,const uint8_t* data,uint16_t len,uint16_t offset) {
  uint16_t total=uint16_t(len+4);
  if(len>MaxPdu || offset>=total || (len && !data)) return false;
  memset(out,0,20);
  out[0]=uint8_t(0x10|(kind&15)); out[1]=pid;
  put16(out+2,ecu); put16(out+4,seq); put16(out+6,offset); put16(out+8,total);
  out[10]=uint8_t(status); out[11]=uint8_t(total-offset<8 ? total-offset : 8);
  for(unsigned i=0;i<out[11];++i) {
    unsigned index=offset+i;
    out[12+i]=index<4 ? uint8_t(time>>(8*index)) : data[index-4];
  }
  return true;
}
}

