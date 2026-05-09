#include <Arduino.h>
#include <Wire.h>
#include <bluefruit.h>
#include "MAX30105.h"

// XIAO nRF52840 default I2C pins: D4 = SDA, D5 = SCL.
// MAX30101/MAX30102/MAX30105 7-bit I2C address used by the SparkFun driver.
static const uint8_t MAX30101_ADDRESS = 0x57;

static const char DEVICE_NAME[] = "JingQiPPG";
static const uint16_t ADC_SAMPLE_RATE_HZ = 100;
static const uint8_t FIFO_AVERAGE = 4;
static const uint16_t FIFO_OUTPUT_RATE_HZ = ADC_SAMPLE_RATE_HZ / FIFO_AVERAGE;
static const uint32_t SAMPLE_PERIOD_US = 1000000UL / FIFO_OUTPUT_RATE_HZ;
static const uint8_t SAMPLES_PER_BLE_BATCH = 4;
static const uint32_t BATCH_MAX_LATENCY_US = 45000UL;
static const size_t BLE_FAST_CHUNK_BYTES = 120;
static const bool SERIAL_SAMPLE_DEBUG = true;
static const uint8_t LED_MODE_RED_IR_GREEN = 3;
static const uint16_t PULSE_WIDTH_US = 411;
// 1. 降低 ADC 量程，提高接收灵敏度 (推荐 4096 或 8192)
static const uint16_t ADC_RANGE_NA = 4096;
// 2. 大幅提升绿光的驱动电流
static const uint8_t RED_LED_CURRENT = 0x24;   // 保持 ~7.2mA
static const uint8_t IR_LED_CURRENT = 0x24;    // 保持 ~7.2mA
// 将绿光直接拉高到 0x7F (~25mA) 或 0xFF (50mA) 测试
static const uint8_t GREEN_LED_CURRENT = 0x7F;


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
  printDeviceInfo();
}

void loop() {
  serialRxPoll();
  handleCommands();
  pumpSamples();
  delay(1);
}
