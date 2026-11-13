#!/usr/bin/env bats
# -------------------------------------------------------
# kernel-updater menu checks
#
# Runs the parts of migrate that read and write GRUB menus as a command runs them: menu.awk's
# scan of the Kali submenu, with braces in quotes and comments, options before titles, nested
# entries, CRLF and LF, none, two and a marked one; the kernel parameters taken from the legacy
# entries and each rewrite, and how a plan shows the parameters; kali.cfg rendered from its
# template, which must equal tests/fixtures/grub's kali.expected.cfg; the new grub.cfg, which
# must equal migrate-after.cfg, also with far more after the submenu than a pipe holds, with
# the byte guard that refuses a change outside the submenu; and finalize's removal of the legacy
# entries.
# -------------------------------------------------------

# shellcheck disable=SC2016 # the code run_ku_lib runs expands its own variables
load helpers

FIXTURES="$TESTS_DIR/fixtures/grub"

# The identity of the fixtures' /boot and root device, and a private directory for the stages'
# files.
setup() {
    stub_init
    ROOT="$BATS_TEST_TMPDIR/root" WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$ROOT/etc" "$WORK"
    printf '%s\n' 'boot_fs_uuid = 5ca1ab1e-0000-4000-8000-000000000b01' \
        'boot_luks_uuid = 5ca1ab1e-0000-4000-8000-000000000c01' \
        'root_device = /dev/mapper/kali--vg-root' > "$ROOT/etc/kernel-updater.conf"
    sed 's/$/\r/' "$FIXTURES/migrate-before.cfg" > "$WORK/before.cfg"
    sed 's/$/\r/' "$FIXTURES/migrate-after.cfg" > "$WORK/after.cfg"
}

# Write the GRUB config FILE from the LINES given, LF ended.
config() {
    local file=$1
    shift
    printf '%s\n' "$@" > "$file"
}

# Run CODE with the private directory WORK, and the menu variants of the configuration.
run_menu() {
    run_ku_lib 'KU_MG_TMP=$1; _ku_mg_variants; shift; eval "$1"' "$WORK" "$@"
}

# Print what _ku_mg_scan read of FILE: one line per Kali submenu, then per entry its title, the
# line of its linux command and its words after the kernel.
scan() {
    run_menu '_ku_mg_scan "$2"
        for (( n = 1; n <= KU_MG_COUNT; n++ )); do
            printf "kali %s %s %s %s %s %s\n" "$n" "${KU_MG_START[$n]}" "${KU_MG_END[$n]}" \
                "${KU_MG_MARKED[$n]}" "${KU_MG_TIDY[$n]}" "${KU_MG_RAWTITLE[$n]}"
        done
        for key in "${KU_MG_ENTRIES[@]}"; do
            printf "%s|%s|%s|%s\n" "$key" "${KU_MG_ENTRY[$key]}" "${KU_MG_LINUX[$key]-none}" \
                "$(printf "%s" "${KU_MG_WORDS[$key]-}" | tr "\n" " ")"
        done
        printf "unbalanced %s\n" "$KU_MG_UNBALANCED"' "$1"
}

@test "The scan finds the one Kali submenu, whatever braces quotes and comments hold" {
    local file
    for file in "$FIXTURES/migrate-before.cfg" "$WORK/before.cfg"; do
        scan "$file"
        [ "$status" -eq 0 ]
        [ "${lines[0]}" = 'kali 1 57 129 0 1 "Kali GNU/Linux amd64 (full install)"' ]
        [ "${lines[1]}" = "1.1|Kali GNU/Linux (persistence)|71|root=/dev/mapper/kali--vg-root \
cryptdevice=UUID=5ca1ab1e-0000-4000-8000-000000000c02:root_crypt ro quiet splash " ]
        [ "${lines[2]}" = "1.2|Kali GNU/Linux (fail-safe mode)|89|root=/dev/mapper/kali--vg-root \
ro nomodeset noapic nolapic nosplash " ]
        [[ "${lines[3]}" == "1.3|Kali GNU/Linux (live mode)|107|"*" overlayroot=tmpfs:resurce=0 " ]]
        [[ "${lines[4]}" == "1.4|Kali GNU/Linux (forensic mode)|125|"*" noswap noautomount " ]]
        [ "${lines[5]}" = "unbalanced 0" ]
        [ "${#lines[@]}" -eq 6 ]
    done
}

