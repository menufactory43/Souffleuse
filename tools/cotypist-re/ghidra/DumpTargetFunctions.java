// Exports decompiled functions containing addresses passed on the command line.
// @category Cotypist

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.symbol.Reference;

public class DumpTargetFunctions extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) {
            throw new IllegalArgumentException(
                "Usage: DumpTargetFunctions.java <output> <address> [address ...]"
            );
        }

        File output = new File(args[0]);
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);

        try (PrintWriter writer = new PrintWriter(new FileWriter(output))) {
            writer.println("Program: " + currentProgram.getName());
            writer.println("Image base: " + currentProgram.getImageBase());

            for (int index = 1; index < args.length; index++) {
                Address target = toAddr(args[index]);
                Function function = getFunctionContaining(target);

                writer.println();
                writer.println("============================================================");
                writer.println("Target: " + target);

                if (function == null) {
                    disassemble(target);
                    function = createFunction(target, "target_" + target);
                }

                if (function == null) {
                    writer.println("Could not create a function at this address.");
                    dumpInstructions(writer, target);
                    continue;
                }

                writer.println("Function: " + function.getName());
                writer.println("Entry: " + function.getEntryPoint());
                writer.println("Body: " + function.getBody());
                dumpReferences(writer, function);

                DecompileResults results = decompiler.decompileFunction(function, 120, monitor);
                if (!results.decompileCompleted()) {
                    writer.println("Decompiler error: " + results.getErrorMessage());
                    continue;
                }

                writer.println();
                writer.println(results.getDecompiledFunction().getC());
            }
        } finally {
            decompiler.dispose();
        }

        println("Wrote " + output.getAbsolutePath());
    }

    private void dumpReferences(PrintWriter writer, Function function) {
        writer.println("Outgoing calls:");
        Instruction instruction =
            currentProgram.getListing().getInstructionAt(function.getEntryPoint());
        while (instruction != null && function.getBody().contains(instruction.getAddress())) {
            for (Reference reference : instruction.getReferencesFrom()) {
                if (reference.getReferenceType().isCall()) {
                    writer.println("  " + instruction.getAddress() + " -> " + reference);
                }
            }
            instruction = instruction.getNext();
        }
    }

    private void dumpInstructions(PrintWriter writer, Address target) throws Exception {
        Address start = target.subtract(32);
        Address end = target.add(64);
        disassemble(start);
        writer.println("Nearby instructions:");
        Instruction instruction = getInstructionAt(start);
        if (instruction == null) {
            instruction = getInstructionAfter(start);
        }
        while (instruction != null && instruction.getAddress().compareTo(end) <= 0) {
            writer.println("  " + instruction.getAddress() + "  " + instruction);
            instruction = instruction.getNext();
        }
    }
}
