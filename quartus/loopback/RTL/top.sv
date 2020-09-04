
module top(
    input   clk50mhz,       // 50MHz input from oscillator.
    inout   usb_dp, usb_dn, // USB D+/D- signal, please pull up D+ with a 10k resistor externally.
    output  LED             // a LED to indicate whether USB is plug in a host.
);

wire        clk48mhz;

wire        tvalid;
wire        tready;
wire [7:0]  tdata;

pll pll_i(
    .inclk0     ( clk50mhz ),
    .c0         ( clk48mhz )
);

usb_serial usb_serial_i(
    .clk48mhz   ( clk48mhz ),
    .usb_dp     ( usb_dp   ),
    .usb_dn     ( usb_dn   ),
    .usb_alive  ( LED      ),
    // connect the rx interface,
    .rx_tvalid  ( tvalid   ),
    .rx_tready  ( tready   ),
    .rx_tdata   ( tdata    ),
    // loopback to the tx interface
    .tx_tvalid  ( tvalid   ),
    .tx_tready  ( tready   ),
    .tx_tdata   ( tdata    )
);

endmodule
