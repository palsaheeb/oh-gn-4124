--------------------------------------------------------------------------------
--                                                                            --
-- CERN BE-CO-HT         GN4124 core for PCIe FMC carrier                     --
--                       http://www.ohwr.org/projects/gn4124-core             --
--------------------------------------------------------------------------------
--
-- unit name: Gn4124 core main block (gn4124-core.vhd)
--
-- author: Simon Deprez (simon.deprez@cern.ch)
--
-- date: 31-08-2010
--
-- version: 0.3
--
-- description:
--
--
-- dependencies:
--
--------------------------------------------------------------------------------
-- last changes: <date> <initials> <log>
-- <extended description>
--------------------------------------------------------------------------------
-- TODO: - P2L DMA master
--       - Interrupt
--       -
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
use work.gn4124_core_pkg.all;

library UNISIM;
use UNISIM.vcomponents.all;


--==============================================================================
-- Entity declaration for GN4124 core (gn4124_core)
--==============================================================================
entity gn4124_core is
  port
    (
      LED         : out std_logic_vector(7 downto 0);
      ---------------------------------------------------------
      -- Clock/Reset from GN412x
      --      L_CLKp                 : in   std_logic;                     -- Running at 100 or 200 Mhz
      --      L_CLKn                 : in   std_logic;                     -- Running at 100 or 200 Mhz
      sys_clk_i   : in  std_logic;
      sys_rst_n_i : in  std_logic;

      ---------------------------------------------------------
      -- P2L Direction
      --
      -- Source Sync DDR related signals
      p2l_clk_p_i  : in  std_logic;                      -- Receiver Source Synchronous Clock+
      p2l_clk_n_i  : in  std_logic;                      -- Receiver Source Synchronous Clock-
      p2l_data_i   : in  std_logic_vector(15 downto 0);  -- Parallel receive data
      p2l_dframe_i : in  std_logic;                      -- Receive Frame
      p2l_valid_i  : in  std_logic;                      -- Receive Data Valid
      -- P2L Control
      p2l_rdy_o    : out std_logic;                      -- Rx Buffer Full Flag
      p_wr_req_o   : in  std_logic_vector(1 downto 0);   -- PCIe Write Request
      p_wr_rdy_o   : out std_logic_vector(1 downto 0);   -- PCIe Write Ready
      rx_error_o   : out std_logic;                      -- Receive Error

      ---------------------------------------------------------
      -- L2P Direction
      --
      -- Source Sync DDR related signals
      l2p_clk_p_o  : out std_logic;                      -- Transmitter Source Synchronous Clock+
      l2p_clk_n_o  : out std_logic;                      -- Transmitter Source Synchronous Clock-
      l2p_data_o   : out std_logic_vector(15 downto 0);  -- Parallel transmit data
      l2p_dframe_o : out std_logic;                      -- Transmit Data Frame
      l2p_valid_o  : out std_logic;                      -- Transmit Data Valid
      l2p_edb_o    : out std_logic;                      -- Packet termination and discard
      -- L2P Control
      l2p_rdy_i    : in  std_logic;                      -- Tx Buffer Full Flag
      l_wr_rdy_i   : in  std_logic_vector(1 downto 0);   -- Local-to-PCIe Write
      p_rd_d_rdy_i : in  std_logic_vector(1 downto 0);   -- PCIe-to-Local Read Response Data Ready
      tx_error_i   : in  std_logic;                      -- Transmit Error
      vc_rdy_i     : in  std_logic_vector(1 downto 0);   -- Channel ready

      ---------------------------------------------------------
      -- Target Interface (Wishbone master)
      wb_adr_o   : out std_logic_vector(31 downto 0);
      wb_dat_i   : in  std_logic_vector(31 downto 0);  -- Data in
      wb_dat_o   : out std_logic_vector(31 downto 0);  -- Data out
      wb_sel_o   : out std_logic_vector(3 downto 0);   -- Byte select
      wb_cyc_o   : out std_logic;
      wb_stb_o   : out std_logic;
      wb_we_o    : out std_logic;
      wb_ack_i   : in  std_logic;
      wb_stall_i : in  std_logic;

      ---------------------------------------------------------
      -- L2P DMA Interface (Pipelined Wishbone master)
      dma_adr_o   : out std_logic_vector(31 downto 0);
      dma_dat_i   : in  std_logic_vector(31 downto 0);  -- Data in
      dma_dat_o   : out std_logic_vector(31 downto 0);  -- Data out
      dma_sel_o   : out std_logic_vector(3 downto 0);   -- Byte select
      dma_cyc_o   : out std_logic;
      dma_stb_o   : out std_logic;
      dma_we_o    : out std_logic;
      dma_ack_i   : in  std_logic;
      dma_stall_i : in  std_logic                       -- for pipelined Wishbone
      );
