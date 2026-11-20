// Kogge-Stone replacement for the $lcu cell (used to approximate a timing-driven adder structure)
(* techmap_celltype = "$lcu" *)
module _80_lcu_kogge_stone (P, G, CI, CO);
	parameter WIDTH = 2;
	(* force_downto *) input [WIDTH-1:0] P, G;
	input CI;
	(* force_downto *) output [WIDTH-1:0] CO;
	integer i, j;
	(* force_downto *) reg [WIDTH-1:0] p, g, p2, g2;
	wire [1023:0] _TECHMAP_DO_ = "proc; opt -fast";
	always @* begin
		p = P; g = G;
		g[0] = g[0] | (p[0] & CI);
		for (i = 1; i < WIDTH; i = i * 2) begin
			p2 = p; g2 = g;
			for (j = i; j < WIDTH; j = j + 1) begin
				g2[j] = g[j] | (p[j] & g[j - i]);
				p2[j] = p[j] & p[j - i];
			end
			p = p2; g = g2;
		end
	end
	assign CO = g;
endmodule