@test "Nested blocks, unquoted titles and other submenus are told apart from the Kali one" {
    config "$WORK/nested.cfg" 'submenu "Tools" {' '    submenu "Kali tools" {' \
        '        menuentry "x" { true; }' '    }' '}' "submenu Kali {" "}" \
        "submenu 'Kali (single quotes)' --class kali {" '    submenu "inner" {' \
        '        menuentry "Kali deep" {' '            linux /vmlinuz-9 ro "quoted word"' \
        '        }' '    }' '    menuentry "no kernel" {' '        reboot' '    }' '}'
    scan "$WORK/nested.cfg"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "kali 1 8 17 0 1 'Kali (single quotes)'" ]
    [ "${lines[1]}" = "1.1|Kali deep|11|ro quoted word " ]
    [ "${lines[2]}" = "1.2|no kernel|none|" ]
    [ "${lines[3]}" = "unbalanced 0" ]
}

@test "Options before a title are passed over, as GRUB's argument parser passes them" {
    config "$WORK/options.cfg" 'submenu --class kali "Kali GNU/Linux" {' \
        '    menuentry --class kali --id=k "Kali" {' '        linux /vmlinuz-9 ro quiet' '    }' \
        '    menuentry --unrestricted --users root "Kali (fail-safe)"' '    {' \
        '        linux /vmlinuz-9 ro single' '    }' '}'
    scan "$WORK/options.cfg"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = 'kali 1 1 9 0 1 "Kali GNU/Linux"' ]
    [ "${lines[1]}" = "1.1|Kali|3|ro quiet " ]
    [ "${lines[2]}" = "1.2|Kali (fail-safe)|7|ro single " ]
    run_menu '_ku_mg_scan_one "$2" "" 1; _ku_mg_derive 1
        printf "%s\n" "${KU_MG_PARAMS[failsafe]}"' "$WORK/options.cfg"
    [ "$status" -eq 0 ]
    [ "$output" = "ro single" ]
    # migrate adds " (legacy entries)" to a title right after submenu only.
    run_menu '_ku_mg_scan_one "$2" "" 1; _ku_mg_title 1
        _ku_mg_menu_block "$2" 1 "$KU_MG_TITLE" "$KU_MG_TMP/repl"' "$WORK/options.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"is not one quoted string right after submenu, before any option such"* ]]
}

@test "Zero, two, an unbalanced or a marked Kali submenu is refused with exit 3" {
    local one='_ku_mg_scan_one "$2" "" 1; printf "%s\n" "$KU_MG_FOUND"'
    config "$WORK/none.cfg" 'menuentry "Kali" {' '}'
    run_menu "$one" "$WORK/none.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"grub.cfg holds 0 Kali submenus; migrate needs exactly one"* ]]
    config "$WORK/two.cfg" 'submenu "Kali A" {' '}' 'submenu "Kali B" {' '}'
    run_menu "$one" "$WORK/two.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"grub.cfg holds 2 Kali submenus"* ]]
    config "$WORK/open.cfg" 'submenu "Kali" {' '    menuentry "x" {' '}'
    run_menu "$one" "$WORK/open.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the braces or quotes of grub.cfg do not balance"* ]]
    config "$WORK/marked.cfg" '#start kali' 'submenu "Kali" {' '    menuentry "x" {' '    }' '}' \
        '#end kali'
    run_menu "$one" "$WORK/marked.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"lies between MultiBootUSB's #start and #end markers"* ]]
    # A marker line inside the submenu marks it too.
    config "$WORK/marked.cfg" 'submenu "Kali" {' '#end kali' '}'
    run_menu "$one" "$WORK/marked.cfg"
    [ "$status" -eq 3 ]
    # A closing brace that shares its line with another command.
    config "$WORK/shared.cfg" 'submenu "Kali" {' '    menuentry "x" {' '    }' '}; echo after'
    run_menu "$one" "$WORK/shared.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"shares its first or last line with other commands"* ]]
    config "$WORK/tidy.cfg" 'submenu "Kali" {' '    menuentry "x" {' '    }' '}  # done'
    run_menu "$one" "$WORK/tidy.cfg"
    [ "$status" -eq 0 ]
    [ "$output" = 1 ]
}

