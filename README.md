![test](https://img.shields.io/badge/test-passing-green.svg)
![docs](https://img.shields.io/badge/docs-passing-green.svg)
![platform](https://img.shields.io/badge/platform-Quartus|Vivado-blue.svg)

FPGA USB Serial
===========================

**使用 FPGA 直接实现 USB 串口通信**

FPGA implementation USB-Serial Converter / USB-UART / USB-CDC

该项目将 FPGA 的普通 IO 引脚直接连接到 USB D+/D- 信号上，实现FPGA与PC机的串口通信，该项目工作在 USB Full-Speed 模式下，好处包括：

* 省去了 USB-UART 芯片
* PC机上不需要指定串口波特率
* 通信速度更快

**注**: 该项目的重点部分（usb_cdc部分）并非原创，而是来自[**这里**](http://jorisvr.nl/article/usb-serial)，本人只做了usb_phy的代码，并提供一些示例，使其方便使用。

# 使用方法

电路连接如下图，只需要把 FPGA 的两个普通IO引脚连接到 USB 线缆的 D+ 和 D- 信号，并将 D+ 信号通过 10k 电阻上拉到 USB 5V 电源上，另外，USB 线缆的 GND 应该与 FPGA 共地。

                                 |--------------------
                                 |
                         |-------| USB 5V
                         |       |
                        |-|      |
    --------|      10kΩ | |      |
            |           |_|      |
            |            |       |
        IO  |--------------------| USB D+
            |                    |
        IO  |--------------------| USB D-
            |                    |
        GND |--------------------| GND
            |                    |
    --------|                    |--------------------
     FPGA                          USB jack or cable

核心代码在 [**RTL目录**](https://github.com/WangXuan95/FPGA-USB-Serial/blob/master/RTL) 里，其中 [**usb_serial.sv**](https://github.com/WangXuan95/FPGA-USB-Serial/blob/master/RTL/usb_serial.sv) 是顶层模块，它的引脚描述如下表。

| 引脚名称  | 方向  | 宽度 | 描述    |
| :----:   | :--: | :--: | :----- |
| clk48mhz | input | 1    | 请提供48MHz的时钟给它 |
| usb_dp   | inout | 1    | 连接到 USB 线缆的 D+ （请在外部用10k电阻上拉到USB电源） |
| usb_dn   | inout | 1   | 连接到 USB 线缆的 D- |
| usb_alive | output | 1 | =1时说明连接建立，=0时说明连接断开 |
| rx_tvalid | output | 1 | 同步于clk48mhz, 当host要发送一个字节到FPGA时，rx_tvalid=1 |
| rx_tready | input  | 1 | 同步于clk48mhz, 若FPGA准备好接收来自host的字节，应该让rx_tready=1 |
| rx_tdata | output | 8 | 同步于clk48mhz, host向FPGA发送的字节，当rx_tvalid=1时有效 |
| tx_tvalid | input | 1 | 同步于clk48mhz, 当FPGA要发送一个字节到host时，应该让tx_tvalid=1 |
| tx_tready | output | 1 | 同步于clk48mhz, 若host准备好接收来自FPGA的字节，应该让tx_tready=1 |
| tx_tdata | input | 8 | 同步于clk48mhz, FPGA向host发送的字节，当tx_tvalid=1时有效 |

使用时，请先将 bitstream 烧录到 FPGA，然后再将 USB 线缆插入到 PC 机，第一次插入时 Windows 10 会自动安装驱动，安装驱动后就可以看到“设备管理器”中出现新的 COM端口，然后就可以使用 putty, HyperTerminal, 串口助手 等串口通信软件，通过该 COM端口 与 FPGA 通信。

# 示例

我提供了以下 2 个基于 Altera Cyclone IV FPGA 的示例。当然，因为项目使用纯RTL编写，你可以仿照顶层模块的写法，将这些示例其它 FPGA 厂商或型号上。

* [**回环测试**](https://github.com/WangXuan95/FPGA-USB-Serial/blob/master/quartus/loopback) 示例，其顶层模块见[**这里**](https://github.com/WangXuan95/FPGA-USB-Serial/blob/master/quartus/loopback/RTL/top.sv)，该示例直接将rx接口与tx接口回环连接，因此PC机发送到FPGA的字节会原样返回。
* [**收发测试**](https://github.com/WangXuan95/FPGA-USB-Serial/blob/master/quartus/send) 示例，其顶层模块见[**这里**](https://github.com/WangXuan95/FPGA-USB-Serial/blob/master/quartus/send/RTL/top.sv)，该示例中 FPGA 会每隔几秒就发送一个字符串 "1234567" ，同时，PC机发给 FPGA 的字节会显示在 8bit LED 上。
