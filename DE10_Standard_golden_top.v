// ============================================================================
// Copyright (c) 2016 by Terasic Technologies Inc.
// ============================================================================
//
// Permission:
//
//   Terasic grants permission to use and modify this code for use
//   in synthesis for all Terasic Development Boards and Altera Development 
//   Kits made by Terasic.  Other use of this code, including the selling 
//   ,duplication, or modification of any portion is strictly prohibited.
//
// Disclaimer:
//
//   This VHDL/Verilog or C/C++ source code is intended as a design reference
//   which illustrates how these types of functions can be implemented.
//   It is the user's responsibility to verify their design for
//   consistency and functionality through the use of formal
//   verification methods.  Terasic provides no warranty regarding the use 
//   or functionality of this code.
//
// ============================================================================
//           
//  Terasic Technologies Inc
//  9F., No.176, Sec.2, Gongdao 5th Rd, East Dist, Hsinchu City, 30070. Taiwan
//  
//  
//                     web: http://www.terasic.com/  
//                     email: support@terasic.com
//
// ============================================================================
//Date:  Thu Nov  3 15:01:20 2016
// ============================================================================

//`define ENABLE_HSMC
`define ENABLE_HPS

module DE10_Standard_golden_top(

      ///////// CLOCK /////////
      input              CLOCK2_50,
      input              CLOCK3_50,
      input              CLOCK4_50,
      input              CLOCK_50,

      ///////// KEY /////////
      input    [ 3: 0]   KEY,

      ///////// SW /////////
      input    [ 9: 0]   SW,

      ///////// LED /////////
      output   [ 9: 0]   LEDR,

      ///////// Seg7 /////////
      output   [ 6: 0]   HEX0,
      output   [ 6: 0]   HEX1,
      output   [ 6: 0]   HEX2,
      output   [ 6: 0]   HEX3,
      output   [ 6: 0]   HEX4,
      output   [ 6: 0]   HEX5,

      ///////// SDRAM /////////
      output             DRAM_CLK,
      output             DRAM_CKE,
      output   [12: 0]   DRAM_ADDR,
      output   [ 1: 0]   DRAM_BA,
      inout    [15: 0]   DRAM_DQ,
      output             DRAM_LDQM,
      output             DRAM_UDQM,
      output             DRAM_CS_N,
      output             DRAM_WE_N,
      output             DRAM_CAS_N,
      output             DRAM_RAS_N,

      ///////// Video-In /////////
      input              TD_CLK27,
      input              TD_HS,
      input              TD_VS,
      input    [ 7: 0]   TD_DATA,
      output             TD_RESET_N,

      ///////// VGA /////////
      output             VGA_CLK,
      output             VGA_HS,
      output             VGA_VS,
      output   [ 7: 0]   VGA_R,
      output   [ 7: 0]   VGA_G,
      output   [ 7: 0]   VGA_B,
      output             VGA_BLANK_N,
      output             VGA_SYNC_N,

      ///////// Audio /////////
      inout              AUD_BCLK,
      output             AUD_XCK,
      inout              AUD_ADCLRCK,
      input              AUD_ADCDAT,
      inout              AUD_DACLRCK,
      output             AUD_DACDAT,

      ///////// PS2 /////////
      inout              PS2_CLK,
      inout              PS2_CLK2,
      inout              PS2_DAT,
      inout              PS2_DAT2,

      ///////// ADC /////////
      output             ADC_SCLK,
      input              ADC_DOUT,
      output             ADC_DIN,
      output             ADC_CONVST,

      ///////// I2C for Audio and Video-In /////////
      output             FPGA_I2C_SCLK,
      inout              FPGA_I2C_SDAT,

      ///////// GPIO /////////
      inout    [35: 0]   GPIO,

`ifdef ENABLE_HSMC
      ///////// HSMC /////////
      input              HSMC_CLKIN_P1,
      input              HSMC_CLKIN_N1,
      input              HSMC_CLKIN_P2,
      input              HSMC_CLKIN_N2,
      output             HSMC_CLKOUT_P1,
      output             HSMC_CLKOUT_N1,
      output             HSMC_CLKOUT_P2,
      output             HSMC_CLKOUT_N2,
      inout    [16: 0]   HSMC_TX_D_P,
      inout    [16: 0]   HSMC_TX_D_N,
      inout    [16: 0]   HSMC_RX_D_P,
      inout    [16: 0]   HSMC_RX_D_N,
      input              HSMC_CLKIN0,
      output             HSMC_CLKOUT0,
      inout    [ 3: 0]   HSMC_D,
      output             HSMC_SCL,
      inout              HSMC_SDA,
