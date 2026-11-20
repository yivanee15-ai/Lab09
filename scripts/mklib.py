#!/usr/bin/env python3
"""Write a small Nangate45-like liberty file (areas in um^2, delays in ns) for abc timing-driven mapping.
Numbers are approximate; they are only used to compare design versions against each other."""
import sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
from cells import cells
out = []
out.append('library (toy45) {\n  delay_model : table_lookup;\n  time_unit : "1ns";\n  voltage_unit : "1V";\n  current_unit : "1mA";\n  capacitive_load_unit (1,pf);\n  pulling_resistance_unit : "1kohm";\n  leakage_power_unit : "1nW";\n  nom_voltage : 1.1; nom_temperature : 25; nom_process : 1;\n')
out.append('  lu_table_template (tmpl) {\n    variable_1 : input_net_transition;\n    variable_2 : total_output_net_capacitance;\n    index_1 ("0.01, 0.4");\n    index_2 ("0.001, 0.05");\n  }\n')
def table(d0, k):
    v = lambda s, c: d0 + 0.15 * s + k * c
    rows = ['"%.4f, %.4f"' % (v(0.01, 0.001), v(0.01, 0.05)), '"%.4f, %.4f"' % (v(0.4, 0.001), v(0.4, 0.05))]
    return "values (" + ", ".join(rows) + ");"
for name, (area, fn, ins, d0, k) in cells.items():
    out.append('  cell (%s) {\n    area : %.3f;\n' % (name, area))
    for p in ins:
        out.append('    pin (%s) { direction : input; capacitance : 0.0017; }\n' % p)
    out.append('    pin (Y) {\n      direction : output;\n      function : "%s";\n      max_capacitance : 0.2;\n' % fn)
    for p in ins:
        out.append('      timing () {\n        related_pin : "%s";\n        timing_sense : non_unate;\n' % p)
        for kind in ("cell_rise", "cell_fall", "rise_transition", "fall_transition"):
            d = d0 if "cell" in kind else d0 * 0.8
            out.append('        %s (tmpl) { %s }\n' % (kind, table(d, k)))
        out.append('      }\n')
    out.append('    }\n  }\n')
# flip-flops
def dff(name, area, rst):
    s = '  cell (%s) {\n    area : %.3f;\n    ff (IQ, IQN) { clocked_on : "CK"; next_state : "D";%s }\n' % (name, area, ' clear : "!RN";' if rst else '')
    s += '    pin (D) { direction : input; capacitance : 0.0017; timing () { related_pin : "CK"; timing_type : setup_rising; rise_constraint (scalar) { values ("0.03"); } fall_constraint (scalar) { values ("0.03"); } } }\n'
    s += '    pin (CK) { direction : input; clock : true; capacitance : 0.0017; }\n'
    if rst:
        s += '    pin (RN) { direction : input; capacitance : 0.0017; }\n'
    s += '    pin (Q) { direction : output; function : "IQ"; timing () { related_pin : "CK"; timing_type : rising_edge; cell_rise (tmpl) { %s } cell_fall (tmpl) { %s } rise_transition (tmpl) { %s } fall_transition (tmpl) { %s } } }\n  }\n' % (table(0.08, 3.0), table(0.08, 3.0), table(0.03, 3.0), table(0.03, 3.0))
    return s
out.append(dff("DFF_X1", 4.522, False))
out.append(dff("DFFR_X1", 5.320, True))
out.append("}\n")
open(sys.argv[1], "w").write("".join(out))
