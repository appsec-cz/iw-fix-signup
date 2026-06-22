#!/usr/bin/env bash
#==============================================================================
# iw-fix-signup.sh
#
# Mitigation for the IceWarp WebClient signup / path-traversal issue.
# It performs two changes:
#
#   1) XML  (config/_webmail/settings.xml)
#        <restrictions>:    disable_signup=1, disable_signup_ip=1
#        <layout_settings>: disable_signup=1
#
#   2) PHP  (html/_shared/tools/filesystem.php)
#        Injects a path-traversal guard into the downloadFile() function:
#          if (preg_match('/\.\./',$path)) { throw new Exc('invalid_path'); }
#
# Features:
#   - Auto-detects the install dir: /etc/icewarp/icewarp.conf (IWS_INSTALL_DIR),
#     then common locations / running daemon.
#   - Load-balanced (LB) clusters: reads path.dat for the shared config folder.
#   - Read-only shared config in LB: warns and continues with the PHP hotfix.
#   - Timestamped backups, idempotent, verification, optional Control restart.
#
# Usage:   sudo ./iw-fix-signup.sh [options]
# Options:
#   -p, --path DIR     Explicit IceWarp installation folder
#       --config DIR    Explicit webmail config root (folder containing _webmail)
#   -n, --no-restart   Do not restart the Control module
#       --dry-run      Show changes, write nothing
#   -h, --help         Show help
#
# Exit: 0 OK | 2 bad arg | 3 install not found | 4 write error | 5 verify failed
#==============================================================================
set -uo pipefail

CONF_DEFAULT="${ICEWARP_CONF:-/etc/icewarp/icewarp.conf}"
INSTALL_DIR=""
CONFIG_ROOT_OVR=""
DO_RESTART=1
DRY_RUN=0
LB_ENV=0
PROG="$(basename "$0")"
RC=0   # overall result

info() { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

#------------------------------------------------------------------ arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--path)   [[ $# -ge 2 ]] || die "Option $1 requires a value" 2; INSTALL_DIR="$2"; shift 2;;
        --config)    [[ $# -ge 2 ]] || die "Option $1 requires a value" 2; CONFIG_ROOT_OVR="$2"; shift 2;;
        -n|--no-restart) DO_RESTART=0; shift;;
        --dry-run)   DRY_RUN=1; shift;;
        -h|--help)   usage; exit 0;;
        *) die "Unknown option: $1 (try --help)" 2;;
    esac
done

#------------------------------------------------------------------ detection
# A plausible IceWarp root: a dir that has icewarpd.sh, or config/, or html/.
looks_like_root() {
    local d="${1:-}"
    [[ -n "$d" && -d "$d" ]] || return 1
    [[ -x "$d/icewarpd.sh" || -d "$d/config" || -d "$d/html" ]]
}

read_conf_install_dir() {
    local conf="$1" v
    [[ -f "$conf" ]] || return 1
    v="$(grep -E '^[[:space:]]*IWS_INSTALL_DIR=' "$conf" 2>/dev/null | tail -n1 | cut -d= -f2- \
         | sed "s/^[[:space:]]*//; s/[[:space:]]*$//; s/^[\"']//; s/[\"']$//")"
    [[ -n "$v" ]] && printf '%s\n' "$v"
}

detect_install_dir() {
    local -a cands=()
    local c es pid exe conf

    [[ -n "$INSTALL_DIR" ]]       && cands+=("$INSTALL_DIR")
    [[ -n "${ICEWARP_HOME:-}" ]]  && cands+=("$ICEWARP_HOME")

    # /etc/icewarp/icewarp.conf -> IWS_INSTALL_DIR  (authoritative)
    for conf in "$CONF_DEFAULT" /etc/icewarp/icewarp/conf; do
        c="$(read_conf_install_dir "$conf")" && [[ -n "$c" ]] && cands+=("$c")
    done

    cands+=("/opt/icewarp")

    command -v icewarpd.sh >/dev/null 2>&1 && cands+=("$(dirname "$(command -v icewarpd.sh)")")

    if command -v systemctl >/dev/null 2>&1; then
        es="$(systemctl show -p ExecStart icewarp 2>/dev/null | grep -oE '/[^ ;]*icewarpd\.sh' | head -1)"
        [[ -n "$es" ]] && cands+=("$(dirname "$es")")
    fi
    if command -v pgrep >/dev/null 2>&1; then
        while read -r pid; do
            [[ -n "$pid" ]] || continue
            exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)" || continue
            [[ -n "$exe" ]] && cands+=("$(dirname "$exe")")
        done < <(pgrep -f 'icewarpd' 2>/dev/null)
    fi
    cands+=("/usr/local/icewarp" "/opt/IceWarp")

    for c in "${cands[@]}"; do
        [[ -z "$c" ]] && continue
        c="${c%/}"
        looks_like_root "$c" && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# Determine the webmail config root (handles LB shared config via path.dat).
