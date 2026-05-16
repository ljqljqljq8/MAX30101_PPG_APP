#include <Arduino.h>
#include <Wire.h>
#include <bluefruit.h>
#include "MAX30105.h"
#include "nrf.h"

// XIAO nRF52840 default I2C pins: D4 = SDA, D5 = SCL.
// MAX30101/MAX30102/MAX30105 7-bit I2C address used by the SparkFun driver.
static const uint8_t MAX30101_ADDRESS = 0x57;

static const char DEVICE_NAME[] = "JingQiPPG";

// === 採樣率設定 ===
static const uint16_t ADC_SAMPLE_RATE_HZ = 400; 
static const uint8_t FIFO_AVERAGE = 4;
static const uint16_t FIFO_OUTPUT_RATE_HZ = ADC_SAMPLE_RATE_HZ / FIFO_AVERAGE; // 100Hz 輸出
static const uint32_t SAMPLE_PERIOD_US = 1000000UL / FIFO_OUTPUT_RATE_HZ;

static const uint8_t SAMPLES_PER_BLE_BATCH = 4;
static const uint32_t BATCH_MAX_LATENCY_US = 45000UL;
static const size_t BLE_FAST_CHUNK_BYTES = 120;
static const bool SERIAL_SAMPLE_DEBUG = true;
static const uint8_t LED_MODE_RED_IR_GREEN = 3;
static const uint16_t PULSE_WIDTH_US = 411; // 411us 提供 18-bit 最高解析度

// === 優化 4：提高 ADC 靈敏度與調整 LED 功率 ===
// 將 ADC_RANGE 從 16384 降至 4096。
// 這會讓感測器對光線變化敏感 4 倍，解決階梯狀波形與微小脈搏被淹沒的問題。
static const uint16_t ADC_RANGE_NA = 4096;

// MAX3010x 電流算法: Value * 0.2mA.
// 調低紅光與 IR 以避免在提高靈敏度後過曝 (0x1F 約 6.2mA)
static const uint8_t RED_LED_CURRENT = 0x1F;   
static const uint8_t IR_LED_CURRENT = 0x1F;    
// 大幅提高綠光功率 (0xE0 約 44.8mA)，以抵抗雜訊並獲取足夠的反射光
static const uint8_t GREEN_LED_CURRENT = 0xE0; 

// ---------- 4 MHz square-wave output on P0.28 (D2) ----------
// Uses TIMER4 + GPIOTE channel 7 + PPI channel 7 (avoids BSP/SD conflicts).
static void startClock4MHz_P0_28() {
  // 1. Stop and clear TIMER4
  NRF_TIMER4->TASKS_STOP  = 1;
  NRF_TIMER4->TASKS_CLEAR = 1;

  // 2. Configure TIMER4: timer mode, 16 MHz (no prescaler), 16-bit
  NRF_TIMER4->MODE        = TIMER_MODE_MODE_Timer;
  NRF_TIMER4->BITMODE     = TIMER_BITMODE_BITMODE_16Bit;
  NRF_TIMER4->PRESCALER   = 0;            // f_timer = 16 MHz
  
  // 3. 產生 4MHz 方波 (每 2 個 tick 翻轉一次 -> 8MHz toggle -> 4MHz pulse)
  NRF_TIMER4->CC[0]       = 2;            
  
  NRF_TIMER4->SHORTS      = TIMER_SHORTS_COMPARE0_CLEAR_Msk;
  NRF_TIMER4->EVENTS_COMPARE[0] = 0;      // clear any pending event

  // 4. Configure GPIOTE channel 7 to toggle P0.28
  NRF_GPIOTE->CONFIG[7] =
      (GPIOTE_CONFIG_MODE_Task       << GPIOTE_CONFIG_MODE_Pos)     |
      (28                            << GPIOTE_CONFIG_PSEL_Pos)     |  // pin 28
      (0                             << GPIOTE_CONFIG_PORT_Pos)     |  // port 0
      (GPIOTE_CONFIG_POLARITY_Toggle << GPIOTE_CONFIG_POLARITY_Pos) |
      (GPIOTE_CONFIG_OUTINIT_Low     << GPIOTE_CONFIG_OUTINIT_Pos);

  // 5. PPI channel 7: TIMER4->COMPARE[0] → GPIOTE->OUT[7]
  NRF_PPI->CH[7].EEP = (uint32_t)&NRF_TIMER4->EVENTS_COMPARE[0];
  NRF_PPI->CH[7].TEP = (uint32_t)&NRF_GPIOTE->TASKS_OUT[7];
  NRF_PPI->CHENSET   = PPI_CHENSET_CH7_Msk;

  // 6. Start TIMER4
  NRF_TIMER4->TASKS_START = 1;

  Serial.println("CLK:4MHz on P0.28 (D2) started");
}

