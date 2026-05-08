# MAX30101 XIAO nRF52840 BLE PPG

This project provides an Arduino sketch for Seeed Studio XIAO nRF52840 and a Web Bluetooth dashboard for MAX30101 raw PPG streaming.

## Hardware

- XIAO nRF52840 SDA: D4
- XIAO nRF52840 SCL: D5
- MAX30101 I2C address: 0x57
- Use 3V3 and GND from the XIAO if the MAX30101 board supports 3.3 V logic.
- A bare MAX30101 IC needs its required sensor and LED power rails; most breakout boards already include this support.

## Arduino dependencies

Install these in Arduino IDE:

- Seeed nRF52 Boards, then select `Seeed XIAO nRF52840`.
- Adafruit Bluefruit nRF52 library, normally provided with the nRF52 board package.
- SparkFun MAX3010x Pulse and Proximity Sensor Library.

The sketch uses the SparkFun MAX3010x Arduino driver because it exposes MAX30101-compatible FIFO APIs for red, IR, and green channels. Analog Devices/Maxim provide official MAX30101 documents and reference platforms, but their MAX30101 driver code is not packaged as a direct Arduino sketch dependency.

## Files

- `MAX30101/MAX30101.ino`: XIAO nRF52840 firmware.
- `index.html`: Web Bluetooth dashboard.
- `MAX30101/MAX30101.ino.bak_20260508_initial`: backup of the original local sketch.

## BLE protocol

The firmware advertises as `JingQiPPG` and uses Nordic UART Service:

- Service: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- RX write: `6e400002-b5a3-f393-e0a9-e50e24dcca9e`
- TX notify: `6e400003-b5a3-f393-e0a9-e50e24dcca9e`

Commands sent from the browser:

- `S`: start streaming
- `P`: pause streaming
- `C`: scan I2C bus
- `R`: reset and reinitialize MAX30101
- `T`: read die temperature
- `H`: print help

PPG samples are sent as compact batched text notifications:

```text
B:t_ms,RRRRR,IIIII,GGGGG;t_ms,RRRRR,IIIII,GGGGG
```

`t_ms` is the decimal sample timestamp in milliseconds from stream start. Red, IR, and green are 5-digit hexadecimal 18-bit raw ADC values.

## Run

1. Upload `MAX30101/MAX30101.ino` to the XIAO nRF52840.
2. Serve the project folder on localhost, for example:

```powershell
python -m http.server 8765 --bind 127.0.0.1
```

3. Open `http://127.0.0.1:8765/index.html` in Chrome or Edge.
4. Click `Connect`, choose `JingQiPPG`, then click `Start`.