@test "The parameters come from the legacy entries, and each rewrite is noted" {
    local uuid=5ca1ab1e-0000-4000-8000-000000000b09 rd=/dev/mapper/kali--vg-root
    # The first linux command runs over three lines, as backslashes continue it.
    config "$WORK/rewrites.cfg" 'submenu "Kali" {' '    menuentry "Kali" {' \
        "        linux /vmlinuz-9 BOOT_IMAGE=/vmlinuz-9 root=UUID=$uuid ro \\" \
        "            initrd=/initrd.img-9 cryptdevice=/dev/sda2:root noswap quiet \\" \
        '            systemd.swap=0 noswap' '    }' \
        '    menuentry "Kali (failsafe)" { linux /vmlinuz-9 ro single; }' \
        '    menuentry "Kali (recovery)" { linux /vmlinuz-9 ro recovery; }' \
        '    menuentry "Kali (live)" {' \
        "        linux /vmlinuz-9 root=$rd overlayroot=tmpfs:resurce=0,swap=1" '    }' \
        '    menuentry "Kali (fail-safe again)" { linux /vmlinuz-9 ro; }' \
        '    menuentry "Kali reboot" { reboot; }' '}'
    printf 'menu_variants = default, failsafe,live ,forensic\n' >> "$ROOT/etc/kernel-updater.conf"
    run_menu '_ku_mg_scan_one "$2" "" 1; _ku_mg_derive 1
        for v in "${KU_MG_MENU[@]}"; do printf "%s=%s\n" "$v" "${KU_MG_PARAMS[$v]}"; done
        printf "note %s\n" "${KU_MG_NOTES[@]}"; printf "left %s\n" "${KU_MG_LEFT[@]}"
        printf "from %s\n" "${KU_MG_FROM[forensic]}"' "$WORK/rewrites.cfg"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "default=ro systemd.swap=0 quiet" ]
    [ "${lines[1]}" = "failsafe=ro single" ]
    [ "${lines[2]}" = "live=overlayroot=tmpfs:recurse=0,swap=1" ]
    [ "${lines[3]}" = "forensic=ro quiet splash overlayroot=tmpfs systemd.swap=0 noautomount" ]
    [[ "$output" == *"note default: BOOT_IMAGE= goes, as GRUB passes it itself"* ]]
    [[ "$output" == *"note default: initrd= goes, as the initrd command loads the initrd"* ]]
    [[ "$output" == *"note default: cryptdevice= goes, as Debian's initramfs ignores it"* ]]
    [[ "$output" == *"note default: noswap, which does nothing on an installed system, becomes"* ]]
    [[ "$output" == *"note default: root= becomes root=<root_device>, another device than"* ]]
    [[ "$output" == *"note live: overlayroot's resurce= becomes recurse="* ]]
    [[ "$output" != *"note live: root="* ]]
    [[ "$output" == *"note failsafe: root=<root_device> is added, as the legacy entry has no"* ]]
    [[ "$output" == *'left "Kali (recovery)", as an earlier entry is the default one'* ]]
    [[ "$output" == *'left "Kali (fail-safe again)", as an earlier entry is the failsafe one'* ]]
    [[ "$output" == *'left "Kali reboot", which has no linux command'* ]]
    [[ "$output" == *"from the built-in ones, as no legacy entry is a forensic one"* ]]
    # Each note comes once, and no value of the old root= or cryptdevice= shows.
    [ "$(grep -c 'noswap, which' <<< "$output")" -eq 1 ]
    [[ "${output,,}" != *5ca1ab1e* && "$output" != */dev/sda* ]]
}

