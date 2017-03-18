part of arm7_tdmi.src.arm.compiler;

/// Implements the 'Add' Instruction.
class _ArmInstruction$ADD extends Instruction {
  /// First operand of the instruction.
  final int op1;

  /// Second operand of the instruction.
  final int op2;

  /// Destination register.
  final int rd;

  /// Determines whether the instruction updates the CPSR.
  final bool s;

  const _ArmInstruction$ADD({
    @required ArmCondition condition,
    @required this.op1,
    @required this.op2,
    @required this.rd,
    @required this.s,
  })
      : super._(condition: condition, name: 'ADD');

  @override
  int execute(Cpu cpu) {
    if (condition.pass(cpu.cpsr)) {
      final r = op1.toUnsigned(32) + op2.toUnsigned(32);
      cpu.gprs[rd] = r.toUnsigned(32);
      if (s) {
        cpu.cpsr
          ..c = r > 0xFFFFFFFF
          ..v = (~(op1 ^ op2) & (op1 ^ r)) > 0x7FFFFFFF
          ..n = r > 0x7FFFFFFF
          ..z = r == 0;
      }
    }
    return 1;
  }
}
