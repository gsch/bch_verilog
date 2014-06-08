`timescale 1ns / 1ps

/* parallel inversionless */
module bch_key_bma_parallel #(
	parameter M = 4,
	parameter T = 3		/* Correctable errors */
) (
	input clk,
	input start,
	input [2*T*M-1:M] syndromes,
	input accepted,

	output reg done = 0,
	output busy,
	output reg [M*(T+1)-1:0] sigma = 0,
	output reg [log2(T+1)-1:0] err_count = 0
);
	`include "bch.vh"

	localparam TCQ = 1;

	reg [M-1:0] d_r = 0;	/* In !shuffle cycle d_r is d_p */
	wire [M-1:0] d_r_next;
	reg [M-1:0] d_p = 0;
	wire [M*(T+1)-1:0] d_r_terms;
	reg [M*(T+1)-1:0] d_r_beta;
	reg [M*(T+1)-1:0] beta = 0;
	wire [M-1:0] syn1 = syndromes[M+:M];
	wire [M*(T+1)-1:0] product;
	reg [M*(T+1)-1:0] in2;
	reg syn_shuffle = 0;
	reg busy_internal = 0;
	reg waiting = 0;
	wire bsel;
	reg [log2(T+1)-1:0] l = 0;
	assign bsel = |d_r && bch_n >= err_count;

	/* beta(1)(x) = syn1 ? x^2 : x^3 */
	wire [M*4-1:0] beta0;
	assign beta0 = {{M-1{1'b0}}, !syn1, {M-1{1'b0}}, |syn1, {2*M{1'b0}}};

	/* d_r(0) = 1 + S_1 * x */
	wire [M*2-1:0] sigma0;
	assign sigma0 = {syn1, {M-1{1'b0}}, 1'b1};

	wire [log2(T)-1:0] bch_n;
	counter #(T) u_bch_n_counter(
		.clk(clk),
		.reset(start),
		.ce(!syn_shuffle),
		.count(bch_n)
	);

	wire [M*(2*T-1)-1:0] syn_shuffled;
	bch_syndrome_shuffle #(M, T) u_bch_syndrome_shuffle(
		.clk(clk),
		.start(start),
		.ce(syn_shuffle),
		.synN(syndromes),
		.syn_shuffled(syn_shuffled)
	);

	assign busy = busy_internal || (waiting && !accepted);

	always @(posedge clk) begin

		if (start) begin
			busy_internal <= #TCQ 1;
			syn_shuffle <= #TCQ 0;
		end else if (busy_internal && !done)
			syn_shuffle <= #TCQ ~syn_shuffle;
		else begin
			busy_internal <= #TCQ 0;
			syn_shuffle <= #TCQ 0;
		end

		if (busy_internal && syn_shuffle && bch_n == T-1)
			waiting <= #TCQ 1;
		else if (accepted)
			waiting <= #TCQ 0;

		done <= #TCQ busy_internal && syn_shuffle && bch_n == T-1;
			
		if (start) begin
			d_r <= #TCQ syn1 ? syn1 : 1;
			d_p <= #TCQ syn1 ? syn1 : 1;
			in2 <= #TCQ sigma0;
			sigma <= #TCQ sigma0;
			beta <= #TCQ beta0;
			err_count <= #TCQ {{log2(T+1)-1{1'b0}}, |syn1};
		end else if (busy_internal && !syn_shuffle) begin
			d_r <= #TCQ d_r_next;
			d_r_beta <= #TCQ product;
			in2 <= #TCQ beta;
		end else if (busy_internal) begin
			/* d_p = bsel ? d_r : d_p */
			if (bsel) begin
				d_p <= #TCQ d_r;
				err_count <= #TCQ 2 * bch_n - err_count + 1;
			end else
				d_r <= #TCQ d_p;

			/* sigma^(r)(x) = d_p * sigma^(r-1)(x) - d_r * beta^(r)(x) */
			sigma <= #TCQ d_r_beta ^ product;
			in2 <= #TCQ d_r_beta ^ product;

			/* b^(r+1)(x) = x^2 * (bsel ? sigmal^(r-1)(x) : b_(r)(x)) */
			beta[2*M+:M*(T-1)] <= #TCQ bsel ? sigma[0*M+:M*(T-1)] : beta[0*M+:M*(T-1)];
		end
	end

	/* d_r * beta^(r)(x), d_p * sigma^(r-1)(x) */
	parallel_standard_multiplier #(M, T+1) u_d_p_sigma(
		.standard_in1(d_r),
		.standard_in2(in2),
		.standard_out(product)
	);

	/* d_r_terms = {sigma_i^(r) * S_(2 * r - i + 1)}[0..t] */
	/* Only used for syn_shuffle cycle */
	parallel_standard_multiplier #(M) u_d_r_terms [T:0] (
		.standard_in1(sigma),
		.standard_in2(syn_shuffled[0+:(T+1)*M]),
		.standard_out(d_r_terms)
	);

	/* d_r = summation of dr_terms */
	finite_parallel_adder #(M, T+1) u_generate_cs(d_r_terms, d_r_next);

endmodule