@test "A plan shows the parameters that may name a device, an identifier or a key as <value>" {
    local words='ro quiet resume=UUID=5ca1ab1e-0000-4000-8000-0000000000d1 rd.luks.key=/k.key'
    words+=' resume=/dev/sdb5 root=PARTUUID=5ca1ab1e-02 resume=LABEL=swap 5ca1ab1e x=0123456789'
    words+=' nomodeset overlayroot=tmpfs:recurse=0'
    run_menu 'printf "[%s]\n" "$(_ku_mg_shown_params "$2")"' "$words"
    [ "$status" -eq 0 ]
    [ "$output" = "[ ro quiet resume=<value> rd.luks.key=<value> resume=<value> root=<value> \
resume=<value> <value> x=<value> nomodeset overlayroot=tmpfs:recurse=0]" ]
    run_menu 'printf "[%s]\n" "$(_ku_mg_shown_params "")"'
    [ "$output" = "[]" ]
}

@test "A word that cannot be carried over exits 3 naming the variant, not the word" {
    config "$WORK/odd.cfg" 'submenu "Kali" {' \
        '    menuentry "Kali (fail-safe)" { linux /vmlinuz-9 ro "acpi_osi=Windows 2009"; }' '}'
    run_menu '_ku_mg_scan_one "$2" "" 1; _ku_mg_derive 1' "$WORK/odd.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the legacy failsafe entry passes the kernel a word with other characters"* ]]
    [[ "$stderr" != *Windows* ]]
    config "$WORK/odd.cfg" 'submenu "Kali" {' \
        '    menuentry "Kali" { linux /vmlinuz-9 ro init=$init; }' '}'
    run_menu '_ku_mg_scan_one "$2" "" 1; _ku_mg_derive 1' "$WORK/odd.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the legacy default entry passes the kernel a word"* ]]
}

