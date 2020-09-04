
module top(
    input   clk50mhz,       // 50MHz input from oscillator.
    inout   usb_dp, usb_dn, // USB D+/D- signal, please pull up D+ with a 10k resistor externally.
    output  [7:0] LED       // 8bit LED to show the last rx byte
);

wire        clk48mhz;

wire        rx_tvalid;
wire [7:0]  rx_tdata;
reg         tx_tvalid = 1'b0;
wire        tx_tready;
reg  [7:0]  tx_tdata  = '0;

pll pll_i(
    .inclk0     ( clk50mhz  ),
    .c0         ( clk48mhz  )
);

usb_serial usb_serial_i(
    .clk48mhz   ( clk48mhz  ),
    .usb_dp     ( usb_dp    ),
    .usb_dn     ( usb_dn    ),
    .usb_alive  (           ),
    // the rx interface,
    .rx_tvalid  ( rx_tvalid ),
    .rx_tready  ( 1'b1      ),
    .rx_tdata   ( rx_tdata  ),
    // the tx interface
    .tx_tvalid  ( tx_tvalid ),
    .tx_tready  ( tx_tready ),
    .tx_tdata   ( tx_tdata  )
);

always @ (posedge clk48mhz)
    if(rx_tvalid)
        LED <= rx_tdata;  // put rx_tdata on LEDs

reg [26:0] cnt = '0;

assign tx_tvalid = (cnt<27'd8);       // try to send when (cnt<28'd8)
assign tx_tdata  = {4'h3, cnt[3:0]};  // send data from ASCII code 0x30 to 0x37, that is, from '0' to '7'

always @ (posedge clk48mhz)
    if(tx_tvalid) begin
        if(tx_tready)
            cnt <= cnt + 27'd1;
    end else begin
        cnt <= cnt + 27'd1;
    end

endmodule
