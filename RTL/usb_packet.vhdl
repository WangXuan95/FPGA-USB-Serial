--
--  USB 2.0 Packet-level logic.
--
--  This entity hides the details of the UTMI interface and handles
--  computation and verificaton of CRCs.
--
--  The low-level interface signals are named PHY_xxx and may be
--  connected to an UTMI compliant USB PHY, such as the SMSC GT3200.
--
--  The application interface signals are named P_xxx.
--  The receiving side of the interface operates as follows:
--    * At the start of an incoming packet, RXACT is set high.
--    * When a new byte arrives, RXRDY is asserted and the byte is put
--      on RXDAT. These signals are valid for only one clock cycle; the
--      application must accept them immediately.
--    * The first byte of a packet is the PID. Subsequent bytes contain
--      data and CRC. This entity verifies the CRC, but does not
--      discard it from the data stream.
--    * Some time after correctly receiving the last byte of a packet,
--      RXACT is deasserted; at the same time RXFIN is asserted for one cycle
--      to confirm the packet.
--    * If a corrupt packet is received, RXACT is deasserted without
--      asserting RXFIN.
--
--  The transmission side of the interface operates as follows:
--    * The application starts transmission by setting TXACT to 1 and setting
--      TXDAT to the PID value (with correctly mirrored high order bits).
--    * The entity asserts TXRDY when it needs the next payload byte.
--      On the following clock cycle, the application must then provide the
--      next payload byte on TXDAT, or deassert TXACT to indicate the end of
--      the packet. The signal on TXDAT must be held stable until the next
--      assertion of TXRDY.
--    * CRC bytes should not be included in the payload; the entity will
--      add them automatically.
--    * As part of the high speed handshake, the application may request
--      transmission of a continuous chirp K state by asserting CHIRPK.
--
--  Implementation note:
--  Transmission timing is a bit tricky due to the following issues:
--    * After the PHY asserts PHY_TXREADY, we must immediately provide
--      new data or deassert PHY_TXVALID on the next clock cycle.
--    * The PHY may assert PHY_TXREADY during subsequent clock cycles,
--      even though the average byte period is more than 40 cycles.
--    * We want to register PHY inputs and outputs to ensure valid timing.
--
--  To satisfy these requirements, we make the application run one byte
--  ahead. While keeping the current byte in the output register PHY_DATAOUT,
--  the application already provides the following data byte. That way, we
--  can respond to PHY_TXREADY immediately in the next cycle, with the
--  application following up in the clock cycle after that.
--

library ieee;
use ieee.std_logic_1164.all, ieee.numeric_std.all;

entity usb_packet is

    port (

        -- 60 MHz UTMI clock.
        CLK :           in  std_logic;

        -- Synchronous reset of this entity.
        RESET :         in  std_logic;

        -- High to force chirp K transmission.
	    P_CHIRPK :      in  std_logic;

        -- High while receiving a packet.
        P_RXACT :       out std_logic;

        -- Indicates next byte received; data must be read from RXDAT immediately.
        P_RXRDY :       out std_logic;

        -- High for one cycle to indicate successful completion of packet.
        P_RXFIN :       out std_logic;

        -- Received byte value. Valid if RXRDY is high.
        P_RXDAT :       out std_logic_vector(7 downto 0);

        -- High while transmitting a packet.
        P_TXACT :       in  std_logic;

        -- Request for next data byte; application must change TXDAT on the next clock cycle.
        P_TXRDY :       out std_logic;

        -- Data byte to transmit. Hold stable until next assertion of TXRDY.
        P_TXDAT :       in  std_logic_vector(7 downto 0);

        -- Connect to UTMI DataIn signal.
        PHY_DATAIN :    in std_logic_vector(7 downto 0);

        -- Connect to UTMI DataOut signal.
        PHY_DATAOUT :   out std_logic_vector(7 downto 0);

        -- Connect to UTMI TxValid signal.
        PHY_TXVALID :   out std_logic;

        -- Connect to UTMI TxReady signal.
        PHY_TXREADY :   in std_logic;

        -- Connect to UTMI RxActive signal.
        PHY_RXACTIVE :  in std_logic;

        -- Connect to UTMI RxValid signal.
        PHY_RXVALID :   in std_logic;

        -- Connect to UTMI RxError signal.
        PHY_RXERROR :   in std_logic );