# Sets globals: CONFIG_ROOT and LB_ENV.
resolve_config() {
    local root="$1" path_dat shared
    if [[ -n "$CONFIG_ROOT_OVR" ]]; then CONFIG_ROOT="${CONFIG_ROOT_OVR%/}"; return 0; fi
    path_dat="$root/path.dat"
    if [[ -f "$path_dat" ]]; then
        LB_ENV=1
        shared="$(head -n1 "$path_dat" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [[ -n "$shared" && -f "$shared/_webmail/settings.xml" ]]; then
            CONFIG_ROOT="${shared%/}"; return 0
        fi
        warn "path.dat found (LB environment) but shared settings.xml not at: $shared/_webmail/settings.xml"
        warn "Falling back to local config folder."
    fi
    CONFIG_ROOT="$root/config"
}

#------------------------------------------------------------------ helpers (perl)
make_helpers() {
    TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/iwfix.XXXXXX")" || die "mktemp failed" 4
    trap 'rm -rf "$TMPDIR_RUN"' EXIT

    cat > "$TMPDIR_RUN/xml.pl" <<'PERL'
use strict; use warnings;
local $/; my $content = <STDIN>;
my @sections = qw(restrictions layout_settings);
my %st;
sub set_or_insert {
    my ($body_ref, $name, $full, $after) = @_;
    if ($$body_ref =~ m{<\Q$name\E\b[^>]*>.*?</\Q$name\E>}s) {
        $$body_ref =~ s{(<\Q$name\E\b[^>]*>).*?(</\Q$name\E>)}{${1}1${2}}s;
        return 'set';
    }
    if (defined $after && $$body_ref =~ m{</\Q$after\E>}) {
        $$body_ref =~ s{(</\Q$after\E>)}{$1\n            $full}s; return 'inserted';
    }
    if ($$body_ref =~ s{(<item\b[^>]*>)}{$1\n            $full}s) { return 'inserted'; }
    return 'no-item';
}
for my $sec (@sections) {
    my $matched = 0;
    $content =~ s{(<\Q$sec\E\b[^>]*>)(.*?)(</\Q$sec\E>)}{
        $matched = 1; my ($open,$body,$close) = ($1,$2,$3);
        $st{"$sec/disable_signup"} = set_or_insert(\$body, 'disable_signup',
            '<disable_signup useraccess="view" domainadminaccess="view">1</disable_signup>', undef);
        if ($sec eq 'restrictions') {
            $st{"$sec/disable_signup_ip"} = set_or_insert(\$body, 'disable_signup_ip',
                '<disable_signup_ip>1</disable_signup_ip>', 'disable_signup');
        }
        $open.$body.$close;
    }gse;
    unless ($matched) {
        $st{"$sec/disable_signup"} = 'no-section';
        $st{"$sec/disable_signup_ip"} = 'no-section' if $sec eq 'restrictions';
    }
}
print STDERR "STATUS"; print STDERR " $_=$st{$_}" for sort keys %st; print STDERR "\n";
print $content;
for my $k (keys %st) { exit 3 if $st{$k} eq 'no-section' || $st{$k} eq 'no-item'; }
exit 0;
PERL

    cat > "$TMPDIR_RUN/xmlverify.pl" <<'PERL'
use strict; use warnings;
local $/; my $c = <STDIN>; my $ok = 1;
my @ck = (['restrictions','disable_signup'],['restrictions','disable_signup_ip'],['layout_settings','disable_signup']);
for my $r (@ck) {
    my ($sec,$el) = @$r;
    if ($c =~ m{<\Q$sec\E\b[^>]*>(.*?)</\Q$sec\E>}s) {
        my $b = $1;
        if ($b =~ m{<\Q$el\E\b[^>]*>(.*?)</\Q$el\E>}s) {
            my $v=$1; $v=~s/^\s+|\s+$//g; if ($v ne '1'){print STDERR "  $sec/$el=$v (want 1)\n";$ok=0;}
        } else { print STDERR "  $sec/$el missing\n"; $ok=0; }
    } else { print STDERR "  $sec missing\n"; $ok=0; }
}
exit($ok?0:1);
PERL

    cat > "$TMPDIR_RUN/php.pl" <<'PERL'
use strict; use warnings;
local $/; my $c = <STDIN>;
if ($c =~ /invalid_path/) { print $c; print STDERR "php=already\n"; exit 0; }
my $nl = ($c =~ /\r\n/) ? "\r\n" : "\n";
my $inj = "${nl}        if (preg_match('/\\.\\./',\$path)) { throw new Exc('invalid_path'); }";
if ($c =~ s/((?:(?:public|private|protected|static)\s+)*function\s+downloadFile\s*\([^)]*\)\s*\{)/$1 . $inj/se) {
    print $c; print STDERR "php=patched\n"; exit 0;
} else { print $c; print STDERR "php=nomatch\n"; exit 2; }
PERL
}