MAX30105 ppg;
BLEUart bleuart;

static bool sensorReady = false;
static bool streamEnabled = false;
static uint32_t sentSamples = 0;
static uint32_t droppedSamples = 0;
static uint32_t streamStartUs = 0;
static uint32_t lastSerialSampleMs = 0;
static bool hasLastSerialSample = false;

struct PpgSample {
  uint32_t timeMs;
  uint32_t red;
  uint32_t ir;
  uint32_t green;
};

static PpgSample sampleBatch[SAMPLES_PER_BLE_BATCH];
static uint8_t sampleBatchCount = 0;
static uint32_t firstBatchQueuedUs = 0;

static volatile bool commandStart = false;
static volatile bool commandPause = false;
static volatile bool commandScan = false;
static volatile bool commandReset = false;
static volatile bool commandTemp = false;
static volatile bool commandInfo = false;
static bool streamStartedFromSerial = false;

static bool sendBleText(const char *text) {
  if (!Bluefruit.connected()) {
    return false;
  }

  const uint8_t *cursor = reinterpret_cast<const uint8_t *>(text);
  size_t remaining = strlen(text);

  while (remaining > 0) {
    size_t chunk = remaining > BLE_FAST_CHUNK_BYTES ? BLE_FAST_CHUNK_BYTES : remaining;
    size_t written = bleuart.write(cursor, chunk);

    if (written == 0 && chunk > 20) {
      chunk = remaining > 20 ? 20 : remaining;
      written = bleuart.write(cursor, chunk);
    }

    if (written == 0) {
      return false;
    }

    cursor += written;
    remaining -= written;
    if (remaining > 0) {
      delay(1);
    }
  }

  return true;
}

static void emitLine(const char *line) {
  Serial.print(line);
  sendBleText(line);
}

static void printDeviceInfo() {
  char line[48];
  snprintf(line, sizeof(line), "READY:%s\n", DEVICE_NAME);
  emitLine(line);
  emitLine("CMD:S start P pause C scan R reset T temp H help\n");
  emitLine("FMT:B:t_ms_dec,red_hex,ir_hex,green_hex;...\n");
}

static void scanI2CBus() {
  emitLine("I2C:SCAN_BEGIN\n");

  bool anyDevice = false;
  for (uint8_t address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    const uint8_t error = Wire.endTransmission();

    if (error == 0) {
      anyDevice = true;
      char line[16];
      snprintf(line, sizeof(line), "I2C:0x%02X\n", address);
      emitLine(line);
      delay(2);
    }
  }

  emitLine(anyDevice ? "I2C:SCAN_END\n" : "I2C:NONE\n");
}

static bool configureMax30101() {
  Wire.begin();
  Wire.setClock(I2C_SPEED_FAST);

  if (!ppg.begin(Wire, I2C_SPEED_FAST, MAX30101_ADDRESS)) {
    sensorReady = false;
    emitLine("INIT:MAX30101_NOT_FOUND\n");
    return false;
  }

  ppg.softReset();
  delay(100);

  ppg.setup(RED_LED_CURRENT,
            FIFO_AVERAGE,
            LED_MODE_RED_IR_GREEN,
            ADC_SAMPLE_RATE_HZ,
            PULSE_WIDTH_US,
            ADC_RANGE_NA);
  ppg.setPulseAmplitudeRed(RED_LED_CURRENT);
  ppg.setPulseAmplitudeIR(IR_LED_CURRENT);
  ppg.setPulseAmplitudeGreen(GREEN_LED_CURRENT);
  ppg.setPulseAmplitudeProximity(0);
  ppg.enableFIFORollover();
  ppg.clearFIFO();

  const uint8_t partId = ppg.readPartID();
  const uint8_t revisionId = ppg.getRevisionID();
  char line[64];
  snprintf(line, sizeof(line), "INIT:OK ID:0x%02X REV:0x%02X ADC:%u OUT:%u AVG:%u\n",
           partId,
           revisionId,
           ADC_SAMPLE_RATE_HZ,
           FIFO_OUTPUT_RATE_HZ,
           FIFO_AVERAGE);
  emitLine(line);

  sensorReady = true;
  return true;
}