end entity usb_packet;

architecture usb_packet_arch of usb_packet is

    -- State machine
    type t_state is (
	ST_NONE, ST_CHIRPK,
	ST_RWAIT, ST_RTOKEN, ST_RDATA, ST_RSHAKE,
	ST_TSTART, ST_TDATA, ST_TCRC1, ST_TCRC2 );
    signal s_state : t_state := ST_NONE;
    signal s_txfirst : std_logic := '0';

    -- Registered inputs
    signal s_rxactive : std_logic;
    signal s_rxvalid : std_logic;
    signal s_rxerror : std_logic;
    signal s_datain : std_logic_vector(7 downto 0);
    signal s_txready : std_logic;

    -- Byte pending for transmission
    signal s_dataout : std_logic_vector(7 downto 0);

    -- True if an incoming packet would be valid if it ended now.
    signal s_rxgoodpacket : std_logic;

    -- CRC computation
    constant crc5_gen : std_logic_vector(4 downto 0) := "00101";
    constant crc5_res : std_logic_vector(4 downto 0) := "01100";
    constant crc16_gen : std_logic_vector(15 downto 0) := "1000000000000101";
    constant crc16_res : std_logic_vector(15 downto 0) := "1000000000001101";
    signal crc5_buf : std_logic_vector(4 downto 0);
    signal crc16_buf : std_logic_vector(15 downto 0);

    -- Update CRC 5 to account for a new byte
    function crc5_upd(
	c : in std_logic_vector(4 downto 0);
	b : in std_logic_vector(7 downto 0) )
	return std_logic_vector
    is
	variable t : std_logic_vector(4 downto 0);
	variable y : std_logic_vector(4 downto 0);
    begin
	t := (
	    b(0) xor c(4),
	    b(1) xor c(3),
	    b(2) xor c(2),
	    b(3) xor c(1),
	    b(4) xor c(0) );
	y := (
	    b(5) xor t(1) xor t(2),
	    b(6) xor t(0) xor t(1) xor t(4),
	    b(5) xor b(7) xor t(0) xor t(3) xor t(4),
	    b(6) xor t(1) xor t(3) xor t(4),
	    b(7) xor t(0) xor t(2) xor t(3) );
	return y;
    end function;

    -- Update CRC-16 to account for new byte
    function crc16_upd(
	c : in std_logic_vector(15 downto 0);
	b : in std_logic_vector(7 downto 0) )
	return std_logic_vector
    is
	variable t : std_logic_vector(7 downto 0);
	variable y : std_logic_vector(15 downto 0);
    begin
	t := (
	    b(0) xor c(15),
	    b(1) xor c(14),
	    b(2) xor c(13),
	    b(3) xor c(12),
	    b(4) xor c(11),
	    b(5) xor c(10),
	    b(6) xor c(9),
	    b(7) xor c(8) );
	y := (
	    c(7) xor t(0) xor t(1) xor t(2) xor t(3) xor t(4) xor t(5) xor t(6) xor t(7),
	    c(6), c(5), c(4), c(3), c(2),
	    c(1) xor t(7),
	    c(0) xor t(6) xor t(7),
	    t(5) xor t(6),
	    t(4) xor t(5),
	    t(3) xor t(4),
	    t(2) xor t(3),
	    t(1) xor t(2),
	    t(0) xor t(1),
	    t(1) xor t(2) xor t(3) xor t(4) xor t(5) xor t(6) xor t(7),
	    t(0) xor t(1) xor t(2) xor t(3) xor t(4) xor t(5) xor t(6) xor t(7) );
	return y;
    end function;

