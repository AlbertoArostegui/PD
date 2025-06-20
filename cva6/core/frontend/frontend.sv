// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 08.02.2018
// Description: Ariane Instruction Fetch Frontend
//
// This module interfaces with the instruction cache, handles control

// change request from the back-end and does branch prediction.

module frontend
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type fetch_entry_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Next PC when reset - SUBSYSTEM
    input logic [CVA6Cfg.NUM_THREADS-1:0][CVA6Cfg.VLEN-1:0] boot_addr_i, //dup
    // Flush branch prediction - zero
    input logic flush_bp_i,
    // Flush requested by FENCE, mis-predict and exception - CONTROLLER
    input logic flush_i, // dup
    input logic [CVA6Cfg.NUM_THREADS_LOG-1:0] flush_thread_id_i,
    // Halt requested by WFI and Accelerate port - CONTROLLER
    input logic [CVA6Cfg.NUM_THREADS-1:0] halt_i, //dup
    // Set COMMIT PC as next PC requested by FENCE, CSR side-effect and Accelerate port - CONTROLLER
    input logic [CVA6Cfg.NUM_THREADS-1:0] set_pc_commit_i, //dup
    // COMMIT PC - COMMIT
    input logic [CVA6Cfg.NUM_THREADS-1:0][CVA6Cfg.VLEN-1:0] pc_commit_i, //dup
    // Exception event - COMMIT
    input logic ex_valid_i,
    // Mispredict event and next PC - EXECUTE
    input bp_resolve_t resolved_branch_i,
    // Return from exception event - CSR
    input logic eret_i,
    // Next PC when returning from exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] epc_i,
    // Next PC when jumping into exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] trap_vector_base_i,
    // Debug event - CSR
    input logic [CVA6Cfg.NUM_THREADS-1:0] set_debug_pc_i, // dup
    // Debug mode state - CSR
    input logic debug_mode_i,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    output icache_dreq_t icache_dreq_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    input icache_drsp_t icache_dreq_i,
    // Handshake's data between fetch and decode - ID_STAGE
    output fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid between fetch and decode - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready between fetch and decode - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i,

    input logic boot_hart1_i,

    input logic [CVA6Cfg.VLEN-1:0] boot_addr_hart1_i,

    //Thread logic
    input logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.NUM_THREADS_LOG-1:0] commit_thread_id_i
);

  localparam type bht_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;     // update at PC
    logic                    taken;
  };

  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type btb_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;              // update at PC
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type ras_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] ra;
  };

  // Instruction Cache Registers, from I$
  logic                            [    CVA6Cfg.FETCH_WIDTH-1:0] icache_data_q;
  logic                                                          icache_valid_q;
  ariane_pkg::frontend_exception_t                               icache_ex_valid_q;
  logic                            [           CVA6Cfg.VLEN-1:0] icache_vaddr_q;
  logic                            [          CVA6Cfg.GPLEN-1:0] icache_gpaddr_q;
  logic                            [                       31:0] icache_tinst_q;
  logic                                                          icache_gva_q;
  logic                                                          instr_queue_ready;
  logic                            [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_queue_consumed;
  // upper-most branch-prediction from last cycle
  btb_prediction_t                                               btb_q;
  bht_prediction_t                                               bht_q;
  // instruction fetch is ready
  logic                                                          if_ready;

  // indicates whether we come out of reset (then we need to load boot_addr_i)
  logic                                       npc_rst_load_q;

  logic                                       replay;
  logic [                   CVA6Cfg.VLEN-1:0] replay_addr;

  // shift amount
  logic [$clog2(CVA6Cfg.INSTR_PER_FETCH)-1:0] shamt;
  // address will always be 16 bit aligned, make this explicit here
  if (CVA6Cfg.RVC) begin : gen_shamt
    assign shamt = icache_dreq_i.vaddr[$clog2(CVA6Cfg.INSTR_PER_FETCH):1];
  end else begin
    assign shamt = 1'b0;
  end

  // -----------------------
  // Ctrl Flow Speculation
  // -----------------------
  // RVI ctrl flow prediction
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvi_return, rvi_call, rvi_branch, rvi_jalr, rvi_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvi_imm;
  // RVC branching
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvc_branch, rvc_jump, rvc_jr, rvc_return, rvc_jalr, rvc_call;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvc_imm;
  // re-aligned instruction and address (coming from cache - combinationally)
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][            31:0] instr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0]                   instruction_valid;
  // BHT, BTB and RAS prediction
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction;
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction_shifted;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction_shifted;
  ras_t                                                            ras_predict;
  ras_t            [    CVA6Cfg.NUM_THREADS-1:0]                   ras_predict_all;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_btb;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_bht;

  // branch-predict update
  logic                                                            is_mispredict;
  logic ras_push, ras_pop;
  logic [           CVA6Cfg.VLEN-1:0] ras_update;

  // Instruction FIFO
  logic [           CVA6Cfg.VLEN-1:0] predict_address;
  cf_t  [CVA6Cfg.INSTR_PER_FETCH-1:0] cf_type;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvi_cf;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvc_cf;

  logic                               serving_unaligned;
  // Re-align instructions
  instr_realign #(
      .CVA6Cfg(CVA6Cfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (icache_dreq_o.kill_s2),
      .valid_i            (icache_valid_q),
      .serving_unaligned_o(serving_unaligned),
      .address_i          (icache_vaddr_q),
      .data_i             (icache_data_q),
      .valid_o            (instruction_valid),
      .addr_o             (addr),
      .instr_o            (instr)
  );
  // --------------------
  // Branch Prediction
  // --------------------
  // select the right branch prediction result
  // in case we are serving an unaligned instruction in instr[0] we need to take
  // the prediction we saved from the previous fetch
  if (CVA6Cfg.RVC) begin : gen_btb_prediction_shifted
    assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][$clog2(
        CVA6Cfg.INSTR_PER_FETCH
    ):1]];
    assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][$clog2(
        CVA6Cfg.INSTR_PER_FETCH
    ):1]];

    // for all other predictions we can use the generated address to index
    // into the branch prediction data structures
    for (genvar i = 1; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_prediction_address
      assign bht_prediction_shifted[i] = bht_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
      assign btb_prediction_shifted[i] = btb_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
    end
  end else begin
    assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][1]];
    assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][1]];
  end
  ;

  // for the return address stack it doens't matter as we have the
  // address of the call/return already
  logic bp_valid;

  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_branch;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_call;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_return;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jalr;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i]);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i]);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr[i] = instruction_valid[i] & ~is_return[i] & (rvi_jalr[i] | rvc_jalr[i] | rvc_jr[i]);
  end

  // taken/not taken
  always_comb begin
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;

    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) cf_type[i] = ariane_pkg::NoCF;

    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;

    // lower most prediction gets precedence
    for (int i = CVA6Cfg.INSTR_PER_FETCH - 1; i >= 0; i--) begin
      unique case ({
        is_branch[i], is_return[i], is_jump[i], is_jalr[i]
      })
        4'b0000: ;  // regular instruction e.g.: no branch
        // unconditional jump to register, we need the BTB to resolve this
        4'b0001: begin
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          if (CVA6Cfg.BTBEntries != 0 && btb_prediction_shifted[i].valid) begin
            predict_address = btb_prediction_shifted[i].target_address;
            cf_type[i] = ariane_pkg::JumpR;
          end
        end
        // its an unconditional jump to an immediate
        4'b0010: begin
          ras_pop = 1'b0;
          ras_push = 1'b0;
          taken_rvi_cf[i] = rvi_jump[i];
          taken_rvc_cf[i] = rvc_jump[i];
          cf_type[i] = ariane_pkg::Jump;
        end
        // return
        4'b0100: begin
          // make sure to only alter the RAS if we actually consumed the instruction
          ras_pop = ras_predict.valid & instr_queue_consumed[i];
          ras_push = 1'b0;
          predict_address = ras_predict_all[current_thread_q].ra;
          cf_type[i] = ariane_pkg::Return;
        end
        // branch prediction
        4'b1000: begin
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          // if we have a valid dynamic prediction use it
          if (bht_prediction_shifted[i].valid) begin
            taken_rvi_cf[i] = rvi_branch[i] & bht_prediction_shifted[i].taken;
            taken_rvc_cf[i] = rvc_branch[i] & bht_prediction_shifted[i].taken;
            // otherwise default to static prediction
          end else begin
            // set if immediate is negative - static prediction
            taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
            taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
          end
          if (taken_rvi_cf[i] || taken_rvc_cf[i]) begin
            cf_type[i] = ariane_pkg::Branch;
          end
        end
        default: ;
        // default: $error("Decoded more than one control flow");
      endcase
      // if this instruction, in addition, is a call, save the resulting address
      // but only if we actually consumed the address
      if (is_call[i]) begin
        ras_push   = instr_queue_consumed[i];
        ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
      end
      // calculate the jump target address
      if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
        predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
      end
    end
  end
  // or reduce struct
  always_comb begin
    bp_valid = 1'b0;
    // BP cannot be valid if we have a return instruction and the RAS is not giving a valid address
    // Check that we encountered a control flow and that for a return the RAS
    // contains a valid prediction.
    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++)
    bp_valid |= ((cf_type[i] != NoCF & cf_type[i] != Return) | ((cf_type[i] == Return) & ras_predict.valid));
  end
  assign is_mispredict = resolved_branch_i.valid & resolved_branch_i.is_mispredict;



  // Cache interface
  assign icache_dreq_o.req = instr_queue_ready /*&& !icache_stall_pending_q*/;
  assign if_ready = icache_dreq_i.ready & instr_queue_ready;
  // We need to flush the cache pipeline if:
  // 1. We mispredicted
  // 2. Want to flush the whole processor front-end
  // 3. Need to replay an instruction because the fetch-fifo was full
  assign icache_dreq_o.kill_s1 = is_mispredict | flush_i | replay;
  // if we have a valid branch-prediction we need to only kill the last cache request
  // also if we killed the first stage we also need to kill the second stage (inclusive flush)
  assign icache_dreq_o.kill_s2 = icache_dreq_o.kill_s1 | bp_valid;
  assign icache_dreq_o.thread_id = current_thread_q;

  // Update Control Flow Predictions
  bht_update_t bht_update;
  btb_update_t btb_update;

  // assert on branch, deassert when resolved
  logic speculative_q, speculative_d;
  assign speculative_d = (speculative_q && !resolved_branch_i.valid || |is_branch || |is_return || |is_jalr) && !flush_i;
  assign icache_dreq_o.spec = speculative_d;

  assign bht_update.valid = resolved_branch_i.valid
                                & (resolved_branch_i.cf_type == ariane_pkg::Branch);
  assign bht_update.pc = resolved_branch_i.pc;
  assign bht_update.taken = resolved_branch_i.is_taken;
  // only update mispredicted branches e.g. no returns from the RAS
  assign btb_update.valid = resolved_branch_i.valid
                                & resolved_branch_i.is_mispredict
                                & (resolved_branch_i.cf_type == ariane_pkg::JumpR);
  assign btb_update.pc = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // THREADING
  // thread scheduling
  logic [CVA6Cfg.VLEN-1:0] thread_pc;
  logic [CVA6Cfg.NUM_THREADS_LOG-1:0] current_thread_id_d, current_thread_id_q;
  logic [CVA6Cfg.NUM_THREADS-1:0] thread_ready;

  logic found_ready_comb;
  logic [CVA6Cfg.NUM_THREADS_LOG-1:0] candidate_thread_id_comb;

  // thread stalling on icache miss
  // Track single outstanding icache miss
  logic icache_stall_pending_d, icache_stall_pending_q;
  logic [CVA6Cfg.NUM_THREADS_LOG-1:0] stalled_thread_id_d, stalled_thread_id_q;

  // drive thread_context status updates
  logic status_update_req_comb;
  logic status_update_thread_id_comb;
  thread_status_t status_update_val_comb;

    // Alberto: thread selection logic
    thread_status_t [CVA6Cfg.NUM_THREADS-1:0] thread_statuses; // Logic only for 2 threads
    logic [CVA6Cfg.NUM_THREADS_LOG-1:0] current_thread_d, current_thread_q;

    always_comb begin : thread_selection
      current_thread_d = current_thread_q;
      /*if (thread_statuses[!current_thread_q] == READY &&
          !replay)*/
      if (fetch_entry_valid_o && boot_hart1_i)
        current_thread_d = !current_thread_q;

    end

    /*Rigth now we only change on icache miss
    * We should look into stalling o dcache load miss*/
    always_comb begin : thread_status_update_logic
      logic cache_accepting_req;
      logic current_thread_is_ready;

      status_update_req_comb = 1'b0;
      status_update_thread_id_comb = 'x;
      status_update_val_comb = READY;

      icache_stall_pending_d = icache_stall_pending_q;
      stalled_thread_id_d = stalled_thread_id_q;

      cache_accepting_req = icache_dreq_i.ready; // Hit in the cache (I assume) based on fetch addr
      current_thread_is_ready = thread_statuses[current_thread_q] == READY;

      if (instr_queue_ready && !cache_accepting_req &&
          current_thread_is_ready && !icache_stall_pending_q) begin
          status_update_req_comb = 1'b1;
          status_update_thread_id_comb = current_thread_q;
          stalled_thread_id_d = current_thread_q;
          status_update_val_comb = STALLED_ICACHE;
          icache_stall_pending_d = 1'b1;
      end

      if (icache_stall_pending_q && icache_dreq_i.ready) begin
        if (thread_statuses[stalled_thread_id_q] == STALLED_ICACHE) begin
          if (icache_dreq_i.ex.valid)
            status_update_req_comb = 1'b0;
          else begin
            status_update_req_comb = 1'b1;
            status_update_val_comb = READY;
            status_update_thread_id_comb = stalled_thread_id_q;
          end
        end
        icache_stall_pending_d = 1'b0;
      end
      if (flush_i)
        icache_stall_pending_d = 1'b0;

    end : thread_status_update_logic


    // Alberto: MUX the thread IDs and the commit ports
    logic [CVA6Cfg.NUM_THREADS-1:0][CVA6Cfg.VLEN-1:0] fetch_addresses;
    logic [CVA6Cfg.VLEN-1:0] fetch_address = fetch_addresses[current_thread_q];
    logic [CVA6Cfg.NUM_THREADS_LOG-1:0] popped_thread_id;
    assign icache_dreq_o.vaddr = fetch_address;

    logic booted_hart1_q, booted_hart1_d;
    assign booted_hart1_d = boot_addr_hart1_i;

    generate
        for (genvar i = 0; i < CVA6Cfg.NUM_THREADS; i++) begin : gen_next_pc
            next_pc #(
            .CVA6Cfg(CVA6Cfg)
            ) i_next_pc_thread (
                .clk_i,
                .rst_ni,
                .npc_rst_load_i(i ? boot_hart1_i & ~booted_hart1_q : npc_rst_load_q), // hart1 boot if boot_addr_hart_1, hart0 from standard npc_rst 
                .boot_addr_i(boot_hart1_i & i ? boot_addr_hart1_i : boot_addr_i), // if boot_hart_1 is set, we boot from that addr.
                // From this thread
                .bp_valid_i(bp_valid & (current_thread_q == i)),
                .if_ready_i(if_ready & (current_thread_q == i)),
                .replay_i(replay & (current_thread_q == i)),
                .mispredict_i(is_mispredict & (resolved_branch_i.thread_id == i)),
                // From commit
                .eret_i(eret_i & (commit_thread_id_i[0] == i)),
                .ex_valid_i(ex_valid_i & (commit_thread_id_i[0] == i)),
                .set_pc_commit_i(set_pc_commit_i & (commit_thread_id_i[0] == i)),
                .set_debug_pc_i(set_debug_pc_i[i]),
                .halt_i(halt_i),

                .predict_address_i(predict_address),
                .replay_addr_i(replay_addr),
                .eret_pc_i(epc_i),
                .trap_vector_base_i,
                .target_address_mispredict_i(resolved_branch_i.target_address),
                .pc_commit_i(pc_commit_i[i]),

                .pc_o(fetch_addresses[i])
            );
        end : gen_next_pc
    endgenerate


  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data;
  // re-align the cache line
  assign icache_data = icache_dreq_i.data >> {shamt, 4'b0};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      speculative_q     <= '0;
      icache_data_q     <= '0;
      icache_valid_q    <= 1'b0;
      icache_vaddr_q    <= 'b0;
      icache_gpaddr_q   <= 'b0;
      icache_tinst_q    <= 'b0;
      icache_gva_q      <= 1'b0;
      icache_ex_valid_q <= ariane_pkg::FE_NONE;
      btb_q             <= '0;
      bht_q             <= '0;
      current_thread_id_q  <= '0;
      icache_stall_pending_q <= '0;
      stalled_thread_id_q <= '0;
      current_thread_q <= 0;
        booted_hart1_q <= 0;
      for (int i = 0; i < CVA6Cfg.NUM_THREADS-1; i++)
        thread_statuses[i] <= READY;

    end else begin
      current_thread_q <= current_thread_d;
      //current_thread_q <= 0;
      speculative_q  <= speculative_d;
      icache_valid_q <= icache_dreq_i.valid;
      thread_statuses[status_update_thread_id_comb] <= status_update_val_comb;
        booted_hart1_q <= booted_hart1_d;

      current_thread_id_q <= current_thread_id_d;
      icache_stall_pending_q <= icache_stall_pending_d;
      stalled_thread_id_q <= stalled_thread_id_d;

      if (icache_dreq_i.valid) begin
        icache_data_q  <= icache_data;
        icache_vaddr_q <= icache_dreq_i.vaddr;
        if (CVA6Cfg.RVH) begin
          icache_gpaddr_q <= icache_dreq_i.ex.tval2[CVA6Cfg.GPLEN-1:0];
          icache_tinst_q  <= icache_dreq_i.ex.tinst;
          icache_gva_q    <= icache_dreq_i.ex.gva;
        end else begin
          icache_gpaddr_q <= 'b0;
          icache_tinst_q  <= 'b0;
          icache_gva_q    <= 1'b0;
        end

        // Map the only three exceptions which can occur in the frontend to a two bit enum
        if (CVA6Cfg.MmuPresent && icache_dreq_i.ex.cause == riscv::INSTR_GUEST_PAGE_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT;
        end else if (CVA6Cfg.MmuPresent && icache_dreq_i.ex.cause == riscv::INSTR_PAGE_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_PAGE_FAULT;
        end else if (icache_dreq_i.ex.cause == riscv::INSTR_ACCESS_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_ACCESS_FAULT;
        end else begin
          icache_ex_valid_q <= ariane_pkg::FE_NONE;
        end
        // save the uppermost prediction
        btb_q <= btb_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
        bht_q <= bht_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
      end
    end
  end

  if (CVA6Cfg.RASDepth == 0) begin : gen_no_ras
    assign ras_predict = '0;
  end else begin : gen_ras_array
    for (genvar thread_id = 0; thread_id < CVA6Cfg.NUM_THREADS; thread_id++) begin : gen_ras_instance
      ras #(
          .CVA6Cfg(CVA6Cfg),
          .ras_t  (ras_t),
          .DEPTH  (CVA6Cfg.RASDepth)
      ) i_ras (
          .clk_i,
          .rst_ni,
          .flush_bp_i(flush_bp_i),
          .push_i(ras_push && (current_thread_q == thread_id)),
          .pop_i(ras_pop && (current_thread_q == thread_id)),
          .data_i(ras_update),
          .data_o(ras_predict_all[thread_id])
      );
    end : gen_ras_instance
  end : gen_ras_array

  if (CVA6Cfg.RASDepth > 0)
    assign ras_predict = ras_predict_all[current_thread_id_q];

  //For FPGA, BTB is implemented in read synchronous BRAM
  //while for ASIC, BTB is implemented in D flip-flop
  //and can be read at the same cycle.
  //Same for BHT
  assign vpc_btb = (CVA6Cfg.FpgaEn) ? icache_dreq_i.vaddr : icache_vaddr_q;
  assign vpc_bht = (CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid) ? icache_dreq_i.vaddr : icache_vaddr_q;

  if (CVA6Cfg.BTBEntries == 0) begin
    assign btb_prediction = '0;
  end else begin : btb_gen
    btb #(
        .CVA6Cfg   (CVA6Cfg),
        .btb_update_t(btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES(CVA6Cfg.BTBEntries)
    ) i_btb (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_btb),
        .btb_update_i    (btb_update),
        .btb_prediction_o(btb_prediction)
    );
  end

  if (CVA6Cfg.BHTEntries == 0) begin
    assign bht_prediction = '0;
  end else if (CVA6Cfg.BPType == config_pkg::BHT) begin : bht_gen
    bht #(
        .CVA6Cfg   (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES(CVA6Cfg.BHTEntries)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::PH_BHT) begin : bht2lvl_gen
    bht2lvl #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_i         (flush_bp_i),
        .vpc_i           (icache_vaddr_q),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end

  // we need to inspect up to CVA6Cfg.INSTR_PER_FETCH instructions for branches
  // and jumps
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_instr_scan
    instr_scan #(
        .CVA6Cfg(CVA6Cfg)
    ) i_instr_scan (
        .instr_i     (instr[i]),
        .rvi_return_o(rvi_return[i]),
        .rvi_call_o  (rvi_call[i]),
        .rvi_branch_o(rvi_branch[i]),
        .rvi_jalr_o  (rvi_jalr[i]),
        .rvi_jump_o  (rvi_jump[i]),
        .rvi_imm_o   (rvi_imm[i]),
        .rvc_branch_o(rvc_branch[i]),
        .rvc_jump_o  (rvc_jump[i]),
        .rvc_jr_o    (rvc_jr[i]),
        .rvc_return_o(rvc_return[i]),
        .rvc_jalr_o  (rvc_jalr[i]),
        .rvc_call_o  (rvc_call[i]),
        .rvc_imm_o   (rvc_imm[i])
    );
  end

  instr_queue #(
      .CVA6Cfg(CVA6Cfg),
      .fetch_entry_t(fetch_entry_t)
  ) i_instr_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .flush_thread_id_i  (flush_thread_id_i),
      .instr_i            (instr),                 // from re-aligner
      .addr_i             (addr),         // from re-aligner
      .fetch_address_i    (icache_vaddr_q),
      .exception_i        (icache_ex_valid_q),     // from I$
      .exception_addr_i   (icache_vaddr_q),
      .exception_gpaddr_i (icache_gpaddr_q),
      .exception_tinst_i  (icache_tinst_q),
      .exception_gva_i    (icache_gva_q),
      .predict_address_i  (predict_address),
      .cf_type_i          (cf_type),
      .thread_id_i        (icache_dreq_i.thread_id),
      .popped_thread_id_o (popped_thread_id),
      .valid_i            (instruction_valid),     // from re-aligner
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i)    // to back-end
  );

endmodule
