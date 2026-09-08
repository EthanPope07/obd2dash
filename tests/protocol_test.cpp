#include "../firmware/obd2dash/Protocol.h"
#include <assert.h>
#include <stdio.h>
#include <vector>
using namespace obd;
int main() {
  Pids a,b;
  uint8_t map[]={0x80,0,0,1};
  assert(a.addPage(0,map,4) && a.has(1) && a.has(32) && !a.has(2));
  assert(!b.has(1)); // ECU support never leaks into another ECU.
  assert(!a.addPage(1,map,4) && !a.addPage(0,map,3));
  for(unsigned base=0;base<=224;base+=32) {
    uint8_t all[]={255,255,255,255}; assert(a.addPage(base,all,4));
  }
  for(unsigned p=1;p<256;++p) assert(a.has(p));
  assert(!a.has(0)); // No 0x100 wrap into PID 0.

  Receiver r; r.reset(0x0c);
  uint8_t rpm[]={4,0x41,0x0c,0x1a,0xf8,0,0,0};
  assert(r.feed(rpm,8)==Step::Done && r.length==4 && r.bytes[2]==0x1a);
  r.reset(0x0d);
  assert(r.feed(rpm,8)==Step::Ignore);
  r.reset(0x0c);
  assert(r.feed(rpm,3)==Step::Error); // Truncated single frame.
  uint8_t pending[]={3,0x7f,1,0x78,0,0,0,0};
  assert(r.feed(pending,8)==Step::Pending);
  r.reset(0x0c);
  uint8_t negative[]={3,0x7f,1,0x12,0,0,0,0};
  assert(r.feed(negative,8)==Step::Done && r.negative==0x12);
  negative[0]=2;
  r.reset(0x0c); assert(r.feed(negative,8)==Step::Error);

  // Exercise all classic ISO-TP lengths, sequence wrap, and last-frame padding.
  for(unsigned len=8;len<=MaxPdu;++len) {
    std::vector<uint8_t> expected(len);
    expected[0]=0x41; expected[1]=0x78;
    for(unsigned i=2;i<len;++i) expected[i]=uint8_t(i);
    r.reset(0x78);
    uint8_t ff[8]={uint8_t(0x10|(len>>8)),uint8_t(len)};
    memcpy(ff+2,expected.data(),6);
    assert(r.feed(ff,8)==Step::FlowControl);
    uint8_t seq=1;
    for(unsigned off=6;off<len;off+=7) {
      uint8_t cf[8]={uint8_t(0x20|seq)};
      unsigned n=len-off<7?len-off:7;
      memcpy(cf+1,expected.data()+off,n);
      auto step=r.feed(cf,8);
      assert(step==(off+n==len ? Step::Done : Step::Waiting));
      seq=(seq+1)&15;
    }
    assert(r.length==len && memcmp(r.bytes,expected.data(),len)==0);
  }
  r.reset(1);
  uint8_t ff[]={0x10,20,0x41,1,2,3,4,5};
  uint8_t bad[]={0x22,6,7,8,9,10,11,12};
  assert(r.feed(ff,8)==Step::FlowControl);
  assert(r.feed(bad,8)==Step::Error);
  r.reset(1); assert(r.feed(bad,8)==Step::Ignore);

  // Reassemble the longest BLE payload with minimum ATT MTU.
  std::vector<uint8_t> raw(MaxPdu), received;
  for(size_t i=0;i<raw.size();++i) raw[i]=uint8_t(i);
  for(uint16_t off=0;off<MaxPdu+4;off+=8) {
    uint8_t out[20];
    assert(packet(out,1,0x1234,0x7e8,0x78,Result::Ok,0x87654321,
                  raw.data(),raw.size(),off));
    assert(out[0]==0x11 && out[2]==0xe8 && out[3]==7 && out[4]==0x34 && out[5]==0x12);
    assert(out[11]<=8);
    received.insert(received.end(),out+12,out+12+out[11]);
  }
  assert(received.size()==MaxPdu+4 && received[0]==0x21 && received[3]==0x87);
  assert(memcmp(received.data()+4,raw.data(),raw.size())==0);
  uint8_t out[20];
  assert(!packet(out,1,0,0,0,Result::Ok,0,nullptr,1,0));
  assert(!packet(out,1,0,0,0,Result::Ok,0,nullptr,0,4));
  puts("PASS: ECU bitmap boundaries, all 4088 multi-frame lengths, sequence errors, negatives, BLE fragmentation");
}
