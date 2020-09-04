`timescale 1ns/1ns

module usb_serial(
    input        clk48mhz,
    // USB D+/D- signal, please pull up D+ with a 10k resistor externally.
    inout        usb_dp, usb_dn,
    // indicate whether USB is plug in a host.
    output       usb_alive,
    // user application recieve interface.
    output       rx_tvalid,
    input        rx_tready,
    output [7:0] rx_tdata,
    // user application send interface.
    input        tx_tvalid,
    output       tx_tready,
    input  [7:0] tx_tdata
);
wire       usb_suspend, usb_online;
reg        usb_oe, usb_txp, usb_txn;
reg  [2:0] rxp_shift, rxn_shift, rxd_shift;
reg        rxdq, rxdp, rxdn;
reg  [1:0] sample_cnt;
reg        delay;
wire       sample = (sample_cnt==2'd0);
wire       inse = (~rxdp & ~rxdn);
wire       ink   = inse ? 1'b0 : ~rxdq;
wire       inj   = inse ? 1'b0 :  rxdq;
reg        injl, inlastj, detectj, send_eop;
wire       bit_trans = sample ? inlastj ^ inj : 1'b0;
reg  [2:0] bit_cnt, one_cnt;
reg  [6:0] se_cnt;
wire       bit_stuff = (one_cnt == 3'd6);
wire       nxt_stuff = (one_cnt == 3'd5) && !bit_trans;
wire       utmi_reset;
wire [7:0] utmi_dout;
reg  [7:0] utmi_din;
wire       utmi_txvalid;
reg        utmi_rxerror, utmi_rxvalid, utmi_txready;
wire       utmi_rxactive = (status == STATE_RX_ACTIVE);
wire [1:0] linestate = usb_oe ? {rxdn, rxdp} : {usb_txn, usb_txp};
assign     usb_alive = usb_online & ~usb_suspend;
assign     usb_dp = usb_oe ? 1'bz : usb_txp;
assign     usb_dn = usb_oe ? 1'bz : usb_txn;

enum logic [3:0] {STATE_IDLE,STATE_RX_DETECT,STATE_RX_SYNC_J,STATE_RX_SYNC_K,STATE_RX_ACTIVE,STATE_RX_EOP0,STATE_RX_EOP1,STATE_TX_SYNC,STATE_TX_ACTIVE,STATE_TX_EOP_STUFF,STATE_TX_EOP0,STATE_TX_EOP1,STATE_TX_EOP2,STATE_TX_RST} status;

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset) begin
        {rxp_shift, rxn_shift, rxd_shift} <= '0;
    end else begin
        rxp_shift <= {rxp_shift[1:0],  usb_dp};
        rxn_shift <= {rxn_shift[1:0],  usb_dn};
        rxd_shift <= {rxd_shift[1:0],  usb_dp & ~usb_dn};
    end

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        {rxdp, rxdn, rxdq} <= '0;
    else begin
        if (&rxp_shift[2:1])
            rxdp <= 1'b1;
        else if (~(|rxp_shift[2:1]))
            rxdp <= 1'b0;
        if (&rxn_shift[2:1])
            rxdn <= 1'b1;
        else if (~(|rxn_shift[2:1]))
            rxdn <= 1'b0;
        if (&rxd_shift[2:1])
            rxdq   <= 1'b1;
        else if (~(|rxd_shift[2:1]))
            rxdq   <= 1'b0;
    end

always @ (posedge clk48mhz or posedge utmi_reset)
    if(utmi_reset) begin
        detectj  <= 1'b0;
        status <= STATE_IDLE;
    end else begin
        case (status)
        STATE_IDLE : begin
            detectj <= 1'b0;
            if (ink)
                status <= STATE_RX_DETECT;
            else if (utmi_txvalid)
                status <= STATE_TX_SYNC;
        end
        STATE_RX_DETECT : if(sample) begin
            status <= ink ? STATE_RX_SYNC_K : STATE_IDLE;
        end
        STATE_RX_SYNC_J : begin
            detectj  <= 1'b1;
            if(sample) begin
                if (ink)
                    status <= STATE_RX_SYNC_K;
                else if (bit_cnt==3'd1)
                    status <= STATE_IDLE;
            end
        end
        STATE_RX_SYNC_K : if(sample) begin
            if(ink) begin
                status <= detectj ? STATE_RX_ACTIVE : STATE_IDLE;
            end else if(inj) begin
                status <= STATE_RX_SYNC_J;
            end
        end
        STATE_RX_ACTIVE : if(sample) begin
            if (inse)
                status <= STATE_RX_EOP0;
            else if (rxdp & rxdn)
                status <= STATE_IDLE;
        end
        STATE_RX_EOP0 : if(sample) begin
            status <= inse ? STATE_RX_EOP1 : STATE_IDLE;
        end
        STATE_RX_EOP1 : if(sample) begin
            status <= STATE_IDLE;
        end
        STATE_TX_SYNC : if(sample) begin
            if (bit_cnt == 3'd7)
                status <= STATE_TX_ACTIVE;
        end
        STATE_TX_ACTIVE : if(sample) begin
            if (bit_cnt==3'd7 & (~utmi_txvalid | send_eop) & ~bit_stuff)
                status <= nxt_stuff ? STATE_TX_EOP_STUFF : STATE_TX_EOP0;
        end
        STATE_TX_EOP_STUFF : if(sample) begin
            status <= STATE_TX_EOP0;
        end
        STATE_TX_EOP0 : if(sample) begin
            status <= STATE_TX_EOP1;
        end
        STATE_TX_EOP1 : if(sample) begin
            status <= STATE_TX_EOP2;
        end
        STATE_TX_EOP2 : if(sample) begin
            status <= STATE_IDLE;
        end
        endcase
    end

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        utmi_rxerror  <= 1'b0;
    else
        utmi_rxerror <= (((((status==STATE_RX_SYNC_K) & ~detectj & ink) | (rxdp & rxdn)) & sample) | (one_cnt==3'd7));

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset) begin
        injl  <= 1'b0;
        delay    <= 1'b0;
        sample_cnt        <= 2'd0;
    end else begin
        injl  <= inj;
        if (delay) begin
            delay <= 1'b0;
        end else if((injl ^ inj) && (status<STATE_TX_SYNC)) begin
            if(sample_cnt!=2'd0) begin
                sample_cnt     <= 2'd0;
            end else begin
                delay <= 1'b1;
                sample_cnt     <= sample_cnt + 2'd1;
            end
        end else begin
            sample_cnt        <= sample_cnt + 2'd1;
        end
    end

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        inlastj  <= 1'b0;
    else if ((status == STATE_IDLE) || sample)
        inlastj  <= inj;

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        one_cnt <= 3'd1;
    else if (status == STATE_IDLE)
        one_cnt <= 3'd1;
    else if ((status == STATE_RX_ACTIVE) && sample) begin
        one_cnt <= bit_trans ? 3'b0 : one_cnt + 3'd1;
    end else if ((status == STATE_TX_ACTIVE) && sample) begin
        one_cnt <= (~utmi_din[0] | bit_stuff) ? 3'b0 : one_cnt + 3'd1;
    end

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        bit_cnt <= 3'b0;
    else if ((status == STATE_IDLE) || (status == STATE_RX_SYNC_K))
        bit_cnt <= 3'b0;
    else if ((status == STATE_RX_ACTIVE || status == STATE_TX_ACTIVE) && sample && !bit_stuff)
        bit_cnt <= bit_cnt + 3'd1;
    else if (((status == STATE_TX_SYNC) || (status == STATE_RX_SYNC_J)) && sample)
        bit_cnt <= bit_cnt + 3'd1;

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        utmi_din  <= 8'b0;
    else if (status == STATE_IDLE)
        utmi_din  <= 8'b00101010;
    else if ((status == STATE_RX_ACTIVE) && sample && !bit_stuff)
        utmi_din  <= {~bit_trans, utmi_din[7:1]};
    else if (((status == STATE_TX_SYNC)||(status == STATE_TX_ACTIVE) && !bit_stuff) && sample) begin
        utmi_din <= (bit_cnt==3'd7) ? utmi_dout : {~bit_trans, utmi_din[7:1]};
    end

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        utmi_rxvalid <= 1'b0;
    else if ((status == STATE_RX_ACTIVE) && sample && (bit_cnt==3'd7) && !bit_stuff)
        utmi_rxvalid <= 1'b1;
    else
        utmi_rxvalid <= 1'b0;

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        utmi_txready <= 1'b0;
    else if ((status == STATE_TX_SYNC) && sample && (bit_cnt == 3'd7))
        utmi_txready <= 1'b1;
    else if ((status == STATE_TX_ACTIVE) && sample && !bit_stuff && (bit_cnt == 3'd7) && !send_eop)
        utmi_txready <= 1'b1;
    else
        utmi_txready <= 1'b0;

always @ (posedge utmi_reset or posedge clk48mhz)
    if (utmi_reset)
        send_eop  <= 1'b0;
    else if ((status == STATE_TX_ACTIVE) && !utmi_txvalid)
        send_eop  <= 1'b1;
    else if (status == STATE_TX_EOP0)
        send_eop  <= 1'b0;

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset) begin
        {usb_txp,usb_txn} <= 2'b00;
        usb_oe  <= 1'b1;
    end else if (status == STATE_IDLE) begin
        {usb_txp,usb_txn} <= 2'b10;
        usb_oe <= ~utmi_txvalid;
    end else if ((status == STATE_TX_SYNC) && sample) begin
        {usb_txp,usb_txn} <= {utmi_din[0],~utmi_din[0]};
    end else if ((status == STATE_TX_ACTIVE || status == STATE_TX_EOP_STUFF) && sample) begin
        if (!utmi_din[0] || bit_stuff) begin
            {usb_txp,usb_txn} <= {~usb_txp,~usb_txn};
        end
    end else if ((status == STATE_TX_EOP0 || status == STATE_TX_EOP1) && sample) begin
        {usb_txp,usb_txn} <= 2'b00;
    end else if ((status == STATE_TX_EOP2) && sample) begin
        {usb_txp,usb_txn} <= 2'b10;
        usb_oe  <= 1'b1;
    end else if (status == STATE_TX_RST) begin
        {usb_txp,usb_txn} <= 2'b00;
    end

always @ (posedge clk48mhz or posedge utmi_reset)
    if (utmi_reset)
        se_cnt <= 7'b0;
    else begin
        if (inse) begin
            if (~(&se_cnt))
                se_cnt <= se_cnt + 7'd1;
        end else begin
            se_cnt <= 7'b0;
        end
    end

usb_cdc #(
    .VENDORID         ( 16'hfb9a          ),
    .PRODUCTID        ( 16'hfb9a          ),
    .VERSIONBCD       ( 16'h0031          )
) usb_cdc_i (
    .CLK              ( clk48mhz          ),
    .RESET            ( 1'b0              ),
    .USBRST           (                   ),
    .HIGHSPEED        (                   ),
    .SUSPEND          ( usb_suspend       ),
    .ONLINE           ( usb_online        ),
    .PHY_RESET        ( utmi_reset        ),
    .PHY_XCVRSELECT   (                   ),
    .PHY_TERMSELECT   (                   ),
    .PHY_OPMODE       (                   ),
    .PHY_LINESTATE    ( linestate         ),
    .PHY_TXVALID      ( utmi_txvalid      ),
    .PHY_TXREADY      ( utmi_txready      ),
    .PHY_RXVALID      ( utmi_rxvalid      ),
    .PHY_RXACTIVE     ( utmi_rxactive     ),
    .PHY_RXERROR      ( utmi_rxerror      ),
    .PHY_DATAIN       ( utmi_din          ),
    .PHY_DATAOUT      ( utmi_dout         ),
    .RXVAL            ( rx_tvalid         ),
    .RXRDY            ( rx_tready         ),
    .RXDAT            ( rx_tdata          ),
    .RXLEN            (                   ),
    .TXVAL            ( tx_tvalid         ),
    .TXRDY            ( tx_tready         ),
    .TXDAT            ( tx_tdata          ),
    .TXCORK           ( 1'b0              ),
    .TXROOM           (                   )
);

endmodule
