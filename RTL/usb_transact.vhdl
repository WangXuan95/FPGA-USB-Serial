
library ieee;
use ieee.std_logic_1164.all, ieee.numeric_std.all;

entity usb_transact is
    port (

        -- 60 MHz UTMI clock.
        CLK :           in  std_logic;

        -- Synchronous reset of this entity.
        RESET :         in  std_logic;

        -- High during IN transactions.
        T_IN :          out std_logic;

        -- High during OUT transactions.
        T_OUT :         out std_logic;

        -- High during SETUP transactions.
        T_SETUP :       out std_logic;

        -- High during PING transactions.
        T_PING :        out std_logic;

        -- Indicates successfull completion of a transaction.
        T_FIN :         out std_logic;

        -- Device address.
        T_ADDR :        in  std_logic_vector(6 downto 0);

        -- Endpoint number for current transaction.
        T_ENDPT :       out std_logic_vector(3 downto 0);

        -- Triggers a NAK response to IN/OUT/PING.
        T_NAK :         in  std_logic;

        -- Triggers a STALL response to IN/OUT.
        T_STALL :       in  std_logic;

        -- Triggers a NYET response to OUT.
        T_NYET :        in  std_logic;

        -- High while application has data to send (in response to OUT).
        T_SEND :        in  std_logic;

        -- Sync bit to use for IN transactions.
        T_ISYNC :       in  std_logic;

        -- Sync bit used for the current OUT transaction.
        T_OSYNC :       out std_logic;

        -- Indicates next byte received.
        T_RXRDY :       out std_logic;

        -- Received data; valid when T_RXRDY = '1'.
        T_RXDAT :       out std_logic_vector(7 downto 0);

        -- Requests next byte to transmit; application must update T_TXDAT or T_SEND in next cycle.
        T_TXRDY :       out std_logic;

        -- Data byte to transmit; must be valid when T_SEND = '1'.
        T_TXDAT :       in  std_logic_vector(7 downto 0);

        -- Connect to I_HIGHSPEED from usb_init.
        I_HIGHSPEED :   in  std_logic;

        -- Connect to P_RXACT from usb_packet.
        P_RXACT :       in  std_logic;

        -- Connect to P_RXRDY from usb_packet.
        P_RXRDY :       in  std_logic;

        -- Connect to P_RXFIN from usb_packet.
        P_RXFIN :       in  std_logic;

        -- Connect to P_RXDAT from usb_packet.
        P_RXDAT :       in  std_logic_vector(7 downto 0);

        -- Connect to P_TXACT towards usb_packet.
        P_TXACT :       out std_logic;

        -- Connect to P_TXRDY from usb_packet.
        P_TXRDY :       in  std_logic;

        -- Connect to P_TXDAT towards usb_packet.
        P_TXDAT :       out std_logic_vector(7 downto 0) );

end entity usb_transact;

