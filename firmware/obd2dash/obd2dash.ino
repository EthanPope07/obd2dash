#include <Arduino.h>
#include <atomic>
#include "driver/twai.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "Config.h"
#include "Protocol.h"

struct Ecu {
  obd::Pids pids;
  bool present=false;
  bool complete=false;
};
Ecu ecus[8];
obd::Receiver receiver;
BLECharacteristic* stream=nullptr;
BLE2902* subscription=nullptr;
std::atomic<bool> connected{false}, restartAdvertising{false};
std::atomic<uint32_t> connectionEpoch{0};
uint16_t sampleSequence=0;
uint32_t lastRequest=0,lastDiscovery=0;
unsigned ecuCursor=0,pidCursor=1;
bool discovered=false;
uint32_t goodSamples=0,failedSamples=0;

class Connections : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    connectionEpoch.fetch_add(1);
    connected.store(true);
  }
  void onDisconnect(BLEServer*) override {
    connected.store(false);
    connectionEpoch.fetch_add(1);
    restartAdvertising.store(true);
  }
};

void serviceBle() {
  if(restartAdvertising.exchange(false)) {
    subscription->setNotifications(false);
    BLEDevice::startAdvertising();
  }
}
void publish(uint8_t kind,uint16_t ecu,uint8_t pid,obd::Result status,
             const uint8_t* data,uint16_t length) {
  const uint16_t seq=sampleSequence++;
  const uint32_t stamp=millis(), epoch=connectionEpoch.load();
  if(!connected.load() || !subscription->getNotifications()) return;
  uint8_t frame[20];
  for(uint16_t offset=0;offset<length+4;offset+=8) {
    if(!connected.load() || connectionEpoch.load()!=epoch ||
       !subscription->getNotifications()) return;
    if(!obd::packet(frame,kind,seq,ecu,pid,status,stamp,data,length,offset)) return;
    stream->setValue(frame,sizeof(frame));
    stream->notify();
    // Notifications are best effort, not an acknowledged sample transport.
    delay(BLE_FRAGMENT_GAP_MS);
  }
}

bool busReady() {
  twai_status_info_t info{};
  if(twai_get_status_info(&info)!=ESP_OK) return false;
  if(info.state==TWAI_STATE_BUS_OFF) {
    Serial.println("CAN bus-off: initiating recovery");
    twai_initiate_recovery();
    return false;
  }
  if(info.state==TWAI_STATE_STOPPED) return twai_start()==ESP_OK;
  return info.state==TWAI_STATE_RUNNING;
}

bool sendCan(uint16_t id,const uint8_t* data) {
  twai_message_t frame{};
  frame.identifier=id;
  frame.data_length_code=8;
  frame.ss=1; // Do not endlessly retry requests on an absent/failed bus.
  memcpy(frame.data,data,8);
  return twai_transmit(&frame,pdMS_TO_TICKS(50))==ESP_OK;
}

obd::Result request(uint8_t ecu,uint8_t pid) {
  serviceBle();
  receiver.reset(pid);
  if(!busReady()) { delay(100); return obd::Result::BusOff; }
  while(uint32_t(millis()-lastRequest)<REQUEST_GAP_MS) delay(1);
  // Discard old queued frames before starting a new physical transaction.
  twai_message_t stale{};
  for(unsigned i=0;i<128 && twai_receive(&stale,0)==ESP_OK;++i) {}
  uint32_t alerts=0;
  twai_read_alerts(&alerts,0);
  const uint8_t payload[8]={2,1,pid,0,0,0,0,0};
  lastRequest=millis();
  if(!sendCan(0x7e0+ecu,payload)) return obd::Result::Transport;
  uint32_t start=millis(), activity=start, waitBudget=RESPONSE_MS;
  // Absolute cap also bounds repeated response-pending replies.
  while(uint32_t(millis()-start)<TRANSACTION_MAX_MS &&
        uint32_t(millis()-activity)<waitBudget) {
    twai_read_alerts(&alerts,0);
    if(alerts & TWAI_ALERT_BUS_OFF) return obd::Result::BusOff;
    if(alerts & (TWAI_ALERT_RX_QUEUE_FULL|TWAI_ALERT_TX_FAILED))
      return obd::Result::Transport;
    twai_message_t frame{};
    if(twai_receive(&frame,pdMS_TO_TICKS(10))!=ESP_OK) continue;
    if(frame.extd || frame.rtr || frame.identifier!=unsigned(0x7e8+ecu)) continue;
    const auto step=receiver.feed(frame.data,frame.data_length_code);
    if(step==obd::Step::Ignore) continue;
    activity=millis(); waitBudget=RESPONSE_MS;
    if(step==obd::Step::Error) return obd::Result::Malformed;
    if(step==obd::Step::FlowControl) {
      const uint8_t fc[8]={0x30,0,5,0,0,0,0,0}; // CTS, unlimited block, 5 ms STmin.
      if(!sendCan(0x7e0+ecu,fc)) return obd::Result::Transport;
    } else if(step==obd::Step::Pending) {
      receiver.reset(pid);
      waitBudget=TRANSACTION_MAX_MS;
    } else if(step==obd::Step::Done) {
      return receiver.negative ? obd::Result::Negative : obd::Result::Ok;
    }
  }
  return obd::Result::Timeout;
}

