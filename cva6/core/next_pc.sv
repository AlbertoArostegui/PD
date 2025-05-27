module next_pc
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    input clk_i,
    input rst_ni,
    input npc_rst_load_i,
    input [CVA6Cfg.VLEN-1:0] boot_addr_i,

// NPC selection logic
    input bp_valid_i,
    input if_ready_i,
    input replay_i,
    input mispredict_i,
    input eret_i,
    input ex_valid_i,
    input set_pc_commit_i,
    input set_debug_pc_i,
    input halt_i,

    input [CVA6Cfg.VLEN-1:0] predict_address_i,
    input [CVA6Cfg.VLEN-1:0] replay_addr_i,
    input [CVA6Cfg.VLEN-1:0] eret_pc_i,
    input [CVA6cfg.VLEN-1:0] trap_vector_base_i,
    input [CVA6cfg.VLEN-1:0] target_address_mispredict_i,
    input [CVA6Cfg.VLEN-1:0] pc_commit_i,

    //input [CVA6Cfg.VLEN-1:0] pc_commit0_i,
    //input [CVA6Cfg.VLEN-1:0] pc_commit1_i,

    output [CVA6Cfg.VLEN-1:0] pc_o
);

    logic pc_write_en;
    logic [CVA6Cfg.VLEN-1:0] pc_d, pc_q;
    logic [CVA6Cfg.VLEN-1:0] fetch_address;

    assign pc_o = fetch_address;
  // Next PC
  // -------------------
  // next PC (NPC) can come from (in order of precedence):
  // 0. Default assignment/replay instruction
  // 1. Branch Predict taken
  // 2. Control flow change request (misprediction)
  // 3. Return from environment call
  // 4. Exception/Interrupt
  // 5. Pipeline Flush because of CSR side effects
  // Mis-predict handling is a little bit different
  // select PC a.k.a PC Gen
  //
  // TODO: Next PC control logic (i. e. the signals that points out if there has been
  // a branch, exception, ret and so on) must be associated with a thread id
    always_comb begin : npc
        pc_write_en = 1'b0;
        pc_d = pc_q;


        if (npc_rst_load) begin
          fetch_address = boot_addr_i;
          pc_d = boot_addr_i;
        end else begin
          fetch_address = pc_q;
          pc_d = pc_q;
        end

        if (bp_valid_i) begin
            pc_write_en = 1'b1;
            fetch_address = predict_address_i;
        end else if (if_ready_i) begin
            pc_write_en = 1'b1;
            pc_d = {
              fetch_address[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1, {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
            };
        end else if (replay_i) begin
            pc_write_en = 1'b1;
            pc_d = replay_addr_i;
        end else if (mispredict_i) begin
            pc_write_en = 1'b1;
            pc_d = target_address_mispredict_i;
        end else if (eret_i) begin
            pc_write_en = 1'b1;
            pc_d = eret_pc_i;
        end else if (ex_valid_i) begin
            pc_write_en = 1'b1;
            pc_d = trap_vector_base_i;
        end else if (set_pc_commit_i) begin
            pc_write_en = 1'b1;
            pc_d = pc_commit_i + (halt_i ? '0 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100});
        end else if (set_debug_pc_i) begin
            pc_write_en = 1'b1;
            pc_d = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0] + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0];
        end

    end : npc

    always_ff @(posedge clk_i) begin
        if (rst_ni)
            pc_q <= boot_addr_i;
        else if (pc_write_en)
            pc_q <= pc_d;
    end

endmodule : next_pc
