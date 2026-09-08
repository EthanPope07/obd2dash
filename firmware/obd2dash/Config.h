#pragma once
#include "driver/gpio.h"
constexpr gpio_num_t CAN_TX_PIN=GPIO_NUM_4;
constexpr gpio_num_t CAN_RX_PIN=GPIO_NUM_5;
constexpr unsigned CAN_BITRATE=500000; // Or 250000 for a known compatible vehicle.
constexpr uint32_t RESPONSE_MS=300;
constexpr uint32_t TRANSACTION_MAX_MS=5000;
constexpr uint32_t REQUEST_GAP_MS=50;
constexpr uint32_t REDISCOVER_MS=60000;
constexpr uint32_t BLE_FRAGMENT_GAP_MS=15;
constexpr char SERVICE_UUID[]="973a0001-6f8a-4db7-a735-79d348be7341";
constexpr char STREAM_UUID[]="973a0002-6f8a-4db7-a735-79d348be7341";
constexpr char INFO_UUID[]="973a0003-6f8a-4db7-a735-79d348be7341";

