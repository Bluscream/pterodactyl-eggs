#!/usr/bin/env perl
use strict;
use warnings;

my $target = $ARGV[0] // "DayZServer";

# This script ONLY patches the binary. It deliberately does not touch serverDZ.cfg.
#
# It used to carry a (commented-out) block that rewrote `battleye = N;` from an ENABLE_BATTLEYE
# environment variable. That block is gone rather than commented, because a second thing able
# to decide BattlEye state is worse than no fallback at all: setup.sh owns that decision
# via DISABLE_BATTLEYE, and it writes serverDZ.cfg itself. Patching here while some other code
# path sets battleye = 1 yields a server that is patched but claims BattlEye is on.
#
# Run standalone, this patches and nothing else -- caller's job to set battleye = 0 to match.

# --- Patch Binary Memory/Signatures ---
unless (-f $target) {
    print STDERR "[BattlEye-Patcher] ERROR: Target binary '$target' not found. Server will start UNPATCHED.\n";
    exit 1;
}

open(my $fh, "+<:raw", $target)
    or do { print STDERR "[BattlEye-Patcher] ERROR: Cannot open '$target' for writing: $!\n"; exit 1; };
read($fh, my $buf, -s $target);

# Check if already patched (quick check for Linux)
if (length($buf) > 0x11e9e13 && substr($buf, 0x11e9e10, 3) eq "\xb0\x01\xc3") {
    print "[BattlEye-Patcher] $target is already patched.\n";
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
        print "[BattlEye-Patcher] Successfully applied memory patch to $target at offset $pos.\n";
        last;
    }
}

close($fh);

if (!$patched) {
    print STDERR "[BattlEye-Patcher] WARNING: Signature not found in $target. Binary may be incompatible or already modified.\n";
    exit 1;
}

exit 0;
