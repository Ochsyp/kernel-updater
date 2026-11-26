# -------------------------------------------------------
# kernel-updater GRUB config linter
#
# Reads the GRUB config named by ENVIRON KU_LINT_CFG and prints LINE, SEVERITY, RULE and
# MESSAGE, tab-separated, per finding. KU_LINT_CMDS and KU_LINT_MODS list the name files, one
# path per line; KU_LINT_FLOOR is the oldest GRUB to support. KU_LINT_SAME_UUID, when set, is
# a UUID without dashes that a filesystem and its LUKS container share. Messages never quote
# identifiers.
# -------------------------------------------------------

BEGIN {
    cfg = ENVIRON["KU_LINT_CFG"]
    exact = (ENVIRON["KU_LINT_EXACT"] == "1")
    same_uuid = nodash(ENVIRON["KU_LINT_SAME_UUID"])
    load_lists(ENVIRON["KU_LINT_CMDS"], known_cmd)
    load_lists(ENVIRON["KU_LINT_MODS"], known_mod)
    # Built into GRUB's kernel, so command.lst does not list them.
    known_cmd["set"] = known_cmd["unset"] = known_cmd["insmod"] = 1
    # Loaded by common configs for platforms whose module lists are not bundled.
    known_mod["efi_gop"] = known_mod["efi_uga"] = known_mod["ieee1275_fb"] = 1
    split("if then else elif while until do !", words, " ")
    for (i in words) keyword[words[i]] = 1
    split(ENVIRON["KU_LINT_FLOOR"], version, ".")
    floor = version[1] * 100 + version[2]
    # The bundled lists are GRUB 2.02's; for a newer floor a name missing from them may still
    # exist, so only exact lists from --grub-dir or the 2.02 floor make it an error.
    unknown_severity = (exact || floor <= 202) ? "error" : "warning"
    read_config()
    # Pass 1 collects the functions the file defines, which menu entries may call before the
    # definition; pass 2 runs the checks.
    for (pass = 1; pass <= 2; pass++) {
        depth = 0; luks = ""; marked = 0; last_cmd = ""
        for (i = 1; i <= n; i++) {
            if (pass == 2) markers(text[i], start[i])
            scan(text[i], start[i])
        }
    }
    exit 0
}

# Read the config into text[1..n] as logical lines, start[] holding each one's first line
# number. A line that ends in an unquoted backslash continues on the next line, and so does
# a quoted string left open; GRUB reads both as one statement.
function read_config(    raw, line, state, cont, phys, first) {
    n = 0; cont = 0; phys = 0
    while ((getline raw < cfg) > 0) {
        phys++
        sub(/\r$/, "", raw)
        if (!cont) { first = phys; line = raw } else line = line raw
        state = end_state(line)
        if (state == "\\") { line = substr(line, 1, length(line) - 1); cont = 1; continue }
        if (state != "") { line = line " "; cont = 1; continue }
        text[++n] = line; start[n] = first; cont = 0
    }
    close(cfg)
    if (cont) { text[++n] = line; start[n] = first }
}

# Return how the line S ends: the open quote character inside a quoted string, "\" before a
# continued line, or "" when the statement ends. A comment ends the scan.
function end_state(s,    i, len, c, q, inword) {
    len = length(s); q = ""; inword = 0
    for (i = 1; i <= len; i++) {
        c = substr(s, i, 1)
        if (q == "'") { if (c == "'") q = ""; continue }
        if (q == "\"") {
            if (c == "\\") i++
            else if (c == "\"") q = ""
            continue
        }
        if (c == "'" || c == "\"") { q = c; inword = 1; continue }
        if (c == "\\") {
            if (i == len) return "\\"
            i++; inword = 1
            continue
        }
        if (c == " " || c == "\t" || c == ";" || c == "{" || c == "}") { inword = 0; continue }
        if (c == "#" && !inword) return ""
        inword = 1
    }
    return q
}

