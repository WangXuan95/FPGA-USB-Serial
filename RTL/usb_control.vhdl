--
--  USB 2.0 Default control endpoint
--
--  This entity implements the minimal required functionality of
--  the default control endpoint.
--
--  The low-level interface signals are named T_xxx and should be conditionally
--  connected to the usb_transact interface in the following way:
--    * Always connect output signal C_ADDR to T_ADDR;
--    * Always connect input signals T_FIN, T_OSYNC, T_RXRDY, T_RXDAT, T_TXRDY;
--    * If T_ENDPT = 0, connect input signals T_IN, T_OUT, T_SETUP, T_PING;
--      otherwise pull these inputs to zero.
--    * If T_ENDPT = 0, connect output signals T_NAK, T_STALL, T_NYET, T_SEND,
--      T_ISYNC, T_TXDAT; otherwise another endpoint should drive these.
--    * If T_ENDPT = 0 and C_DSCBUSY = 0, connect output signal T_TXDAT;
--      otherwise if T_ENDPT = 0 and C_DSCBUSY = 1, drive T_TXDAT
--      from descriptor memory;
--      otherwise another endpoint drives T_TXDAT.
--
--  A device descriptor and a configuration descriptor must be provided
--  in external memory. If high speed mode is supported, an other-speed
--  device qualifier and other-speed configuration descriptor must also
--  be provided. In addition, string descriptors may optionally be provided.
--  Each descriptor may be at most 255 bytes long.
--  A maximum packet size of 64 bytes is assumed for control transfers.
--
--  This entity uses the following protocol to access descriptor data:
--    * When C_DSCBUSY is high, the entity is accessing descriptor data.
--      A descriptor is selected by signals C_DSCTYP and C_DSCINX;
--      a byte within this descriptor is selected by signal C_DSCOFF.
--    * Based on C_DSCTYP and C_DSCINX, the application must assign
--      the length of the selected descriptor to C_DSCLEN. If the selected
--      descriptor does not exist, the application must set C_DSCLEN to zero.
--      C_DSCLEN must be valid one clock after rising C_DSCBUSY and must
--      remain stable as long as C_DSCBUSY, C_DSCTYP and C_DSCINX remain
--      unchanged.
--    * When C_DSCRD is asserted, the application must put the selected
--      byte from the selected descriptor on T_TXDAT towards usb_transact.
--      The application must respond in the first clock cycle following
--      assertion of C_DSCRD.
--    * When C_DSCRD is not asserted, but C_DSCBUSY is still high, 
--      the application must keep T_TXDAT unchanged. Changes to C_DSCOFF
--      must not affect T_TXDAT while C_DSCRD is low.
--
--  The standard device requests are handled as follows:
--
--    Clear Feature:
--      When clearing the ENDPOINT_HALT feature, reset the endpoint's
--      sync bits (as required by spec). Otherwise ignore but report
--      success status.
--      BAD: should return STALL when referring to invalid endpoint/interface.
--
--    Get Configuration:
--      Return 1 if configured, 0 if not configured.
--
--    Get Descriptor:
--      Handled by application through descriptor data interface as
--      described above.
--
--    Get Interface:
--      Always return zero byte.
--      BAD: should return STALL when referring to invalid endpoint/interface.
--
--    Get Status:
--      Return device status / endpoint status / zero.
--      BAD: should return STALL when referring to invalid endpoint/interface.
--
--    Set Address:
--      Store new address.
--
--    Set Configuration:
--      Switch between Configured and Address states; clear all endpoint
--      sync bits (as required by spec). Accepts only configuration values
--      0 and 1.
--
--    Set Descriptor:
--      Not implemented; returns STALL. (Correct; request is optional.)
--
--    Set Feature:
--      Only ENDPOINT_HALT feature implemented; otherwise returns STALL.
--      BAD: every high speed device must support TEST_MODE.
--
--    Set Interface:
--      Not implemented; returns STALL.
--      (Correct; request is optional if no interfaces have alternate settings.)
--
--    Synch Frame:
--      Not implemented; returns STALL.
--      (Correct, assuming no isosynchronous endpoints.)
--
--  Non-standard requests are silently ignored but return success status.
--  This is incorrect, but necessary to get host software to accept usb_serial
--  as CDC-ACM device.
--

