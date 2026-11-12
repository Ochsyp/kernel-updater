# -------------------------------------------------------
# kernel-updater GRUB menu scanner
#
# Reads the GRUB config named by ENVIRON KU_MENU_CFG and prints, tab-separated, what migrate
# needs to move the Kali entries: each top-level submenu whose quoted title holds "Kali", with
# the lines it spans, the menu entries in it, and the kernel and parameters of each entry's
# first linux command. Braces count only outside quotes and comments. Run it with LC_ALL=C.
# -------------------------------------------------------

# The records, one per line, with every control character of a field turned into DEL, so that
# a field never holds a tab or a line break:
#   kali   N START END MARKED CLEAN RAWTITLE  the Nth Kali submenu: its first and last line,
#                                             1 when MultiBootUSB's #start or #end markers
#                                             lie around or in it, 1 when nothing but blanks
#                                             comes before "submenu" on its first line and
#                                             nothing but blanks or a comment after its closing
#                                             brace, and its title as written, quotes included
#   entry  N M LINE TITLE                     the Mth menu entry in it and its title
#   linux  N M LINE KERNEL                    the first linux command of that entry
#   param  N M WORD                           each word after the kernel, in order
#   error  unbalanced                         the braces or quotes do not balance
BEGIN {
    cfg = ENVIRON["KU_MENU_CFG"]
    del = sprintf("%c", 127)
    for (i = 1; i < 32; i++) ctl = ctl sprintf("%c", i)
    split("if then else elif while until do !", words, " ")
    for (i in words) keyword[words[i]] = 1
    depth = 0; q = ""; comment = 0; nw = 0; word = ""; wraw = ""; inword = 0
    kali = 0; inkali = 0; entry = 0; inentry = 0; inmark = 0; bad = 0
    ln = 0
    while ((getline raw < cfg) > 0) {
        ln++
        sub(/\r$/, "", raw)
        text[ln] = raw
        if (q == "" && !comment) markers(raw)
        scan(raw "\n")
    }
    close(cfg)
    if (q != "" || depth != 0 || bad) print "error\tunbalanced"
    exit 0
}

# Track MultiBootUSB's "#start NAME" and "#end NAME" markers, between which its uninstaller
# deletes or rewrites what it finds, and mark the Kali submenu open while one comes.
function markers(s) {
    if (s ~ /^[ \t]*#start([ \t]|$)/) {
        inmark = 1
        if (inkali) marked[inkali] = 1
    } else if (s ~ /^[ \t]*#end([ \t]|$)/) {
        if (inkali) marked[inkali] = 1
        inmark = 0
    }
}

# Scan S, one line and its line break, a character at a time: '...' and "..." quoting, which
# may run over several lines, backslash escapes outside single quotes, ${...} expansions,
# blanks between words, line breaks and ";" between statements, "#" comments that start a
# word, and "{" and "}", which open and close blocks.
function scan(s,    i, n, c, j) {
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (comment) {
            if (c == "\n") { comment = 0; endstmt() }
            continue
        }
        if (q == "'") {
            wraw = wraw c
            if (c == "'") q = ""; else word = word c
            continue
        }
        if (q == "\"") {
            wraw = wraw c
            if (c == "\\" && i < n) {
                i++; c = substr(s, i, 1); wraw = wraw c
                if (c != "\n") word = word c
            } else if (c == "\"") q = ""
            else word = word c
            continue
        }
        if (c == "'" || c == "\"") { q = c; wraw = wraw c; inword = 1; continue }
        if (c == "\\" && i < n) {
            i++; c = substr(s, i, 1)
            if (c != "\n") { word = word c; wraw = wraw "\\" c; inword = 1 }
            continue
        }
        if (c == "$" && substr(s, i + 1, 1) == "{") {
            j = index(substr(s, i), "}")
            if (j == 0) j = n - i
            word = word substr(s, i, j); wraw = wraw substr(s, i, j); inword = 1; i += j - 1
            continue
        }
        if (c == " " || c == "\t") { endword(); continue }
        if (c == "\n" || c == ";") { endword(); endstmt(); continue }
        if (c == "{") { endword(); openblock(); continue }
        if (c == "}") { endword(); endstmt(); closeblock(substr(s, i + 1)); continue }
        if (c == "#" && !inword) { comment = 1; continue }
        word = word c; wraw = wraw c; inword = 1
    }
}