# Backup + atomic replace, preserving perms/owner. $1=target $2=newcontent-file
backup_and_write() {
    local target="$1" newf="$2" ts bak dir tmpw
    ts="$(date +%Y%m%d-%H%M%S)"; bak="${target}.bak.${ts}"
    cp -p "$target" "$bak" || return 1
    ok "Backup: $bak"
    dir="$(dirname "$target")"
    tmpw="$(mktemp "$dir/.iwtmp.XXXXXX")" || return 1
    cat "$newf" > "$tmpw" || { rm -f "$tmpw"; return 1; }
    chmod --reference="$target" "$tmpw" 2>/dev/null || true
    chown --reference="$target" "$tmpw" 2>/dev/null || true
    mv -f "$tmpw" "$target" || { rm -f "$tmpw"; return 1; }
    return 0
}

writable_target() { # file + its dir must be writable
    local f="$1"; [[ -w "$f" && -w "$(dirname "$f")" ]]
}

#------------------------------------------------------------------ start
command -v perl >/dev/null 2>&1 || die "'perl' is required (not found in PATH)." 1

info "Detecting IceWarp installation..."
ROOT="$(detect_install_dir)" || die "IceWarp installation not found. Use: $PROG --path /opt/icewarp" 3
ROOT="${ROOT%/}"
resolve_config "$ROOT"
SETTINGS="$CONFIG_ROOT/_webmail/settings.xml"
PHP_FILE="$ROOT/html/_shared/tools/filesystem.php"

ok   "Install dir : $ROOT"
info "Config root : $CONFIG_ROOT"
info "LB cluster  : $([[ $LB_ENV -eq 1 ]] && echo yes || echo no)"
info "Settings XML: $SETTINGS"
info "Filesystem  : $PHP_FILE"
echo "------------------------------------------------"

make_helpers

# Skeleton used when settings.xml does not exist yet (no XML declaration).
# It is passed through the SAME transform (which also adds disable_signup_ip),
# so a freshly created file is identical to modifying this minimal file.
SKELETON='<settings>
<restrictions><item><disable_signup useraccess="view" domainadminaccess="view">1</disable_signup></item></restrictions>
<layout_settings><item><disable_signup useraccess="view" domainadminaccess="view">1</disable_signup></item></layout_settings>
</settings>'

#========================= 1) XML =========================
if [[ ! -f "$SETTINGS" ]]; then
    # settings.xml does not exist -> create it from the skeleton (same transform).
    XMLDIR="$(dirname "$SETTINGS")"
    NEWXML="$TMPDIR_RUN/settings.new.xml"
    printf '%s\n' "$SKELETON" | perl "$TMPDIR_RUN/xml.pl" > "$NEWXML" 2>"$TMPDIR_RUN/xml.err"
    sed 's/^/    /' "$TMPDIR_RUN/xml.err" >&2 || true
    [[ -d "$XMLDIR" ]] || mkdir -p "$XMLDIR" 2>/dev/null || true
    if [[ $DRY_RUN -eq 1 ]]; then
        info "XML DRY-RUN: $SETTINGS does not exist - would CREATE it with:"
        sed 's/^/    | /' "$NEWXML" >&2
    elif [[ -d "$XMLDIR" && -w "$XMLDIR" ]]; then
        if cat "$NEWXML" > "$SETTINGS"; then
            if perl "$TMPDIR_RUN/xmlverify.pl" < "$SETTINGS"; then ok "XML: created ($SETTINGS) and verified."
            else die "XML create verification failed." 5; fi
        else
            if [[ $LB_ENV -eq 1 ]]; then warn "XML: cannot create settings.xml (LB read-only). Continuing with PHP hotfix."
            else die "Cannot create settings.xml: $SETTINGS (run as root: sudo $PROG)" 4; fi
        fi
    else
        if [[ $LB_ENV -eq 1 ]]; then warn "XML: config dir not writable (LB): $XMLDIR. Continuing with PHP hotfix."
        else die "Config directory not writable: $XMLDIR (run as root: sudo $PROG)" 4; fi
    fi