library ieee;
use ieee.std_logic_1164.all, ieee.numeric_std.all;

entity usb_control is

    port (

        -- 60 MHz UTMI clock.
        CLK :           in  std_logic;

        -- Synchronous reset of this entity.
        RESET :         in  std_logic;

        -- Current device address.
        C_ADDR :        out std_logic_vector(6 downto 0);

        -- High when in Configured state.
        C_CONFD :       out std_logic;

        -- Trigger clearing of sync/halt bits for IN endpoint.
        C_CLRIN :       out std_logic_vector(1 to 2);

        -- Trigger clearing of sync/halt bits for OUT endpoint.
        C_CLROUT :      out std_logic_vector(1 to 2);

         -- Current status of halt bit for IN endpoints.
        C_HLTIN :       in  std_logic_vector(1 to 2);

        -- Current status of halt bit for IN endpoints.
        C_HLTOUT :      in  std_logic_vector(1 to 2);

        -- Trigger setting of halt bit for IN endpoints.
        C_SHLTIN :      out std_logic_vector(1 to 2);

        -- Trigger setting of halt bit for OUT endpoints.
        C_SHLTOUT :     out std_logic_vector(1 to 2);

        -- High when accessing descriptor memory.
        -- Note that C_DSCBUSY may go low in between packets of a single descriptor.
        C_DSCBUSY :     out std_logic;

        -- Descriptor read enable. Asserted to request a descriptor byte;
        -- in the next clock cycle, the application must update T_TXDAT.
        C_DSCRD :       out std_logic;

        -- LSB bits of the requested descriptor type. Valid when C_DSCBUSY is high.
        C_DSCTYP :      out std_logic_vector(2 downto 0);

        -- Requested descriptor index. Valid when C_DSCBUSY is high.
        C_DSCINX :      out std_logic_vector(7 downto 0);

        -- Offset within requested descriptor. Valid when C_DSCBUSY and C_DSCRD are high.
        C_DSCOFF :      out std_logic_vector(7 downto 0);

        -- Set to length of current descriptor by application.
        C_DSCLEN :      in  std_logic_vector(7 downto 0);

        -- High if the device is not drawing bus power.
        C_SELFPOWERED : in  std_logic;

        -- Connect to T_IN from usb_transact when T_ENDPT = 0, otherwise pull to 0.
        T_IN :          in  std_logic;

        -- Connect to T_OUT from usb_transact when T_ENDPT = 0, otherwise pull to 0.
        T_OUT :         in  std_logic;

        -- Connect to T_SETUP from usb_transact when T_ENDPT = 0, otherwise pull to 0.
        T_SETUP :       in  std_logic;

        -- Connect to T_PING from usb_transact when T_ENDPT = 0, otherwise pull to 0.
        T_PING :        in  std_logic;

        -- Connect to T_FIN from ubs_transact.
        T_FIN :         in  std_logic;

        -- Connect to T_NAK towards usb_transact when T_ENDPT = 0.
        T_NAK :         out std_logic;

        -- Connect to T_STALL towards usb_transact when T_ENDPT = 0.
        T_STALL :       out std_logic;

        -- Connect to T_NYET towards usb_transact when T_ENDPT = 0.
        T_NYET :        out std_logic;

        -- Connect to T_SEND towards usb_transact when T_ENDPT = 0.
        T_SEND :        out std_logic;

        -- Connect to T_ISYNC towards usb_transact when T_ENDPT = 0.
        T_ISYNC :       out std_logic;

        -- Connect to T_OSYNC from usb_transact.
        T_OSYNC :       in  std_logic;

        -- Connect to T_RXRDY from usb_transact.
        T_RXRDY :       in  std_logic;

        -- Connect to T_RXDAT from usb_transact.
        T_RXDAT :       in  std_logic_vector(7 downto 0);

        -- Connect to T_TXRDY from usb_transact.
        T_TXRDY :       in  std_logic;

        -- Connect to T_TXDAT towards usb_transact when T_ENDPT = 0 and C_DSCBUSY = '0'.
        T_TXDAT :       out std_logic_vector(7 downto 0) );