begin

    -- Assign output signals
    P_RXACT <= s_rxactive;
    P_RXFIN <= (not s_rxactive) and (not s_rxerror) and s_rxgoodpacket;
    P_RXRDY <= s_rxactive and s_rxvalid;
    P_RXDAT <= s_datain;

    -- Assert P_TXRDY during ST_TSTART to acknowledge the PID byte,
    -- during the first cycle of ST_TDATA to acknowledge the first
    -- data byte, and whenever we need a new data byte during ST_TDATA.
    P_TXRDY <= '1' when (s_state = ST_TSTART)
               else (s_txfirst or s_txready) when (s_state = ST_TDATA)
	       else '0';

    -- On every rising clock edge
    process is
	variable v_dataout : std_logic_vector(7 downto 0);
	variable v_txvalid : std_logic;	
	variable v_crc_upd : std_logic;	
	variable v_crc_data : std_logic_vector(7 downto 0);
        variable v_crc5_new : std_logic_vector(4 downto 0);
        variable v_crc16_new : std_logic_vector(15 downto 0);
    begin
	wait until rising_edge(CLK);

	-- Default assignment to temporary variables
        v_dataout := s_dataout;
	v_txvalid := '0';
	v_crc_upd := '0';
	v_crc_data := "00000000";
        v_crc5_new := "00000";
        v_crc16_new := "0000000000000000";

	-- Default assignment to s_txfirst
	s_txfirst <= '0';

	-- Register inputs
	s_rxactive <= PHY_RXACTIVE;
	s_rxvalid <= PHY_RXVALID;
	s_rxerror <= PHY_RXERROR;
	s_datain <= PHY_DATAIN;
	s_txready <= PHY_TXREADY;

	-- State machine
	if RESET = '1' then

	    -- Reset entity
	    s_state <= ST_NONE;
            s_rxgoodpacket <= '0';

	else

	    case s_state is
		when ST_NONE =>
		    -- Waiting for incoming or outgoing packet

		    -- Initialize CRC buffers
		    crc5_buf <= "11111";
		    crc16_buf <= "1111111111111111";
                    s_rxgoodpacket <= '0';

                    if P_CHIRPK = '1' then
                        -- Send continuous chirp K.
                        s_state <= ST_CHIRPK;

                    elsif s_rxactive = '1' then
			-- Receiver starting

			if s_rxerror = '1' then
			    -- Receive error at PHY level
			    s_state <= ST_RWAIT;
			elsif s_rxvalid = '1' then
			    -- Got PID byte
			    if s_datain(3 downto 0) = not s_datain(7 downto 4) then
				case s_datain(1 downto 0) is
				    when "01" => -- token packet
					s_state <= ST_RTOKEN;
				    when "11" => -- data packet
					s_state <= ST_RDATA;
				    when "10" => -- handshake packet
					s_state <= ST_RSHAKE;
                                        s_rxgoodpacket <= '1';
				    when others => -- PING token or special packet
                                        -- If this is a PING token, it will work out fine;
                                        -- otherwise it will be flagged as a bad packet
                                        -- either here or in usb_transact.
					s_state <= ST_RTOKEN;
				end case;
			    else
				-- Corrupt PID byte
				s_state <= ST_RWAIT;
			    end if;
			end if;

		    elsif P_TXACT = '1' then
			-- Transmission starting; put data in output buffer
			v_txvalid := '1';
			v_dataout := P_TXDAT;
			s_state <= ST_TSTART;
		    end if;

                when ST_CHIRPK =>
                    -- Sending continuous chirp K.
                    if P_CHIRPK = '0' then
                        s_state <= ST_NONE;
                    end if;

		when ST_RTOKEN =>
		    -- Receiving a token packet
		    if s_rxactive = '0' then
			-- End of packet
                        s_rxgoodpacket <= '0';
                        s_state <= ST_NONE;
		    elsif s_rxerror = '1' then
			-- Error at PHY level
                        s_rxgoodpacket <= '0';
			s_state <= ST_RWAIT;
		    elsif s_rxvalid = '1' then
			-- Just received a byte; update CRC
			v_crc5_new := crc5_upd(crc5_buf, s_datain);
                        crc5_buf   <= v_crc5_new;
                        if v_crc5_new = crc5_res then
                            s_rxgoodpacket <= '1';
                        else
                            s_rxgoodpacket <= '0';
                        end if;
		    end if;

		when ST_RDATA =>
		    -- Receiving a data packet
		    if s_rxactive = '0' then
			-- End of packet
                        s_rxgoodpacket <= '0';
                        s_state <= ST_NONE;
		    elsif s_rxerror = '1' then
			-- Error at PHY level
                        s_rxgoodpacket <= '0';
			s_state <= ST_RWAIT;
		    elsif s_rxvalid = '1' then
			-- Just received a byte; update CRC
			v_crc_upd := '1';
			v_crc_data := s_datain;
		    end if;

		when ST_RWAIT =>
		    -- Wait until the end of the current packet
		    if s_rxactive = '0' then
			s_state <= ST_NONE;
		    end if;

		when ST_RSHAKE =>
		    -- Receiving a handshake packet
		    if s_rxactive = '0' then
			-- Got good handshake
                        s_rxgoodpacket <= '0';
			s_state <= ST_NONE;
		    elsif s_rxerror = '1' or s_rxvalid = '1' then
			-- Error or unexpected data byte in handshake packet
                        s_rxgoodpacket <= '0';
			s_state <= ST_RWAIT;
		    end if;

		when ST_TSTART =>
		    -- Transmission starting;
		    -- PHY module sees our PHY_TXVALID signal;
		    -- PHY_TXREADY is undefined;
		    -- we assert P_TXRDY to acknowledge the PID byte
		    v_txvalid := '1';
		    -- Check packet type
		    case P_TXDAT(1 downto 0) is
			when "11" => -- data packet
			    s_state <= ST_TDATA;
			    s_txfirst <= '1';
			when "10" => -- handshake packet
			    s_state <= ST_RWAIT;
			when others => -- should not happen
		    end case;

		when ST_TDATA =>
		    -- Sending a data packet
		    v_txvalid := '1';
		    if (s_txready = '1') or (s_txfirst = '1') then
			-- Need next byte
			if P_TXACT = '0' then
			    -- No more data; send first CRC byte
			    for i in 0 to 7 loop
				v_dataout(i) := not crc16_buf(15-i);
			    end loop;
			    s_state <= ST_TCRC1;
			else
			    -- Put next byte in output buffer
			    v_dataout := P_TXDAT;
			    -- And update the CRC
			    v_crc_upd := '1';
			    v_crc_data := P_TXDAT;
			end if;
		    end if;

		when ST_TCRC1 =>
		    -- Sending the first CRC byte of a data packet
		    v_txvalid := '1';
		    if s_txready = '1' then
			-- Just queued the first CRC byte; move to 2nd byte
			for i in 0 to 7 loop
			    v_dataout(i) := not crc16_buf(7-i);
			end loop;
			s_state <= ST_TCRC2;
		    end if;

		when ST_TCRC2 =>
		    -- Sending the second CRC byte of a data packet
		    if s_txready = '1' then
			-- Just sent the 2nd CRC byte; end packet
			s_state <= ST_RWAIT;
		    else
			-- Last byte is still pending
			v_txvalid := '1';
		    end if;

	    end case;

	end if;

	-- CRC-16 update
	if v_crc_upd = '1' then
	    v_crc16_new := crc16_upd(crc16_buf, v_crc_data);
	    crc16_buf   <= v_crc16_new;
            if s_state = ST_RDATA and v_crc16_new = crc16_res then
                -- If this is the last byte of the packet, it is a valid packet.
                s_rxgoodpacket <= '1';
            else
                s_rxgoodpacket <= '0';
            end if;
	end if;

        -- Drive data output to PHY
        if RESET = '1' then
            -- Reset.
            PHY_TXVALID <= '0';
            PHY_DATAOUT <= "00000000";
        elsif s_state = ST_CHIRPK then
            -- Continuous chirp-K.
            PHY_TXVALID <= P_CHIRPK;
            PHY_DATAOUT <= "00000000";
        elsif (PHY_TXREADY = '1') or (s_state = ST_NONE and P_TXACT = '1') then
            -- Move a data byte from the buffer to the output lines when the PHY
            -- accepts the previous byte, and also at the start of a new packet.
	    PHY_TXVALID <= v_txvalid;
	    PHY_DATAOUT <= v_dataout;
	end if;

        -- Keep pending output byte in register.
        s_dataout <= v_dataout;

    end process;

end architecture usb_packet_arch;