void discovery() {
  Serial.println("Discovering each ECU's Mode 01 support pages");
  for(unsigned e=0;e<8;++e) {
    ecus[e]=Ecu{};
    for(unsigned base=0;base<=0xe0;base+=0x20) {
      obd::Result result=obd::Result::Timeout;
      for(unsigned attempt=0;attempt<3;++attempt) {
        result=request(e,uint8_t(base));
        if(result==obd::Result::Ok || result==obd::Result::Negative) break;
      }
      if(result!=obd::Result::Ok) {
        // A failed page is not interpreted as an empty supported-PID map.
        const uint8_t nrc=receiver.negative;
        publish(2,0x7e8+e,uint8_t(base),result,&nrc,
                result==obd::Result::Negative ? 1 : 0);
        break;
      }
      if(receiver.length!=6 ||
         !ecus[e].pids.addPage(uint8_t(base),receiver.bytes+2,receiver.length-2)) {
        publish(2,0x7e8+e,uint8_t(base),obd::Result::Malformed,nullptr,0);
        break;
      }
      ecus[e].present=true;
      publish(2,0x7e8+e,uint8_t(base),obd::Result::Ok,receiver.bytes+2,4);
      if(base==0xe0 || !ecus[e].pids.has(uint8_t(base+32))) {
        ecus[e].complete=true; break;
      }
    }
    unsigned count=0;
    for(unsigned p=1;p<256;++p)
      if(p%32 && ecus[e].pids.has(uint8_t(p))) ++count;
    Serial.printf("ECU %03X: %u data PIDs; discovery %s\n",0x7e8+e,count,
                  ecus[e].complete ? "complete" : "unavailable/incomplete");
  }
  lastDiscovery=millis(); discovered=true; ecuCursor=0; pidCursor=1;
}

void setup() {
  Serial.begin(115200);
  BLEDevice::init("OBD2Dash");
  auto* server=BLEDevice::createServer();
  server->setCallbacks(new Connections());
  auto* service=server->createService(SERVICE_UUID);
  stream=service->createCharacteristic(STREAM_UUID,BLECharacteristic::PROPERTY_NOTIFY);
  subscription=new BLE2902();
  stream->addDescriptor(subscription);
  auto* info=service->createCharacteristic(INFO_UUID,BLECharacteristic::PROPERTY_READ);
  info->setValue("OBD2Dash v1; Mode01; CAN11; raw; 20-byte fragments");
  service->start();
  auto* advertising=BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  twai_general_config_t general=TWAI_GENERAL_CONFIG_DEFAULT(CAN_TX_PIN,CAN_RX_PIN,TWAI_MODE_NORMAL);
  general.rx_queue_len=128;
  general.tx_queue_len=0;
  general.alerts_enabled=TWAI_ALERT_BUS_OFF|TWAI_ALERT_RX_QUEUE_FULL|TWAI_ALERT_TX_FAILED;
  static_assert(CAN_BITRATE==500000 || CAN_BITRATE==250000,"Unsupported CAN bitrate");
  twai_timing_config_t timing=TWAI_TIMING_CONFIG_500KBITS();
  const twai_timing_config_t slow=TWAI_TIMING_CONFIG_250KBITS();
  if(CAN_BITRATE==250000) timing=slow;
  twai_filter_config_t filter=TWAI_FILTER_CONFIG_ACCEPT_ALL();
  if(twai_driver_install(&general,&timing,&filter)!=ESP_OK || twai_start()!=ESP_OK) {
    Serial.println("CAN initialization failed; check pins/configuration");
    while(true) delay(1000);
  }
}

void loop() {
  serviceBle();
  // Rediscover only between full sweeps so slow ECUs cannot starve later PIDs.
  if(!discovered || (ecuCursor>=8 && uint32_t(millis()-lastDiscovery)>=REDISCOVER_MS)) {
    discovery();
  }
  if(ecuCursor>=8) {
    ecuCursor=0; pidCursor=1;
    Serial.printf("Samples: %lu valid, %lu failed\n",
                  (unsigned long)goodSamples,(unsigned long)failedSamples);
    delay(50);
  }
  while(ecuCursor<8) {
    while(pidCursor<256) {
      const uint8_t pid=uint8_t(pidCursor++);
      if(pid%32==0 || !ecus[ecuCursor].pids.has(pid)) continue;
      auto result=request(ecuCursor,pid);
      if(result==obd::Result::Ok) {
        ++goodSamples;
        publish(1,0x7e8+ecuCursor,pid,result,receiver.bytes+2,receiver.length-2);
      } else {
        ++failedSamples;
        uint8_t nrc=receiver.negative;
        publish(1,0x7e8+ecuCursor,pid,result,&nrc,result==obd::Result::Negative ? 1 : 0);
      }
      return;
    }
    ++ecuCursor; pidCursor=1;
  }
  delay(10);
}