@test "kali.cfg rendered for the fixture equals kali.expected.cfg, without kernel versions" {
    run_menu '_ku_mg_scan_one "$2" "" 1; _ku_mg_title 1; _ku_mg_derive 1
        _ku_mg_render "$KU_MG_TMP/kali.cfg" "$KU_MG_TITLE"' "$WORK/before.cfg"
    [ "$status" -eq 0 ]
    cmp "$FIXTURES/kali.expected.cfg" "$WORK/kali.cfg"
    refute_line_match '7\.2\.9|#start|#end|load_video|&&|\|\|' "$WORK/kali.cfg"
    # It passes lint with GRUB 2.02's lists, without a finding.
    run_ku lint --porcelain "$FIXTURES/kali.expected.cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Every variant gets its entry, and previous_variants its previous-kernel twin" {
    printf '%s\n' 'menu_variants = default,failsafe,live,forensic' \
        'previous_variants = forensic,default' >> "$ROOT/etc/kernel-updater.conf"
    run_menu '_ku_mg_scan_one "$2" "" 1; _ku_mg_title 1; _ku_mg_derive 1
        _ku_mg_render "$KU_MG_TMP/kali.cfg" "$KU_MG_TITLE"' "$WORK/before.cfg"
    [ "$status" -eq 0 ]
    [ "$(grep -o -e '--id kali[a-z-]*' "$WORK/kali.cfg" | tr '\n' ' ')" = "--id kali \
--id kali-default --id kali-previous --id kali-failsafe --id kali-live --id kali-forensic \
--id kali-forensic-previous " ]
    # The live entry takes the legacy one's parameters, its resurce= mended; forensic's come
    # from the legacy entry too, noswap becoming systemd.swap=0.
    local root="root=/dev/mapper/kali--vg-root ro quiet splash"
    grep -q -x -F $'\t\t\t'"linux /vmlinuz $root overlayroot=tmpfs:recurse=0" "$WORK/kali.cfg"
    grep -q -x -F $'\t\t\t'"linux /vmlinuz.old $root overlayroot=tmpfs systemd.swap=0 noautomount" \
        "$WORK/kali.cfg"
    # A previous_variants the file sets must stay within menu_variants; the default narrows.
    printf 'menu_variants = default\nprevious_variants = default,failsafe\n' \
        > "$ROOT/etc/kernel-updater.conf"
    run_menu 'printf "%s\n" "${KU_MG_PREV[*]}"'
    [ "$status" -eq 78 ]
    [[ "$stderr" == *"previous_variants names failsafe, which menu_variants does not"* ]]
    printf 'menu_variants = default\n' > "$ROOT/etc/kernel-updater.conf"
    run_menu 'printf "%s\n" "${KU_MG_PREV[*]}"'
    [ "$status" -eq 0 ]
    [ "$output" = default ]
}

@test "The new grub.cfg equals migrate-after.cfg, CRLF or LF as the submenu's lines end" {
    local code='_ku_mg_scan_one "$2" "" 1; _ku_mg_title 1
        _ku_mg_menu_block "$2" 1 "$KU_MG_TITLE" "$KU_MG_TMP/repl"
        _ku_mg_splice "$2" "${KU_MG_START[1]}" "${KU_MG_END[1]}" "$KU_MG_TMP/repl" "$3"'
    run_menu "$code" "$WORK/before.cfg" "$WORK/new.cfg"
    [ "$status" -eq 0 ]
    cmp "$WORK/after.cfg" "$WORK/new.cfg"
    run_menu "$code" "$FIXTURES/migrate-before.cfg" "$WORK/new-lf.cfg"
    [ "$status" -eq 0 ]
    cmp "$FIXTURES/migrate-after.cfg" "$WORK/new-lf.cfg"
    # The marker line tells a migrated grub.cfg, whatever its line endings.
    run_menu 'ku_menu_sources_kali "$2" && ! ku_menu_sources_kali "$3"; ku_menu_legacy_count "$2"' \
        "$WORK/after.cfg" "$WORK/before.cfg"
    [ "$status" -eq 0 ]
    [ "$output" = 1 ]
}

@test "A grub.cfg with far more after the submenu than a pipe holds comes through whole" {
    local i
    # Under pipefail, a reader that stopped early would kill the writer before it with SIGPIPE.
    for (( i = 1; i <= 2500; i++ )); do
        printf 'menuentry "ISO %s" {\r\n\tlinux (loop)/live/vmlinuz findiso=/iso/%s.iso\r\n}\r\n' \
            "$i" "$i"
    done > "$WORK/isos.cfg"
    cat "$WORK/before.cfg" "$WORK/isos.cfg" > "$WORK/long.cfg"
    [ "$(wc -c < "$WORK/isos.cfg")" -gt 180000 ]
    run_menu '_ku_mg_scan_one "$2" "" 1; _ku_mg_title 1
        _ku_mg_menu_block "$2" 1 "$KU_MG_TITLE" "$KU_MG_TMP/repl"
        _ku_mg_splice "$2" "${KU_MG_START[1]}" "${KU_MG_END[1]}" "$KU_MG_TMP/repl" "$3"' \
        "$WORK/long.cfg" "$WORK/long-new.cfg"
    [ "$status" -eq 0 ]
    cat "$WORK/after.cfg" "$WORK/isos.cfg" > "$WORK/long-after.cfg"
    cmp "$WORK/long-after.cfg" "$WORK/long-new.cfg"
}

@test "The byte guard refuses a new grub.cfg that differs outside the submenu" {
    local guard='_ku_mg_guard "$2" "$3" 2000 412 1234'
    cp "$WORK/before.cfg" "$WORK/same.cfg"
    # Old: 2000 bytes before, the block, 412 after; new: the same 2000, 1234 of its own, the
    # same 412.
    head -c 2000 "$WORK/before.cfg" > "$WORK/new.cfg"
    head -c 1234 /dev/zero | tr '\0' x >> "$WORK/new.cfg"
    tail -c 412 "$WORK/before.cfg" >> "$WORK/new.cfg"
    run_menu "$guard" "$WORK/before.cfg" "$WORK/new.cfg"
    [ "$status" -eq 0 ]
    # One byte changed before the block, one after it, and one byte more in between.
    cp "$WORK/new.cfg" "$WORK/bad.cfg"
    poke_byte "$WORK/bad.cfg" 100
    run_menu "$guard" "$WORK/before.cfg" "$WORK/bad.cfg"
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"the new grub.cfg would differ from the old one outside the Kali submenu"* ]]
    cp "$WORK/new.cfg" "$WORK/bad.cfg"
    poke_byte "$WORK/bad.cfg" "$(( $(wc -c < "$WORK/new.cfg") - 3 ))"
    run_menu "$guard" "$WORK/before.cfg" "$WORK/bad.cfg"
    [ "$status" -eq 3 ]
    { cat "$WORK/new.cfg"; printf 'x'; } > "$WORK/bad.cfg"
    run_menu "$guard" "$WORK/before.cfg" "$WORK/bad.cfg"
    [ "$status" -eq 3 ]
}