`endif /*ENABLE_HSMC*/

`ifdef ENABLE_HPS
      ///////// HPS /////////
      inout              HPS_CONV_USB_N,
      output   [14: 0]   HPS_DDR3_ADDR,
      output   [ 2: 0]   HPS_DDR3_BA,
      output             HPS_DDR3_CAS_N,
      output             HPS_DDR3_CKE,
      output             HPS_DDR3_CK_N,
      output             HPS_DDR3_CK_P,
      output             HPS_DDR3_CS_N,
      output   [ 3: 0]   HPS_DDR3_DM,
      inout    [31: 0]   HPS_DDR3_DQ,
      inout    [ 3: 0]   HPS_DDR3_DQS_N,
      inout    [ 3: 0]   HPS_DDR3_DQS_P,
      output             HPS_DDR3_ODT,
      output             HPS_DDR3_RAS_N,
      output             HPS_DDR3_RESET_N,
      input              HPS_DDR3_RZQ,
      output             HPS_DDR3_WE_N,
      output             HPS_ENET_GTX_CLK,
      inout              HPS_ENET_INT_N,
      output             HPS_ENET_MDC,
      inout              HPS_ENET_MDIO,
      input              HPS_ENET_RX_CLK,
      input    [ 3: 0]   HPS_ENET_RX_DATA,
      input              HPS_ENET_RX_DV,
      output   [ 3: 0]   HPS_ENET_TX_DATA,
      output             HPS_ENET_TX_EN,
      inout    [ 3: 0]   HPS_FLASH_DATA,
      output             HPS_FLASH_DCLK,
      output             HPS_FLASH_NCSO,
      inout              HPS_GSENSOR_INT,
      inout              HPS_I2C1_SCLK,
      inout              HPS_I2C1_SDAT,
      inout              HPS_I2C2_SCLK,
      inout              HPS_I2C2_SDAT,
      inout              HPS_I2C_CONTROL,
      inout              HPS_KEY,
      inout              HPS_LCM_BK,
      inout              HPS_LCM_D_C,
      inout              HPS_LCM_RST_N,
      output             HPS_LCM_SPIM_CLK,
      output             HPS_LCM_SPIM_MOSI,
	  input 			 HPS_LCM_SPIM_MISO,
      output             HPS_LCM_SPIM_SS,
      inout              HPS_LED,
      inout              HPS_LTC_GPIO,
      output             HPS_SD_CLK,
      inout              HPS_SD_CMD,
      inout    [ 3: 0]   HPS_SD_DATA,
      output             HPS_SPIM_CLK,
      input              HPS_SPIM_MISO,
      output             HPS_SPIM_MOSI,
      output             HPS_SPIM_SS,
      input              HPS_UART_RX,
      output             HPS_UART_TX,
      input              HPS_USB_CLKOUT,
      inout    [ 7: 0]   HPS_USB_DATA,
      input              HPS_USB_DIR,
      input              HPS_USB_NXT,
      output             HPS_USB_STP,