# Add the names in each file listed in PATHS (one path per line) to the set NAMES. Reads plain
# lists (one name per line, # comments) and GRUB's command.lst ("*name: module") and
# moddep.lst ("name: deps") alike.
function load_lists(paths, names,    files, m, i, l) {
    m = split(paths, files, "\n")
    for (i = 1; i <= m; i++) {
        if (files[i] == "") continue
        while ((getline l < files[i]) > 0) {
            sub(/\r$/, "", l)
            if (l ~ /^[ \t]*(#|$)/) continue
            sub(/^\*/, "", l)
            sub(/:.*$/, "", l)
            gsub(/[ \t]/, "", l)
            if (l != "") names[l] = 1
        }
        close(files[i])
    }
}

# Split the logical line S into statements and pass each to statement() as W[1..nw]. Handles
# '...' and "..." quoting, backslash escapes outside single quotes, ${...} expansions, ";"
# separators and "#" comments that start a word. "{" ends a statement and "}" is one.
function scan(s, ln,    i, len, c, q, word, inword, nw, j) {
    len = length(s); nw = 0; word = ""; inword = 0; q = ""
    for (i = 1; i <= len; i++) {
        c = substr(s, i, 1)
        if (q == "'") {
            if (c == "'") q = ""; else word = word c
            continue
        }
        if (q == "\"") {
            if (c == "\\" && i < len) { i++; word = word substr(s, i, 1) }
            else if (c == "\"") q = ""
            else word = word c
            continue
        }
        if (c == "'" || c == "\"") { q = c; inword = 1; continue }
        if (c == "\\" && i < len) { i++; word = word substr(s, i, 1); inword = 1; continue }
        if (c == "$" && substr(s, i + 1, 1) == "{") {
            j = index(substr(s, i), "}")
            if (j == 0) j = len - i + 1
            word = word substr(s, i, j); inword = 1; i += j - 1
            continue
        }
        if (c == " " || c == "\t" || c == ";" || c == "{" || c == "}") {
            if (inword) { W[++nw] = word; word = ""; inword = 0 }
            if (c == "{") {
                W[++nw] = c; statement(nw, ln); nw = 0
            } else if (c == "}") {
                if (nw) statement(nw, ln)
                W[1] = c; statement(1, ln); nw = 0
            } else if (c == ";") {
                if (nw) statement(nw, ln)
                nw = 0
            }
            continue
        }
        if (c == "#" && !inword) break
        word = word c; inword = 1
    }
    if (inword) W[++nw] = word
    if (nw) statement(nw, ln)
}

# Check one statement: track blocks and defined functions, check the command word, and check
# the arguments of the commands that take identifiers or kernel parameters.
function statement(nw, ln,    k, cmd, j, first, assign, form, fs, val) {
    for (k = 1; k <= nw && (W[k] in keyword); k++) ;
    if (k > nw) return
    cmd = W[k]
    if (cmd == "}") {
        if (depth > 0) {
            if (block[depth] == "menuentry") luks = ""
            depth--
        }
        return
    }
    # A "{" on a line of its own opens the block of the statement before it.
    if (cmd == "{") {
        block[++depth] = last_cmd
        if (last_cmd == "menuentry") luks = ""
        return
    }
    last_cmd = cmd
    if (W[nw] == "{") {
        block[++depth] = cmd
        if (cmd == "menuentry") luks = ""
    }
    if (cmd == "function") {
        if (pass == 1 && k < nw) defined[W[k + 1]] = 1
        return
    }
    if (pass == 1) return
    if (cmd == "fi" || cmd == "done" || cmd == "for" || cmd ~ /^\$/) return
    assign = (cmd ~ /^[A-Za-z_][A-Za-z0-9_]*=/)
    if (!assign && !(cmd in known_cmd) && !(cmd in defined))
        report(ln, unknown_severity, "unknown-command", "unknown command " shown(cmd))
    first = assign ? k : k + 1
    if (cmd != "menuentry" && cmd != "submenu" && cmd != "echo") {
        for (j = first; j <= nw; j++) {
            if (W[j] ~ /\(hd[0-9]/) {
                report(ln, "warning", "hard-coded-drive", "names a drive as (hdN,...), whose number changes with the machine and the boot path; find the partition by UUID instead")
                break
            }
        }
    }
    for (j = first; j <= nw; j++)
        if (index(W[j], "cryptouuid/")) check_cryptouuid(W[j], W[j - 1], ln)
    if (assign) return
    if (cmd == "insmod") {
        for (j = k + 1; j <= nw; j++)
            if (!(W[j] in known_mod) && W[j] !~ /^\$/)
                report(ln, unknown_severity, "unknown-module", "unknown module " shown(W[j]))
    } else if (cmd == "cryptomount") {
        if (marked && !marked_reported) {
            report(marked, "warning", "mbusb-marker", "an encrypted entry lies between MultiBootUSB's #start and #end markers, which its uninstaller deletes")
            marked_reported = 1
        }
        for (j = k + 1; j < nw; j++) {
            if (W[j] != "-u" || variable(W[j + 1])) continue
            form = luks_form(W[j + 1])
            if (form == "bad")
                report(ln, "error", "cryptomount-uuid", "cryptomount -u is not given a LUKS UUID (32 hex digits)")
            else if (form == "dashed" && floor < 212)
                report(ln, "error", "cryptomount-uuid", "cryptomount -u is given a UUID with dashes, which GRUB older than 2.12 never matches")
            luks = nodash(W[j + 1])
        }
    } else if (cmd == "search" || cmd == "search.fs_uuid") {
        fs = (cmd == "search.fs_uuid")
        val = fs ? W[k + 1] : W[nw]
        for (j = k + 1; j <= nw; j++)
            if (W[j] == "--fs-uuid" || W[j] == "-u") fs = 1
        if (fs && nw > k && val !~ /^-/ && !variable(val)) {
            if (!fs_uuid_form(val))
                report(ln, "error", "fs-uuid-malformed", "search --fs-uuid is not given a filesystem UUID or volume serial")
            else if (luks != "" && nodash(val) == luks && luks != same_uuid)
                report(ln, "warning", "fs-uuid-is-luks", "search --fs-uuid is given the LUKS container's UUID, which matches only when the filesystem inside has the same UUID; set boot_fs_uuid and boot_luks_uuid if it has")
        }
    } else if (cmd == "linux" || cmd == "linux16") {
        for (j = k + 2; j <= nw; j++) check_param(W[j], ln)
    }
}

# Check the cryptouuid/ device name in the word W; PREV is the word before it. GRUB skips a
# search hint it cannot match, so that is a warning; anywhere else the device is not found.
function check_cryptouuid(w, prev, ln,    v, form, severity) {
    v = substr(w, index(w, "cryptouuid/") + 11)
    sub(/[),].*$/, "", v)
    if (variable(v)) return
    severity = (w ~ /^--hint/ || prev == "--hint" || prev == "-h") ? "warning" : "error"
    form = luks_form(v)
    if (form == "bad")
        report(ln, severity, "cryptouuid-malformed", "cryptouuid/ device name is not a LUKS UUID (32 hex digits)")
    else if (form == "dashed" && floor < 212)
        report(ln, severity, "cryptouuid-dashes", "cryptouuid/ device name has dashes, which GRUB older than 2.12 never matches")
}

# Report kernel parameters that have no effect on an installed Debian or Kali system.
function check_param(w, ln,    key, m, opts, i, o) {
    key = w
    sub(/=.*$/, "", key)
    if (key == "cryptdevice") {
        report(ln, "warning", "arch-param", "cryptdevice= is mkinitcpio (Arch) syntax; Debian's initramfs ignores it and unlocks from the crypttab in the initrd")
    } else if (w == "noswap") {
        report(ln, "warning", "live-boot-param", "noswap does nothing on an installed system; systemd.swap=0 keeps swap off")
    } else if (key == "overlayroot" && substr(w, 13, 6) == "tmpfs:") {
        m = split(substr(w, 19), opts, ",")
        for (i = 1; i <= m; i++) {
            o = opts[i]
            sub(/=.*$/, "", o)
            if (o != "recurse" && o != "swap")
                report(ln, "warning", "overlayroot-option", "overlayroot ignores the unknown option " shown(o) "; tmpfs takes recurse and swap")
        }
    }
}

# Track MultiBootUSB's "#start NAME" and "#end NAME" markers. Its uninstaller deletes what lies
# between them, so the first encrypted entry inside a marked block is reported at the marker.
function markers(s, ln) {
    if (s ~ /^[ \t]*#start[ \t]/) { marked = ln; marked_reported = 0 }
    else if (s ~ /^[ \t]*#end[ \t]/) marked = 0
}

# Return W quoted when it has the shape of a command, module or option name, and a neutral
# phrase otherwise, so a stray identifier from the file never reaches the output.
function shown(w,    t) {
    t = w
    if (w ~ /^[A-Za-z_][A-Za-z0-9_.-]*$/ && length(w) <= 32 && gsub(/-/, "", t) <= 1 &&
        !(length(w) >= 8 && w ~ /^[0-9A-Fa-f.-]+$/))
        return "'" w "'"
    return "(a word that looks like data)"
}

# Return 1 when V holds a GRUB variable, whose value lint cannot know.
function variable(v) {
    return v ~ /^\$/ || index(v, "${") > 0
}

# Classify V as a LUKS UUID: "dashless" (32 hex digits), "dashed" (8-4-4-4-12) or "bad".
function luks_form(v,    p) {
    v = tolower(v)
    if (hexlen(v, 32)) return "dashless"
    if (split(v, p, "-") == 5 && hexlen(p[1], 8) && hexlen(p[2], 4) && hexlen(p[3], 4) && hexlen(p[4], 4) && hexlen(p[5], 12))
        return "dashed"
    return "bad"
}

# Return 1 when the shape of V is one search --fs-uuid can match: a dashed UUID, a 16-digit
# NTFS serial, an XXXX-XXXX FAT serial or an ISO9660 date (YYYY-MM-DD-HH-MM-SS-CC).
function fs_uuid_form(v,    p, m) {
    if (luks_form(v) == "dashed" || hexlen(v, 16)) return 1
    m = split(v, p, "-")
    if (m == 2) return hexlen(p[1], 4) && hexlen(p[2], 4)
    return m == 7 && digits(p[1], 4) && digits(p[2], 2) && digits(p[3], 2) && digits(p[4], 2) && digits(p[5], 2) && digits(p[6], 2) && digits(p[7], 2)
}

# Return 1 when S consists of exactly N hex digits.
function hexlen(s, n) {
    return length(s) == n && s ~ /^[0-9a-fA-F]+$/
}

# Return 1 when S consists of exactly N decimal digits.
function digits(s, n) {
    return length(s) == n && s ~ /^[0-9]+$/
}

# Return V in lower case without dashes, so UUIDs written either way compare equal.
function nodash(v) {
    v = tolower(v)
    gsub(/-/, "", v)
    return v
}

# Print one finding.
function report(ln, severity, rule, message) {
    printf "%d\t%s\t%s\t%s\n", ln, severity, rule, message
}
