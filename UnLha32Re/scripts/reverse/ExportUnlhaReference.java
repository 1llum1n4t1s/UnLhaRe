// 原版 DLL の解析結果をローカルの比較資料として書き出す。製品のソースには取り込まない。
// @category UnLhaRe
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Symbol;
import java.io.BufferedWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.LinkedHashSet;
import java.util.Set;

public class ExportUnlhaReference extends GhidraScript {
    private BufferedWriter create(Path path) throws Exception {
        return Files.newBufferedWriter(path, StandardCharsets.UTF_8, StandardOpenOption.CREATE_NEW);
    }

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) throw new IllegalArgumentException("出力ディレクトリと任意の解析アドレスを指定してください。");
        if (!"126f81c57d54c1ca6bbcdd524c647af635cdb408401a5bc21216b4a0a792dc5c".equalsIgnoreCase(currentProgram.getExecutableSHA256()))
            throw new IllegalArgumentException("確認済みの原版 DLL ではありません。");
        Path output = Path.of(args[0]).toAbsolutePath().normalize();
        Files.createDirectories(output);
        if (Files.exists(output.resolve("functions.tsv"))) throw new IllegalArgumentException("既存の解析結果は上書きしません。");
        Set<Address> selected = new LinkedHashSet<>();
        for (int argument = 1; argument < args.length; argument++) {
            if (!args[argument].matches("[0-9a-fA-F]{8}")) throw new IllegalArgumentException("8 桁の仮想アドレスを指定してください。");
            Address address = toAddr(Long.parseUnsignedLong(args[argument], 16));
            Function function = getFunctionAt(address);
            if (function == null) {
                if (getFunctionContaining(address) != null) throw new IllegalArgumentException("既存の関数境界と重複します: " + address);
                if (getInstructionAt(address) == null && !disassemble(address)) throw new IllegalArgumentException("命令を解析できません: " + address);
                function = createFunction(address, "FUN_" + address);
                if (function == null) throw new IllegalArgumentException("関数入口を作成できません: " + address);
            }
            selected.add(address);
        }
        int completed = 0;
        int failed = 0;
        DecompInterface decompiler = new DecompInterface();
        try (BufferedWriter index = create(output.resolve("functions.tsv"));
             BufferedWriter exports = create(output.resolve("exports.tsv"))) {
            if (!decompiler.openProgram(currentProgram)) {
                throw new IllegalStateException(decompiler.getLastMessage());
            }
            exports.write("address\tname\n");
            AddressIterator entries = currentProgram.getSymbolTable().getExternalEntryPointIterator();
            while (entries.hasNext()) {
                Address address = entries.next();
                for (Symbol symbol : currentProgram.getSymbolTable().getSymbols(address)) {
                    exports.write(address + "\t" + symbol.getName() + "\n");
                }
            }
            index.write("address\tname\tstatus\tfile\n");
            FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
            while (functions.hasNext()) {
                monitor.checkCancelled();
                Function function = functions.next();
                if (function.isExternal()) continue;
                if (!selected.isEmpty() && !selected.contains(function.getEntryPoint())) continue;
                String name = function.getName();
                String filename = function.getEntryPoint() + "_" + name.replaceAll("[^A-Za-z0-9_.-]", "_") + ".c";
                DecompileResults result = decompiler.decompileFunction(function, 60, monitor);
                boolean success = result.decompileCompleted() && result.getDecompiledFunction() != null;
                try (BufferedWriter file = create(output.resolve(filename))) {
                    file.write("/* 原版 DLL の機械生成解析資料。元ソースの復元結果でも、ビルド可能な実装でもない。 */\n");
                    file.write("/* address=" + function.getEntryPoint() + ", name=" + name + " */\n");
                    if (success) {
                        file.write(result.getDecompiledFunction().getC());
                        completed++;
                    } else {
                        file.write("/* DECOMPILATION FAILED: " + result.getErrorMessage().replace("*/", "* /") + " */\n");
                        failed++;
                    }
                }
                index.write(function.getEntryPoint() + "\t" + name + "\t" + (success ? "completed" : "failed") + "\t" + filename + "\n");
                if ((completed + failed) % 100 == 0) println("Decompiled " + completed + ", failed " + failed);
            }
        } finally {
            decompiler.dispose();
        }
        try (BufferedWriter summary = create(output.resolve("analysis.txt"))) {
            summary.write("program=" + currentProgram.getName() + "\n");
            summary.write("sha256=" + currentProgram.getExecutableSHA256() + "\n");
            summary.write("language=" + currentProgram.getLanguageID() + "\n");
            summary.write("compiler=" + currentProgram.getCompilerSpec().getCompilerSpecID() + "\n");
            summary.write("selection=" + (selected.isEmpty() ? "all" : selected.size()) + "\n");
            summary.write("completed=" + completed + "\nfailed=" + failed + "\n");
        }
        println("REFERENCE_EXPORT_COMPLETE completed=" + completed + " failed=" + failed);
    }
}