`endif /*ENABLE_HPS*/


      ///////// IR /////////
      output             IRDA_TXD,
      input              IRDA_RXD
);


//=======================================================
//  REG/WIRE declarations
//=======================================================

wire        hps_fpga_reset_n;
wire [8:0]  fpga_led_internal;
wire        hps_cold_reset;
wire        hps_warm_reset;
wire        hps_debug_reset;
wire [27:0] stm_hw_events;
wire        fpga_clk_50;

assign LEDR[9:1] = fpga_led_internal;
assign stm_hw_events = {{4{1'b0}}, SW, 4'b0000, KEY};
assign fpga_clk_50 = CLOCK_50;

// REVERTED (see fpga_docs/bugs.md #12): a power-on-reset generator was
// added here to fix bug #11's reject-rate divergence, and made things
// worse on real hardware - fpga_matching_core hung permanently mid-order
// (STATUS.BUSY stuck at 1) and took the whole shared Avalon interconnect
// behind mm_bridge_0 down with it (led_pio stopped responding too, not
// just our core). Most likely cause: fpga_matching_core's Avalon
// interface is declared fixed-latency with no waitrequest - a hard
// promise to the interconnect that real silicon's CDC apparently broke
// in a way zero-delay RTL simulation never could. Reverting to the
// known-stable prior behavior (reset tied permanently high, relying on
// Quartus's bitstream configuration to initialize registers) to ship
// today; bug #11's smaller reject-rate discrepancy stands as a known,
// non-blocking, documented limitation rather than risk another hang
// chasing it further right now.

//=======================================================
//  Structural coding
//=======================================================

// soc_system: hps_0 (Cyclone V HPS, DDR3 configured for this exact board -
// reused verbatim from the proven-working de10_ghrd reference project's
// own soc_system.qsys, only cfar_bridge_0 swapped for fpga_matching_core_0
// on the same lightweight HPS-to-FPGA bridge connection point) + our
// bounded matching core. This instantiation pattern (port names, HPS pin
// wiring) is copied from that reference's own DE10_Standard_GHRD.v, which
// is confirmed working against this exact physical board - not
// reconstructed from the HPS datasheet by hand. button_pio is wired
// directly to KEY (undebounced) rather than through a debounce module -
// a deliberate simplification, since this project has no functional
// dependency on debounced button behavior.
soc_system u0 (
        .clk_clk                               (CLOCK_50),
        .reset_reset_n                         (1'b1),

        //HPS ddr3
        .memory_mem_a                          ( HPS_DDR3_ADDR),
        .memory_mem_ba                         ( HPS_DDR3_BA),
        .memory_mem_ck                         ( HPS_DDR3_CK_P),
        .memory_mem_ck_n                       ( HPS_DDR3_CK_N),
        .memory_mem_cke                        ( HPS_DDR3_CKE),
        .memory_mem_cs_n                       ( HPS_DDR3_CS_N),
        .memory_mem_ras_n                      ( HPS_DDR3_RAS_N),
        .memory_mem_cas_n                      ( HPS_DDR3_CAS_N),
        .memory_mem_we_n                       ( HPS_DDR3_WE_N),
        .memory_mem_reset_n                    ( HPS_DDR3_RESET_N),
        .memory_mem_dq                         ( HPS_DDR3_DQ),
        .memory_mem_dqs                        ( HPS_DDR3_DQS_P),
        .memory_mem_dqs_n                      ( HPS_DDR3_DQS_N),
        .memory_mem_odt                        ( HPS_DDR3_ODT),
        .memory_mem_dm                         ( HPS_DDR3_DM),
        .memory_oct_rzqin                      ( HPS_DDR3_RZQ),

        //HPS ethernet
        .hps_0_hps_io_hps_io_emac1_inst_TX_CLK ( HPS_ENET_GTX_CLK),
        .hps_0_hps_io_hps_io_emac1_inst_TXD0   ( HPS_ENET_TX_DATA[0] ),
        .hps_0_hps_io_hps_io_emac1_inst_TXD1   ( HPS_ENET_TX_DATA[1] ),
        .hps_0_hps_io_hps_io_emac1_inst_TXD2   ( HPS_ENET_TX_DATA[2] ),
        .hps_0_hps_io_hps_io_emac1_inst_TXD3   ( HPS_ENET_TX_DATA[3] ),
        .hps_0_hps_io_hps_io_emac1_inst_RXD0   ( HPS_ENET_RX_DATA[0] ),
        .hps_0_hps_io_hps_io_emac1_inst_MDIO   ( HPS_ENET_MDIO ),
        .hps_0_hps_io_hps_io_emac1_inst_MDC    ( HPS_ENET_MDC  ),
        .hps_0_hps_io_hps_io_emac1_inst_RX_CTL ( HPS_ENET_RX_DV),
        .hps_0_hps_io_hps_io_emac1_inst_TX_CTL ( HPS_ENET_TX_EN),
        .hps_0_hps_io_hps_io_emac1_inst_RX_CLK ( HPS_ENET_RX_CLK),
        .hps_0_hps_io_hps_io_emac1_inst_RXD1   ( HPS_ENET_RX_DATA[1] ),
        .hps_0_hps_io_hps_io_emac1_inst_RXD2   ( HPS_ENET_RX_DATA[2] ),
        .hps_0_hps_io_hps_io_emac1_inst_RXD3   ( HPS_ENET_RX_DATA[3] ),

        //HPS QSPI
        .hps_0_hps_io_hps_io_qspi_inst_IO0     ( HPS_FLASH_DATA[0]    ),
        .hps_0_hps_io_hps_io_qspi_inst_IO1     ( HPS_FLASH_DATA[1]    ),
        .hps_0_hps_io_hps_io_qspi_inst_IO2     ( HPS_FLASH_DATA[2]    ),
        .hps_0_hps_io_hps_io_qspi_inst_IO3     ( HPS_FLASH_DATA[3]    ),
        .hps_0_hps_io_hps_io_qspi_inst_SS0     ( HPS_FLASH_NCSO    ),
        .hps_0_hps_io_hps_io_qspi_inst_CLK     ( HPS_FLASH_DCLK    ),

        //HPS SD card
        .hps_0_hps_io_hps_io_sdio_inst_CMD     ( HPS_SD_CMD    ),
        .hps_0_hps_io_hps_io_sdio_inst_D0      ( HPS_SD_DATA[0]     ),
        .hps_0_hps_io_hps_io_sdio_inst_D1      ( HPS_SD_DATA[1]     ),
        .hps_0_hps_io_hps_io_sdio_inst_CLK     ( HPS_SD_CLK   ),
        .hps_0_hps_io_hps_io_sdio_inst_D2      ( HPS_SD_DATA[2]     ),
        .hps_0_hps_io_hps_io_sdio_inst_D3      ( HPS_SD_DATA[3]     ),

        //HPS USB
        .hps_0_hps_io_hps_io_usb1_inst_D0      ( HPS_USB_DATA[0]    ),
        .hps_0_hps_io_hps_io_usb1_inst_D1      ( HPS_USB_DATA[1]    ),
        .hps_0_hps_io_hps_io_usb1_inst_D2      ( HPS_USB_DATA[2]    ),
        .hps_0_hps_io_hps_io_usb1_inst_D3      ( HPS_USB_DATA[3]    ),
        .hps_0_hps_io_hps_io_usb1_inst_D4      ( HPS_USB_DATA[4]    ),
        .hps_0_hps_io_hps_io_usb1_inst_D5      ( HPS_USB_DATA[5]    ),
        .hps_0_hps_io_hps_io_usb1_inst_D6      ( HPS_USB_DATA[6]    ),
        .hps_0_hps_io_hps_io_usb1_inst_D7      ( HPS_USB_DATA[7]    ),
        .hps_0_hps_io_hps_io_usb1_inst_CLK     ( HPS_USB_CLKOUT    ),
        .hps_0_hps_io_hps_io_usb1_inst_STP     ( HPS_USB_STP    ),
        .hps_0_hps_io_hps_io_usb1_inst_DIR     ( HPS_USB_DIR    ),
        .hps_0_hps_io_hps_io_usb1_inst_NXT     ( HPS_USB_NXT    ),

        //HPS SPI0 -> LCM
        .hps_0_hps_io_hps_io_spim0_inst_CLK    ( HPS_LCM_SPIM_CLK),
        .hps_0_hps_io_hps_io_spim0_inst_MOSI   ( HPS_LCM_SPIM_MOSI),
        .hps_0_hps_io_hps_io_spim0_inst_MISO   ( HPS_LCM_SPIM_MISO),
        .hps_0_hps_io_hps_io_spim0_inst_SS0    ( HPS_LCM_SPIM_SS),

        //HPS SPI1
        .hps_0_hps_io_hps_io_spim1_inst_CLK    ( HPS_SPIM_CLK  ),
        .hps_0_hps_io_hps_io_spim1_inst_MOSI   ( HPS_SPIM_MOSI ),
        .hps_0_hps_io_hps_io_spim1_inst_MISO   ( HPS_SPIM_MISO ),
        .hps_0_hps_io_hps_io_spim1_inst_SS0    ( HPS_SPIM_SS ),

        //HPS UART
        .hps_0_hps_io_hps_io_uart0_inst_RX     ( HPS_UART_RX    ),
        .hps_0_hps_io_hps_io_uart0_inst_TX     ( HPS_UART_TX    ),

        //HPS I2C1
        .hps_0_hps_io_hps_io_i2c0_inst_SDA     ( HPS_I2C1_SDAT    ),
        .hps_0_hps_io_hps_io_i2c0_inst_SCL     ( HPS_I2C1_SCLK    ),

        //HPS I2C2
        .hps_0_hps_io_hps_io_i2c1_inst_SDA     ( HPS_I2C2_SDAT    ),
        .hps_0_hps_io_hps_io_i2c1_inst_SCL     ( HPS_I2C2_SCLK    ),

        //HPS GPIO
        .hps_0_hps_io_hps_io_gpio_inst_GPIO09  ( HPS_CONV_USB_N),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO35  ( HPS_ENET_INT_N),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO37  ( HPS_LCM_BK ),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO40  ( HPS_LTC_GPIO ),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO41  ( HPS_LCM_D_C ),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO44  ( HPS_LCM_RST_N  ),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO48  ( HPS_I2C_CONTROL),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO53  ( HPS_LED),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO54  ( HPS_KEY),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO61  ( HPS_GSENSOR_INT),

        .led_pio_external_connection_export    ( fpga_led_internal ),
        .dipsw_pio_external_connection_export  ( SW ),
        .button_pio_external_connection_export ( KEY ),

        .hps_0_h2f_reset_reset_n               ( hps_fpga_reset_n ),
        .hps_0_f2h_cold_reset_req_reset_n      ( ~hps_cold_reset ),
        .hps_0_f2h_debug_reset_req_reset_n     ( ~hps_debug_reset ),
        .hps_0_f2h_stm_hw_events_stm_hwevents  ( stm_hw_events ),
        .hps_0_f2h_warm_reset_req_reset_n      ( ~hps_warm_reset )
    );

endmodule