static void sendTemperature() {
  if (!sensorReady) {
    emitLine("TEMP:NO_SENSOR\n");
    return;
  }

  const float temperatureC = ppg.readTemperature();
  char line[24];
  snprintf(line, sizeof(line), "T:%.2f\n", temperatureC);
  emitLine(line);
}

static void sendStatus() {
  char line[48];
  snprintf(line, sizeof(line), "STAT:%lu,%lu\n",
           static_cast<unsigned long>(sentSamples),
           static_cast<unsigned long>(droppedSamples));
  emitLine(line);
}

static void resetStreamCounters() {
  streamStartUs = micros();
  sampleBatchCount = 0;
  firstBatchQueuedUs = 0;
  lastSerialSampleMs = 0;
  hasLastSerialSample = false;
  sentSamples = 0;
  droppedSamples = 0;
}

static void printSampleDebug(uint32_t timeMs, uint32_t red, uint32_t ir, uint32_t green) {
  if (!SERIAL_SAMPLE_DEBUG) {
    return;
  }

  const uint32_t dtMs = hasLastSerialSample ? timeMs - lastSerialSampleMs : 0;
  lastSerialSampleMs = timeMs;
  hasLastSerialSample = true;

  Serial.print("P:");
  Serial.print(timeMs);
  Serial.print(',');
  Serial.print(dtMs);
  Serial.print(',');
  Serial.print(red);
  Serial.print(',');
  Serial.print(ir);
  Serial.print(',');
  Serial.println(green);
}

static void flushSampleBatch() {
  if (sampleBatchCount == 0) {
    return;
  }

  char packet[132];
  size_t offset = 0;
  int written = snprintf(packet, sizeof(packet), "B:");
  if (written < 0) {
    sampleBatchCount = 0;
    return;
  }
  offset = static_cast<size_t>(written);

  for (uint8_t i = 0; i < sampleBatchCount && offset < sizeof(packet); i++) {
    const PpgSample &sample = sampleBatch[i];
    written = snprintf(packet + offset,
                       sizeof(packet) - offset,
                       "%lu,%05lX,%05lX,%05lX%c",
                       static_cast<unsigned long>(sample.timeMs),
                       static_cast<unsigned long>(sample.red & 0x3FFFFUL),
                       static_cast<unsigned long>(sample.ir & 0x3FFFFUL),
                       static_cast<unsigned long>(sample.green & 0x3FFFFUL),
                       i + 1 == sampleBatchCount ? '\n' : ';');
    if (written < 0) {
      break;
    }
    offset += static_cast<size_t>(written);
  }

  const bool ok = sendBleText(packet);
  if (ok) {
    sentSamples += sampleBatchCount;
  } else {
    droppedSamples += sampleBatchCount;
  }
  sampleBatchCount = 0;
  firstBatchQueuedUs = 0;
}

static void queueSample(uint32_t timeMs, uint32_t red, uint32_t ir, uint32_t green) {
  if (sampleBatchCount == 0) {
    firstBatchQueuedUs = micros();
  }

  sampleBatch[sampleBatchCount].timeMs = timeMs;
  sampleBatch[sampleBatchCount].red = red;
  sampleBatch[sampleBatchCount].ir = ir;
  sampleBatch[sampleBatchCount].green = green;
  sampleBatchCount++;
  if (sampleBatchCount >= SAMPLES_PER_BLE_BATCH) {
    flushSampleBatch();
  }
}

