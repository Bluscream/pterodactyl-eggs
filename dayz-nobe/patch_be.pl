#!/usr/bin/env perl
use strict;
use warnings;

my $target = $ARGV[0] // "DayZServer";

# --- 1. Enforce/Respect BattlEye Setting in serverDZ.cfg ---
# NOTE: Commented out because Pterodactyl's egg configuration parser already
# natively parses and manages serverDZ.cfg variables (including battleye = {{env.ENABLE_BATTLEYE}};).
# Retained as a comment in case patch_be.pl is executed standalone outside of Pterodactyl.
#
# if (-f "serverDZ.cfg") {
#     my $enable_be = $ENV{ENABLE_BATTLEYE} // "0";
#     my $be_val = ($enable_be eq "1") ? 1 : 0;
#
#     open(my $in, "<", "serverDZ.cfg");
#     my @lines = <$in>;
#     close($in);
#
#     my $found_be = 0;
#     for (@lines) {
#         if (/^\s*battleye\s*=/i) {
#             $_ = "battleye = $be_val;\n";
#             $found_be = 1;
#         }
#     }
#     push @lines, "battleye = $be_val;\n" unless $found_be;
#
#     open(my $out, ">", "serverDZ.cfg");
#     print $out @lines;
#     close($out);
# }

# --- 2. Patch Binary Memory/Signatures ---
exit 0 unless -f $target;

open(my $fh, "+<:raw", $target) or exit 0;
read($fh, my $buf, -s $target);

# Check if already patched (quick check for Linux)
if (length($buf) > 0x11e9e13 && substr($buf, 0x11e9e10, 3) eq "\xb0\x01\xc3") {
    close($fh);
    exit 0;
}

my @sigs = (
    # Linux x64 DayZServer Init signature
    pack("H*", "4155415455534889fb4881ec28010000c70700000000c6471000"),
    # Linux fallback
    pack("H*", "4155415455534889fb4881ec28010000"),
    # Windows x64 DayZServer_x64.exe signatures
    pack("H*", "405355565741544881ec"),
    pack("H*", "48895c240848896c2410565741564881ec")
);

my $patched = 0;
for my $pat (@sigs) {
    my $pos = index($buf, $pat);
    if ($pos != -1) {
        seek($fh, $pos, 0);
        print $fh pack("C*", 0xb0, 0x01, 0xc3);
        $patched = 1;
        last;
    }
}

close($fh);
