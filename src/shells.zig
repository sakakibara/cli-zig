//! Shell completion scripts: for each supported shell, the function and
//! registration that wires a program's hidden `__complete` command into that
//! shell's tab-completion system.
const std = @import("std");
const testing = std.testing;

/// A shell `emit` can generate a completion script for.
pub const Shell = enum { bash, zsh, fish, powershell };

/// Looks up `name` (e.g. `"zsh"`) as a `Shell`. Null when unrecognized.
pub fn parse(name: []const u8) ?Shell {
    return std.meta.stringToEnum(Shell, name);
}

/// Writes the completion script for `shell`, with `prog_name` substituted
/// for the invoked program and its generated function/registration names.
pub fn emit(w: *std.Io.Writer, shell: Shell, prog_name: []const u8) !void {
    switch (shell) {
        .bash => try emitBash(w, prog_name),
        .zsh => try emitZsh(w, prog_name),
        .fish => try emitFish(w, prog_name),
        .powershell => try emitPowershell(w, prog_name),
    }
}

/// `<prog> __complete` prints a directive line then one candidate per line
/// as `value<TAB>description`; the generated script reads the directive,
/// then strips the description at the tab for the values it feeds back to
/// the shell.
///
/// `COMP_WORDBREAKS` includes `=` by default, so bash splits a glued
/// `--flag=value` into separate `COMP_WORDS` entries around a bare `=`;
/// the loop below rejoins them into one word before calling `__complete`.
/// Only a `=` immediately following a flag-shaped word (leading `-`) is
/// rejoined this way, so a standalone `=` argument (not itself part of a
/// `--flag=value`) is left as its own word.
fn emitBash(w: *std.Io.Writer, prog: []const u8) !void {
    try w.writeAll("_");
    try w.writeAll(prog);
    try w.writeAll("_complete() {\n");
    try w.writeAll(
        \\    local cur="${COMP_WORDS[COMP_CWORD]}"
        \\    local -a words=()
        \\    local i=1
        \\    while ((i <= COMP_CWORD)); do
        \\        if [[ "${COMP_WORDS[i]}" == "=" && ${#words[@]} -gt 0 && "${words[${#words[@]} - 1]}" == -* ]]; then
        \\            local nxt=""
        \\            if ((i + 1 <= COMP_CWORD)); then
        \\                nxt="${COMP_WORDS[i + 1]}"
        \\                i=$((i + 1))
        \\            fi
        \\            words[${#words[@]} - 1]="${words[${#words[@]} - 1]}=${nxt}"
        \\        else
        \\            words+=("${COMP_WORDS[i]}")
        \\        fi
        \\        i=$((i + 1))
        \\    done
        \\    local IFS=$'\n'
        \\    local reply=($(
    );
    try w.writeAll(prog);
    try w.writeAll(" __complete \"${words[@]}\"))\n");
    try w.writeAll(
        \\    local directive="${reply[0]}"
        \\    reply=("${reply[@]:1}")
        \\    if [ "$directive" = "files" ]; then
        \\        COMPREPLY=($(compgen -f -- "$cur")); return
        \\    fi
        \\    [ "$directive" = "nospace" ] && compopt -o nospace 2>/dev/null
        \\    COMPREPLY=()
        \\    local line val
        \\    for line in "${reply[@]}"; do
        \\        val="${line%%$'\t'*}"
        \\        COMPREPLY+=("$(printf '%q' "$val")")
        \\    done
        \\}
    );
    try w.writeAll("\n");
    try w.writeAll("complete -F _");
    try w.writeAll(prog);
    try w.writeAll("_complete ");
    try w.writeAll(prog);
    try w.writeAll("\n");
}

/// zsh drops empty elements when an array expands unquoted; every array
/// expansion here uses the `(@)` flag with quoting so an empty cursor word
/// or an empty candidate value survives instead of vanishing.
fn emitZsh(w: *std.Io.Writer, prog: []const u8) !void {
    try w.writeAll("_");
    try w.writeAll(prog);
    try w.writeAll("_complete() {\n");
    try w.writeAll(
        \\    local -a lines values descs
        \\    lines=("${(@f)$(
    );
    try w.writeAll(prog);
    try w.writeAll(" __complete \"${(@)words[2,$CURRENT]}\")}\")\n");
    try w.writeAll(
        \\    local directive=$lines[1]
        \\    lines=("${(@)lines[2,-1]}")
        \\    local line
        \\    for line in "${(@)lines}"; do
        \\        values+=("${line%%$'\t'*}")
        \\        if [[ $line == *$'\t'* ]]; then descs+=("${line#*$'\t'}"); else descs+=("${line%%$'\t'*}"); fi
        \\    done
        \\    if [[ $directive == files ]]; then
        \\        _files
        \\    elif [[ $directive == nospace ]]; then
        \\        compadd -S '' -d descs -- "${values[@]}"
        \\    else
        \\        compadd -d descs -- "${values[@]}"
        \\    fi
        \\}
    );
    try w.writeAll("\n");
    try w.writeAll("compdef _");
    try w.writeAll(prog);
    try w.writeAll("_complete ");
    try w.writeAll(prog);
    try w.writeAll("\n");
}

/// The full `__complete` reply (directive line plus candidate lines) is
/// captured so the directive can be acted on instead of discarded: `files`
/// completes real filesystem paths via `__fish_complete_path` (candidates
/// from `__complete` are empty for that directive); `default` and `nospace`
/// both emit the candidate lines as-is (`value<TAB>description`, which
/// fish's own `-a` handling splits on the tab). Fish omits the trailing
/// space after a candidate ending in `/` (or a few other punctuation
/// chars), so a `nospace` directive is honored under fish for candidates of
/// that shape; fish offers no general per-candidate no-trailing-space
/// control for other shapes. The `-f` on the `complete` registration
/// disables fish's own file-completion fallback, since candidates come
/// entirely from `__complete`.
///
/// In a completion context fish supplies the current token via
/// `commandline -ct` as a single (possibly empty) element, so the cursor
/// word always reaches `__complete` even at a fresh, unstarted argument.
fn emitFish(w: *std.Io.Writer, prog: []const u8) !void {
    try w.writeAll("function __");
    try w.writeAll(prog);
    try w.writeAll("_complete\n");
    try w.writeAll(
        \\    set -l prior (commandline -opc)
        \\    set -l cur (commandline -ct)
        \\    set -l reply (
    );
    try w.writeAll(prog);
    try w.writeAll(" __complete $prior[2..-1] $cur)\n");
    try w.writeAll(
        \\    set -l directive $reply[1]
        \\    if test "$directive" = files
        \\        __fish_complete_path (commandline -ct)
        \\        return
        \\    end
        \\    if test (count $reply) -gt 1
        \\        for line in $reply[2..-1]
        \\            echo $line
        \\        end
        \\    end
        \\end
        \\
    );
    try w.writeAll("complete -c ");
    try w.writeAll(prog);
    try w.writeAll(" -f -a '(__");
    try w.writeAll(prog);
    try w.writeAll("_complete)'\n");
}

/// `$commandAst.CommandElements` already includes the partial word under
/// the cursor once it has been typed (though not when the cursor sits
/// after a trailing space, since there is nothing yet to tokenize there);
/// `$prior` strips that trailing element so it isn't also sent via
/// `$wordToComplete`. Slicing is avoided for 0 or 1 elements (a
/// negative-range slice on those wraps to the last element instead of
/// yielding an empty result). The `if`/`else` is wrapped in the outer
/// `@(...)`, not just around the slice: a script block's result stream
/// unrolls a single-element array down to its lone element, so without
/// the outer wrap a two-token `$tokens` would collapse `$prior` to a
/// bare string, and `@prior` would then splat it character-by-character
/// instead of as one word.
fn emitPowershell(w: *std.Io.Writer, prog: []const u8) !void {
    try w.writeAll("Register-ArgumentCompleter -Native -CommandName ");
    try w.writeAll(prog);
    try w.writeAll(
        \\ -ScriptBlock {
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\    $tokens = @($commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { "$_" })
        \\    $prior = $tokens
        \\    if ($wordToComplete -ne '' -and $tokens.Count -gt 0) {
        \\        $prior = @(if ($tokens.Count -gt 1) { $tokens[0..($tokens.Count - 2)] } else { @() })
        \\    }
        \\    &
    );
    try w.writeAll(" ");
    try w.writeAll(prog);
    try w.writeAll(" __complete @prior $wordToComplete | Select-Object -Skip 1 | ForEach-Object {\n");
    try w.writeAll(
        \\        $parts = $_ -split "`t", 2
        \\        $val = $parts[0]
        \\        $desc = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
        \\        [System.Management.Automation.CompletionResult]::new($val, $val, 'ParameterValue', $desc)
        \\    }
        \\}
        \\
    );
}

fn emitToString(alloc: std.mem.Allocator, shell: Shell, prog: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try emit(&aw.writer, shell, prog);
    return aw.written();
}

test "parse: recognizes every supported shell name, rejects anything else" {
    try testing.expectEqual(Shell.bash, parse("bash").?);
    try testing.expectEqual(Shell.zsh, parse("zsh").?);
    try testing.expectEqual(Shell.fish, parse("fish").?);
    try testing.expectEqual(Shell.powershell, parse("powershell").?);
    try testing.expect(parse("csh") == null);
    try testing.expect(parse("") == null);
}

test "emit: bash wires __complete and registers the completion function" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .bash, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "myapp __complete") != null);
    try testing.expect(std.mem.indexOf(u8, s, "complete -F _myapp_complete myapp") != null);
}

test "emit: zsh wires __complete and registers via compdef" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .zsh, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "myapp __complete") != null);
    try testing.expect(std.mem.indexOf(u8, s, "compdef _myapp_complete myapp") != null);
}