# End the word being read, if any, as the next word of the statement: W[] holds its text,
# R[] its text as written and L[] the line it ends on.
function endword() {
    if (inword) {
        nw++
        W[nw] = word; R[nw] = wraw; L[nw] = ln
    }
    word = ""; wraw = ""; inword = 0
}

# End the statement in W[1..nw], keeping its command and title for a "{" on a line of its
# own, and report the first linux command of a menu entry in a Kali submenu.
function endstmt(    k, j, t) {
    if (nw == 0) return
    for (k = 1; k <= nw && (W[k] in keyword); k++) ;
    if (k <= nw) {
        lcmd = W[k]; lline = L[k]; t = titleat(k)
        ltitle = t ? W[t] : ""; lraw = t ? R[t] : ""
        if (inkali && inentry && !seen && (lcmd == "linux" || lcmd == "linux16")) {
            seen = 1
            print "linux\t" inkali "\t" entry "\t" L[k] "\t" clean((k < nw) ? W[k + 1] : "")
            for (j = k + 2; j <= nw; j++) print "param\t" inkali "\t" entry "\t" clean(W[j])
        }
    }
    nw = 0
}

# Return the index of the title among the words after the command W[K], or 0 when there is
# none: the first word that is no option, as GRUB's argument parser takes it, which also passes
# over the value after --class, --users, --hotkey, --id or --source written without "=".
function titleat(k,    j) {
    for (j = k + 1; j <= nw; j++) {
        if (W[j] !~ /^--/) return j
        if (W[j] ~ /^--(class|users|hotkey|id|source)$/ && j < nw && W[j + 1] !~ /^-/) j++
    }
    return 0
}

# Open a block for the statement before "{", or for the one before it when the brace stands
# on a line of its own: a top-level submenu with a quoted title that holds Kali starts a Kali
# block, and a menu entry inside one starts an entry. Options before the title pass over.
function openblock(    k, t, cmd, title, rawtitle, line) {
    if (nw) {
        for (k = 1; k <= nw && (W[k] in keyword); k++) ;
        cmd = ""
        if (k <= nw) {
            cmd = W[k]; line = L[k]; t = titleat(k)
            title = t ? W[t] : ""; rawtitle = t ? R[t] : ""
        }
        nw = 0
    } else {
        cmd = lcmd; line = lline; title = ltitle; rawtitle = lraw
    }
    lcmd = ""
    depth++
    type[depth] = cmd
    if (depth == 1 && cmd == "submenu" && rawtitle ~ /^["']/ && index(title, "Kali")) {
        kali++; inkali = kali; entry = 0
        start[kali] = line; raw_title[kali] = rawtitle
        if (inmark) marked[kali] = 1
        tidy[kali] = (text[line] ~ /^[ \t]*submenu[ \t]/)
    } else if (cmd == "menuentry" && inkali && !inentry) {
        entry++; inentry = depth; seen = 0
        print "entry\t" inkali "\t" entry "\t" line "\t" clean(title)
    }
}

# Close the innermost block; REST is what follows the brace on its line. Closing a Kali
# submenu prints its record.
function closeblock(rest) {
    if (depth == 0) { bad = 1; return }
    if (depth == 1 && inkali) {
        sub(/\n$/, "", rest)
        if (rest !~ /^[ \t]*(#.*)?$/) tidy[inkali] = 0
        print "kali\t" inkali "\t" start[inkali] "\t" ln "\t" (marked[inkali] ? 1 : 0) "\t" \
            tidy[inkali] "\t" clean(raw_title[inkali])
        inkali = 0
    }
    if (inentry == depth) inentry = 0
    depth--
}

# Return S with each control character turned into DEL.
function clean(s,    out, i, c, n) {
    out = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (index(ctl, c)) c = del
        out = out c
    }
    return out
}
