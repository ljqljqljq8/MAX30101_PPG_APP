# 功能说明

这个项目提供 XIAO nRF52840 + MAX30101 的 Arduino 固件，以及一个用于查看原始 PPG 波形的 Web Bluetooth 页面。

## 硬件

- XIAO nRF52840 SDA：D4
- XIAO nRF52840 SCL：D5
- MAX30101 I2C 地址：`0x57`
- 如果 MAX30101 模块支持 3.3 V 逻辑电平，可以直接使用 XIAO 的 `3V3` 和 `GND`。
- 如果使用裸 MAX30101 芯片，需要额外准备传感器和 LED 所需电源；常见开发板通常已经集成。

## Arduino 依赖

在 Arduino IDE 中安装：

- Seeed nRF52 Boards，并选择 `Seeed XIAO nRF52840`。
- Adafruit Bluefruit nRF52 library，通常随 nRF52 板卡包提供。
- SparkFun MAX3010x Pulse and Proximity Sensor Library。

固件使用 SparkFun MAX3010x Arduino 驱动，因为它提供了兼容 MAX30101 的 FIFO API，可读取 Red、IR 和 Green 三路原始数据。

## 文件

- `MAX30101/MAX30101.ino`：XIAO nRF52840 固件。
- `index.html`：Web Bluetooth 实时看板。
- `docs/images/web-bluetooth-ppg.png`：网页端蓝牙效果图。
- `docs/images/ios-live-ppg.jpg`：iOS 端效果图。

## BLE 协议

固件广播设备名为 `JingQiPPG`，使用 Nordic UART Service：

- Service：`6e400001-b5a3-f393-e0a9-e50e24dcca9e`
- RX write：`6e400002-b5a3-f393-e0a9-e50e24dcca9e`
- TX notify：`6e400003-b5a3-f393-e0a9-e50e24dcca9e`

网页端发送的命令：

- `S`：开始采集
- `P`：暂停采集
- `C`：扫描 I2C 总线
- `R`：复位并重新初始化 MAX30101
- `T`：读取芯片温度
- `H`：打印帮助信息

PPG 样本通过紧凑的批量文本通知发送：

```text
B:t_ms,RRRRR,IIIII,GGGGG;t_ms,RRRRR,IIIII,GGGGG
```

其中 `t_ms` 是从采集开始计时的毫秒时间戳，Red、IR 和 Green 是 5 位十六进制表示的 18-bit 原始 ADC 值。

## 运行

1. 将 `MAX30101/MAX30101.ino` 上传到 XIAO nRF52840。
2. 在仓库目录启动本地服务，例如：

```powershell
python -m http.server 8765 --bind 127.0.0.1
```

3. 在 Chrome 或 Edge 中打开 `http://127.0.0.1:8765/index.html`。
4. 点击 `Connect`，选择 `JingQiPPG`，再点击 `Start`。