test "emit: fish wires __complete and registers via complete -c" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .fish, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "myapp __complete") != null);
    try testing.expect(std.mem.indexOf(u8, s, "complete -c myapp") != null);
}

test "emit: powershell wires __complete and registers via Register-ArgumentCompleter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .powershell, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "myapp __complete") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Register-ArgumentCompleter") != null);
    try testing.expect(std.mem.indexOf(u8, s, "-CommandName myapp") != null);
}

test "emit: no shell's script contains the literal holt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    inline for (.{ Shell.bash, Shell.zsh, Shell.fish, Shell.powershell }) |sh| {
        const s = try emitToString(alloc, sh, "myapp");
        try testing.expect(std.mem.indexOf(u8, s, "holt") == null);
    }
}

test "emit: no shell's script carries holt's app-specific navigation layer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    inline for (.{ Shell.bash, Shell.zsh, Shell.fish, Shell.powershell }) |sh| {
        const s = try emitToString(alloc, sh, "myapp");
        try testing.expect(std.mem.indexOf(u8, s, "fzf") == null);
        try testing.expect(std.mem.indexOf(u8, s, "holt path") == null);
        try testing.expect(std.mem.indexOf(u8, s, "function hi") == null);
        try testing.expect(std.mem.indexOf(u8, s, "hir") == null);
    }
}