end entity usb_control;

architecture usb_control_arch of usb_control is

    -- Constants for control request
    constant NENDPT : integer := 2;
    
    constant req_getstatus :    std_logic_vector(3 downto 0) := "0000";
    constant req_clearfeature : std_logic_vector(3 downto 0) := "0001";
    constant req_setfeature :   std_logic_vector(3 downto 0) := "0011";
    constant req_setaddress :   std_logic_vector(3 downto 0) := "0101";
    constant req_getdesc :      std_logic_vector(3 downto 0) := "0110";
    constant req_getconf :      std_logic_vector(3 downto 0) := "1000";
    constant req_setconf :      std_logic_vector(3 downto 0) := "1001";
    constant req_getiface :     std_logic_vector(3 downto 0) := "1010";

    -- State machine
    type t_state is (
      ST_IDLE, ST_STALL,
      ST_SETUP, ST_SETUPERR, ST_NONSTANDARD, ST_ENDSETUP, ST_WAITIN,
      ST_SENDRESP, ST_STARTDESC, ST_SENDDESC, ST_DONESEND );
    signal s_state : t_state := ST_IDLE;

    -- Current control request
    signal s_ctlrequest :   std_logic_vector(3 downto 0);
    signal s_ctlparam :     std_logic_vector(7 downto 0);
    signal s_desctyp :      std_logic_vector(2 downto 0);
    signal s_answerlen :    unsigned(7 downto 0);
    signal s_sendbyte :     std_logic_vector(7 downto 0) := "00000000";

    -- Device state
    signal s_addr :         std_logic_vector(6 downto 0) := "0000000";
    signal s_confd :        std_logic := '0';

    -- Counters
    signal s_setupptr :     unsigned(2 downto 0);
    signal s_answerptr :    unsigned(7 downto 0);