architecture usb_transact_arch of usb_transact is

    constant HSSUPPORT :  boolean := false;
    
    -- PID constants
    constant pid_out :  std_logic_vector(3 downto 0) := "0001";
    constant pid_in :   std_logic_vector(3 downto 0) := "1001";
    constant pid_setup: std_logic_vector(3 downto 0) := "1101";
    constant pid_ack :  std_logic_vector(3 downto 0) := "0010";
    constant pid_nak :  std_logic_vector(3 downto 0) := "1010";
    constant pid_stall: std_logic_vector(3 downto 0) := "1110";
    constant pid_nyet : std_logic_vector(3 downto 0) := "0110";
    constant pid_ping : std_logic_vector(3 downto 0) := "0100";
    constant pid_data : std_logic_vector(2 downto 0) :=  "011";

    function pid_mirror(v: std_logic_vector) return std_logic_vector
    is begin
	return (not v) & v;
    end function;

    -- State machine
    type t_state is (
      ST_IDLE, ST_SKIP,
      ST_GETTOKEN1, ST_GETTOKEN2, ST_GETTOKEN3, ST_GOTTOKEN,
      ST_SENDSHAKE,
      ST_GETDATA, ST_GOTDATA,
      ST_SENDDATA, ST_SENDING,
      ST_WAITACK, ST_WAITSKIP, ST_GETACK );
    signal s_state : t_state := ST_IDLE;
    signal s_active :   std_logic;

    -- Transaction state
    signal s_in :       std_logic := '0';
    signal s_out :      std_logic := '0';
    signal s_setup :    std_logic := '0';
    signal s_ping :     std_logic := '0';
    signal s_finished : std_logic := '0';

    -- Previous value of P_RXACT; needed to detect bad packet while waiting for host.
    signal s_prevrxact : std_logic;

    -- PID byte to use for outgoing packet (ST_SENDSHAKE or ST_SENDDATA)
    signal s_sendpid :  std_logic_vector(3 downto 0);

    -- Registered output signals
    signal s_endpt : std_logic_vector(3 downto 0) := "0000";
    signal s_osync : std_logic := '0';

    -- In full speed mode, we must time out an expected host response after
    -- 16 to 18 bit periods. In high speed mode, we must time out after
    -- 736 to 816 bit periods. We can not get accurate timing because we don't
    -- know the delay due to CRC, EOP, SYNC and UTMI pipeline. (We should use
    -- PHY_LINESTATE for timing, but we don't.) So we just use a much longer
    -- timeout; wait_timeout_fs = 511 cycles = 102 bit periods;
    -- wait_timeout_hs = 127 cycles = 1020 bit periods.
    constant wait_timeout_fs : unsigned(8 downto 0) := "111111111";
    constant wait_timeout_hs : unsigned(8 downto 0) := "001111111";

    -- In full speed mode, we must wait at least 2 and at most 6.5 bit periods
    -- before responding to the host. We have wait_send_fs = 14 cycles from
    -- rising T_IN/OUT/SETUP until valid T_NAK; equals 16 cycles from rising
    -- P_RXFIN until rising P_TXACT; equals 18 cycles from falling PHY_RXACTIVE
    -- until rising PHY_TXVALID. Including pipeline delay in the UTMI, we end
    -- up with 2 to 5 bit periods from SE0-to-J until SYNC.
    constant wait_send_fs : unsigned(8 downto 0) := "000001110";

    -- In high speed mode, we must wait at least 8 and at most 192 bit periods
    -- before responding to the host. We give the application wait_send_hs = 2
    -- cycles to get its act together; i.e. from rising T_IN/OUT/SETUP/PING
    -- until valid T_NAK/STALL/NYET/SEND. This corresponds to 4 cycles from
    -- P_RXFIN until P_TXACT; equals 6 cycles from falling PHY_RXACTIVE until
    -- rising PHY_TXVALID. Including pipeline delay in the UTMI, we end up
    -- with 78 to 127 bit periods between packets.
    constant wait_send_hs : unsigned(8 downto 0) := "000000010";

    -- Count down timer.
    signal wait_count : unsigned(8 downto 0);

begin

    -- Assign control signals
    s_active <=
        '1' when (s_state = ST_IDLE or s_state = ST_GOTTOKEN or
                  s_state = ST_SENDSHAKE or
                  s_state = ST_GETDATA or s_state = ST_GOTDATA or
                  s_state = ST_SENDDATA or s_state = ST_SENDING or
                  s_state = ST_WAITACK or s_state = ST_WAITSKIP or s_state = ST_GETACK)
        else '0';
    T_IN    <= s_in and s_active;
    T_OUT   <= s_out and s_active;
    T_SETUP <= s_setup and s_active;
    T_PING  <= s_ping and s_active;
    T_FIN   <= s_finished;  -- Note: T_FIN only occurs when s_state = ST_IDLE
    T_ENDPT <= s_endpt;
    T_OSYNC <= s_osync;

    -- Received bytes
    T_RXRDY <= P_RXRDY when (s_state = ST_GETDATA) else '0';
    T_RXDAT <= P_RXDAT;

    -- Byte to transmit: handshake PID, data PID or data byte
    T_TXRDY <= P_TXRDY when (s_state = ST_SENDING) else '0';
    P_TXACT <= '1' when (s_state = ST_SENDSHAKE or s_state = ST_SENDDATA or
                         (s_state = ST_SENDING and T_SEND = '1'))
               else '0';
    P_TXDAT <= pid_mirror(s_sendpid) when (s_state = ST_SENDSHAKE or s_state = ST_SENDDATA)
               else T_TXDAT;


    -- On every rising clock edge
    process is
    begin
        wait until rising_edge(CLK);

        s_prevrxact     <= P_RXACT;

        if RESET = '1' then

            -- Reset this component
            s_state     <= ST_IDLE;
            s_in        <= '0';
            s_out       <= '0';
            s_setup     <= '0';
            s_ping      <= '0';
            s_finished  <= '0';

        else

            case s_state is

                when ST_IDLE =>
                    -- Idle; wait for incoming packet
                    s_in        <= '0';
                    s_out       <= '0';
                    s_setup     <= '0';
                    s_ping      <= '0';
                    s_finished  <= '0';
                    if P_RXRDY = '1' then
                        case P_RXDAT(3 downto 0) is
                            when pid_out =>
                                -- OUT token
                                s_out   <= '1';
                                s_state <= ST_GETTOKEN1;
                            when pid_in =>
                                -- IN token
                                s_in    <= '1';
                                s_state <= ST_GETTOKEN1;
                            when pid_setup =>
                                -- SETUP token
                                s_setup <= '1';
                                s_state <= ST_GETTOKEN1;
                            when pid_ping =>
                                -- PING token
                                s_state <= ST_SKIP;
                            when others =>
                                -- unexpected packet
                                s_state <= ST_SKIP;
                        end case;
                    end if;

		when ST_SKIP =>
		    -- Skip incoming packet and go back to IDLE
		    if P_RXACT = '0' then
			s_state <= ST_IDLE;
		    end if;

		when ST_GETTOKEN1 =>
		    -- Receive and check 2nd byte of a token packet
		    if P_RXACT = '0' then
			-- Bad packet
			s_state <= ST_IDLE;
		    elsif P_RXRDY = '1' then
			-- Store endpoint number
			s_endpt(0) <= P_RXDAT(7);
			-- Check address
			if P_RXDAT(6 downto 0) = T_ADDR then
			    -- Packet is addressed to us
			    s_state <= ST_GETTOKEN2;
			else
			    -- Packet not addressed to us
			    s_state <= ST_SKIP;
			end if;
		    end if;

		when ST_GETTOKEN2 =>
		    -- Receive 3rd byte of token packet
		    if P_RXACT = '0' then
			-- Bad packet
			s_state <= ST_IDLE;
		    elsif P_RXRDY = '1' then
			-- Store endpoint number
			s_endpt(3 downto 1) <= P_RXDAT(2 downto 0);
			s_state <= ST_GETTOKEN3;
		    end if;

                when ST_GETTOKEN3 =>
                    -- Wait for end of incoming token packet
                    if P_RXFIN = '1' then
                        -- Token was ok
                        s_state <= ST_GOTTOKEN;
                    elsif P_RXACT = '0' then
                        -- Token was bad
                        s_state <= ST_IDLE;
                    end if;
                    if (s_in = '1') or (HSSUPPORT and (s_ping = '1')) then
                        if HSSUPPORT and (I_HIGHSPEED = '1') then
                            wait_count <= wait_send_hs;
                        else
                            wait_count <= wait_send_fs;
                        end if;
                    else
                        if HSSUPPORT and (I_HIGHSPEED = '1') then
                            wait_count <= wait_timeout_hs;
                        else
                            wait_count <= wait_timeout_fs;
                        end if;
                    end if;

		when ST_GOTTOKEN =>
                    -- Wait for data packet or wait for our turn to respond
		    if P_RXACT = '1' then
			if P_RXRDY = '1' then
			    -- Got PID byte
			    if ((s_out = '1') or (s_setup = '1')) and
                               (P_RXDAT(2 downto 0) = pid_data) then
				-- This is the DATA packet we were waiting for
				s_osync <= P_RXDAT(3);
				s_state <= ST_GETDATA;
			    else
				-- Got unexpected packet
				s_in    <= '0';
				s_out   <= '0';
				s_setup <= '0';
                                s_ping  <= '0';
				case P_RXDAT(3 downto 0) is
				    when pid_out =>
					-- unexpected OUT token
					s_out <= '1';
					s_state <= ST_GETTOKEN1;
				    when pid_in =>
					-- unexpected IN token
					s_in <= '1';
					s_state <= ST_GETTOKEN1;
				    when pid_setup =>
					-- unexpected SETUP token
					s_setup <= '1';
					s_state <= ST_GETTOKEN1;
                                    when pid_ping =>
                                        s_state <= ST_SKIP;
				    when others =>
					-- unexpected packet
					s_state <= ST_SKIP;
				end case;
			    end if;
			end if;
                    elsif s_prevrxact = '1' then
                        -- got bad packet
                        s_state <= ST_IDLE;
		    elsif wait_count = 0 then
                        -- timer reached zero
                        if s_in = '1' then
                            -- IN transaction: send response
                            if T_STALL = '1' then
                                s_state   <= ST_SENDSHAKE;
                                s_sendpid <= pid_stall;
                            elsif T_NAK = '1' then
                                s_state   <= ST_SENDSHAKE;
                                s_sendpid <= pid_nak;
                            else
                                s_state   <= ST_SENDDATA;
                                s_sendpid <= T_ISYNC & pid_data;
                            end if;
                        elsif HSSUPPORT and (s_ping = '1') then
                            -- PING transaction: send handshake
                            s_state <= ST_SENDSHAKE;
                            if T_STALL = '1' then
                                s_sendpid <= pid_stall;
                            elsif T_NAK = '1' then
                                s_sendpid <= pid_nak;
                            else
                                s_sendpid <= pid_ack;
                            end if;
                        else
                            -- OUT/SETUP transaction:
                            -- timeout while waiting for DATA packet
                            s_state <= ST_IDLE;
                        end if;
                    end if;
                    -- count down timer
                    wait_count <= wait_count - 1;

                when ST_SENDSHAKE =>
                    -- Send handshake packet
                    if P_TXRDY = '1' then
                        -- Handshake done, transaction completed
                        s_finished <= '1';
                        s_state <= ST_IDLE;
                    end if;

                when ST_GETDATA =>
                    -- Wait for end of incoming data packet
                    if P_RXFIN = '1' then
                        -- Data packet was good, respond with handshake
                        s_state <= ST_GOTDATA;
                    elsif P_RXACT = '0' then
                        -- Data packet was bad, ignore it
                        s_state <= ST_IDLE;
                    end if;
                    if HSSUPPORT and (I_HIGHSPEED = '1') then
                        wait_count <= wait_send_hs;
                    else
                        wait_count <= wait_send_fs;
                    end if;

		when ST_GOTDATA =>
		    -- Wait for inter-packet delay before responding
		    if wait_count = 0 then
			-- Move to response state
			s_state <= ST_SENDSHAKE;
                        if T_STALL = '1' then
                            s_sendpid <= pid_stall;
                        elsif T_NAK = '1' then
                            s_sendpid <= pid_nak;
                        elsif HSSUPPORT and (I_HIGHSPEED = '1') and (T_NYET = '1') then
                            s_sendpid <= pid_nyet;
                        else
                            s_sendpid <= pid_ack;
                        end if;
		    end if;
		    wait_count <= wait_count - 1;

		when ST_SENDDATA =>
		    -- Start sending a data packet
		    if P_TXRDY = '1' then
			-- Sent PID byte, need first data byte
			s_state <= ST_SENDING;
		    end if;

                when ST_SENDING =>
                    -- Send payload of data packet
                    if T_SEND = '0' then
                        -- End of data packet; wait for ACK.
                        if P_RXACT = '1' then
                            -- We are receiving something; probably an echo
                            -- of our outgoing packet. Let this stuff pass
                            -- before we start waiting for ACK.
                            s_state <= ST_WAITSKIP;
                        else
                            s_state <= ST_WAITACK;
                        end if;
                    end if;
                    -- Initialize ACK timer.
                    if HSSUPPORT and (I_HIGHSPEED = '1') then
                        wait_count <= wait_timeout_hs;
                    else
                        wait_count <= wait_timeout_fs;
                    end if;

		when ST_WAITACK =>
		    -- Wait for ACK handshake
		    if P_RXACT = '1' then
			if P_RXRDY = '1' then
			    -- Got PID byte
			    case P_RXDAT(3 downto 0) is
				when pid_ack =>
				    -- ACK handshake
				    s_state <= ST_GETACK;
				when pid_out =>
				    -- unexpected OUT token
				    s_in    <= '0';
				    s_out   <= '1';
				    s_state <= ST_GETTOKEN1;
				when pid_in =>
				    -- unexpected IN token
				    s_in    <= '1';
				    s_state <= ST_GETTOKEN1;
				when pid_setup =>
				    -- unexpected SETUP token
				    s_in    <= '0';
				    s_setup <= '1';
				    s_state <= ST_GETTOKEN1;
                                when pid_ping =>
                                        s_state <= ST_SKIP;
				when others =>
				    -- unexpected packet
                                    -- This could be our own transmitted packet
                                    -- (if it was very short), so skip this.
				    s_state <= ST_WAITSKIP;
			    end case;
			end if;
                    elsif s_prevrxact = '1' then
                        -- got bad packet
                        s_state <= ST_IDLE;
		    elsif wait_count = 0 then
                        -- timeout while waiting for ACK
                        s_state <= ST_IDLE;
		    end if;
                    -- count down timer
                    wait_count <= wait_count - 1;

                when ST_WAITSKIP =>
                    -- Skip the echo of our own transmitted packet
                    if wait_count = 0 then
                        -- timeout
                        s_state <= ST_SKIP;
                    elsif P_RXACT = '0' then
                        -- end of packet
                        s_state <= ST_WAITACK;
                    end if;
                    -- count down timer
                    wait_count <= wait_count - 1;

                when ST_GETACK =>
                    -- Wait for end of incoming ACK packet
                    if P_RXFIN = '1' then
                        -- ACK handshake was good
                        s_finished <= '1';
                        s_state <= ST_IDLE;
                    elsif P_RXACT = '0' then
			-- ACK handshake was bad
                        s_state <= ST_IDLE;
                    end if;

	    end case;

	end if;

    end process;

end architecture usb_transact_arch;
