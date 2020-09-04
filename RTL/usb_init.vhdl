
library ieee;
use ieee.std_logic_1164.all, ieee.numeric_std.all;

entity usb_init is

    port (

        -- 60 MHz UTMI clock.
        CLK :           in std_logic;

        -- Synchronous reset; triggers detach and reattach to the USB bus.
        RESET :         in std_logic;

        -- High for one clock if a reset signal is detected on the USB bus.
        I_USBRST :      out std_logic;

        -- High when attached to the host in high speed mode.
        I_HIGHSPEED :   out std_logic;

        -- High when suspended.
        -- Reset of this signal is asynchronous.
        -- This signal may be used to drive (inverted) the UTMI SuspendM pin.
        I_SUSPEND :     out std_logic;

        -- High to tell usb_packet that it must drive a continuous K state.
        P_CHIRPK :      out std_logic;

        -- Connect to the UTMI Reset signal.
        PHY_RESET :     out std_logic;

        -- Connect to the UTMI LineState signal.
        PHY_LINESTATE : in std_logic_vector(1 downto 0);

        -- Cconnect to the UTMI OpMode signal.
        PHY_OPMODE :    out std_logic_vector(1 downto 0);

        -- Connect to the UTMI XcvrSelect signal (0 = high speed, 1 = full speed).
        PHY_XCVRSELECT : out std_logic;

        -- Connect to the UTMI TermSelect signal (0 = high speed, 1 = full speed).
        PHY_TERMSELECT : out std_logic );

end entity usb_init;

architecture usb_init_arch of usb_init is

    -- Time from bus idle until device suspend (3 ms).
    constant TIME_SUSPEND : unsigned(19 downto 0) := to_unsigned(180000, 20);

    -- Time from start of SE0 until detection of reset signal (2.5 us + 10%).
    constant TIME_RESET :   unsigned(7 downto 0)  := to_unsigned(165, 8);

    -- Time to wait for good SE0 when waking up from suspend (6 ms).
    constant TIME_SUSPRST:  unsigned(19 downto 0) := to_unsigned(360000, 20);

    -- Duration of chirp K from device during high speed detection (1 ms + 10%).
    constant TIME_CHIRPK :  unsigned(19 downto 0) := to_unsigned(66000, 20);

    -- Minimum duration of chirp J/K during high speed detection (2.5 us + 10%).
    constant TIME_FILT :    unsigned(7 downto 0)  := to_unsigned(165, 8);

    -- Time to wait for chirp until giving up (1.1 ms).
    constant TIME_WTFS :    unsigned(19 downto 0) := to_unsigned(66000, 20);

    -- Time to wait after reverting to full-speed before sampling the bus (100 us).
    constant TIME_WTRSTHS : unsigned(19 downto 0) := to_unsigned(6000, 20);

    -- State machine
    type t_state is (
        ST_INIT, ST_FSRESET, ST_FULLSPEED, ST_SUSPEND, ST_SUSPRESET,
        ST_SENDCHIRP, ST_RECVCHIRP, ST_HIGHSPEED, ST_HSREVERT );
    signal s_state :        t_state := ST_INIT;

    -- Timers.
    signal s_timer1 :       unsigned(7 downto 0);
    signal s_timer2 :       unsigned(19 downto 0) := to_unsigned(0, 20);

    -- Count J/K chirps.
    signal s_chirpcnt :     unsigned(2 downto 0);

    -- High if the device is operating in high speed (or suspended from high speed).
    signal s_highspeed :    std_logic := '0';

    -- High if the device is currently suspended.
    -- Reset of this signal is asynchronous.
    signal s_suspend :      std_logic := '0';

    -- Input registers.
    signal s_linestate :    std_logic_vector(1 downto 0);

    -- Output registers.
    signal s_reset :        std_logic := '1';
    signal s_opmode :       std_logic_vector(1 downto 0) := "01";
    signal s_xcvrselect :   std_logic := '1';
    signal s_termselect :   std_logic := '1';
    signal s_chirpk :       std_logic := '0';