else
    NEWXML="$TMPDIR_RUN/settings.new.xml"
    if perl "$TMPDIR_RUN/xml.pl" < "$SETTINGS" > "$NEWXML" 2>"$TMPDIR_RUN/xml.err"; then
        sed 's/^/    /' "$TMPDIR_RUN/xml.err" >&2 || true
        if cmp -s "$SETTINGS" "$NEWXML"; then
            ok "XML: already set (no change)."
        elif [[ $DRY_RUN -eq 1 ]]; then
            info "XML DRY-RUN diff:"; diff -u "$SETTINGS" "$NEWXML" || true
        elif writable_target "$SETTINGS"; then
            if backup_and_write "$SETTINGS" "$NEWXML"; then
                if perl "$TMPDIR_RUN/xmlverify.pl" < "$SETTINGS"; then
                    ok "XML: updated and verified."
                else die "XML verification failed. Restore the .bak file." 5; fi
            else die "XML write failed." 4; fi
        else
            if [[ $LB_ENV -eq 1 ]]; then
                warn "XML: settings.xml is read-only (LB shared config). Update it on the writable/master node."
                warn "Continuing with the local PHP hotfix."
            else
                die "settings.xml is not writable: $SETTINGS (run as root: sudo $PROG)" 4
            fi
        fi
    else
        sed 's/^/    /' "$TMPDIR_RUN/xml.err" >&2 || true
        warn "XML: required section/<item> not found - left unchanged."
        RC=3
    fi
fi
echo "------------------------------------------------"

#========================= 2) PHP =========================
if [[ ! -f "$PHP_FILE" ]]; then
    warn "filesystem.php not found - PHP hotfix NOT applied ($PHP_FILE)"
    warn "The path-traversal mitigation is incomplete on this node."
    RC=3
else
    NEWPHP="$TMPDIR_RUN/filesystem.new.php"
    perl "$TMPDIR_RUN/php.pl" < "$PHP_FILE" > "$NEWPHP" 2>"$TMPDIR_RUN/php.err"; PRC=$?
    PST="$(cat "$TMPDIR_RUN/php.err")"
    if [[ "$PST" == *already* ]]; then
        ok "PHP: guard already present (no change)."
    elif [[ $PRC -ne 0 || "$PST" == *nomatch* ]]; then
        warn "PHP: downloadFile() not found - left unchanged. Apply the guard manually."
        RC=3
    elif [[ $DRY_RUN -eq 1 ]]; then
        info "PHP DRY-RUN diff:"; diff -u "$PHP_FILE" "$NEWPHP" || true
    elif writable_target "$PHP_FILE"; then
        if backup_and_write "$PHP_FILE" "$NEWPHP"; then
            if grep -qF "invalid_path" "$PHP_FILE" && grep -qF "preg_match('/\\.\\./'" "$PHP_FILE"; then
                ok "PHP: guard injected and verified."
            else die "PHP verification failed. Restore the .bak file." 5; fi
        else die "PHP write failed." 4; fi
    else
        die "filesystem.php is not writable: $PHP_FILE (run as root: sudo $PROG)" 4
    fi
fi
echo "------------------------------------------------"

#========================= 3) restart =========================
if [[ $DRY_RUN -eq 1 ]]; then
    info "DRY-RUN complete - nothing was written."
    exit 0
fi
if [[ $DO_RESTART -eq 1 ]]; then
    IWD="$ROOT/icewarpd.sh"
    if [[ -x "$IWD" ]]; then
        info "Restarting the Control module..."
        if "$IWD" --restart control; then ok "Control module restarted."
        else warn "Restart failed. Run manually: $IWD --restart control"; fi
    else
        warn "icewarpd.sh not found. Restart Control manually: <install>/icewarpd.sh --restart control"
    fi
else
    info "Restart skipped (--no-restart). Apply with: $ROOT/icewarpd.sh --restart control"
fi

echo "------------------------------------------------"
if [[ $RC -eq 0 ]]; then ok "Done. Mitigation applied successfully."
else warn "Done with warnings - review the messages above; mitigation may be incomplete."; fi
echo "Note: this is a mitigation. Upgrade to a fixed IceWarp build when available."
exit $RC