end gn4124_core;

--==============================================================================
-- Architecture declaration for GN4124 core (gn4124_core)
--==============================================================================
architecture rtl of gn4124_core is


--==============================================================================
-- Internal signals
--==============================================================================

  -------------------------------------------------------------
  -- Clock/Reset
  -------------------------------------------------------------
  -- Internal 1X clock operating at the same rate as LCLK
  signal clk_p     : std_logic;
  signal clk_n     : std_logic;
  signal clk_p_buf : std_logic;
  signal clk_n_buf : std_logic;
  -- RESET for all clk_p logic
  signal rst_reg   : std_logic;
  signal rst_n     : std_logic;

-------------------------------------------------------------
-- P2L DataPath (from deserializer to packet decoder)
-------------------------------------------------------------
  signal des_pd_valid  : std_logic;
  signal des_pd_dframe : std_logic;
  signal des_pd_data   : std_logic_vector(31 downto 0);

-------------------------------------------------------------
-- P2L DataPath (from packet decoder to Wishbone master and P2L DMA master)
-------------------------------------------------------------

  signal p2l_hdr_start   : std_logic;                     -- Indicates Header start cycle
  signal p2l_hdr_length  : std_logic_vector(9 downto 0);  -- Latched LENGTH value from header
  signal p2l_hdr_cid     : std_logic_vector(1 downto 0);  -- Completion ID
  signal p2l_hdr_last    : std_logic;                     -- Indicates Last packet in a completion
  signal p2l_hdr_stat    : std_logic_vector(1 downto 0);  -- Completion Status
  signal p2l_target_mrd  : std_logic;
  signal p2l_target_mwr  : std_logic;
  signal p2l_master_cpld : std_logic;
  signal p2l_master_cpln : std_logic;

  signal p2l_d_valid    : std_logic;                      -- Indicates Address/Data is valid
  signal p2l_d_last     : std_logic;                      -- Indicates end of the packet
  signal p2l_d          : std_logic_vector(31 downto 0);  -- Address/Data
  signal p2l_be         : std_logic_vector(3 downto 0);   -- Byte Enable for data
  signal p2l_addr       : std_logic_vector(31 downto 0);  -- Registered and counting Address
  signal p2l_addr_start : std_logic;
  signal p2l_epi_select : std_logic;

  signal p_wr_rdy : std_logic;

  -------------------------------------------------------------
  -- L2P DataPath (from arbiter to serializer)
  -------------------------------------------------------------
  signal arb_ser_valid  : std_logic;
  signal arb_ser_dframe : std_logic;
  signal arb_ser_data   : std_logic_vector(31 downto 0);

  signal l2p_data_o_o : std_logic_vector(l2p_data_o'range);

  -- Resync bridge controls
  signal Il_wr_rdy_i   : std_logic;     -- Clocked version of L_WR_RDY from GN412x
  signal Ip_rd_d_rdy_i : std_logic;     -- Clocked version of p_rd_d_rdy_i from GN412x
  signal Il2p_rdy_i    : std_logic;     -- Clocked version of l2p_rdy_i from GN412x

  -------------------------------------------------------------
  -- Target Controller (Wishbone master)
  -------------------------------------------------------------
  signal wbm_arb_valid  : std_logic;
  signal wbm_arb_dframe : std_logic;
  signal wbm_arb_data   : std_logic_vector(31 downto 0);
  signal wbm_arb_req    : std_logic;
  signal arb_wbm_gnt    : std_logic;

  -------------------------------------------------------------
  -- DMA controller
  -------------------------------------------------------------
  signal dma_ctrl_carrier_addr : std_logic_vector(31 downto 0);
  signal dma_ctrl_host_addr_h  : std_logic_vector(31 downto 0);
  signal dma_ctrl_host_addr_l  : std_logic_vector(31 downto 0);
  signal dma_ctrl_len          : std_logic_vector(31 downto 0);
  signal dma_ctrl_start_l2p    : std_logic;  -- To the L2P DMA master
  signal dma_ctrl_start_p2l    : std_logic;  -- To the P2L DMA master
  signal dma_ctrl_start_next   : std_logic;  -- To the P2L DMA master

  signal dma_ctrl_done      : std_logic;
  signal dma_ctrl_error     : std_logic;
  signal dma_ctrl_l2p_done  : std_logic;
  signal dma_ctrl_l2p_error : std_logic;
  signal dma_ctrl_p2l_done  : std_logic;
  signal dma_ctrl_p2l_error : std_logic;
  signal dma_ctrl_byte_swap : std_logic_vector(1 downto 0);

  signal next_item_carrier_addr : std_logic_vector(31 downto 0);
  signal next_item_host_addr_h  : std_logic_vector(31 downto 0);
  signal next_item_host_addr_l  : std_logic_vector(31 downto 0);
  signal next_item_len          : std_logic_vector(31 downto 0);
  signal next_item_next_l       : std_logic_vector(31 downto 0);
  signal next_item_next_h       : std_logic_vector(31 downto 0);
  signal next_item_attrib       : std_logic_vector(31 downto 0);
  signal next_item_valid        : std_logic;

  signal wb_adr              : std_logic_vector(31 downto 0);  -- Adress
  signal wb_dat_s2m          : std_logic_vector(31 downto 0);  -- Data in
  signal wb_dat_m2s          : std_logic_vector(31 downto 0);  -- Data out
  signal wb_sel              : std_logic_vector(3 downto 0);   -- Byte select
  signal wb_cyc              : std_logic;                      -- Read or write cycle
  signal wb_stb              : std_logic;                      -- Read or write strobe
  signal wb_we               : std_logic;                      -- Write
  signal wb_ack              : std_logic;                      -- Acknowledge
  signal wb_stall            : std_logic;                      -- Pipelined mode
  signal wb_ack_dma_ctrl     : std_logic;                      --
  signal wb_stall_dma_ctrl   : std_logic;                      --
  signal wb_dat_s2m_dma_ctrl : std_logic_vector(31 downto 0);  --

  signal l2p_dma_adr     : std_logic_vector(31 downto 0);  -- Adress
  signal l2p_dma_dat_s2m : std_logic_vector(31 downto 0);  -- Data in
  signal l2p_dma_dat_m2s : std_logic_vector(31 downto 0);  -- Data out
  signal l2p_dma_sel     : std_logic_vector(3 downto 0);   -- Byte select
  signal l2p_dma_cyc     : std_logic;                      -- Read or write cycle
  signal l2p_dma_stb     : std_logic;                      -- Read or write strobe
  signal l2p_dma_we      : std_logic;                      -- Write
  signal l2p_dma_ack     : std_logic;                      -- Acknowledge
  signal l2p_dma_stall   : std_logic;                      -- Acknowledge

  signal p2l_dma_adr     : std_logic_vector(31 downto 0);  -- Adress
  signal p2l_dma_dat_s2m : std_logic_vector(31 downto 0);  -- Data in
  signal p2l_dma_dat_m2s : std_logic_vector(31 downto 0);  -- Data out
  signal p2l_dma_sel     : std_logic_vector(3 downto 0);   -- Byte select
  signal p2l_dma_cyc     : std_logic;                      -- Read or write cycle
  signal p2l_dma_stb     : std_logic;                      -- Read or write strobe
  signal p2l_dma_we      : std_logic;                      -- Write
  signal p2l_dma_ack     : std_logic;                      -- Acknowledge
  signal p2l_dma_stall   : std_logic;                      -- Acknowledge

  -------------------------------------------------------------
  -- L2P DMA master
  -------------------------------------------------------------
  signal ldm_arb_req    : std_logic;    -- Request use of the L2P bus
  signal arb_ldm_gnt    : std_logic;    -- L2P bus emits data on behalf of the L2P DMA
  signal ldm_arb_valid  : std_logic;
  signal ldm_arb_dframe : std_logic;
  signal ldm_arb_data   : std_logic_vector(31 downto 0);

--  signal IL2P_DMA_RDY          : STD_LOGIC; -- Clocked version of l2p_rdy_i from GN412x

  -------------------------------------------------------------
  -- P2L DMA master
  -------------------------------------------------------------
  signal pdm_arb_valid  : std_logic;
  signal pdm_arb_dframe : std_logic;
  signal pdm_arb_data   : std_logic_vector(31 downto 0);
  signal pdm_arb_req    : std_logic;
  signal arb_pdm_gnt    : std_logic;

--==============================================================================
-- Architecture begin (gn4124_core)
--==============================================================================
begin


  -----------------------------------------------------------------------------
  -- The Internal Core Clock is Derived from the P2L_CLK
  -----------------------------------------------------------------------------
  CLK_ibuf : IBUFGDS
    port map(
      I  => p2l_clk_p_i,
      IB => p2l_clk_n_i,
      O  => clk_p_buf);

  CLK_bufg : BUFG
    port map(
      I => clk_p_buf,
      O => clk_p);

  CLKn_ibuf : IBUFGDS
    port map(
      I  => p2l_clk_n_i,
      IB => p2l_clk_p_i,
      O  => clk_n_buf);

  CLKn_bufg : BUFG
    port map(
      I => clk_n_buf,
      O => clk_n);


  ------------------------------------------------------------------------------
  -- Reset aligned to core clock
  ------------------------------------------------------------------------------
  process (clk_p, sys_rst_n_i)
  begin
    if sys_rst_n_i = c_RST_ACTIVE then
      rst_reg <= c_RST_ACTIVE;
    elsif rising_edge(clk_p) then
      rst_reg <= not(c_RST_ACTIVE);
    end if;
  end process;


  cmp_rst_buf : BUFG
    port map (
      I => rst_reg,
      O => rst_n
      );


--=============================================================================================--
--=============================================================================================--
--== P2L DataPath
--=============================================================================================--
--=============================================================================================--

-----------------------------------------------------------------------------
-- p2l_des: Deserialize the P2L DDR inputs
-----------------------------------------------------------------------------
  cmp_p2l_des : p2l_des
    port map
    (
      ---------------------------------------------------------
      -- Raw unprocessed reset from the GN412x
      rst_n_i => rst_n,
      clk_p_i => clk_p,
      clk_n_i => clk_n,

      ---------------------------------------------------------
      -- P2L Clock Domain
      --
      -- P2L Inputs
      p2l_valid_i  => p2l_valid_i,
      p2l_dframe_i => p2l_dframe_i,
      p2l_data_i   => p2l_data_i,

      ---------------------------------------------------------
      -- Core Clock Domain
      --
      -- DeSerialized Output
      p2l_valid_o  => des_pd_valid,
      p2l_dframe_o => des_pd_dframe,
      p2l_data_o   => des_pd_data
      );

-----------------------------------------------------------------------------
-- p2l_decode32: Decode the output of the p2l_des
-----------------------------------------------------------------------------
  cmp_p2l_decode32 : p2l_decode32
    port map
    (
      ---------------------------------------------------------
      -- Clock/Reset
      clk_i   => clk_p,
      rst_n_i => rst_n,

      ---------------------------------------------------------
      -- Input from the Deserializer
      --
      des_p2l_valid_i  => des_pd_valid,
      des_p2l_dframe_i => des_pd_dframe,
      des_p2l_data_i   => des_pd_data,

      ---------------------------------------------------------
      -- Decoder Outputs
      --
      -- Header
      p2l_hdr_start_o   => p2l_hdr_start,
      p2l_hdr_length_o  => p2l_hdr_length,
      p2l_hdr_cid_o     => p2l_hdr_cid,
      p2l_hdr_last_o    => p2l_hdr_last,
      p2l_hdr_stat_o    => p2l_hdr_stat,
      p2l_target_mrd_o  => p2l_target_mrd,
      p2l_target_mwr_o  => p2l_target_mwr,
      p2l_master_cpld_o => p2l_master_cpld,
      p2l_master_cpln_o => p2l_master_cpln,
      --
      -- Address
      p2l_addr_start_o  => p2l_addr_start,
      p2l_addr_o        => p2l_addr,
      --
      -- Data
      p2l_d_valid_o     => p2l_d_valid,
      p2l_d_last_o      => p2l_d_last,
      p2l_d_o           => p2l_d,
      p2l_be_o          => p2l_be
      );


-----------------------------------------------------------------------------
-- Resync some GN412x Signals
-----------------------------------------------------------------------------
  process (clk_p, rst_n)
  begin
    if(rst_n = c_RST_ACTIVE) then
      Il_wr_rdy_i   <= '0';
      Ip_rd_d_rdy_i <= '0';
      Il2p_rdy_i    <= '0';
    elsif rising_edge(clk_p) then
      Il_wr_rdy_i   <= l_wr_rdy_i(0);
      Ip_rd_d_rdy_i <= p_rd_d_rdy_i(0);
      Il2p_rdy_i    <= l2p_rdy_i;
    end if;
  end process;


--=============================================================================================--
--=============================================================================================--
--== Core Logic Blocks
--=============================================================================================--
--=============================================================================================--

-----------------------------------------------------------------------------
-- Wishbone master
-----------------------------------------------------------------------------
  u_wbmaster32 : wbmaster32
    generic map
    (
      WBM_TIMEOUT => 5
      )
    port map
    (
      DEBUG => LED (3 downto 0),

      ---------------------------------------------------------
      -- Clock/Reset
      sys_clk_i    => clk_p,--sys_clk_i,
      sys_rst_n_i  => rst_n,
      gn4124_clk_i => clk_p,

      ---------------------------------------------------------
      -- From P2L Decoder
      --
      -- Header
      pd_wbm_hdr_start_i  => p2l_hdr_start,
      pd_wbm_hdr_length_i => p2l_hdr_length,
      pd_wbm_hdr_cid_i    => p2l_hdr_cid,
      pd_wbm_target_mrd_i => p2l_target_mrd,
      pd_wbm_target_mwr_i => p2l_target_mwr,
      --
      -- Address
      pd_wbm_addr_start_i => p2l_addr_start,
      pd_wbm_addr_i       => p2l_addr,
      pd_wbm_wbm_addr_i   => p2l_epi_select,
      --
      -- Data
      pd_wbm_data_valid_i => p2l_d_valid,
      pd_wbm_data_last_i  => p2l_d_last,
      pd_wbm_data_i       => p2l_d,
      pd_wbm_be_i         => p2l_be,

      ---------------------------------------------------------
      -- P2L Control
      p_wr_rdy_o => p_wr_rdy,

      ---------------------------------------------------------
      -- To the L2P Interface
      wbm_arb_valid_o  => wbm_arb_valid,
      wbm_arb_dframe_o => wbm_arb_dframe,
      wbm_arb_data_o   => wbm_arb_data,
      wbm_arb_req_o    => wbm_arb_req,
      arb_wbm_gnt_i    => arb_wbm_gnt,

      ---------------------------------------------------------
      -- Wishbone Interface
      wb_adr_o   => wb_adr,
      wb_dat_i   => wb_dat_s2m,
      wb_dat_o   => wb_dat_m2s,
      wb_sel_o   => wb_sel,
      wb_cyc_o   => wb_cyc,
      wb_stb_o   => wb_stb,
      wb_we_o    => wb_we,
      wb_ack_i   => wb_ack,
      wb_stall_i => wb_stall
      );

  wb_adr_o   <= wb_adr;
  wb_dat_s2m <= wb_dat_i or wb_dat_s2m_dma_ctrl;
  wb_dat_o   <= wb_dat_m2s;
  wb_sel_o   <= wb_sel;
  wb_cyc_o   <= wb_cyc;
  wb_stb_o   <= wb_stb;
  wb_we_o    <= wb_we;
  wb_ack     <= wb_ack_i or wb_ack_dma_ctrl;
  wb_stall   <= wb_stall_i or wb_stall_dma_ctrl;


  wb_stall_dma_ctrl <= wb_stb and not wb_ack;

  p2l_epi_select <= not p2l_addr(0);

-----------------------------------------------------------------------------
  u_dma_controller : dma_controller
-----------------------------------------------------------------------------
    port map
    (
      --DEBUG=> LED (7 downto 4),
      sys_clk_i   => clk_p,--sys_clk_i,
      sys_rst_n_i => rst_n,

      dma_ctrl_carrier_addr_o => dma_ctrl_carrier_addr,
      dma_ctrl_host_addr_h_o  => dma_ctrl_host_addr_h,
      dma_ctrl_host_addr_l_o  => dma_ctrl_host_addr_l,
      dma_ctrl_len_o          => dma_ctrl_len,
      dma_ctrl_start_l2p_o    => dma_ctrl_start_l2p,
      dma_ctrl_start_p2l_o    => dma_ctrl_start_p2l,
      dma_ctrl_start_next_o   => dma_ctrl_start_next,
      dma_ctrl_done_i         => dma_ctrl_done,
      dma_ctrl_error_i        => dma_ctrl_error,
      dma_ctrl_byte_swap_o    => dma_ctrl_byte_swap,

      next_item_carrier_addr_i => next_item_carrier_addr,
      next_item_host_addr_h_i  => next_item_host_addr_h,
      next_item_host_addr_l_i  => next_item_host_addr_l,
      next_item_len_i          => next_item_len,
      next_item_next_l_i       => next_item_next_l,
      next_item_next_h_i       => next_item_next_h,
      next_item_attrib_i       => next_item_attrib,
      next_item_valid_i        => next_item_valid,

      wb_adr_i => wb_adr(5 downto 2),
      wb_dat_o => wb_dat_s2m_dma_ctrl,
      wb_dat_i => wb_dat_m2s,
      wb_sel_i => wb_sel,
      wb_cyc_i => wb_cyc,
      wb_stb_i => wb_stb,
      wb_we_i  => wb_we,
      wb_ack_o => wb_ack_dma_ctrl
      );



  dma_ctrl_done  <= dma_ctrl_l2p_done or dma_ctrl_p2l_done;
  dma_ctrl_error <= dma_ctrl_l2p_error or dma_ctrl_p2l_error;
-----------------------------------------------------------------------------
  u_l2p_dma_master : l2p_dma_master
-----------------------------------------------------------------------------
    port map
    (
      sys_clk_i   => clk_p,--sys_clk_i,
      sys_rst_n_i => rst_n,

      gn4124_clk_i => clk_p,

      dma_ctrl_carrier_addr_i => dma_ctrl_carrier_addr,
      dma_ctrl_host_addr_h_i  => dma_ctrl_host_addr_h,
      dma_ctrl_host_addr_l_i  => dma_ctrl_host_addr_l,
      dma_ctrl_len_i          => dma_ctrl_len,
      dma_ctrl_start_l2p_i    => dma_ctrl_start_l2p,
      dma_ctrl_done_o         => dma_ctrl_l2p_done,
      dma_ctrl_error_o        => dma_ctrl_l2p_error,
      dma_ctrl_byte_swap_i    => dma_ctrl_byte_swap,

      ldm_arb_valid_o  => ldm_arb_valid,
      ldm_arb_dframe_o => ldm_arb_dframe,
      ldm_arb_data_o   => ldm_arb_data,
      ldm_arb_req_o    => ldm_arb_req,
      arb_ldm_gnt_i    => arb_ldm_gnt,

      l2p_dma_adr_o   => l2p_dma_adr,
      l2p_dma_dat_i   => l2p_dma_dat_s2m,
      l2p_dma_dat_o   => l2p_dma_dat_m2s,
      l2p_dma_sel_o   => l2p_dma_sel,
      l2p_dma_cyc_o   => l2p_dma_cyc,
      l2p_dma_stb_o   => l2p_dma_stb,
      l2p_dma_we_o    => l2p_dma_we,
      l2p_dma_ack_i   => l2p_dma_ack,
      l2p_dma_stall_i => l2p_dma_stall
      );

-----------------------------------------------------------------------------
  u_p2l_dma_master : p2l_dma_master
-----------------------------------------------------------------------------
    port map
    (
      DEBUG       => LED (7 downto 4),
      sys_clk_i   => clk_p,--sys_clk_i,
      sys_rst_n_i => rst_n,

      gn4124_clk_i => clk_p,

      dma_ctrl_carrier_addr_i => dma_ctrl_carrier_addr,
      dma_ctrl_host_addr_h_i  => dma_ctrl_host_addr_h,
      dma_ctrl_host_addr_l_i  => dma_ctrl_host_addr_l,
      dma_ctrl_len_i          => dma_ctrl_len,
      dma_ctrl_start_p2l_i    => dma_ctrl_start_p2l,
      dma_ctrl_start_next_i   => dma_ctrl_start_next,
      dma_ctrl_done_o         => dma_ctrl_p2l_done,
      dma_ctrl_error_o        => dma_ctrl_p2l_error,
      dma_ctrl_byte_swap_i    => dma_ctrl_byte_swap,

      pd_pdm_hdr_start_i   => p2l_hdr_start,
      pd_pdm_hdr_length_i  => p2l_hdr_length,
      pd_pdm_hdr_cid_i     => p2l_hdr_cid,
      pd_pdm_target_mrd_i  => p2l_target_mrd,
      pd_pdm_target_mwr_i  => p2l_target_mwr,
      pd_pdm_target_cpld_i => p2l_master_cpld,

      pd_pdm_addr_start_i => p2l_addr_start,
      pd_pdm_addr_i       => p2l_addr,
      pd_pdm_wbm_addr_i   => p2l_epi_select,

      pd_pdm_data_valid_i => p2l_d_valid,
      pd_pdm_data_last_i  => p2l_d_last,
      pd_pdm_data_i       => p2l_d,
      pd_pdm_be_i         => p2l_be,

      pdm_arb_valid_o  => pdm_arb_valid,
      pdm_arb_dframe_o => pdm_arb_dframe,
      pdm_arb_data_o   => pdm_arb_data,
      pdm_arb_req_o    => pdm_arb_req,
      arb_pdm_gnt_i    => arb_pdm_gnt,

      p2l_dma_adr_o   => p2l_dma_adr,
      p2l_dma_dat_i   => p2l_dma_dat_s2m,
      p2l_dma_dat_o   => p2l_dma_dat_m2s,
      p2l_dma_sel_o   => p2l_dma_sel,
      p2l_dma_cyc_o   => p2l_dma_cyc,
      p2l_dma_stb_o   => p2l_dma_stb,
      p2l_dma_we_o    => p2l_dma_we,
      p2l_dma_ack_i   => p2l_dma_ack,
      p2l_dma_stall_i => p2l_dma_stall,

      next_item_carrier_addr_o => next_item_carrier_addr,
      next_item_host_addr_h_o  => next_item_host_addr_h,
      next_item_host_addr_l_o  => next_item_host_addr_l,
      next_item_len_o          => next_item_len,
      next_item_next_l_o       => next_item_next_l,
      next_item_next_h_o       => next_item_next_h,
      next_item_attrib_o       => next_item_attrib,
      next_item_valid_o        => next_item_valid
      );

  dma_adr_o       <= l2p_dma_adr or p2l_dma_adr;
  l2p_dma_dat_s2m <= dma_dat_i;
  p2l_dma_dat_s2m <= dma_dat_i;
  dma_dat_o       <= l2p_dma_dat_m2s or p2l_dma_dat_m2s;
  dma_sel_o       <= l2p_dma_sel or p2l_dma_sel;
  dma_cyc_o       <= l2p_dma_cyc or p2l_dma_cyc;
  dma_stb_o       <= l2p_dma_stb or p2l_dma_stb;
  dma_we_o        <= l2p_dma_we or p2l_dma_we;
  l2p_dma_ack     <= dma_ack_i;
  l2p_dma_stall   <= dma_stall_i;
  p2l_dma_ack     <= dma_ack_i;
  p2l_dma_stall   <= dma_stall_i;



-----------------------------------------------------------------------------
-- Top Level LB Controls
-----------------------------------------------------------------------------

  p_wr_rdy_o <= p_wr_rdy & p_wr_rdy;
  rx_error_o <= '0';
  l2p_edb_o  <= '0';
  p2l_rdy_o  <= rst_n;



--=============================================================================================--
--=============================================================================================--
--== L2P DataPath
--=============================================================================================--
--=============================================================================================--

--  arb_wbm_gnt <= '1';

--  arb_ser_valid   <= wbm_arb_valid;

--  arb_ser_dframe  <= wbm_arb_dframe;

--  arb_ser_data    <= wbm_arb_data;

-----------------------------------------------------------------------------
-- ARBITER: Arbitrate between Wishbone master, DMA master and DMA pdmuencer
-----------------------------------------------------------------------------
  u_arbiter : arbiter
    port map
    (
      ---------------------------------------------------------
      -- Clock/Reset
      clk_i   => clk_p,
      rst_n_i => rst_n,

      ---------------------------------------------------------
      -- From Wishbone master (wbm) to arbiter (arb)
      wbm_arb_valid_i  => wbm_arb_valid,
      wbm_arb_dframe_i => wbm_arb_dframe,
      wbm_arb_data_i   => wbm_arb_data,
      wbm_arb_req_i    => wbm_arb_req,
      arb_wbm_gnt_o    => arb_wbm_gnt,

      ---------------------------------------------------------
      -- From DMA controller (pdm) to arbiter (arb)
      pdm_arb_valid_i  => pdm_arb_valid,
      pdm_arb_dframe_i => pdm_arb_dframe,
      pdm_arb_data_i   => pdm_arb_data,
      pdm_arb_req_i    => pdm_arb_req,
      arb_pdm_gnt_o    => arb_pdm_gnt,

      ---------------------------------------------------------
      -- From P2L DMA master (pdm) to arbiter (arb)
      ldm_arb_valid_i  => ldm_arb_valid,
      ldm_arb_dframe_i => ldm_arb_dframe,
      ldm_arb_data_i   => ldm_arb_data,
      ldm_arb_req_i    => ldm_arb_req,
      arb_ldm_gnt_o    => arb_ldm_gnt,

      ---------------------------------------------------------
      -- From arbiter (arb) to serializer (ser)
      arb_ser_valid_o  => arb_ser_valid,
      arb_ser_dframe_o => arb_ser_dframe,
      arb_ser_data_o   => arb_ser_data
      );



-----------------------------------------------------------------------------
-- L2P_SER: Generate the L2P DDR Outputs
-----------------------------------------------------------------------------
  cmp_l2p_ser : l2p_ser
    port map
    (
      ---------------------------------------------------------
      -- clk_p Clock Domain Inputs
      clk_p_i => clk_p,
      clk_n_i => clk_n,
      rst_n_i => rst_n,

      ---------------------------------------------------------
      -- DeSerialized Output
      l2p_valid_i  => arb_ser_valid,
      l2p_dframe_i => arb_ser_dframe,
      l2p_data_i   => arb_ser_data,

      ---------------------------------------------------------
      -- SER Outputs
      --
      -- P2L Inputs
      l2p_clk_p_o  => l2p_clk_p_o,
      l2p_clk_n_o  => l2p_clk_n_o,
      l2p_valid_o  => l2p_valid_o,
      l2p_dframe_o => l2p_dframe_o,
      l2p_data_o   => l2p_data_o
      );


end rtl;
--==============================================================================
-- Architecture end (gn4124_core)
--==============================================================================