begin

    -- Status signals
    C_ADDR <= s_addr;
    C_CONFD <= s_confd;

    -- Memory interface
    C_DSCBUSY   <= T_IN when (s_state = ST_WAITIN) else
                   '1' when (s_state = ST_STARTDESC or s_state = ST_SENDDESC) else
	           '0';
    C_DSCRD     <= '1' when (s_state = ST_STARTDESC) else T_TXRDY;
    C_DSCTYP    <= s_desctyp;
    C_DSCINX    <= s_ctlparam;
    C_DSCOFF    <= std_logic_vector(s_answerptr);

    -- Transaction interface
    T_NAK   <= '0';
    T_STALL <= '1' when (s_state = ST_STALL) else '0';  
    T_NYET  <= '0';
    T_SEND  <= '1' when ((s_state = ST_SENDRESP) or (s_state = ST_SENDDESC))
	       else '0';
    T_ISYNC <= not std_logic(s_answerptr(6));
    T_TXDAT <= s_sendbyte;

    -- On every rising clock edge
    process is
    begin
        wait until rising_edge(CLK);

        -- Set endpoint reset/halt lines to zero by default
        C_CLRIN   <= (others => '0');
        C_CLROUT  <= (others => '0');
        C_SHLTIN  <= (others => '0');
        C_SHLTOUT <= (others => '0');

        -- State machine
        if RESET = '1' then

            -- Reset this entity
            s_state <= ST_IDLE;
            s_addr  <= "0000000";
            s_confd <= '0';

            -- Trigger endpoint reset lines
            C_CLRIN  <= (others => '1');
            C_CLROUT <= (others => '1');

        else

            case s_state is

                when ST_IDLE =>
                    -- Idle; wait for SETUP transaction;
                    -- OUT transactions are ignored but acknowledged;
                    -- IN transactions send an empty packet.
                    s_answerptr <= to_unsigned(0, s_answerptr'length);
                    if T_SETUP = '1' then
                        -- Start of SETUP transaction
                        s_state <= ST_SETUP;
                        s_setupptr <= to_unsigned(0, s_setupptr'length);
                    end if;

                when ST_STALL =>
                    -- Stalled; wait for next SETUP transaction;
                    -- respond to IN/OUT transactions with a STALL handshake.
                    if T_SETUP = '1' then
                        -- Start of SETUP transaction
                        s_state <= ST_SETUP;
                        s_setupptr <= to_unsigned(0, s_setupptr'length);
                    end if;

                when ST_SETUP =>
                    -- In SETUP transaction; parse request structure.
                    s_answerptr <= to_unsigned(0, s_answerptr'length);
                    if T_RXRDY = '1' then
                        -- Process next request byte
                        case s_setupptr is
                            when "000" =>
                                -- bmRequestType
                                s_ctlparam <= T_RXDAT;
                                if T_RXDAT(6 downto 5) /= "00" then
                                    -- non-standard device request
                                    s_state <= ST_NONSTANDARD;
                                end if;
                            when "001" =>
                                -- bRequest
                                s_ctlrequest <= T_RXDAT(3 downto 0);
                                if T_RXDAT(7 downto 4) /= "0000" then
                                    -- Unknown request
                                    s_state <= ST_SETUPERR;
                                end if;
                            when "010" =>
                                -- wValue lsb
                                if s_ctlrequest /= req_getstatus then
                                    s_ctlparam <= T_RXDAT;
                                end if;
                            when "011" =>
                                -- wValue msb
                                if s_ctlrequest = req_getdesc then
                                    if T_RXDAT(7 downto 3) /= "00000" then
                                        -- Unsupported descriptor type
                                        s_state <= ST_SETUPERR;
                                    end if;
                                end if;
                                -- Store descriptor type (assuming GET_DESCRIPTOR request)
                                s_desctyp <= T_RXDAT(2 downto 0);
                            when "100" =>
                                -- wIndex lsb
                                case s_ctlrequest is
                                    when req_clearfeature =>
                                        if s_ctlparam = "00000000" then
                                            -- Clear ENDPOINT_HALT feature;
                                            -- store endpoint selector
                                            s_ctlparam <= T_RXDAT;
                                        else
                                            -- Unknown clear feature request
                                            s_ctlparam <= "00000000";
                                        end if;
                                    when req_setfeature => 
                                        if s_ctlparam = "00000000" then
                                            -- Set ENDPOINT_HALT feature;
                                            -- store endpoint selector
                                            s_ctlparam <= T_RXDAT;
                                        else
                                            -- Unsupported set feature request
                                            s_state <= ST_SETUPERR;
                                        end if;
                                    when req_getstatus =>
                                        if s_ctlparam(1 downto 0) = "00" then
                                            -- Get device status
                                            s_sendbyte <= "0000000" & C_SELFPOWERED;
                                            s_ctlparam <= "00000000";
                                        elsif s_ctlparam(1 downto 0) = "10" then
                                            -- Get endpoint status
                                            s_sendbyte <= "00000000";
                                            s_ctlparam <= T_RXDAT;
                                        else
                                            -- Probably get interface status
                                            s_sendbyte <= "00000000";
                                            s_ctlparam <= "00000000";
                                        end if;
                                    when others =>
                                        -- Don't care about index.
                                end case;
                            when "101" =>
                                -- wIndex msb; don't care
                            when "110" =>
                                -- wLength lsb
                                s_answerlen <= unsigned(T_RXDAT);
                            when "111" =>
                                -- wLength msb
                                if T_RXDAT /= "00000000" then
                                    s_answerlen <= "11111111";
                                end if;
                                s_state <= ST_ENDSETUP;
                            when others =>
                                -- Impossible
                        end case;
                        -- Increment position within SETUP packet
                        s_setupptr <= s_setupptr + 1;
                    elsif T_FIN = '1' then
                        -- Got short SETUP packet; answer with STALL status.
                        s_state <= ST_STALL;
                    elsif T_SETUP = '0' then
                        -- Got corrupt SETUP packet; ignore.
                        s_state <= ST_IDLE;
                    end if;

		when ST_SETUPERR =>
                    -- In SETUP transaction; got request error
                    if T_FIN = '1' then
                        -- Got good SETUP packet that causes request error
                        s_state <= ST_STALL;
                    elsif T_SETUP = '0' then
                        -- Got corrupt SETUP packet; ignore
                        s_state <= ST_IDLE;
                    end if;

                when ST_NONSTANDARD =>
                    -- Ignore non-standard requests
                    if T_SETUP = '0' then
                        s_state <= ST_IDLE;
                    end if;

                when ST_ENDSETUP =>
                    -- Parsed request packet; wait for end of SETUP transaction
                    if T_FIN = '1' then
                        -- Got complet SETUP packet; handle it
                        case s_ctlrequest is
                            when req_getstatus =>
                                -- Prepare status byte and move to data stage
                                -- If s_ctlparam = 0, the status byte has already
                                -- been prepared in state S_SETUP.
                                for i in 1 to NENDPT loop
                                    if unsigned(s_ctlparam(3 downto 0)) = i then
                                        if s_ctlparam(7) = '1' then
                                            s_sendbyte <= "0000000" & C_HLTIN(i);
                                        else
                                            s_sendbyte <= "0000000" & C_HLTOUT(i);
                                        end if;
                                    end if;
                                end loop;
                                s_state <= ST_WAITIN;
                            when req_clearfeature =>
                                -- Reset endpoint
                                for i in 1 to NENDPT loop
                                    if unsigned(s_ctlparam(3 downto 0)) = i then
                                        if s_ctlparam(7) = '1' then
                                            C_CLRIN(i)  <= '1';
                                        else
                                            C_CLROUT(i) <= '1';
                                        end if;
                                    end if;
                                end loop;
                                s_state <= ST_IDLE;
                            when req_setfeature =>
                                -- Set endpoint HALT
                                for i in 1 to NENDPT loop
                                    if unsigned(s_ctlparam(3 downto 0)) = i then
                                        if s_ctlparam(7) = '1' then
                                            C_SHLTIN(i)  <= '1';
                                        else
                                            C_SHLTOUT(i) <= '1';
                                        end if;
                                    end if;
                                end loop;
                                s_state <= ST_IDLE;
                            when req_setaddress =>
                                -- Move to status stage
                                s_state <= ST_WAITIN;
                            when req_getdesc =>
                                -- Move to data stage
                                s_state <= ST_WAITIN;
                            when req_getconf =>
                                -- Move to data stage
                                s_state <= ST_WAITIN;
                            when req_setconf =>
                                -- Set device configuration
                                if s_ctlparam(7 downto 1) = "0000000" then
                                    s_confd <= s_ctlparam(0);
                                    s_state <= ST_IDLE;
                                    C_CLRIN  <= (others => '1');
                                    C_CLROUT <= (others => '1');
                                else
                                    -- Unknown configuration number
                                    s_state <= ST_STALL;
                                end if;
                            when req_getiface =>
                                -- Move to data stage
                                s_state <= ST_WAITIN;
                            when others =>
                                -- Unsupported request
                                s_state <= ST_STALL;
                        end case;
                    elsif T_SETUP = '0' then
                        -- Got corrupt SETUP packet; ignore
                        s_state <= ST_IDLE;
                    end if;

                when ST_WAITIN =>
                    -- Got valid SETUP packet; waiting for IN transaction.
                    s_answerptr(5 downto 0) <= "000000";
                    if T_SETUP = '1' then
                        -- Start of next SETUP transaction
                        s_state <= ST_SETUP;
                        s_setupptr <= to_unsigned(0, s_setupptr'length);
                    elsif T_IN = '1' then
                        -- Start of IN transaction; respond to the request
                        case s_ctlrequest is
                            when req_getstatus =>
                                -- Respond with status byte, followed by zero byte.
                                s_state <= ST_SENDRESP;
                            when req_setaddress =>
                                -- Effectuate change of device address
                                s_addr <= s_ctlparam(6 downto 0);
                                s_state <= ST_IDLE;
                            when req_getdesc =>
                                -- Respond with descriptor
                                s_state <= ST_STARTDESC;
                            when req_getconf =>
                                -- Respond with current configuration
                                s_sendbyte  <= "0000000" & s_confd;
                                s_state     <= ST_SENDRESP;
                            when req_getiface =>
                                -- Respond with zero byte
                                s_sendbyte  <= "00000000";
                                s_state     <= ST_SENDRESP;
                            when others =>
                                -- Impossible
                        end case;
                    end if;

                when ST_SENDRESP =>
                    -- Respond to IN with a preset byte,
                    -- followed by zero or more nul byte(s)
                    if T_IN = '0' then
                        -- Aborted IN transaction; wait for retry
                        s_state <= ST_WAITIN;
                    elsif T_TXRDY = '1' then
                        -- Need next data byte
                        s_sendbyte <= "00000000";
                        if (s_answerptr(0) = '1') or (s_answerlen(0) = '1') then
                            -- Reached end of transfer.
                            -- Note that we only ever send 1 or 2 byte answers.
                            s_state <= ST_DONESEND;
                        end if;
                        s_answerptr(5 downto 0) <= s_answerptr(5 downto 0) + 1;
                    end if;

                when ST_STARTDESC =>
                    -- Fetching first byte of packet.
                    if T_IN = '0' then
                        -- Aborted IN transaction; wait for retry
                        s_state <= ST_WAITIN;
                    elsif unsigned(C_DSCLEN) = 0 then
                        -- Invalid descriptor.
                        s_state <= ST_STALL;
                    elsif (s_answerptr = unsigned(C_DSCLEN)) or
                          (s_answerptr = s_answerlen) then
                        -- Send an empty packet to complete the transfer.
                        s_state <= ST_DONESEND;
                    else
                        -- Send a normal descriptor packet.
                        s_state <= ST_SENDDESC;
                    end if;
                    s_answerptr(5 downto 0) <= s_answerptr(5 downto 0) + 1;

		when ST_SENDDESC =>
		    -- Respond to IN with descriptor
		    if T_IN = '0' then
			-- Aborted IN transaction; wait for retry
			s_state <= ST_WAITIN;
		    elsif T_TXRDY = '1' then
			-- Need next data byte
                        if (s_answerptr(5 downto 0) = 0) or
                           (s_answerptr = unsigned(C_DSCLEN)) or
                           (s_answerptr = s_answerlen) then
                            -- Just sent the last byte of the packet
                            s_state <= ST_DONESEND;
                        else
                            s_answerptr(5 downto 0) <= s_answerptr(5 downto 0) + 1;
                        end if;
		    end if;

		when ST_DONESEND =>
                    -- Done sending packet; wait until IN transaction completes.
                    -- Note: s_answerptr contains the number of bytes sent so-far,
                    -- unless this is a multiple of 64, in which case s_answerptr
                    -- contains 64 less than the number of bytes sent; and unless
                    -- the last packet sent was an empty end-of-transfer packet,
                    -- in which case s_answerptr contains 1 more than the number
                    -- of bytes sent.
                    if T_FIN = '1' then
                        -- Host acknowledged transaction.
                        if s_answerptr(5 downto 0) = 0 then
                            -- The last sent packet was a full sized packet.
                            -- If s_answerptr + 64 = s_answerlen, the transfer
                            -- is now complete; otherwise the host will expect
                            -- more data. In either case, we go back to WAITIN.
                            -- This can't go wrong because WAITIN also listens
                            -- for the next SETUP and handles it properly.
                            s_state <= ST_WAITIN;
                        else
                            -- The last sent packet was not full sized;
                            -- it was either empty or reached the end of
                            -- the descriptor. In either case, the transfer
                            -- is now complete.
                            s_state <= ST_IDLE;
                        end if;
                        s_answerptr <= s_answerptr + 64;
                    elsif T_IN = '0' then
                        -- Transaction failed; wait for retry.
                        s_state <= ST_WAITIN;
                    end if;

            end case;

        end if;

    end process;

end architecture usb_control_arch;