@test "finalize's splice removes exactly the legacy submenu" {
    run_menu '_ku_mg_scan_one "$2" "$KU_MG_LEGACY" 0; n=$KU_MG_FOUND
        printf "%s %s\n" "${KU_MG_START[$n]}" "${KU_MG_END[$n]}"; : > "$KU_MG_TMP/empty"
        _ku_mg_splice "$2" "${KU_MG_START[$n]}" "${KU_MG_END[$n]}" "$KU_MG_TMP/empty" "$3"' \
        "$WORK/after.cfg" "$WORK/final.cfg"
    [ "$status" -eq 0 ]
    [ "$output" = "65 137" ]
    cmp <(head -n 64 "$WORK/after.cfg"; tail -n +138 "$WORK/after.cfg") "$WORK/final.cfg"
    # No legacy entries remain, and the source block stays.
    run_menu 'ku_menu_legacy_count "$2"; ku_menu_sources_kali "$2"' "$WORK/final.cfg"
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
    # A grub.cfg without legacy entries leaves nothing to find.
    run_menu '_ku_mg_scan_one "$2" "$KU_MG_LEGACY" 0; printf "%s\n" "$KU_MG_COUNT"' \
        "$WORK/final.cfg"
    [ "$output" = 0 ]
}

@test "Without grub-script-check, which checks the new menu, the stages refuse with exit 3" {
    # Only builtins run up to the refusal, so a PATH that finds nothing stands in for a system
    # without the package.
    run_menu 'PATH=/nonexistent; _ku_mg_need_check_tool'
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"grub-script-check, from the package grub-common, is needed to check the"* ]]
    [[ "$stderr" == *"new menu; nothing was changed"* ]]
}

@test "A real grub-script-check takes the rendered kali.cfg and both grub.cfg fixtures" {
    command -v grub-script-check > /dev/null ||
        skip "grub-script-check is not on PATH (package grub-common)"
    local cfg
    for cfg in "$FIXTURES/kali.expected.cfg" "$FIXTURES/migrate-before.cfg" \
        "$FIXTURES/migrate-after.cfg" "$WORK/after.cfg"; do
        run grub-script-check "$cfg"
        [ "$status" -eq 0 ] || { printf '%s: %s\n' "$cfg" "$output" >&2; return 1; }
    done
}

@test "menu.awk gives the same records under mawk and under gawk" {
    command -v mawk > /dev/null || skip "mawk is not on PATH"
    command -v gawk > /dev/null || skip "gawk is not on PATH"
    local awk
    for awk in mawk gawk; do
        LC_ALL=C KU_MENU_CFG="$WORK/before.cfg" "$awk" -f "$REPO_DIR/lib/kernel-updater/menu.awk" \
            > "$WORK/$awk.out"
    done
    cmp "$WORK/mawk.out" "$WORK/gawk.out"
    [ "$(grep -c '^param' "$WORK/gawk.out")" -eq 23 ]
}