static void pumpSamples() {
  if (!sensorReady || !streamEnabled) {
    return;
  }

  ppg.check();

  const uint32_t newestSampleUs = micros();
  while (ppg.available() > 0) {
    const uint8_t remaining = ppg.available();
    const uint32_t sampleUs = newestSampleUs - static_cast<uint32_t>(remaining - 1) * SAMPLE_PERIOD_US;
    const uint32_t sampleMs = (sampleUs - streamStartUs) / 1000UL;
    const uint32_t red = ppg.getFIFORed();
    const uint32_t ir = ppg.getFIFOIR();
    const uint32_t green = ppg.getFIFOGreen();

    printSampleDebug(sampleMs, red, ir, green);
    queueSample(sampleMs, red, ir, green);
    ppg.nextSample();
  }

  if (sampleBatchCount > 0 && micros() - firstBatchQueuedUs >= BATCH_MAX_LATENCY_US) {
    flushSampleBatch();
  }
}

static void handleCommands() {
  if (commandInfo) {
    commandInfo = false;
    printDeviceInfo();
  }

  if (commandScan) {
    commandScan = false;
    scanI2CBus();
  }

  if (commandReset) {
    commandReset = false;
    flushSampleBatch();
    streamEnabled = false;
    emitLine("RESET:BEGIN\n");
    configureMax30101();
    emitLine("RESET:END\n");
  }

  if (commandTemp) {
    commandTemp = false;
    sendTemperature();
  }

  if (commandPause) {
    commandPause = false;
    flushSampleBatch();
    streamEnabled = false;
    streamStartedFromSerial = false;
    emitLine("STREAM:OFF\n");
    sendStatus();
  }

  if (commandStart) {
    commandStart = false;
    if (!sensorReady && !configureMax30101()) {
      return;
    }
    ppg.clearFIFO();
    resetStreamCounters();
    streamEnabled = true;
    emitLine("STREAM:ON\n");
  }
}

static void acceptCommand(char command, bool fromSerial) {
  switch (toupper(command)) {
    case 'S':
      commandStart = true;
      streamStartedFromSerial = fromSerial;
      break;
    case 'P':
      commandPause = true;
      break;
    case 'C':
      commandScan = true;
      break;
    case 'R':
      commandReset = true;
      break;
    case 'T':
      commandTemp = true;
      break;
    case 'H':
    case '?':
      commandInfo = true;
      break;
    default:
      break;
  }
}

static void serialRxPoll() {
  while (Serial.available() > 0) {
    const int incoming = Serial.read();
    if (incoming >= 0) {
      acceptCommand(static_cast<char>(incoming), true);
    }
  }
}

static void bleConnectCallback(uint16_t connHandle) {
  (void)connHandle;
  streamEnabled = false;
  streamStartedFromSerial = false;
}

static void bleDisconnectCallback(uint16_t connHandle, uint8_t reason) {
  (void)connHandle;
  (void)reason;
  streamEnabled = false;
  streamStartedFromSerial = false;
}

static void bleRxCallback(uint16_t connHandle) {
  (void)connHandle;

  while (bleuart.available()) {
    const int incoming = bleuart.read();
    if (incoming < 0) {
      continue;
    }

    acceptCommand(static_cast<char>(incoming), false);
  }
}

static void startAdvertising() {
  Bluefruit.Advertising.stop();
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(bleuart);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

static void setupBle() {
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin();
  Bluefruit.setTxPower(4);
  Bluefruit.setName(DEVICE_NAME);
  Bluefruit.Periph.setConnectCallback(bleConnectCallback);
  Bluefruit.Periph.setDisconnectCallback(bleDisconnectCallback);

  bleuart.begin();
  bleuart.setRxCallback(bleRxCallback);

  startAdvertising();
}

void setup() {
  Serial.begin(115200);
  delay(300);

  setupBle();
  configureMax30101();
  startClock4MHz_P0_28();   // D2 → 4 MHz square wave (after BLE/sensor init)
  printDeviceInfo();
}

void loop() {
  serialRxPoll();
  handleCommands();
  pumpSamples();
  delay(1); 
}