begin

    I_USBRST    <= s_reset;
    I_HIGHSPEED <= s_highspeed;
    I_SUSPEND   <= s_suspend;
    P_CHIRPK    <= s_chirpk;
    PHY_RESET   <= s_reset;
    PHY_OPMODE  <= s_opmode;
    PHY_XCVRSELECT <= s_xcvrselect;
    PHY_TERMSELECT <= s_termselect;

    -- Synchronous process.
    process is
        variable v_clrtimer1 : std_logic;
        variable v_clrtimer2 : std_logic;
    begin
	wait until rising_edge(CLK);

        -- By default, do not clear the timers.
        v_clrtimer1 := '0';
        v_clrtimer2 := '0';

	-- Register linestate input.
	s_linestate <= PHY_LINESTATE;

        -- Default assignments to registers.
        s_reset     <= '0';
        s_chirpk    <= '0';

        if RESET = '1' then

            -- Reset PHY.
            s_reset      <= '1';
	        s_opmode     <= "01";
            s_xcvrselect <= '1';
            s_termselect <= '1';

            -- Go to ST_INIT state and wait until bus attachment.
            v_clrtimer1  := '1';
            v_clrtimer2  := '1';
            s_highspeed  <= '0';
            s_state      <= ST_INIT;

	else

            case s_state is

                when ST_INIT =>
                    -- Wait before attaching to bus.
                    s_opmode     <= "01";   -- non-driving
                    s_xcvrselect <= '1';    -- full speed
                    s_termselect <= '1';    -- full speed
                    v_clrtimer1  := '1';
                    if s_timer2 = to_unsigned(0, s_timer2'length) - 1 then
                        -- Timer2 overflows after ~ 17 ms; attach to bus.
                        v_clrtimer2 := '1';
                        s_state     <= ST_FULLSPEED;
                    end if;

                when ST_FSRESET =>
                    -- Waiting for end of reset before full speed operation.
                    s_highspeed  <= '0';
                    s_opmode     <= "00";   -- normal
                    s_xcvrselect <= '1';    -- full speed
                    s_termselect <= '1';    -- full speed
                    v_clrtimer1  := '1';
                    v_clrtimer2  := '1';
                    if s_linestate /= "00" then
                        -- Reset signal ended.
                        s_state     <= ST_FULLSPEED;
                    end if;

                when ST_FULLSPEED =>
                    -- Operating in full speed.
                    s_highspeed  <= '0';
                    s_opmode     <= "00";   -- normal
                    s_xcvrselect <= '1';    -- full speed
                    s_termselect <= '1';    -- full speed
                    if s_linestate /= "00" then
                        -- Bus not in SE0 state; clear reset timer.
                        v_clrtimer1 := '1';
                    end if;
                    if s_linestate /= "01" then
                        -- Bus not in J state; clear suspend timer.
                        v_clrtimer2 := '1';
                    end if;
                    if s_timer1 = TIME_RESET then
                        -- Bus has been in SE0 state for TIME_RESET;
                        -- this is a reset signal.
                        s_reset     <= '1';
                        s_state     <= ST_FSRESET;
                    elsif s_timer2 = TIME_SUSPEND then
                        -- Bus has been idle for TIME_SUSPEND;
                        -- go to suspend state.
                        s_state     <= ST_SUSPEND;
                    end if;

                when ST_SUSPEND =>
                    -- Suspended; waiting for resume signal.
                    -- Possibly our clock will be disabled; wake up
                    -- is initiated by the asynchronous reset of s_suspend.
                    s_opmode     <= "00";   -- normal   
                    s_xcvrselect <= '1';    -- full speed
                    s_termselect <= '1';    -- full speed
                    v_clrtimer1  := '1';
                    v_clrtimer2  := '1';
                    if s_linestate /= "01" then
                        s_state     <= ST_FULLSPEED;
                    end if;

                when ST_SUSPRESET =>
                    -- Wake up in SE0 state; wait for proper reset signal.
                    s_opmode     <= "00";   -- normal   
                    s_xcvrselect <= '1';    -- full speed
                    s_termselect <= '1';    -- full speed
                    if s_linestate /= "00" then
                        -- Bus not in SE0 state; clear reset timer.
                        v_clrtimer1 := '1';
                    end if;
                    if s_timer1 = TIME_RESET then
                        -- Bus has been in SE0 state for TIME_RESET;
                        -- this is a reset signal.
                        s_reset     <= '1';
                        v_clrtimer2 := '1';
                        s_state     <= ST_SENDCHIRP;
                    end if;
                    if s_timer2 = TIME_SUSPRST then
                        -- Still no proper reset signal; go back to sleep.
                        s_state     <= ST_SUSPEND;
                    end if;

                when ST_SENDCHIRP =>
                    -- Sending chirp K for a duration of TIME_CHIRPK.
                    s_highspeed  <= '0';
                    s_opmode     <= "10";   -- disable bit stuffing
                    s_xcvrselect <= '0';    -- high speed
                    s_termselect <= '1';    -- full speed
                    s_chirpk     <= '1';    -- send chirp K
                    v_clrtimer1  := '1';
                    if s_timer2 = TIME_CHIRPK then
                        -- end of chirp K
                        v_clrtimer2 := '1';
                        s_chirpcnt  <= "000";
                        s_state     <= ST_RECVCHIRP;
                    end if;

                when ST_RECVCHIRP =>
                    -- Waiting for K-J-K-J-K-J chirps.
                    -- Note: DO NOT switch Opmode to normal yet; there
                    -- may be pending bits in the transmission buffer.
                    s_opmode     <= "10";   -- disable bit stuffing
                    s_xcvrselect <= '0';    -- high speed
                    s_termselect <= '1';    -- full speed
                    if ( s_chirpcnt(0) = '0' and s_linestate /= "10" ) or
                       ( s_chirpcnt(0) = '1' and s_linestate /= "01" ) then
                        -- Not the linestate we want.
                        v_clrtimer1 := '1';
                    end if;
                    if s_timer2 = TIME_WTFS then
                        -- High speed detection failed; go to full speed.
                        v_clrtimer1 := '1';
                        v_clrtimer2 := '1';
                        s_state     <= ST_FSRESET;
                    elsif s_timer1 = TIME_FILT then
                        -- We got the chirp we wanted.
                        if s_chirpcnt = 5 then
                            -- This was the last chirp;
                            -- we got a successful high speed handshake.
                            v_clrtimer2 := '1';
                            s_state     <= ST_HIGHSPEED;
                        end if;
                        s_chirpcnt  <= s_chirpcnt + 1;
                        v_clrtimer1 := '1';
                    end if;

                when ST_HIGHSPEED =>
                    -- Operating in high speed.
                    s_highspeed  <= '1';
                    s_opmode     <= "00";   -- normal
                    s_xcvrselect <= '0';    -- high speed
                    s_termselect <= '0';    -- high speed
                    if s_linestate /= "00" then
                        -- Bus not idle; clear revert timer.
                        v_clrtimer2 := '1';
                    end if;
                    if s_timer2 = TIME_SUSPEND then
                        -- Bus has been idle for TIME_SUSPEND;
                        -- revert to full speed.
                        v_clrtimer2 := '1';
                        s_state     <= ST_HSREVERT;
                    end if;

                when ST_HSREVERT =>
                    -- Revert to full speed and wait for 100 us.
                    s_opmode     <= "00";   -- normal
                    s_xcvrselect <= '1';    -- full speed
                    s_termselect <= '1';    -- full speed
                    if s_timer2 = TIME_WTRSTHS then
                        v_clrtimer2 := '1';
                        if s_linestate = "00" then
                            -- Reset from high speed.
                            s_reset     <= '1';
                            s_state     <= ST_SENDCHIRP;
                        else
                            -- Suspend from high speed.
                            s_state     <= ST_SUSPEND;
                        end if;
                    end if;

            end case;

	end if;

        -- Increment or clear timer1.
        if v_clrtimer1 = '1' then
            s_timer1 <= to_unsigned(0, s_timer1'length);
        else
            s_timer1 <= s_timer1 + 1;
        end if;

        -- Increment or clear timer2.
        if v_clrtimer2 = '1' then
            s_timer2 <= to_unsigned(0, s_timer2'length);
        else
            s_timer2 <= s_timer2 + 1;
        end if;

    end process;

    -- Drive the s_suspend flipflop (synchronous set, asynchronous reset).
    process (CLK, PHY_LINESTATE) is
    begin
        if PHY_LINESTATE /= "01" then
            -- The bus is not in full speed idle state;
            -- reset the s_suspend flipflop.
            s_suspend   <= '0';
        elsif rising_edge(CLK) then
            if s_state = ST_SUSPEND then
                -- Bus is idle and FSM is in suspend state;
                -- enable the s_suspend flipflop.
                s_suspend   <= '1';
            end if;
        end if;
    end process;

end architecture usb_init_arch;

