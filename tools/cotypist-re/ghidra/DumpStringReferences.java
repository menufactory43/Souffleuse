// Traces incoming references from string/metadata addresses and decompiles callers.
// @category Cotypist

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.Set;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;

public class DumpStringReferences extends GhidraScript {
    private static final int MAX_REFERENCE_DEPTH = 4;

    private record PendingAddress(Address address, int depth) {}

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) {
            throw new IllegalArgumentException(
                "Usage: DumpStringReferences.java <output> <address> [address ...]"
            );
        }

        Set<Function> functions = new LinkedHashSet<>();
        File output = new File(args[0]);

        try (PrintWriter writer = new PrintWriter(new FileWriter(output))) {
            writer.println("Program: " + currentProgram.getName());
            writer.println("Image base: " + currentProgram.getImageBase());

            for (int index = 1; index < args.length; index++) {
                Address root = toAddr(args[index]);
                writer.println();
                writer.println("============================================================");
                writer.println("Reference root: " + root);
                traceReferences(writer, root, functions);
            }

            writer.println();
            writer.println("============================================================");
            writer.println("Referenced functions: " + functions.size());
            decompileFunctions(writer, functions);
        }

        println("Wrote " + output.getAbsolutePath());
    }

    private void traceReferences(
        PrintWriter writer,
        Address root,
        Set<Function> functions
    ) {
        ArrayDeque<PendingAddress> queue = new ArrayDeque<>();
        Set<Address> visited = new HashSet<>();
        queue.add(new PendingAddress(root, 0));

        while (!queue.isEmpty()) {
            PendingAddress pending = queue.removeFirst();
            if (!visited.add(pending.address())) {
                continue;
            }

            ReferenceIterator references =
                currentProgram.getReferenceManager().getReferencesTo(pending.address());
            writer.println(
                "depth=" + pending.depth()
                    + " target=" + pending.address()
            );

            for (Reference reference : references) {
                Address source = reference.getFromAddress();
                Function function = getFunctionContaining(source);
                writer.println(
                    "  " + source
                        + " " + reference.getReferenceType()
                        + (function == null ? "" : " function=" + function.getName())
                );

                if (function != null) {
                    functions.add(function);
                } else if (pending.depth() < MAX_REFERENCE_DEPTH) {
                    queue.addLast(new PendingAddress(source, pending.depth() + 1));
                }
            }
        }
    }

    private void decompileFunctions(PrintWriter writer, Set<Function> functions) {
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);

        try {
            for (Function function : functions) {
                writer.println();
                writer.println("------------------------------------------------------------");
                writer.println("Function: " + function.getName());
                writer.println("Entry: " + function.getEntryPoint());
                writer.println("Body: " + function.getBody());

                DecompileResults results =
                    decompiler.decompileFunction(function, 180, monitor);
                if (!results.decompileCompleted()) {
                    writer.println("Decompiler error: " + results.getErrorMessage());
                    continue;
                }
                writer.println(results.getDecompiledFunction().getC());
            }
        } finally {
            decompiler.dispose();
        }
    }
}