test "emit: bash falls back to file completion on the files directive and strips the description at the tab" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .bash, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "\"files\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "compgen -f") != null);
    try testing.expect(std.mem.indexOf(u8, s, "%%$'\\t'") != null);
    try testing.expect(std.mem.indexOf(u8, s, "printf '%q'") != null);
}

test "emit: zsh dispatches on the directive for files, nospace, and default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .zsh, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "== files") != null);
    try testing.expect(std.mem.indexOf(u8, s, "_files") != null);
    try testing.expect(std.mem.indexOf(u8, s, "== nospace") != null);
    try testing.expect(std.mem.indexOf(u8, s, "compadd -S ''") != null);
}

test "emit: bash reassembles a COMP_WORDBREAKS-split --flag=value into one word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .bash, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "\"${COMP_WORDS[i]}\" == \"=\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "__complete \"${words[@]}\"") != null);
}

test "emit: bash only merges a bare = into a flag-shaped preceding word, leaving a standalone = its own argument" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .bash, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "\"${words[${#words[@]} - 1]}\" == -*") != null);
}

test "emit: zsh quotes the cursor-word window and candidate values to preserve empty elements" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .zsh, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "\"${(@)words[2,$CURRENT]}\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "compadd -S '' -d descs -- \"${values[@]}\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "compadd -d descs -- \"${values[@]}\"") != null);
}

test "emit: fish captures the prior words and cursor word into variables before splicing them in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .fish, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "set -l prior (commandline -opc)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "set -l cur (commandline -ct)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "$prior[2..-1] $cur") != null);
}

test "emit: fish reads the directive instead of discarding it, and completes real paths on files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .fish, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "tail -n +2") == null);
    try testing.expect(std.mem.indexOf(u8, s, "set -l reply (") != null);
    try testing.expect(std.mem.indexOf(u8, s, "set -l directive $reply[1]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "__fish_complete_path (commandline -ct)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "for line in $reply[2..-1]") != null);
}

test "emit: powershell drops the cursor token from tokens before appending wordToComplete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .powershell, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "$prior = $tokens") != null);
    try testing.expect(std.mem.indexOf(u8, s, "@(if ($tokens.Count -gt 1)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "__complete @prior $wordToComplete") != null);
}

test "emit: powershell splits value and description on the tab" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try emitToString(arena_state.allocator(), .powershell, "myapp");
    try testing.expect(std.mem.indexOf(u8, s, "-split \"`t\", 2") != null);
    try testing.expect(std.mem.indexOf(u8, s, "'ParameterValue', $desc") != null);
}
